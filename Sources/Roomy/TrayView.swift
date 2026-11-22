import AppKit
import RoomyCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An item of the current scan dragged inside RoomyDisk. Declared in Info.plist.
    static let roomyItem = UTType(exportedAs: "io.github.hoangtuanbs.Roomy.item")
}

/// What a drag from a list, the treemap or the rings carries: the item's path.
struct TrayItem: Codable, Transferable {
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .roomyItem)
    }
}

/// Finder icons for files and folders, kept once read.
@MainActor
enum FileIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// The picture shown under the pointer while an item is dragged.
struct DragPreview: View {
    let path: String
    let name: String
    let size: Int64

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcon.image(for: path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(name).lineLimit(1)
            Text(size.bytes).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
    }
}

extension View {
    /// Lets the item be dragged onto the tray.
    @MainActor
    func trayDraggable(_ node: ScanTree.Index?, model: AppModel) -> some View {
        let tree = model.tree
        let path = node.flatMap { n in tree.map { $0.path(of: n) } } ?? ""
        return draggable(TrayItem(path: path)) {
            if let node, let tree {
                DragPreview(path: path, name: tree.name(node), size: tree.size(node))
            }
        }
    }
}

/// The collector at the bottom of the window. Items dragged here, added from a context menu or ticked in a list are
/// collected for **Review and Clean…**.
struct TrayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var flyers: [Flyer] = []
    @State private var bounce = 0

    private static let iconCenter = CGPoint(x: 30, y: 29)

    var body: some View {
        let items = model.basketItems
        let accent = Color.accentColor

        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: items.isEmpty ? "tray" : "tray.full.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isTargeted || !items.isEmpty ? accent : Color.secondary)
                    .symbolEffect(.bounce, value: bounce)
                    .frame(width: 32, height: 32)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 6, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if items.isEmpty {
                Text(isTargeted ? "Drop to collect it for cleaning" : "Drag files and folders here to collect them for cleaning")
                    .foregroundStyle(isTargeted ? Color.primary : Color.secondary)
                    .transition(.opacity)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items, id: \.self) { node in
                            TrayChip(node: node)
                                .transition(chipTransition)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .transition(.opacity)

                VStack(alignment: .trailing, spacing: 0) {
                    CountingBytes(model.basketBytes)
                        .font(.headline)
                        .animation(Motion.smooth.unless(reduceMotion), value: model.basketBytes)
                    Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .fixedSize()
                Button("Clear") { model.basket = [] }
            }

            Button("Compress and Clean…") { model.startCompressBasket() }
                .buttonStyle(.bordered)
                .disabled(!model.canCompressBasket)
                .help("Zip the collected items, then move the originals to the Trash")
            Button("Review and Clean…") { model.showReview = true }
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(isTargeted ? accent.opacity(0.10) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(isTargeted ? 0.8 : 0), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(4)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(flyers) { flyer in
                    FlyerView(flyer: flyer, target: Self.iconCenter)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if let notice = model.trayNotice {
                Label(notice, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.5)))
                    .offset(y: -20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.bouncy.unless(reduceMotion), value: items)
        .animation(Motion.hover.unless(reduceMotion), value: isTargeted)
        .animation(Motion.spring.unless(reduceMotion), value: model.trayNotice)
        .dropDestination(for: TrayItem.self) { dropped, location in
            let first = dropped.first.flatMap { model.tree?.index(ofPath: $0.path) }
            let added = model.addToTray(paths: dropped.map(\.path))
            guard added > 0 else { return false }
            bounce += 1
            if !reduceMotion, let first {
                let flyer = Flyer(path: model.path(of: first), start: location)
                flyers.append(flyer)
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    flyers.removeAll { $0.id == flyer.id }
                }
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var chipTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.2).combined(with: .opacity).combined(with: .offset(y: -22)),
            removal: .scale(scale: 0.5).combined(with: .opacity)
        )
    }
}

private struct Flyer: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let start: CGPoint
}

/// The dropped item's icon shrinking into the tray.
private struct FlyerView: View {
    let flyer: Flyer
    let target: CGPoint
    @State private var landed = false

    var body: some View {
        Image(nsImage: FileIcon.image(for: flyer.path))
            .resizable()
            .frame(width: 36, height: 36)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .scaleEffect(landed ? 0.25 : 1.3)
            .opacity(landed ? 0 : 1)
            .position(landed ? target : flyer.start)
            .onAppear {
                withAnimation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.45)) { landed = true }
            }
    }
}

/// One collected item in the tray.
private struct TrayChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let node: ScanTree.Index
    @State private var isHovered = false

    var body: some View {
        if let tree = model.tree {
            let color = model.category(of: node).color
            let path = tree.path(of: node)

            HStack(spacing: 5) {
                Image(nsImage: FileIcon.image(for: path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(tree.name(node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize()
                Text(tree.size(node).bytes)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(Motion.spring.unless(reduceMotion)) {
                        model.toggleBasket(node)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(isHovered ? Color.secondary : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .help("Remove from the tray")
            }
            .font(.callout)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(isHovered ? 0.24 : 0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
            .animation(Motion.quick.unless(reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
            .help(path)
            .contextMenu {
                Button("Quick Look") { model.quickLook(node) }
                Button("Reveal in Finder") { model.reveal(node) }
                Divider()
                Button("Remove from Tray") { model.toggleBasket(node) }
            }
        }
    }
}
