import Combine
import Sparkle
import SwiftUI

/// Signed automatic updates through Sparkle. Only a release build carries the update key
/// (scripts/release.sh adds it), so local and CI builds never look for updates.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheck = false
    @Published var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let args = CommandLine.arguments
        let isDevRun = args.contains("--tour") || args.contains("--snapshot")
        guard !key.isEmpty, Bundle.main.bundleURL.pathExtension == "app", !isDevRun else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// "Check for Updates…" in the RoomyDisk menu, shown only in release builds.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}
