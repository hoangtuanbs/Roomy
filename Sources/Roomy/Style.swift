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
