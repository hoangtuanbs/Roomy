import AppKit
import SwiftUI

@main
struct RoomyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Roomy") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.tree == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
