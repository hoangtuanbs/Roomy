import Foundation

/// Cloud drives in `~/Library/CloudStorage` are served by an app (Google Drive, Dropbox, OneDrive…). When that app is
/// not running, even listing its folder can wait forever, because macOS waits for the app to answer. The folders
/// that can do this (`CloudStorage` itself and each account folder in it) are read on a thread of their own, and
/// after a short wait RoomyDisk gives up on them and shows them as not available.
public enum CloudGuard {
    /// True for `…/Library/CloudStorage` and the folders directly inside it.
    public static func isGuarded(_ path: String) -> Bool {
        if path.hasSuffix("/Library/CloudStorage") { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.hasSuffix("/Library/CloudStorage") && !(path as NSString).lastPathComponent.hasPrefix(".")
    }

    /// The service that serves an account folder, such as "Google Drive" for `GoogleDrive-anna@example.com`.
    public static func providerName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return CloudLocations.provider(folderName: name, rootPath: path)?.name ?? name
    }

    /// "Not available (Google Drive isn't running)".
    public static func unavailableNote(for path: String) -> String {
        String(format: String(localized: "Not available (%@ isn't running)"), providerName(of: path))
    }
}

/// Runs work that may never return on a thread of its own, and stops waiting after a time limit. While one call
/// for a key has not returned, later calls for that key give up at once instead of starting another thread, so a
/// stuck folder never ties up more than one thread.
public final class StallGuard: @unchecked Sendable {
    public enum Outcome<Value> {
        case finished(Value)
        case timedOut
    }

    private let lock = NSLock()
    private var waiting: Set<String> = []

    public init() {}

    public static let shared = StallGuard()

    /// True while an earlier call for `key` has not returned.
    public func isStuck(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting.contains(key)
    }

    public func run<Value>(key: String, timeout: TimeInterval, _ work: @escaping @Sendable () -> Value) -> Outcome<Value> {
        lock.lock()
        if waiting.contains(key) {
            lock.unlock()
            return .timedOut
        }
        waiting.insert(key)
        lock.unlock()

        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        // A thread of its own, not a shared queue: if it never returns, it holds no thread anyone else waits for.
        let thread = Thread { [weak self] in
            let value = work()
            box.set(value)
            self?.finished(key)
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        if done.wait(timeout: .now() + timeout) == .timedOut { return .timedOut }
        guard let value = box.get() else { return .timedOut }
        return .finished(value)
    }

    private func finished(_ key: String) {
        lock.lock()
        waiting.remove(key)
        lock.unlock()
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// How a folder was read.
enum GuardedListing {
    case entries([RawEntry])
    /// The folder could not be read.
    case unreadable
    /// A cloud folder whose app did not answer in time.
    case unavailable
}

/// Reads folders for scans. Folders that a cloud app serves (see `CloudGuard`) are read with a time limit; the rest
/// are read directly. Tests pass a reader that blocks.
public struct FolderReader: Sendable {
    /// How long to wait for a cloud folder.
    public var timeout: TimeInterval
    let read: @Sendable (_ path: String, _ clones: Bool) -> [RawEntry]?
    let stalls: StallGuard

    init(timeout: TimeInterval = 4, stalls: StallGuard = .shared,
         read: @escaping @Sendable (_ path: String, _ clones: Bool) -> [RawEntry]? = { DirectoryReader.list(path: $0, clones: $1) }) {
        self.timeout = timeout
        self.stalls = stalls
        self.read = read
    }

    /// Reads folders straight from the disk.
    public static let direct = FolderReader()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = FolderReader.direct

    /// The reader scans use when none is given. The app's flow test swaps it for one with a stuck cloud folder.
    public static var standard: FolderReader {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// A reader that treats folders named in `stuck` as cloud folders that never answer, and reads the rest from the
    /// disk. For the app's flow test; `release` lets the waiting reads finish.
    public static func withStuckFolders(_ stuck: Set<String>, timeout: TimeInterval, release: DispatchSemaphore) -> FolderReader {
        FolderReader(timeout: timeout, stalls: StallGuard()) { path, clones in
            if stuck.contains(path) {
                release.wait()
                release.signal()
            }
            return DirectoryReader.list(path: path, clones: clones)
        }
    }

    func list(_ path: String, clones: Bool = false) -> GuardedListing {
        guard CloudGuard.isGuarded(path) else {
            return read(path, clones).map(GuardedListing.entries) ?? .unreadable
        }
        let read = self.read
        switch stalls.run(key: path, timeout: timeout, { read(path, clones) }) {
        case .finished(let entries?): return .entries(entries)
        case .finished(nil): return .unreadable
        case .timedOut: return .unavailable
        }
    }

    /// The entries, or nil when the folder could not be read in time.
    func entries(_ path: String) -> [RawEntry]? {
        if case .entries(let entries) = list(path) { return entries }
        return nil
    }
}
