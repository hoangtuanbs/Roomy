import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// One change FSEvents recorded: a folder whose contents changed, with the event's flags.
public struct FolderChange: Sendable, Equatable {
    public let path: String
    public let flags: UInt32
    public let id: UInt64

    public init(path: String, flags: UInt32, id: UInt64 = 0) {
        self.path = path
        self.flags = flags
        self.id = id
    }
}

/// What a quick rescan has to do.
public enum RescanPlan: Equatable, Sendable {
    /// Nothing changed since the last scan.
    case upToDate
    /// List these folders again (only their own items), and scan these whole folders again, shallowest first.
    case patch(folders: [String], subtrees: [String])
    /// The history cannot be trusted; scan everything.
    case full(reason: String)
}

/// The FSEvents history of a folder: what changed in it since an event id, so a rescan only has to read those
/// folders. FSEvents keeps this history across restarts, for every disk that supports it.
public enum ChangeJournal {
    // From FSEvents.h, written out so their types stay simple.
    public static let mustScanSubDirs: UInt32 = 0x0001
    public static let userDropped: UInt32 = 0x0002
    public static let kernelDropped: UInt32 = 0x0004
    public static let eventIDsWrapped: UInt32 = 0x0008
    public static let historyDone: UInt32 = 0x0010
    public static let rootChanged: UInt32 = 0x0020
    public static let mount: UInt32 = 0x0040
    public static let unmount: UInt32 = 0x0080

    /// The newest event id, taken when a scan starts: everything that changes after it is in the history.
    public static func currentEventID() -> UInt64 {
        #if canImport(CoreServices)
        return FSEventsGetCurrentEventId()
        #else
        return 0
        #endif
    }

    /// The disk's identity, so a quick rescan never patches a scan of a different disk mounted at the same place.
    public static func volumeID(forPath path: String) -> String {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString ?? ""
    }

    // MARK: Planning (pure, so it can be tested)

    /// Turns the recorded changes under `root` into a plan. `aliases` are other spellings of the root that FSEvents
    /// may report, such as its path with links resolved (`/private/var/...` for `/var/...`).
    public static func plan(changes: [FolderChange], root rawRoot: String, aliases: [String] = []) -> RescanPlan {
        let root = DiskScanner.standardize(rawRoot)
        let spellings = ([root] + aliases.map(DiskScanner.standardize)).filter { !$0.isEmpty }
        var folders = Set<String>()
        var subtrees = Set<String>()

        for change in changes {
            if change.flags & (userDropped | kernelDropped) != 0 { return .full(reason: "events were dropped") }
            if change.flags & eventIDsWrapped != 0 { return .full(reason: "event ids wrapped") }
            if change.flags & rootChanged != 0 { return .full(reason: "the scanned folder moved") }
            if change.flags & historyDone != 0 && change.path.isEmpty { continue }

            let path = DiskScanner.standardize(change.path)
            guard let local = spellings.lazy.compactMap({ rebase(path, from: $0, to: root) }).first else {
                // A folder above the root: only a demand to rescan below it concerns us.
                if change.flags & mustScanSubDirs != 0, spellings.contains(where: { isInside($0, path) }) {
                    return .full(reason: "the history above the folder was coalesced")
                }
                continue
            }
            if change.flags & mustScanSubDirs != 0 {
                if local == root { return .full(reason: "the history of the folder was coalesced") }
                subtrees.insert(local)
            } else {
                folders.insert(local)
            }
        }

        // A folder inside one that is scanned whole needs nothing more, nor does a subtree inside another.
        let wholes = subtrees.filter { candidate in !subtrees.contains { $0 != candidate && isInside(candidate, $0) } }
        let lists = folders.filter { folder in !wholes.contains { folder == $0 || isInside(folder, $0) } }
        if wholes.isEmpty && lists.isEmpty { return .upToDate }
        return .patch(folders: lists.sorted(by: shallowFirst), subtrees: wholes.sorted(by: shallowFirst))
    }

    /// `path` written below `root` instead of `base`, or nil when it is not at or under `base`.
    static func rebase(_ path: String, from base: String, to root: String) -> String? {
        if path == base { return root }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return DiskScanner.join(root, String(path.dropFirst(prefix.count)))
    }

    /// True when `path` lies strictly inside `folder`.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path != folder && path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    static func shallowFirst(_ a: String, _ b: String) -> Bool {
        let da = a.split(separator: "/").count, db = b.split(separator: "/").count
        return da != db ? da < db : a < b
    }

    // MARK: Reading the history

    /// The folders under `root` that changed after event `since`, as FSEvents replays them, and the newest event id
    /// seen. Nil when the history could not be read in time.
    public static func changes(under root: String, since: UInt64,
                               timeout: Duration = .seconds(10)) async -> (changes: [FolderChange], lastID: UInt64)? {
        #if canImport(CoreServices)
        guard since > 0 else { return nil }
        let collector = EventCollector()
        let queue = DispatchQueue(label: "io.github.hoangtuanbs.Roomy.fsevents")
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let collector = Unmanaged<EventCollector>.fromOpaque(info).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var batch: [FolderChange] = []
            var done = false
            for i in 0..<count {
                let flag = UInt32(truncatingIfNeeded: flags[i])
                if flag & ChangeJournal.historyDone != 0 {
                    done = true
                    continue
                }
                batch.append(FolderChange(path: String(cString: names[i]), flags: flag, id: UInt64(ids[i])))
            }
            collector.add(batch, done: done)
        }
        // kFSEventStreamCreateFlagNoDefer: deliver at once.
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(since), 0, FSEventStreamCreateFlags(0x2)) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !collector.isDone && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
        guard collector.isDone else { return nil }
        let found = collector.changes
        return (found, max(since, found.map(\.id).max() ?? since))
        #else
        return nil
        #endif
    }
}

/// Gathers events on the stream's queue for the waiting task.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [FolderChange] = []
    private var done = false

    func add(_ batch: [FolderChange], done finished: Bool) {
        lock.lock()
        found.append(contentsOf: batch)
        if finished { done = true }
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var changes: [FolderChange] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
}
