import Foundation
import RoomyCore

/// Where RoomyDisk finds the home folder and keeps its settings, scan cache and cleanup history. These are the
/// real places, except in the flow test (`RoomyDisk --flow-test <sandbox>`), which moves every one of them into its
/// sandbox, so a test run changes nothing else on the Mac.
enum AppEnvironment {
    /// The flow test's sandbox, with links resolved. Nil in normal use. A sandbox that is not inside $TMPDIR or
    /// $RUNNER_TEMP stops the app before anything runs.
    static let flowSandbox: String? = readFlowSandbox()
    static var isFlowTest: Bool { flowSandbox != nil }

    /// The home folder the features look in: the real one, or `<sandbox>/home` in the flow test.
    static let home: String = flowSandbox.map { $0 + "/home" } ?? NSHomeDirectory()
    /// The flow test's own settings, so the real ones are never touched. It removes them when it ends.
    static let flowDefaultsSuite = "io.github.hoangtuanbs.Roomy.flow-test"
    static let defaults: UserDefaults = makeDefaults()

    /// The safety rules. In the flow test they block everything outside the sandbox too.
    static let policy = SafetyPolicy(homePath: home, confinedTo: flowSandbox)
    static let history: CleanupHistory? = flowSandbox.map {
        CleanupHistory(fileURL: URL(fileURLWithPath: $0 + "/state/cleanup-history.jsonl"))
    } ?? .standard
    static let scanCache: ScanCache = flowSandbox.map { ScanCache(directory: $0 + "/state/Scans") }
        ?? .standard(bundleID: Bundle.main.bundleIdentifier ?? "io.github.hoangtuanbs.Roomy")
    /// Where the Uninstaller looks for apps; nil for the usual app folders.
    static let appFolders: [String]? = flowSandbox.map { _ in [home + "/Applications"] }

    /// The folder with the shared LaunchAgents and LaunchDaemons: `/Library`, or `<sandbox>/system/Library`.
    static let sharedLibrary: String = flowSandbox.map { $0 + "/system/Library" } ?? "/Library"
    /// Asks launchd about jobs. The flow test uses a stand-in, so launchctl is never run there.
    static let launchControl: any LaunchControlling = flowSandbox == nil
        ? SystemLaunchControl() : RecordingLaunchControl(loaded: ["io.github.roomy.flowagent"])

    /// Reads installer receipts. The flow test uses a made-up package in its sandbox, so pkgutil is never run there.
    static let packageDatabase: any PackageDatabase = flowSandbox.map { sandbox in
        StaticPackageDatabase([(PackageInfo(id: "io.github.roomy.flowpkg", version: "2.0", volume: sandbox + "/system"), [
            "Applications", "Applications/Flow Tool.app", "Applications/Flow Tool.app/Contents", "Library",
            "Library/Application Support", "Library/Application Support/FlowTool",
            "Library/Application Support/FlowTool/engine.bin", "usr", "usr/local", "usr/local/bin", "usr/local/bin/flowtool",
        ])])
    } ?? SystemPackageDatabase()
    /// Checks code signatures. The flow test's made-up apps are not signed.
    static let signatureChecker: any SignatureChecking = flowSandbox == nil
        ? SystemSignatureChecker() : FixedSignatureChecker(.unsigned)

    /// Moves items to the Trash under these rules, and notes each clean in the history.
    static func cleanupService() -> CleanupService {
        CleanupService(policy: policy, history: history)
    }

    private static func readFlowSandbox() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--flow-test") else { return nil }
        guard i + 1 < args.count else { refuse("--flow-test needs a sandbox folder") }
        do {
            let folders = FlowSandbox.temporaryFolders(environment: ProcessInfo.processInfo.environment)
            return try FlowSandbox.check(args[i + 1], temporaryFolders: folders)
        } catch {
            refuse("\(error)")
        }
    }

    private static func makeDefaults() -> UserDefaults {
        guard isFlowTest else { return .standard }
        guard let suite = UserDefaults(suiteName: flowDefaultsSuite) else { refuse("could not open its own settings") }
        return suite
    }

    private static func refuse(_ reason: String) -> Never {
        print("flow: refusing to run: \(reason)")
        fflush(stdout)
        exit(2)
    }
}
