import AppKit
import QuickLookThumbnailing
import RoomyCore
import SwiftUI
import UniformTypeIdentifiers

/// Finds identical files, shows each set of copies as a card, and moves the copies that are not kept to the Trash.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClean = false

    var body: some View {
        let dups = model.duplicates

        VStack(spacing: 0) {
            DuplicatesHeader()
            Divider()
            ZStack {
                switch dups.phase {
                case .idle:
                    DuplicatesStart()
                        .transition(.opacity)
                case .scanning:
                    DuplicatesScanning()
                        .transition(.opacity)
                case .ready:
                    DuplicatesResults()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .cleaning:
                    DuplicatesCleaning()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .done:
                    DuplicatesDone()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: dups.phase)
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 580, idealHeight: 700)
        .interactiveDismissDisabled(dups.isBusy)
        .alert("Move \(dups.selectedFiles.count) \(dups.selectedFiles.count == 1 ? "duplicate" : "duplicates") to the Trash?",
               isPresented: $confirmClean) {
            Button("Move to Trash") { dups.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees about \(dups.selectedBytes.bytes). One copy of every file is kept, and you can use Put Back in Finder to restore anything.")
        }
    }

    @ViewBuilder
    private var footer: some View {
        let dups = model.duplicates
        HStack(spacing: 10) {
            switch dups.phase {
            case .idle:
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .scanning:
                Spacer()
                Button("Cancel") {
                    dups.cancelScan()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            case .ready:
                Text("One copy of each file is always kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder…") { dups.chooseFolder() }
                if model.tree != nil {
                    Button("Scan Again") { model.findDuplicates() }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirmClean = true
                } label: {
                    Label("Move Duplicates to Trash", systemImage: "trash").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(dups.selectedFiles.isEmpty)
            case .cleaning:
                Spacer()
                Text("Please wait…").foregroundStyle(.secondary)
            case .done:
                Button("Open Trash") { dups.openTrash() }
                Spacer()
                if !dups.groups.isEmpty {
                    Button("Show Remaining") { dups.showRemaining() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
}

private struct DuplicatesHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dups = model.duplicates
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient.duplicates)
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: dups.isBusy && !reduceMotion)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Duplicates").font(.title2.weight(.semibold))
                Text(dups.scope.isEmpty
                     ? "Identical files that take up space more than once."
                     : "Identical files in \((dups.scope as NSString).abbreviatingWithTildeInPath).")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if dups.phase == .ready && !dups.groups.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(dups.selectedBytes.bytes)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(dups.selectedBytes)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: dups.selectedBytes)
                    Text("\(dups.selectedFiles.count) \(dups.selectedFiles.count == 1 ? "copy" : "copies") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: dups.selectedFiles.count)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(18)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: dups.phase)
    }
}

/// Shown when there is no scan to look in yet.
private struct DuplicatesStart: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Choose where to look", systemImage: "doc.on.doc")
        } description: {
            Text("Scan a folder or disk in the main window first, or choose a folder here.")
        } actions: {
            Button("Choose Folder…") { model.duplicates.chooseFolder() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct DuplicatesScanning: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var shuffled = false

    var body: some View {
        let progress = model.duplicates.progress
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.02, progress.fraction))
                    .stroke(LinearGradient.duplicates, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress.fraction)
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(-10)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .opacity(reduceMotion ? 0 : 1)
                // Two pages sliding over each other, like copies being compared.
                ZStack {
                    Image(systemName: "doc.fill")
                        .offset(x: shuffled ? -9 : 0, y: shuffled ? -5 : 0)
                        .opacity(0.55)
                    Image(systemName: "doc.fill")
                        .offset(x: shuffled ? 9 : 0, y: shuffled ? 5 : 0)
                }
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(LinearGradient.duplicates)
            }
            .frame(width: 110, height: 110)

            Text(title(progress))
                .font(.title3.weight(.medium))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: progress.stage)
            Text(detail(progress))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Text("Files are only read and compared. Nothing is moved yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spinning = true }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { shuffled = true }
        }
    }

    private func title(_ progress: DuplicateProgress) -> String {
        switch progress.stage {
        case .listing: return "Reading the folder…"
        case .comparing: return "Comparing files of the same size…"
        case .hashing: return "Checking that the contents match…"
        }
    }

    private func detail(_ progress: DuplicateProgress) -> String {
        switch progress.stage {
        case .listing: return "\(progress.done.formatted()) files found"
        case .comparing: return "\(progress.done.formatted()) of \(progress.total.formatted()) files"
        case .hashing: return "\(progress.done.bytes) of \(progress.total.bytes)"
        }
    }
}

private struct DuplicatesResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dups = model.duplicates
        if let message = dups.errorMessage {
            ContentUnavailableView("Could not look for duplicates", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else if dups.groups.isEmpty {
            ContentUnavailableView(
                "No duplicates",
                systemImage: "checkmark.seal",
                description: Text("No identical files of 1 MB or more were found. Packages, Git folders and protected places are not checked.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    DuplicatesSummary()
                    ForEach(Array(dups.groups.enumerated()), id: \.element.id) { index, group in
                        DuplicateCard(group: group, index: index)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.95))))
                    }
                }
                .padding(16)
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: dups.groups.map(\.id))
            }
        }
    }
}

private struct DuplicatesSummary: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dups = model.duplicates
        let copies = dups.groups.reduce(0) { $0 + $1.files.count }
        HStack(spacing: 16) {
            stat(value: "\(dups.groups.count)", label: dups.groups.count == 1 ? "file with copies" : "files with copies")
            stat(value: "\(copies)", label: "copies in all")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                CountingBytes(appeared ? dups.wastedBytes : 0)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LinearGradient.duplicates)
                Text("taken by extra copies").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .onAppear {
            guard !appeared else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { appeared = true }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DuplicateCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: DuplicateGroup
    let index: Int
    @State private var appeared = false
    @Namespace private var keepHighlight

    private static let color = Color(red: 0.20, green: 0.66, blue: 0.70)

    var body: some View {
        let dups = model.duplicates
        let state = dups.selection.state(of: group)
        let isExpanded = dups.expanded.contains(group.id)
        let kept = dups.selection.keptPath(in: group)
        let selectedBytes = dups.selection.selectedBytes(in: [group])

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SelectionBox(state: state, color: Self.color) {
                    withAnimation(motion(.snappy(duration: 0.25))) {
                        dups.selection.setAll(group, selected: state != .all)
                    }
                }
                FileThumbnail(path: kept, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.suggestedKeep.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.files.count) copies · \(group.bytes.bytes) each")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    CountingBytes(appeared ? selectedBytes : 0)
                        .font(.title3.weight(.semibold))
                    Text(state == .all ? "can be freed" : "of \(group.wastedBytes.bytes) can be freed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(motion(.snappy(duration: 0.3)), value: selectedBytes)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(motion(.spring(response: 0.35, dampingFraction: 0.85))) { dups.toggleExpanded(group) }
            }
            .help(isExpanded ? "Hide the copies" : "Show the copies")

            if isExpanded {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 2) {
                    ForEach(group.files) { file in
                        DuplicateRow(file: file, group: group, highlight: keepHighlight)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.08) : Self.color.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .scaleEffect(appeared ? 1 : 0.97)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(index < 8 ? index : 0) * 0.05)) {
                    appeared = true
                }
            }
        }
    }

    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct DuplicateRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let file: DuplicateFile
    let group: DuplicateGroup
    let highlight: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let dups = model.duplicates
        let isKept = dups.selection.isKept(file, in: group)
        let isTicked = dups.selection.isTicked(file, in: group)

        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    dups.selection.keep(file, in: group)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isKept ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text("Keep")
                        .font(.caption.weight(isKept ? .semibold : .regular))
                        .foregroundStyle(isKept ? Color.green : Color.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help(isKept ? "This copy is kept" : "Keep this copy instead")

            FileThumbnail(path: file.path, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(file.modified, format: .dateTime.year().month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Last modified")

            if isKept {
                Badge(text: "Kept", color: .green)
                    .frame(width: 68, alignment: .trailing)
                    .transition(.scale.combined(with: .opacity))
            } else {
                HStack(spacing: 4) {
                    Text("Trash").font(.caption).foregroundStyle(isTicked ? Color.primary : Color.secondary)
                    SelectionBox(state: isTicked ? .all : .none, color: .red) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            dups.selection.toggle(file, in: group)
                        }
                    }
                }
                .frame(width: 68, alignment: .trailing)
                .transition(.scale.combined(with: .opacity))
            }

            Button {
                dups.reveal(file.path)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if isKept {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.10))
                    .matchedGeometryEffect(id: "kept", in: highlight)
            } else if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .opacity(isTicked ? 0.75 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu {
            Button("Keep This Copy") { dups.selection.keep(file, in: group) }
                .disabled(isKept)
            Button("Show in Finder") { dups.reveal(file.path) }
            Button("Open") { dups.open(file.path) }
        }
    }
}

/// A Quick Look thumbnail for pictures, videos and PDFs, and the Finder icon for everything else.
struct FileThumbnail: View {
    let path: String
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var icon: NSImage?
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: path) {
            thumbnail = nil
            icon = NSWorkspace.shared.icon(forFile: path)
            guard Self.hasPreview(path) else { return }
            let image = await Self.makeThumbnail(path: path, size: size, scale: displayScale)
            guard !Task.isCancelled, let image else { return }
            withAnimation(.easeOut(duration: 0.25)) { thumbnail = image }
        }
    }

    static func hasPreview(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    static func makeThumbnail(path: String, size: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        } catch {
            return nil
        }
    }
}

private struct DuplicatesCleaning: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dups = model.duplicates
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0.02, dups.cleanFraction))
                    .stroke(LinearGradient.duplicates, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: dups.cleanFraction)
                VStack(spacing: 2) {
                    Text(dups.cleanedBytes.bytes)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(dups.cleanedBytes)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: dups.cleanedBytes)
                    Text("moved to the Trash").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            Text("Moving \(min(dups.cleanedCount + 1, dups.cleanTotal)) of \(dups.cleanTotal)…")
                .font(.title3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: dups.cleanedCount)
        }
        .padding(32)
    }
}

private struct DuplicatesDone: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let dups = model.duplicates
        let moved = dups.report?.succeeded.count ?? 0
        let failed = dups.report?.failed ?? []

        ZStack {
            if shown && !reduceMotion {
                ConfettiBurst()
            }
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(Color.green.gradient)
                    .scaleEffect(shown ? 1 : 0.3)
                    .opacity(shown ? 1 : 0)
                    .symbolEffect(.bounce, value: shown)
                CountingBytes(shown ? dups.cleanedBytes : 0, suffix: " freed")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Moved \(moved) \(moved == 1 ? "duplicate" : "duplicates") to the Trash and kept one copy of each file. Empty the Trash to get the space back for good, or use Put Back in Finder to restore anything.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .opacity(shown ? 1 : 0)
                if !failed.isEmpty {
                    DisclosureGroup("\(failed.count) could not be moved") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(failed, id: \.path) { result in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((result.path as NSString).lastPathComponent)
                                    Text(result.error ?? "Unknown error").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 460)
                    .foregroundStyle(.orange)
                }
            }
            .padding(32)
        }
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { shown = true }
            }
        }
    }
}
