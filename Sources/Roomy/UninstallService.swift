import AppKit
import RoomyCore

/// The Finder service "Uninstall with RoomyDisk" (Info.plist `NSServices`): right-click an app in Finder, choose
/// Services › Uninstall with RoomyDisk, and the Uninstaller opens with that app chosen. Nothing is removed until you
/// press Uninstall there.
@MainActor
final class UninstallService: NSObject {
    static let shared = UninstallService()

    /// Called by the system with the files Finder selected (`NSMessage` in Info.plist).
    @objc func uninstallApp(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let path = AppUninstaller.appBundle(among: urls.map(\.path)) else {
            error.pointee = String(localized: "Choose an app to uninstall.") as NSString
            return
        }
        MainWindow.show(.uninstall(path))
    }

    /// Offers the service to the system.
    static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }
}
