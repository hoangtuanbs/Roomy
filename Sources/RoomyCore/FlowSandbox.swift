import Foundation

/// The folder the app's flow test (`RoomyDisk --flow-test <sandbox>`) may change. It must be a folder strictly
/// inside a temporary folder ($TMPDIR or $RUNNER_TEMP), so a mistyped path can never point the test at real files.
public enum FlowSandbox {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case noTemporaryFolder
        case missing(String)
        case outsideTemporaryFolders(String)

        public var description: String {
            switch self {
            case .noTemporaryFolder:
                return "neither TMPDIR nor RUNNER_TEMP names a usable temporary folder"
            case .missing(let path):
                return "\(path) is not a folder"
            case .outsideTemporaryFolders(let path):
                return "\(path) is not inside TMPDIR or RUNNER_TEMP"
            }
        }
    }

    /// The temporary folders named by the environment: TMPDIR and RUNNER_TEMP, when set.
    public static func temporaryFolders(environment: [String: String]) -> [String] {
        ["TMPDIR", "RUNNER_TEMP"].compactMap { environment[$0] }.filter { !$0.isEmpty }
    }

    /// The sandbox with every link resolved, when it is an existing folder strictly inside one of
    /// `temporaryFolders` (also with links resolved). A temporary folder itself is not accepted, and neither is
    /// a "temporary folder" that is the whole disk or holds the home folder.
    public static func check(_ path: String, temporaryFolders: [String], homePath: String = NSHomeDirectory()) throws -> String {
        let home = SafetyPolicy.realPath(DiskScanner.standardize(homePath)) ?? DiskScanner.standardize(homePath)
        let roots = temporaryFolders.compactMap { SafetyPolicy.realPath(DiskScanner.standardize($0)) }.filter { root in
            root != "/" && root != home && !home.hasPrefix(root + "/")
        }
        guard !roots.isEmpty else { throw Problem.noTemporaryFolder }
        let standardized = DiskScanner.standardize(path)
        guard DirectoryReader.entry(atPath: standardized)?.kind == .directory,
              let real = SafetyPolicy.realPath(standardized) else { throw Problem.missing(path) }
        let inside = roots.contains { real.hasPrefix($0 + "/") }
        guard inside else { throw Problem.outsideTemporaryFolders(path) }
        return real
    }
}
