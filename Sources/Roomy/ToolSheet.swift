import SwiftUI

/// The one layout every tool sheet uses (Smart Clean, Duplicates, Uninstaller, Space Hunters, Cloud Space and Disk
/// Health): a header with the tool's icon tile, title, subtitle and total; the content on a soft well where cards
/// stand out; and a footer with the secondary buttons and one gradient primary action.
struct ToolSheet<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header()
            Rectangle().fill(Palette.hairline).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.well)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer()
                .controlSize(.large)
                .padding(.horizontal, Space.xl)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(Palette.bar)
        }
        .background(Palette.content)
    }
}

/// The top of a tool sheet: the gradient icon tile, the title and subtitle, and on the right the tool's total.
struct ToolSheetHeader<Icon: View, Accessory: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: LocalizedStringKey
    let subtitle: Text
    let gradient: LinearGradient
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory
    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(gradient)
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                icon()
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .frame(width: 50, height: 50)
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .scaleEffect(shown || reduceMotion ? 1 : 0.8)
            .opacity(shown || reduceMotion ? 1 : 0)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typo.sheetTitle)
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.m)
            accessory()
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, 18)
        .background(
            gradient.opacity(0.10)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom))
        )
        .onAppear {
            guard !shown else { return }
            withAnimation(Motion.bouncy.unless(reduceMotion)) { shown = true }
        }
    }
}

/// The big total on the right of a tool sheet's header, with a short caption under it.
struct ToolSheetTotal: View {
    let value: Text
    let caption: Text
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            value
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}
