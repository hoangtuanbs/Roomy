import Foundation

/// Smart Clean's default clean without the window: finds the junk, keeps only what Smart Clean ticks by itself
/// (caches, logs, build data, package caches, old installers; never the Trash or anything that needs a review),
/// and moves it to the Trash through `CleanupService`, so the safety rules and the history apply. Used by Shortcuts
/// and by `roomy-scan clean`.
public struct JunkClean: Sendable {
    public let finder: JunkFinder
    public let service: CleanupService

    public init(finder: JunkFinder, service: CleanupService) {
        self.finder = finder
        self.service = service
    }

    /// The items a clean would move, largest first. Items the safety rules block are left out.
    public func items() async -> [JunkItem] {
        JunkSummary.safeItems(await finder.find()).filter { !service.policy.verdict(for: $0.path).isBlocked }
    }

    /// Moves `items` to the Trash. Each is judged again by the safety rules just before.
    public func clean(_ items: [JunkItem], progress: ((CleanupResult) -> Void)? = nil) -> CleanupReport {
        let sizes = Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        return service.execute(service.plan(paths: items.map(\.path), sizeOf: { sizes[$0] ?? 0 }), progress: progress)
    }
}

/// `roomy-scan clean [--dry-run] [--yes]`: lists what Smart Clean would move to the Trash with sizes, then asks
/// "Move … to the Trash? [y/N]" and moves it only after "y". `--dry-run` only lists; `--yes` skips the question.
/// Nothing is ever deleted; everything goes to the Trash, where Put Back works.
public struct CleanCommand {
    public var clean: JunkClean
    public var dryRun = false
    public var assumeYes = false
    /// Reads the answer to the question; nil when there is no input, which counts as no.
    public var readAnswer: () -> String? = { Swift.readLine() }
    public var write: (String) -> Void = { print($0) }
    /// Shows the question, leaving the cursor after it.
    public var prompt: (String) -> Void = { print($0, terminator: ""); fflush(stdout) }

    public init(clean: JunkClean, dryRun: Bool = false, assumeYes: Bool = false) {
        self.clean = clean
        self.dryRun = dryRun
        self.assumeYes = assumeYes
    }

    /// Reads `clean`'s own options from the arguments after "clean". Nil for an unknown option.
    public static func options(_ arguments: [String]) -> (dryRun: Bool, yes: Bool)? {
        var dryRun = false, yes = false
        for argument in arguments {
            switch argument {
            case "--dry-run", "-n": dryRun = true
            case "--yes", "-y": yes = true
            default: return nil
            }
        }
        return (dryRun, yes)
    }

    /// Runs the command and returns the exit status: 0 when done (or nothing to do, or declined), 1 when an item
    /// could not be moved.
    public func run() async -> Int32 {
        let items = await clean.items()
        guard !items.isEmpty else {
            write("Nothing to clean: Smart Clean found no caches, logs or other safe junk.")
            return 0
        }
        let total = items.reduce(0) { $0 + $1.bytes }
        let width = items.map { ByteFormat.string($0.bytes).count }.max() ?? 0
        for item in items {
            let size = ByteFormat.string(item.bytes)
            write(String(repeating: " ", count: max(0, width - size.count)) + size + "  " + item.path)
        }
        let summary = "\(items.count) \(items.count == 1 ? "item" : "items"), \(ByteFormat.string(total))"
        if dryRun {
            write("Would move \(summary) to the Trash. Dry run: nothing was moved.")
            return 0
        }
        if !assumeYes {
            prompt("Move \(summary) to the Trash? [y/N] ")
            let answer = (readAnswer() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                write("Nothing was moved.")
                return 0
            }
        }
        let report = clean.clean(items)
        write("Moved \(report.succeeded.count) of \(items.count) to the Trash, freeing \(ByteFormat.string(report.freedBytes)). "
              + "Empty the Trash to get the space back, or use Put Back in Finder to restore anything.")
        for failure in report.failed {
            write("Not moved: \(failure.path): \(failure.error ?? "unknown error")")
        }
        return report.failed.isEmpty ? 0 : 1
    }
}
