import AppKit
import Quartz

/// Shows the selected item in the system Quick Look panel. The arrow keys in the panel move the selection.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    /// Called with -1 or +1 when an arrow key is pressed in the panel.
    var onMove: (@MainActor (Int) -> Void)?
    private var url: URL?
    private let controller = QuickLookResponder()

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func show(_ url: URL) {
        self.url = url
        if isVisible {
            QLPreviewPanel.shared().reloadData()
            return
        }
        // The panel looks for its controller along the key window's responder chain.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, !(window is QLPreviewPanel) {
            var responder = window.nextResponder
            var found = false
            while let r = responder {
                if r === controller { found = true; break }
                responder = r.nextResponder
            }
            if !found {
                controller.nextResponder = window.nextResponder
                window.nextResponder = controller
            }
        }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let url = MainActor.assumeIsolated { self.url }
        return url.map { $0 as NSURL }
    }

    // MARK: QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let delta: Int
        switch event.keyCode {
        case 125, 124: delta = 1   // down, right
        case 126, 123: delta = -1  // up, left
        default: return false
        }
        MainActor.assumeIsolated { onMove?(delta) }
        return true
    }
}

/// Takes control of the Quick Look panel for `QuickLook`.
final class QuickLookResponder: NSResponder {
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLook.shared
            panel.delegate = QuickLook.shared
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
