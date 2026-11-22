import Foundation

// MARK: Providers

/// A cloud service that keeps files in a folder on this Mac and can download them again on demand.
public struct CloudProvider: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case iCloudDrive, dropbox, oneDrive, googleDrive, box, other
    }

    public var id: String { rootPath }
    public let kind: Kind
    /// The service's name, such as "Dropbox" or "OneDrive".
    public let name: String
    /// The account or tenant from the folder name, such as "Personal" or an email address. Nil when there is none.
    public let account: String?
    public let rootPath: String

    public init(kind: Kind, name: String, account: String?, rootPath: String) {
        self.kind = kind
        self.name = name
        self.account = account
        self.rootPath = rootPath
    }

    /// The name with the account, for telling two accounts of one service apart.
    public var title: String {
        guard let account, !account.isEmpty else { return name }
        return "\(name) (\(account))"
    }
}

/// Where cloud folders live, and which service a folder or path belongs to. Only reads folder names.
public struct CloudLocations: Sendable {
    public let homePath: String

    public init(homePath: String = NSHomeDirectory()) {
        self.homePath = DiskScanner.standardize(homePath)
    }

    /// iCloud Drive and the iCloud folders of apps.
    public var mobileDocuments: String { homePath + "/Library/Mobile Documents" }
    /// Where macOS puts File Provider clouds such as Dropbox, OneDrive, Google Drive and Box, one folder per account.
    public var cloudStorage: String { homePath + "/Library/CloudStorage" }
    /// The folder of iCloud Drive itself inside `mobileDocuments`.
    public static let iCloudDriveFolder = "com~apple~CloudDocs"

    /// The service of a folder directly inside ~/Library/CloudStorage, from its name ("Dropbox",
    /// "OneDrive-Personal", "GoogleDrive-anna@example.com", "Box-Box"). Nil for hidden folders.
    public static func provider(folderName name: String, rootPath: String) -> CloudProvider? {
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        let service: Substring
        let account: String?
        if let dash = name.firstIndex(of: "-") {
            service = name[..<dash]
            let rest = String(name[name.index(after: dash)...])
            account = rest.isEmpty ? nil : rest
        } else {
            service = Substring(name)
            account = nil
        }
        let named: (kind: CloudProvider.Kind, display: String)
        switch service.lowercased() {
        case "dropbox": named = (.dropbox, "Dropbox")
        case "onedrive": named = (.oneDrive, "OneDrive")
        case "googledrive": named = (.googleDrive, "Google Drive")
        case "box": named = (.box, "Box")
        case "icloud", "iclouddrive": named = (.iCloudDrive, "iCloud Drive")
        default: named = (.other, String(service))
        }
        let (kind, display) = named
        // Box names its folder "Box-Box"; the repeated name is not an account.
        let shownAccount = account.flatMap { $0.caseInsensitiveCompare(display) == .orderedSame ? nil : $0 }
        return CloudProvider(kind: kind, name: display, account: shownAccount, rootPath: rootPath)
    }

    /// The iCloud provider, whose root is ~/Library/Mobile Documents.
    public var iCloud: CloudProvider {
        CloudProvider(kind: .iCloudDrive, name: "iCloud Drive", account: nil, rootPath: mobileDocuments)
    }

    /// The cloud folders on this Mac: iCloud when its folder exists, then each account in ~/Library/CloudStorage.
    public func providers() -> [CloudProvider] {
        var found: [CloudProvider] = []
        if Self.isDirectory(mobileDocuments + "/" + Self.iCloudDriveFolder) { found.append(iCloud) }
        if let entries = DirectoryReader.list(path: cloudStorage) {
            for entry in entries.sorted(by: { $0.name < $1.name }) where entry.kind == .directory {
                if let provider = Self.provider(folderName: entry.name, rootPath: DiskScanner.join(cloudStorage, entry.name)) {
                    found.append(provider)
                }
            }
        }
        return found
    }

    /// The provider whose folder holds `path`, among `providers`. A provider's own root folder is not inside it.
    public static func provider(containing path: String, in providers: [CloudProvider]) -> CloudProvider? {
        let path = DiskScanner.standardize(path)
        return providers.first { path.hasPrefix($0.rootPath + "/") }
    }

    /// The folder an item is grouped under: the first folder inside the provider, such as "Documents". In iCloud
    /// that is the first folder inside iCloud Drive, or the app's name for an app's own iCloud folder. Items
    /// directly in the root are grouped as "Top level".
    public static func group(of path: String, in provider: CloudProvider) -> (name: String, path: String) {
        let relative = String(path.dropFirst(provider.rootPath.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return (topLevel, provider.rootPath) }
        if provider.kind == .iCloudDrive && provider.rootPath.hasSuffix("/Mobile Documents") {
            if first == iCloudDriveFolder {
                let drive = provider.rootPath + "/" + first
                guard parts.count > 2 else { return (topLevel, drive) }
                return (parts[1], drive + "/" + parts[1])
            }
            return (appName(container: first), provider.rootPath + "/" + first)
        }
        guard parts.count > 1 else { return (topLevel, provider.rootPath) }
        return (first, provider.rootPath + "/" + first)
    }

    public static let topLevel = "Top level"

    /// A readable name for an app's iCloud folder: "iCloud~com~apple~Pages" becomes "Pages".
    public static func appName(container: String) -> String {
        let last = container.split(separator: "~").last.map(String.init) ?? container
        return last.isEmpty ? container : last
    }

    private static func isDirectory(_ path: String) -> Bool {
        DirectoryReader.entry(atPath: path)?.kind == .directory
    }
}

// MARK: Status

/// What the system says about a file's cloud copy. Each value may be unknown.
public struct CloudStatus: Sendable, Equatable {
    public enum Download: Sendable, Equatable {
        /// The newest version is on this Mac.
        case current
        /// A local copy is on this Mac, though a newer version may be in the cloud.
        case downloaded
        /// Only in the cloud.
        case notDownloaded
        case unknown
    }

    public var isCloudItem: Bool?
    public var download: Download
    public var isUploaded: Bool?
    public var isUploading: Bool?
    public var hasConflicts: Bool?

    public init(isCloudItem: Bool? = nil, download: Download = .unknown, isUploaded: Bool? = nil,
                isUploading: Bool? = nil, hasConflicts: Bool? = nil) {
        self.isCloudItem = isCloudItem
        self.download = download
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.hasConflicts = hasConflicts
    }
}

/// What may happen to a file's local copy.
public enum CloudVerdict: Sendable, Equatable {
    /// Safely in the cloud with a local copy: the local copy can be removed.
    case evictable
    /// Its changes have not all reached the cloud. Kept.
    case notUploaded
    /// Has unresolved version conflicts. Kept.
    case conflicted
    /// No local copy to remove.
    case notLocal
    /// Not a cloud file, or its state is unknown.
    case notCloud

    /// Kept even though it takes space on this Mac.
    public var isKept: Bool { self == .notUploaded || self == .conflicted }

    public var note: String? {
        switch self {
        case .notUploaded: return "Not uploaded yet — kept"
        case .conflicted: return "Has conflicting versions — kept"
        default: return nil
        }
    }
}

public enum CloudRule {
    /// A local copy is only removed when the system says the file is a cloud file, has a local copy, is fully
    /// uploaded, is not uploading and has no conflicts. Anything unknown keeps the file.
    public static func verdict(_ status: CloudStatus) -> CloudVerdict {
        guard status.isCloudItem == true else { return .notCloud }
        switch status.download {
        case .notDownloaded: return .notLocal
        case .unknown: return .notCloud
        case .current, .downloaded: break
        }
        if status.isUploaded != true || status.isUploading == true { return .notUploaded }
        if status.hasConflicts == true { return .conflicted }
        return .evictable
    }
}

/// Reads a file's cloud status. The app uses `SystemCloudStatus`; tests pass their own.
public protocol CloudStatusReading: Sendable {
    func status(of path: String) -> CloudStatus
}

/// Removes a file's local copy while it stays in the cloud.
public protocol CloudEvicting: Sendable {
    func evict(_ path: String) throws
}

/// Cloud status from the file's URL resource values. iCloud Drive and File Provider clouds (Dropbox, OneDrive,
/// Google Drive, Box on macOS 12.3 and later) answer these.
public struct SystemCloudStatus: CloudStatusReading {
    public init() {}

    public func status(of path: String) -> CloudStatus {
        #if canImport(Darwin)
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return CloudStatus() }
        var download = CloudStatus.Download.unknown
        if let value = values.ubiquitousItemDownloadingStatus {
            if value == .current {
                download = .current
            } else if value == .downloaded {
                download = .downloaded
            } else if value == .notDownloaded {
                download = .notDownloaded
            }
        }
        return CloudStatus(isCloudItem: values.isUbiquitousItem, download: download,
                           isUploaded: values.ubiquitousItemIsUploaded, isUploading: values.ubiquitousItemIsUploading,
                           hasConflicts: values.ubiquitousItemHasUnresolvedConflicts)
        #else
        return CloudStatus()
        #endif
    }
}

/// Removes local copies with `FileManager.evictUbiquitousItem(at:)`. The file stays in the cloud.
public struct SystemCloudEvictor: CloudEvicting {
    public init() {}

    public func evict(_ path: String) throws {
        #if canImport(Darwin)
        try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

// MARK: Finding

/// A file (or a document package such as a Pages file) with a local copy in a cloud folder.
public struct CloudItem: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let verdict: CloudVerdict

    public init(path: String, bytes: Int64, verdict: CloudVerdict) {
        self.path = path
        self.bytes = bytes
        self.verdict = verdict
    }
}

/// The local copies in one folder of a provider.
public struct CloudFolderGroup: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public var items: [CloudItem]

    public init(id: String, name: String, path: String, items: [CloudItem]) {
        self.id = id
        self.name = name
        self.path = path
        self.items = items
    }

    public var evictable: [CloudItem] { items.filter { $0.verdict == .evictable } }
    public var evictableBytes: Int64 { evictable.reduce(0) { $0 + $1.bytes } }
    public var kept: [CloudItem] { items.filter(\.verdict.isKept) }
    public var keptBytes: Int64 { kept.reduce(0) { $0 + $1.bytes } }
}

/// One provider and its folders with local copies, largest first.
public struct CloudProviderFindings: Sendable, Identifiable, Equatable {
    public var id: String { provider.id }
    public let provider: CloudProvider
    public var groups: [CloudFolderGroup]

    public init(provider: CloudProvider, groups: [CloudFolderGroup]) {
        self.provider = provider
        self.groups = groups
    }

    public var evictableBytes: Int64 { groups.reduce(0) { $0 + $1.evictableBytes } }
    public var keptBytes: Int64 { groups.reduce(0) { $0 + $1.keptBytes } }
    public var keptCount: Int { groups.reduce(0) { $0 + $1.kept.count } }
}

/// Walks cloud folders and lists the files that have a local copy, grouped by provider and top folder.
public struct CloudSpaceFinder: Sendable {
    public struct Progress: Sendable, Equatable {
        public var provider: String
        public var filesChecked: Int
    }

    public struct Findings: Sendable, Equatable {
        public var providers: [CloudProviderFindings] = []
        /// True when a provider had more files than are checked, so some were not looked at.
        public var capped = false

        public init(providers: [CloudProviderFindings] = [], capped: Bool = false) {
            self.providers = providers
            self.capped = capped
        }

        public var evictableBytes: Int64 { providers.reduce(0) { $0 + $1.evictableBytes } }
        public var groups: [CloudFolderGroup] { providers.flatMap(\.groups) }
    }

    /// At most this many files are checked in each provider.
    public static let fileLimit = 250_000
    /// Folders saved as one document. Their local copy is removed as a whole.
    public static let packageExtensions: Set<String> = [
        "pages", "numbers", "key", "rtfd", "band", "logicx", "fcpbundle", "imovielibrary", "playground", "scriv",
    ]

    public let providers: [CloudProvider]
    public var status: any CloudStatusReading
    public var fileLimit: Int

    public init(providers: [CloudProvider], status: any CloudStatusReading = SystemCloudStatus(),
                fileLimit: Int = CloudSpaceFinder.fileLimit) {
        self.providers = providers
        self.status = status
        self.fileLimit = fileLimit
    }

    public func find(progress: (@Sendable (Progress) -> Void)? = nil) -> Findings {
        var findings = Findings()
        for provider in providers {
            if Task.isCancelled { break }
            let (items, capped) = walk(provider, progress: progress)
            findings.capped = findings.capped || capped
            let groups = Self.group(items, in: provider)
            if !groups.isEmpty { findings.providers.append(CloudProviderFindings(provider: provider, groups: groups)) }
        }
        findings.providers.sort {
            let a = $0.evictableBytes + $0.keptBytes, b = $1.evictableBytes + $1.keptBytes
            return a != b ? a > b : $0.provider.title < $1.provider.title
        }
        return findings
    }

    /// Groups items by their top folder, largest first, and each group's items largest first.
    public static func group(_ items: [CloudItem], in provider: CloudProvider) -> [CloudFolderGroup] {
        var byPath: [String: CloudFolderGroup] = [:]
        for item in items {
            let (name, path) = CloudLocations.group(of: item.path, in: provider)
            byPath[path, default: CloudFolderGroup(id: path, name: name, path: path, items: [])].items.append(item)
        }
        return byPath.values.map { group in
            var group = group
            group.items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            return group
        }
        .sorted {
            let a = $0.evictableBytes + $0.keptBytes, b = $1.evictableBytes + $1.keptBytes
            return a != b ? a > b : $0.name < $1.name
        }
    }

    /// Lists the files with a local copy. Files that take no space are skipped without asking for their status.
    private func walk(_ provider: CloudProvider, progress: (@Sendable (Progress) -> Void)?) -> ([CloudItem], Bool) {
        var items: [CloudItem] = []
        var checked = 0
        var stack = [provider.rootPath]
        while let dir = stack.popLast() {
            if Task.isCancelled { break }
            guard let entries = DirectoryReader.list(path: dir) else { continue }
            for entry in entries where !entry.name.hasPrefix(".") {
                let path = DiskScanner.join(dir, entry.name)
                switch entry.kind {
                case .directory:
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    if Self.packageExtensions.contains(ext) {
                        let bytes = OldDownloadsFinder.walk(path).bytes
                        checked += 1
                        if bytes > 0, let item = item(path, bytes: bytes) { items.append(item) }
                    } else {
                        stack.append(path)
                    }
                case .file:
                    checked += 1
                    if entry.allocated > 0, let item = item(path, bytes: entry.allocated) { items.append(item) }
                default:
                    continue
                }
                if checked % 500 == 0 { progress?(Progress(provider: provider.title, filesChecked: checked)) }
                if checked >= fileLimit { return (items, true) }
            }
        }
        progress?(Progress(provider: provider.title, filesChecked: checked))
        return (items, false)
    }

    private func item(_ path: String, bytes: Int64) -> CloudItem? {
        let verdict = CloudRule.verdict(status.status(of: path))
        guard verdict == .evictable || verdict.isKept else { return nil }
        return CloudItem(path: path, bytes: bytes, verdict: verdict)
    }
}

// MARK: Selection

/// Which folder groups are ticked. Only their evictable items are ever acted on.
public struct CloudSelection: Sendable, Equatable {
    public private(set) var ids: Set<String> = []

    public init() {}

    public func contains(_ group: CloudFolderGroup) -> Bool { ids.contains(group.id) }

    /// A group with nothing to remove cannot be ticked.
    public mutating func toggle(_ group: CloudFolderGroup) {
        if ids.contains(group.id) {
            ids.remove(group.id)
        } else if !group.evictable.isEmpty {
            ids.insert(group.id)
        }
    }

    public mutating func setAll(_ provider: CloudProviderFindings, selected: Bool) {
        let tickable = provider.groups.filter { !$0.evictable.isEmpty }.map(\.id)
        if selected { ids.formUnion(tickable) } else { ids.subtract(provider.groups.map(\.id)) }
    }

    public func state(of provider: CloudProviderFindings) -> JunkSelection.State {
        let tickable = provider.groups.filter { !$0.evictable.isEmpty }
        let count = tickable.filter { ids.contains($0.id) }.count
        if count == 0 { return .none }
        return count == tickable.count ? .all : .some
    }

    /// The files whose local copies would be removed: the evictable items of the ticked groups.
    public func selectedItems(in findings: CloudSpaceFinder.Findings) -> [CloudItem] {
        findings.groups.filter { ids.contains($0.id) }.flatMap(\.evictable)
    }

    public func selectedBytes(in findings: CloudSpaceFinder.Findings) -> Int64 {
        selectedItems(in: findings).reduce(0) { $0 + $1.bytes }
    }

    /// The providers with a ticked group, in the findings' order.
    public func selectedProviders(in findings: CloudSpaceFinder.Findings) -> [CloudProvider] {
        findings.providers.filter { provider in provider.groups.contains { ids.contains($0.id) } }.map(\.provider)
    }

    /// Drops groups that are gone.
    public mutating func keep(only findings: CloudSpaceFinder.Findings) {
        ids.formIntersection(findings.groups.map(\.id))
    }
}

// MARK: Removing local copies

public struct CloudEvictionResult: Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    /// Why the local copy was kept or could not be removed. Nil when it was removed.
    public let error: String?

    public init(path: String, bytes: Int64, error: String?) {
        self.path = path
        self.bytes = bytes
        self.error = error
    }

    public var succeeded: Bool { error == nil }
}

public struct CloudEvictionReport: Sendable, Equatable {
    public let results: [CloudEvictionResult]

    public init(results: [CloudEvictionResult]) {
        self.results = results
    }

    public var succeeded: [CloudEvictionResult] { results.filter(\.succeeded) }
    public var failed: [CloudEvictionResult] { results.filter { !$0.succeeded } }
    public var freedBytes: Int64 { succeeded.reduce(0) { $0 + $1.bytes } }
}

/// Removes local copies of cloud files. It never moves or deletes a file: the only action is evicting, and only
/// for files inside a known cloud folder whose status, read again just before, still says they are safely uploaded.
public struct CloudEvictionService: Sendable {
    public let providers: [CloudProvider]
    public var status: any CloudStatusReading
    public var evictor: any CloudEvicting

    public init(providers: [CloudProvider], status: any CloudStatusReading = SystemCloudStatus(),
                evictor: any CloudEvicting = SystemCloudEvictor()) {
        self.providers = providers
        self.status = status
        self.evictor = evictor
    }

    public func evict(_ items: [CloudItem], onEach: ((CloudEvictionResult) -> Void)? = nil) -> CloudEvictionReport {
        var results: [CloudEvictionResult] = []
        for item in items {
            if Task.isCancelled { break }
            let result = evictOne(item)
            results.append(result)
            onEach?(result)
        }
        return CloudEvictionReport(results: results)
    }

    private func evictOne(_ item: CloudItem) -> CloudEvictionResult {
        guard CloudLocations.provider(containing: item.path, in: providers) != nil else {
            return CloudEvictionResult(path: item.path, bytes: item.bytes, error: "Not in a cloud folder")
        }
        let verdict = CloudRule.verdict(status.status(of: item.path))
        guard verdict == .evictable else {
            let reason = verdict.note ?? (verdict == .notLocal ? "Already only in the cloud" : "Not a cloud file — kept")
            return CloudEvictionResult(path: item.path, bytes: verdict == .notLocal ? 0 : item.bytes, error: reason)
        }
        do {
            try evictor.evict(item.path)
            return CloudEvictionResult(path: item.path, bytes: item.bytes, error: nil)
        } catch {
            return CloudEvictionResult(path: item.path, bytes: item.bytes, error: error.localizedDescription)
        }
    }
}
