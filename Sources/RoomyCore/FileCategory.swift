import Foundation

public enum FileCategory: String, CaseIterable, Sendable {
    case folder, video, audio, image, archive, application, developer, document, other

    public var title: String {
        switch self {
        case .folder: return "Folders"
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Images"
        case .archive: return "Archives and disk images"
        case .application: return "Apps"
        case .developer: return "Developer files"
        case .document: return "Documents"
        case .other: return "Other"
        }
    }

    static let developerFolders: Set<String> = [
        "node_modules", "DerivedData", ".git", ".build", "build", "Pods", ".gradle", "target",
        "venv", ".venv", "__pycache__", ".cache", ".npm", ".cargo", ".rustup", "CoreSimulator",
    ]

    static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ exts: [String]) { for e in exts { map[e] = category } }
        add(.video, ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "mts", "braw", "r3d"])
        add(.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "caf"])
        add(.image, ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "psd", "raw", "cr2", "cr3",
                     "nef", "arw", "dng", "webp", "svg", "ai"])
        add(.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "img", "sparseimage",
                       "sparsebundle", "pkg", "mpkg", "ipsw", "xip"])
        add(.application, ["app"])
        add(.developer, ["o", "a", "dylib", "so", "xcarchive", "ipa", "apk", "aab", "jar", "class", "pyc",
                         "dSYM", "xcodeproj", "xcworkspace", "framework"])
        add(.document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt",
                        "md", "rtf", "epub", "csv", "json"])
        return map
    }()

    public static func classify(name: String, kind: NodeKind) -> FileCategory {
        if kind == .directory && developerFolders.contains(name) { return .developer }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...].lowercased()
            if let category = byExtension[ext] ?? byExtension[String(name[name.index(after: dot)...])] {
                return category
            }
        }
        return kind.isContainer ? .folder : .other
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let text: String
        if value >= 100 { text = String(format: "%.0f", value) }
        else if value >= 10 { text = String(format: "%.1f", value) }
        else { text = String(format: "%.2f", value) }
        return "\(text) \(units[unit])"
    }
}
