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
            CommandGroup(replacing: .appInfo) {
                Button("About Roomy") { About.show() }
            }
            HelpCommands()
            CommandGroup(after: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.tree == nil)
                Divider()
                Button("Smart Clean…") { model.openSmartClean() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Find Duplicates…") { model.openDuplicates() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Uninstall Apps…") { model.openUninstaller() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Quick Look") { model.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(model.selection == nil)
                Divider()
                Picker("Map", selection: Binding(get: { model.mapStyle }, set: { model.mapStyle = $0 })) {
                    ForEach(MapStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }

        Window("Donate", id: "donate") {
            DonateView()
        }
        .windowResizability(.contentSize)
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Email Us…") { About.emailSupport() }
            Button("Donate…") { openWindow(id: "donate") }
            Divider()
            Button("Roomy on GitHub") { NSWorkspace.shared.open(About.projectURL) }
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
