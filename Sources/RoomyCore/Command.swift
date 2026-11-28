import Foundation

/// Runs a command-line tool directly (no shell) with a time limit.
public enum Command {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// What the tool printed and its exit status, or nil when it could not start or took longer than `timeout`
    /// seconds, in which case it is stopped.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timedOut = Flag()
        let stop = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        guard !timedOut.isSet, process.terminationReason == .exit else { return nil }
        return Output(status: process.terminationStatus, stdout: data)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}
