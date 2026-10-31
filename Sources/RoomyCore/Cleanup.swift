import Foundation

public protocol Trasher: Sendable {
    func moveToTrash(path: String) throws -> String?
}

public enum CleanupError: Error, LocalizedError {
    case trashUnavailable
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .trashUnavailable: return "The Trash is not available on this system."
        case .blocked(let reason): return reason
        }
    }
}

/// Uses Finder's Trash, so Put Back keeps working.
public struct SystemTrasher: Trasher {
    public init() {}

    public func moveToTrash(path: String) throws -> String? {
        #if os(macOS)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
        #else
        throw CleanupError.trashUnavailable
        #endif
    }
}

public struct CleanupItem: Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let verdict: SafetyVerdict

    public init(path: String, bytes: Int64, verdict: SafetyVerdict) {
        self.path = path
        self.bytes = bytes
        self.verdict = verdict
    }
}

public struct CleanupResult: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let trashedTo: String?
    public let error: String?

    public var succeeded: Bool { error == nil }
}

public struct CleanupReport: Codable, Sendable, Equatable {
    public let date: Date
    public let results: [CleanupResult]

    public var freedBytes: Int64 { results.filter(\.succeeded).reduce(0) { $0 + $1.bytes } }
    public var succeeded: [CleanupResult] { results.filter(\.succeeded) }
    public var failed: [CleanupResult] { results.filter { !$0.succeeded } }
}

public struct CleanupService: Sendable {
    public let policy: SafetyPolicy
    public let trasher: Trasher
    public let history: CleanupHistory?

    public init(policy: SafetyPolicy = SafetyPolicy(), trasher: Trasher = SystemTrasher(), history: CleanupHistory? = .standard) {
        self.policy = policy
        self.trasher = trasher
        self.history = history
    }

    public func plan(paths: [String], sizeOf: (String) -> Int64) -> [CleanupItem] {
        Selection.normalized(paths).map { path in
            CleanupItem(path: path, bytes: sizeOf(path), verdict: policy.verdict(for: path))
        }
    }

    public func execute(_ items: [CleanupItem]) -> CleanupReport {
        var results: [CleanupResult] = []
        for item in items {
            let verdict = policy.verdict(for: item.path)
            if case .blocked(let reason) = verdict {
                results.append(CleanupResult(path: item.path, bytes: item.bytes, trashedTo: nil, error: reason))
                continue
            }
            do {
                let destination = try trasher.moveToTrash(path: item.path)
                results.append(CleanupResult(path: item.path, bytes: item.bytes, trashedTo: destination, error: nil))
            } catch {
                results.append(CleanupResult(path: item.path, bytes: item.bytes, trashedTo: nil, error: error.localizedDescription))
            }
        }
        let report = CleanupReport(date: Date(), results: results)
        try? history?.append(report)
        return report
    }
}

public struct CleanupHistory: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: CleanupHistory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return CleanupHistory(fileURL: base.appendingPathComponent("Roomy/cleanup-history.jsonl"))
    }

    public func append(_ report: CleanupReport) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(report)
        line.append(0x0A)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL)
        }
    }

    public func load() -> [CleanupReport] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(CleanupReport.self, from: Data($0)) }
    }
}
