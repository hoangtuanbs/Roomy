import Foundation

public struct CompressionResult: Sendable, Equatable {
    public let sourcePath: String
    public let archivePath: String?
    public let originalBytes: Int64
    public let archiveBytes: Int64
    public let trashedTo: String?
    public let error: String?

    public var succeeded: Bool { error == nil }
    public var savedBytes: Int64 { succeeded ? max(0, originalBytes - archiveBytes) : 0 }
}

/// Zips an item next to itself, checks the archive reads back, then moves the original to the Trash.
/// The original is only touched after the archive has been verified and saves enough space.
public struct CompressionService: Sendable {
    public let policy: SafetyPolicy
    public let trasher: Trasher
    public let history: CleanupHistory?
    /// The archive must be at least this much smaller than the original, or the original is kept.
    public let minimumSaving: Double

    public init(
        policy: SafetyPolicy = SafetyPolicy(),
        trasher: Trasher = SystemTrasher(),
        history: CleanupHistory? = .standard,
        minimumSaving: Double = 0.1
    ) {
        self.policy = policy
        self.trasher = trasher
        self.history = history
        self.minimumSaving = minimumSaving
    }

    /// A path next to the original that does not exist yet: `Name.zip`, `Name 2.zip`, …
    public static func archivePath(for rawPath: String) -> String {
        let path = DiskScanner.standardize(rawPath)
        let fm = FileManager.default
        var candidate = path + ".zip"
        var n = 2
        while fm.fileExists(atPath: candidate) {
            candidate = path + " \(n).zip"
            n += 1
        }
        return candidate
    }

    public func compressAndTrash(path rawPath: String, originalBytes: Int64) async -> CompressionResult {
        let path = DiskScanner.standardize(rawPath)
        func failure(_ message: String, archive: String? = nil, archiveBytes: Int64 = 0) -> CompressionResult {
            CompressionResult(sourcePath: path, archivePath: archive, originalBytes: originalBytes,
                              archiveBytes: archiveBytes, trashedTo: nil, error: message)
        }

        if case .blocked(let reason) = policy.verdict(for: path) { return failure(reason) }
        guard let entry = DirectoryReader.entry(atPath: path) else { return failure("This item no longer exists.") }
        guard entry.kind == .file || entry.kind == .directory else {
            return failure("Only files and folders can be compressed.")
        }
        guard originalBytes > 0 else { return failure("This item is empty.") }

        let parent = (path as NSString).deletingLastPathComponent
        if let available = Self.availableBytes(at: parent), available < originalBytes {
            return failure("There is not enough free space to make the archive. It can need up to \(ByteFormat.string(originalBytes)).")
        }

        #if os(macOS)
        let archive = Self.archivePath(for: path)
        func discardArchive() { try? FileManager.default.removeItem(atPath: archive) }

        do {
            let zipped = try await Self.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", path, archive])
            guard zipped == 0 else {
                discardArchive()
                return failure("The archive could not be created (ditto exit code \(zipped)). The original was not changed.")
            }
            let tested = try await Self.run("/usr/bin/unzip", ["-tqq", archive])
            guard tested == 0 else {
                discardArchive()
                return failure("The archive did not pass its check, so it was removed. The original was not changed.")
            }
        } catch {
            discardArchive()
            if error is CancellationError { return failure("Cancelled. The original was not changed.") }
            return failure("\(error.localizedDescription) The original was not changed.")
        }

        let archiveBytes = DirectoryReader.entry(atPath: archive)?.allocated ?? 0
        if Double(archiveBytes) > Double(originalBytes) * (1 - minimumSaving) {
            discardArchive()
            let percent = Int((minimumSaving * 100).rounded())
            return failure("Compressing would save less than \(percent)%, so Roomy kept the original and removed the archive.")
        }

        do {
            let destination = try trasher.moveToTrash(path: path)
            let result = CompressionResult(sourcePath: path, archivePath: archive, originalBytes: originalBytes,
                                           archiveBytes: archiveBytes, trashedTo: destination, error: nil)
            let record = CleanupResult(path: path, bytes: result.savedBytes, trashedTo: destination, error: nil)
            try? history?.append(CleanupReport(date: Date(), results: [record]))
            return result
        } catch {
            return failure("The archive was created, but the original could not be moved to the Trash: \(error.localizedDescription)",
                           archive: archive, archiveBytes: archiveBytes)
        }
        #else
        return failure("Compression is only available on macOS.")
        #endif
    }

    static func availableBytes(at path: String) -> Int64? {
        #if os(macOS)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    #if os(macOS)
    /// Runs a tool and waits for it; cancelling the task terminates the tool.
    static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        let box = ProcessBox()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.start(tool: tool, arguments: arguments, continuation: continuation)
            }
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        return status
    }
    #endif
}

#if os(macOS)
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(tool: String, arguments: [String], continuation: CheckedContinuation<Int32, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
        do {
            try process.run()
            self.process = process
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
#endif
