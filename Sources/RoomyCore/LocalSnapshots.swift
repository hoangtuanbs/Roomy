import Foundation

/// An APFS local snapshot, as `tmutil listlocalsnapshots` names it.
public struct LocalSnapshot: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// Such as `com.apple.TimeMachine.2026-11-20-101500.local`.
    public let name: String
    /// The date part of the name, such as `2026-11-20-101500`, which `tmutil deletelocalsnapshots` takes.
    public let dateStamp: String?
    public let date: Date?

    public init(name: String, dateStamp: String?, date: Date?) {
        self.name = name
        self.dateStamp = dateStamp
        self.date = date
    }

    /// Time Machine made it, so Time Machine can delete it. Others (such as macOS update snapshots) are left alone.
    public var isTimeMachine: Bool { name.hasPrefix("com.apple.TimeMachine.") }

    public var canDelete: Bool { isTimeMachine && dateStamp != nil }
}

/// What a command printed and how it ended.
public struct CommandOutput: Sendable, Equatable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }
}

public enum LocalSnapshotError: Error, LocalizedError, Equatable {
    case cannotDelete(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotDelete(let name): return String(format: String(localized: "%@ was not made by Time Machine, so RoomyDisk leaves it alone."), name)
        case .failed(let message): return message
        }
    }
}

/// Lists, deletes and thins local snapshots with `/usr/bin/tmutil`. Never needs admin rights:
/// it only touches Time Machine snapshots, and only one at a time unless thinning.
public enum LocalSnapshots {
    public static let tmutil = "/usr/bin/tmutil"

    // MARK: Parsing (pure, so it can be tested on sample output)

    /// Snapshots in the output of `tmutil listlocalsnapshots <disk>`, oldest first.
    /// Header lines such as `Snapshots for disk /:` and blank lines are skipped.
    public static func parseList(_ output: String, timeZone: TimeZone = .current) -> [LocalSnapshot] {
        var out: [LocalSnapshot] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasSuffix(":"), !line.contains(" ") else { continue }
            let stamp = dateStamp(in: line)
            out.append(LocalSnapshot(name: line, dateStamp: stamp, date: stamp.flatMap { date(fromStamp: $0, timeZone: timeZone) }))
        }
        return out.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?): return x < y
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil): return a.name < b.name
            }
        }
    }

    /// The first `YYYY-MM-DD-HHMMSS` in a snapshot name.
    public static func dateStamp(in name: String) -> String? {
        let chars = Array(name)
        let length = 17
        guard chars.count >= length else { return nil }
        for start in 0...(chars.count - length) {
            let candidate = String(chars[start..<(start + length)])
            guard isDateStamp(candidate) else { continue }
            // Not part of a longer run of digits.
            if start > 0, chars[start - 1].isASCII, chars[start - 1].isNumber { continue }
            let end = start + length
            if end < chars.count, chars[end].isASCII, chars[end].isNumber { continue }
            return candidate
        }
        return nil
    }

    /// True for exactly `YYYY-MM-DD-HHMMSS`: digits and dashes, nothing else.
    public static func isDateStamp(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count == 17 else { return false }
        for (i, c) in chars.enumerated() {
            if i == 4 || i == 7 || i == 10 {
                if c != "-" { return false }
            } else if !(c.isASCII && c.isNumber) {
                return false
            }
        }
        return date(fromStamp: text, timeZone: TimeZone(identifier: "UTC")!) != nil
    }

    /// Time Machine writes snapshot dates in local time.
    public static func date(fromStamp stamp: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        return formatter.date(from: stamp)
    }

    // MARK: Arguments (pure, so what gets deleted can be tested)

    public static func listArguments(mountPoint: String) -> [String] {
        ["listlocalsnapshots", mountPoint]
    }

    /// Arguments that delete exactly this snapshot, or nil when it is not a Time Machine snapshot with a date.
    /// `deletelocalsnapshots` also takes a mount point and then deletes every snapshot, so only a checked
    /// date stamp is ever passed.
    public static func deleteArguments(for snapshot: LocalSnapshot) -> [String]? {
        guard snapshot.isTimeMachine, let stamp = snapshot.dateStamp, isDateStamp(stamp),
              snapshot.name.contains(stamp)
        else { return nil }
        return ["deletelocalsnapshots", stamp]
    }

    /// Arguments that ask Time Machine to remove its local snapshots on a disk until `bytes` are free.
    /// Urgency runs from 1 (low) to 4 (high).
    public static func thinArguments(mountPoint: String, bytes: Int64, urgency: Int = 4) -> [String]? {
        guard bytes > 0, (1...4).contains(urgency), mountPoint.hasPrefix("/") else { return nil }
        return ["thinlocalsnapshots", mountPoint, String(bytes), String(urgency)]
    }

    // MARK: Running tmutil

    public static func list(mountPoint: String) async throws -> [LocalSnapshot] {
        let result = await run(listArguments(mountPoint: mountPoint))
        guard result.succeeded else { throw LocalSnapshotError.failed(message(from: result)) }
        return parseList(result.output)
    }

    /// Deletes one Time Machine snapshot. This cannot be undone.
    public static func delete(_ snapshot: LocalSnapshot) async throws {
        guard let arguments = deleteArguments(for: snapshot) else { throw LocalSnapshotError.cannotDelete(snapshot.name) }
        let result = await run(arguments)
        guard result.succeeded else { throw LocalSnapshotError.failed(message(from: result)) }
    }

    /// Lets Time Machine remove local snapshots until up to `bytes` are free. This cannot be undone.
    public static func thin(mountPoint: String, bytes: Int64) async throws {
        guard let arguments = thinArguments(mountPoint: mountPoint, bytes: bytes) else {
            throw LocalSnapshotError.failed(String(localized: "There is nothing to free."))
        }
        let result = await run(arguments)
        guard result.succeeded else { throw LocalSnapshotError.failed(message(from: result)) }
    }

    static func message(from result: CommandOutput) -> String {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(format: String(localized: "tmutil stopped with code %lld."), Int64(result.status)) : text
    }

    /// Runs tmutil directly (no shell) and collects what it prints.
    public static func run(_ arguments: [String], executable: String = tmutil) async -> CommandOutput {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return CommandOutput(status: -1, output: error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandOutput(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
