import AppKit
import RoomyCore
import SwiftUI

/// The Updates tab of the Uninstaller: apps with a newer version. RoomyDisk only points to the update; the app
/// itself, its download page or the App Store installs it.
struct UpdatesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let updates = model.appUpdates
        if updates.apps.isEmpty {
            ContentUnavailableView("No apps to check", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("None of your apps has an update feed RoomyDisk can read, and none is from the App Store."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            list(updates)
        }
    }

    private func list(_ updates: AppUpdatesModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                UpdatesHeader()
                if !updates.available.isEmpty {
                    SectionTitle(title: String(localized: "Update available"), symbol: "arrow.down.circle.fill")
                    ForEach(Array(updates.available.enumerated()), id: \.element.app.path) { index, entry in
                        UpdateRow(app: entry.app, item: entry.item)
                            .entrance(index: min(index, 12), offset: 8)
                    }
                }
                if !updates.appStoreApps.isEmpty {
                    AppStoreCard(apps: updates.appStoreApps)
                }
                if updates.checkedAt != nil {
                    if updates.upToDateCount > 0 {
                        Label("\(updates.upToDateCount) \(Plural.word(updates.upToDateCount, "app is", "apps are")) up to date",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    if !updates.failed.isEmpty {
                        FailedChecks(failed: updates.failed)
                    }
                } else if !updates.unchecked.isEmpty {
                    WaitingApps(apps: updates.unchecked)
                }
            }
            .padding(16)
            .animation(Motion.spring.unless(reduceMotion), value: updates.available.map(\.app.path))
            .animation(Motion.smooth.unless(reduceMotion), value: updates.checkedAt)
        }
    }
}

private struct UpdatesHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let updates = model.appUpdates
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: updates.isChecking ? updates.checkFraction : (updates.checkedAt == nil ? 0 : 1))
                    .stroke(LinearGradient.uninstaller, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.smooth.unless(reduceMotion), value: updates.checkFraction)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LinearGradient.uninstaller)
                    .rotationEffect(.degrees(updates.isChecking && !reduceMotion ? 360 : 0))
                    .animation(updates.isChecking && !reduceMotion ? .linear(duration: 1.2).repeatForever(autoreverses: false) : .default,
                               value: updates.isChecking)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Check \(updates.apps.count) \(Plural.word(updates.apps.count, "app", "apps")) for updates")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("RoomyDisk asks each app's own update feed for its newest version. Nothing is downloaded or installed; you choose how to update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if updates.isChecking {
                Text("\(updates.checkedCount) of \(updates.apps.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                Button {
                    updates.check()
                } label: {
                    Label(updates.checkedAt == nil ? "Check for Updates" : "Check Again", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.primaryAction(.uninstaller))
                .disabled(updates.apps.allSatisfy(\.isFromAppStore))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
    }
}

private struct SectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(LinearGradient.uninstaller)
    }
}

private struct UpdateRow: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    let item: AppcastItem

    var body: some View {
        let updates = model.appUpdates
        HStack(spacing: 10) {
            FileThumbnail(path: app.path, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(item.displayVersion) is available · you have \(app.version ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.releaseNotesURL != nil {
                Button("Release Notes") { updates.openReleaseNotes(item) }
                    .controlSize(.small)
            }
            if item.downloadURL != nil {
                Button("Download") { updates.openDownload(item) }
                    .controlSize(.small)
                    .help("Opens the download in your browser")
            }
            Button("Open App") { updates.open(app) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Opens the app, so it can update itself")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
    }
}

private struct AppStoreCard: View {
    @Environment(AppModel.self) private var model
    let apps: [InstalledApp]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bag.fill").font(.title3).foregroundStyle(.blue).frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("From the App Store").font(.callout.weight(.medium))
                Text(apps.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("The App Store keeps these up to date.").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("Open in App Store") { model.appUpdates.openAppStore() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
    }
}

private struct WaitingApps: View {
    let apps: [InstalledApp]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps with an update feed").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(apps.map(\.name).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}

private struct FailedChecks: View {
    let failed: [(app: InstalledApp, reason: String)]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(failed, id: \.app.path) { entry in
                    HStack {
                        Text(entry.app.name).lineLimit(1)
                        Spacer()
                        Text(entry.reason).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(failed.count) could not be checked").font(.callout).foregroundStyle(.secondary)
        }
    }
}
