import RoomyCore
import SwiftUI

extension FileCategory {
    var color: Color {
        switch self {
        case .folder: return Color(red: 0.29, green: 0.52, blue: 0.86)
        case .video: return Color(red: 0.86, green: 0.36, blue: 0.42)
        case .audio: return Color(red: 0.93, green: 0.58, blue: 0.25)
        case .image: return Color(red: 0.36, green: 0.72, blue: 0.48)
        case .archive: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .application: return Color(red: 0.25, green: 0.70, blue: 0.80)
        case .developer: return Color(red: 0.85, green: 0.72, blue: 0.25)
        case .document: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case .other: return Color(red: 0.60, green: 0.60, blue: 0.62)
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .archive: return "archivebox"
        case .application: return "app.dashed"
        case .developer: return "hammer"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }
}

extension Int64 {
    var bytes: String { ByteFormat.string(self) }
}

struct SizeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

extension JunkCategory {
    var color: Color {
        switch self {
        case .caches: return Color(red: 0.29, green: 0.52, blue: 0.86)
        case .logs: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case .developer: return Color(red: 0.85, green: 0.62, blue: 0.20)
        case .packages: return Color(red: 0.36, green: 0.72, blue: 0.48)
        case .installers: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .trash: return Color(red: 0.86, green: 0.36, blue: 0.42)
        }
    }

    var symbol: String {
        switch self {
        case .caches: return "bolt.horizontal.circle"
        case .logs: return "text.alignleft"
        case .developer: return "hammer"
        case .packages: return "shippingbox"
        case .installers: return "opticaldiscdrive"
        case .trash: return "trash"
        }
    }
}

extension DiskPart {
    var color: Color {
        switch self {
        case .scanned: return FileCategory.folder.color
        case .hidden: return FileCategory.audio.color
        case .purgeable: return FileCategory.archive.color
        case .free: return Color.secondary.opacity(0.25)
        }
    }
}

/// The blue-to-purple gradient used for Smart Clean.
extension LinearGradient {
    static let smartClean = LinearGradient(
        colors: [Color(red: 0.29, green: 0.52, blue: 0.86), Color(red: 0.62, green: 0.45, blue: 0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// A byte count that counts up or down to its new value when it changes inside an animation.
struct CountingBytes: View, Animatable {
    var value: Double
    var suffix: String

    init(_ bytes: Int64, suffix: String = "") {
        value = Double(bytes)
        self.suffix = suffix
    }

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int64(max(0, value).rounded()).bytes + suffix).monospacedDigit()
    }
}
