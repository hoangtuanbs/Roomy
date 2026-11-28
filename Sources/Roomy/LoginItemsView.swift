import AppKit
import RoomyCore
import SwiftUI

/// The Login Items tab of the Uninstaller: what starts with the Mac. Your own launch agents can be turned off; the
/// rest are shown, with a way to System Settings.
struct LoginItemsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let login = model.loginItems
        ZStack {
            if login.isLoading && !login.loaded {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for what starts with your Mac…").foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if login.items.isEmpty {
                ContentUnavailableView("Nothing starts with your Mac", systemImage: "checkmark.seal",
                                       description: Text("No launch agents, daemons or app helpers were found."))
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let result = login.lastResult {
                            TurnOffBanner(result: result, title: login.lastTitle ?? "")
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        LoginSection(title: String(localized: "Your login items"),
                                     subtitle: String(localized: "~/Library/LaunchAgents · start when you log in. You can turn these off."),
                                     symbol: "person.crop.circle", items: login.userItems, baseIndex: 0)
                        LoginSection(title: String(localized: "For all users"),
                                     subtitle: String(localized: "/Library/LaunchAgents and LaunchDaemons · changing these needs an administrator."),
                                     symbol: "person.2.circle", items: login.sharedItems, baseIndex: login.userItems.count,
                                     settingsButton: true)
                        LoginSection(title: String(localized: "Managed by apps"),
                                     subtitle: String(localized: "Helpers that apps turn on themselves. Switch them off in System Settings."),
                                     symbol: "app.badge", items: login.appItems,
                                     baseIndex: login.userItems.count + login.sharedItems.count, settingsButton: true)
                    }
                    .padding(16)
                    .animation(Motion.spring.unless(reduceMotion), value: login.items.map(\.id))
                    .animation(Motion.smooth.unless(reduceMotion), value: login.lastResult)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.smooth.unless(reduceMotion), value: login.loaded)
    }
}

private struct LoginSection: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    let symbol: String
    let items: [LaunchItem]
    let baseIndex: Int
    var settingsButton = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(LinearGradient.uninstaller)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if settingsButton {
                        Button("Open Login Items Settings") { model.loginItems.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    LoginItemRow(item: item)
                        .entrance(index: min(baseIndex + index, 14), offset: 8)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
                }
            }
        }
    }
}

private struct LoginItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: LaunchItem
    @State private var confirm = false
    @State private var hovering = false

    var body: some View {
        let login = model.loginItems
        let refusal = login.refusal(for: item)
        let busy = login.turningOff == item.id

        HStack(alignment: .top, spacing: 10) {
            Group {
                if let owner = item.ownerPath {
                    FileThumbnail(path: owner, size: 32)
                } else {
                    IconTile(symbol: item.domain == .systemDaemon ? "gearshape.2.fill" : "gearshape.fill",
                             gradient: .uninstaller, size: 32)
                }
            }
            .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    StateBadge(item: item)
                    if item.program != nil && !item.programExists {
                        Badge(text: "Program missing", color: .orange)
                            .help("The program it starts is no longer on this Mac.")
                    }
                }
                if item.ownerName != nil {
                    Text(item.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let program = item.program {
                    Text(program).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let plist = item.plistPath {
                Button {
                    login.reveal(plist)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            if item.domain == .userAgent {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Turn Off") { confirm = true }
                        .controlSize(.small)
                        .disabled(refusal != nil || login.turningOff != nil)
                        .help(refusal ?? String(localized: "Stop it and move its file to the Trash"))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
        .onHover { inside in withAnimation(Motion.quick.unless(reduceMotion)) { hovering = inside } }
        .alert("Turn off \(item.title)?", isPresented: $confirm) {
            Button("Turn Off and Move to Trash", role: .destructive) { login.turnOff(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let file = ((item.plistPath ?? "") as NSString).lastPathComponent
            Text("RoomyDisk stops it and moves \(file) to the Trash, so it no longer starts when you log in. Put it back from the Trash to turn it on again. Its app may turn it on again when you open the app.")
        }
    }
}

private struct StateBadge: View {
    let item: LaunchItem

    var body: some View {
        switch item.isLoaded {
        case true?: Badge(text: "Running", color: .green)
        case false?: Badge(text: "Not running", color: .secondary)
        case nil: EmptyView()
        }
    }
}

private struct TurnOffBanner: View {
    @Environment(AppModel.self) private var model
    let result: CleanupResult
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.succeeded ? .green : .orange)
                .symbolEffect(.bounce, value: result.path)
            if result.succeeded {
                Text("\(title) is off. Its file is in the Trash.")
            } else {
                Text("\(title) was not turned off: \(result.error ?? String(localized: "unknown error"))")
            }
            Spacer()
            Button {
                model.loginItems.dismissResult()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((result.succeeded ? Color.green : Color.orange).opacity(0.10)))
    }
}
