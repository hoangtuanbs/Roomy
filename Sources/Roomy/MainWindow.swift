import AppKit
import SwiftUI

/// Brings the main window forward from code that lives outside any window, such as a click on a notification
/// while the menu bar icon is hidden and every window is closed. The app's commands hand over their `openWindow`
/// action, which lives as long as the app does.
@MainActor
enum MainWindow {
    /// Where a click on a RoomyDisk notification leads.
    enum Route: Sendable {
        case main, smartClean, diskHealth
        /// The Uninstaller with this app chosen, from the Finder service.
        case uninstall(String)
    }

    nonisolated(unsafe) static var openAction: OpenWindowAction?
    static weak var model: AppModel?

    /// Opens the sheet for `route` on the model, then shows the main window, which presents it.
    static func show(_ route: Route) {
        switch route {
        case .main: break
        case .smartClean: model?.openSmartClean()
        case .diskHealth: model?.openDiskHealth()
        case .uninstall(let path): model?.openUninstaller(choosing: path)
        }
        bringForward()
    }

    /// Shows the main window, opening a new one when none is left.
    static func bringForward() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if focusExisting() { return }
        // Right after a launch the first window may still be on its way; give it a moment before opening one.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !focusExisting() { openAction?(id: "main") }
        }
    }

    private static func focusExisting() -> Bool {
        guard let window = NSApp.windows.first(where: isMain) else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// SwiftUI names the windows of the "main" group "main-…". A minimized window cannot become main until it is
    /// back on screen, so that is only asked of a window that is shown.
    private static func isMain(_ window: NSWindow) -> Bool {
        guard window.identifier?.rawValue.hasPrefix("main") == true else { return false }
        return window.isMiniaturized || (window.isVisible && window.canBecomeMain)
    }
}
