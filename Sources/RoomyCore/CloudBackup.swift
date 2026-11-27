import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

// MARK: Thresholds

/// How big a file must be before Cloud Backup offers to move it.
public enum BackupMinimumSize: Int64, CaseIterable, Sendable, Identifiable {
    case mb100 = 100_000_000
    case mb250 = 250_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000
    case gb5 = 5_000_000_000

    public var id: Int64 { rawValue }
    public static let standard = BackupMinimumSize.mb500

    /// "100 MB", "1 GB". Units are not translated anywhere in the app.
    public var label: String {
        rawValue >= 1_000_000_000 ? "\(rawValue / 1_000_000_000) GB" : "\(rawValue / 1_000_000) MB"
    }
}

/// How long a file must have gone unused before Cloud Backup offers to move it.
public enum BackupUnusedFor: Int, CaseIterable, Sendable, Identifiable {
    case months3 = 3
    case months6 = 6
    case months12 = 12
    case months24 = 24

    public var id: Int { rawValue }
    public static let standard = BackupUnusedFor.months6

    public var label: String {
        switch self {
        case .months3, .months6: return String(format: String(localized: "%lld months"), rawValue)
        case .months12: return String(localized: "1 year")
        case .months24: return String(format: String(localized: "%lld years"), rawValue / 12)
        }
    }
}

// MARK: Last used

/// The dates that tell when a file was last used. Any of them may be unknown.
public struct BackupFileDates: Sendable, Equatable {
    /// When the file was last opened, from Spotlight (kMDItemLastUsedDate).
    public var lastUsed: Date?
    /// The last access date. macOS updates it lazily, so it is only one of the dates looked at.
    public var accessed: Date?
    public var modified: Date?
    public var created: Date?

    public init(lastUsed: Date? = nil, accessed: Date? = nil, modified: Date? = nil, created: Date? = nil) {
        self.lastUsed = lastUsed
        self.accessed = accessed
        self.modified = modified
        self.created = created
    }
}

public enum BackupRule {
    /// The last time anything happened to the file: the latest of all the dates that are known. A file counts as
    /// used when any one of them is recent, so no single date (such as the lazy access date) can make it look old.
    public static func lastUsed(_ dates: BackupFileDates) -> Date? {
        [dates.lastUsed, dates.accessed, dates.modified, dates.created].compactMap { $0 }.max()
    }

    /// The moment before which a file counts as unused: `months` calendar months before `now`.
    public static func cutoff(now: Date, months: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(byAdding: .month, value: -months, to: now) ?? now.addingTimeInterval(-Double(months) * 30 * 86_400)
    }

    /// True when nothing happened to the file for `months`. A file with no known date is never unused.
    public static func isUnused(_ dates: BackupFileDates, now: Date, months: Int) -> Bool {
        guard let last = lastUsed(dates) else { return false }
        return last <= cutoff(now: now, months: months)
    }

    /// Whole months from `date` to `now`, for "Last used 14 months ago".
    public static func monthsSince(_ date: Date, now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return max(0, calendar.dateComponents([.month], from: date, to: now).month ?? 0)
    }
}

/// Reads a file's dates. The app uses `SystemBackupDates`; tests pass their own.
public protocol BackupDateReading: Sendable {
    func dates(of path: String) -> BackupFileDates
}

/// The file system's dates plus Spotlight's last-used date, when Spotlight knows the file.
public struct SystemBackupDates: BackupDateReading {
    public init() {}

    public func dates(of path: String) -> BackupFileDates {
        #if canImport(Darwin)
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey, .creationDateKey]
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
        var dates = BackupFileDates(accessed: values?.contentAccessDate, modified: values?.contentModificationDate,
                                    created: values?.creationDate)
        #if canImport(CoreServices)
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
            dates.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        #endif
        return dates
        #else
        guard let entry = DirectoryReader.entry(atPath: path) else { return BackupFileDates() }
        return BackupFileDates(modified: Date(timeIntervalSince1970: TimeInterval(entry.modified)))
        #endif
    }
}

// MARK: Finding

/// A big file that has not been used for a long time.
public struct BackupCandidate: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    /// The space the file takes on disk.
    public let bytes: Int64
    /// The file's length, checked again just before it is moved.
    public let length: Int64
    public let lastUsed: Date

    public init(path: String, name: String, bytes: Int64, length: Int64, lastUsed: Date) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.length = length
        self.lastUsed = lastUsed
    }

    public var folderPath: String { (path as NSString).deletingLastPathComponent }
}

/// The candidates in one folder.
public struct BackupFolderGroup: Sendable, Identifiable, Equatable {
    public var id: String { path }
    /// The folder relative to the home folder, such as "Documents/Renders", or "Home" for files directly in it.
    public let name: String
    public let path: String
    public var items: [BackupCandidate]

    public init(name: String, path: String, items: [BackupCandidate]) {
        self.name = name
        self.path = path
        self.items = items
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Looks through the home folders for big files that have not been used for a long time. It only reads.
///
/// It never looks in ~/Library, hidden files and folders, packages (apps, Photos and Music libraries, Final Cut
/// bundles and other folders macOS shows as one file), cloud folders, or through links. Files with more than one
/// hard link are left out, since moving one name frees nothing. Every file must also be allowed by `policy`.
public struct CloudBackupFinder: Sendable {
    public struct Progress: Sendable, Equatable {
        public var filesChecked: Int
        public var folder: String
    }

    public struct Findings: Sendable, Equatable {
        public var groups: [BackupFolderGroup]
        public var filesChecked: Int
        /// True when there were more files than are checked, so some were not looked at.
        public var capped: Bool

        public init(groups: [BackupFolderGroup] = [], filesChecked: Int = 0, capped: Bool = false) {
            self.groups = groups
            self.filesChecked = filesChecked
            self.capped = capped
        }

        public var items: [BackupCandidate] { groups.flatMap(\.items) }
        public var bytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }

        /// The findings without these files, and without folders left empty.
        public func removing(_ paths: Set<String>) -> Findings {
            var copy = self
            for g in copy.groups.indices { copy.groups[g].items.removeAll { paths.contains($0.path) } }
            copy.groups.removeAll { $0.items.isEmpty }
            return copy
        }
    }

    /// The home folders looked through. Files directly in the home folder are looked at too.
    public static let homeFolders = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
    /// At most this many files are checked.
    public static let fileLimit = 500_000
    /// Folders that macOS shows as one file. They are never looked into or moved.
    public static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "fcpproject", "imovielibrary", "theater", "logicx", "band", "bundle", "framework", "plugin",
        "kext", "xcarchive", "xcodeproj", "xcworkspace", "pages", "numbers", "key", "rtfd", "sparsebundle",
        "vmwarevm", "pvm", "utm", "lrdata", "cocatalog", "dvdmedia", "prproj", "screenflow", "scriv",
    ]

    public let homePath: String
    public var roots: [String]
    /// Whether files directly in the home folder are looked at.
    public var includeHomeFiles: Bool
    public var minimumBytes: Int64
    public var unusedMonths: Int
    public var now: Date
    public var policy: SafetyPolicy
    public var providers: [CloudProvider]
    public var dates: any BackupDateReading
    public var fileLimit: Int

    /// `roots` nil means the usual home folders. `providers` nil means the cloud folders found in `homePath`.
    public init(homePath: String = NSHomeDirectory(), roots: [String]? = nil, includeHomeFiles: Bool = true,
                minimumBytes: Int64 = BackupMinimumSize.standard.rawValue,
                unusedMonths: Int = BackupUnusedFor.standard.rawValue, now: Date = Date(),
                policy: SafetyPolicy? = nil, providers: [CloudProvider]? = nil,
                dates: any BackupDateReading = SystemBackupDates(), fileLimit: Int = CloudBackupFinder.fileLimit) {
        let home = DiskScanner.standardize(homePath)
        self.homePath = home
        self.roots = (roots ?? Self.homeFolders.map { home + "/" + $0 }).map(DiskScanner.standardize)
        self.includeHomeFiles = includeHomeFiles
        self.minimumBytes = minimumBytes
        self.unusedMonths = unusedMonths
        self.now = now
        self.policy = policy ?? SafetyPolicy(homePath: home)
        self.providers = providers ?? CloudLocations(homePath: home).providers()
        self.dates = dates
        self.fileLimit = fileLimit
    }

    public func find(progress: (@Sendable (Progress) -> Void)? = nil) -> Findings {
        var found: [BackupCandidate] = []
        var checked = 0
        var capped = false

        func look(at entry: RawEntry, in dir: String) {
            checked += 1
            if checked % 500 == 0 { progress?(Progress(filesChecked: checked, folder: dir)) }
            if let candidate = candidate(entry, in: dir) { found.append(candidate) }
        }

        if includeHomeFiles, let entries = DirectoryReader.list(path: homePath) {
            for entry in entries where entry.kind == .file && !entry.name.hasPrefix(".") {
                look(at: entry, in: homePath)
            }
        }
        walk: for root in roots where DirectoryReader.entry(atPath: root)?.kind == .directory && !isSkippedFolder(root) {
            var stack = [root]
            while let dir = stack.popLast() {
                if Task.isCancelled { break walk }
                guard let entries = DirectoryReader.list(path: dir) else { continue }
                for entry in entries where !entry.name.hasPrefix(".") {
                    let path = DiskScanner.join(dir, entry.name)
                    switch entry.kind {
                    case .directory:
                        if !isSkippedFolder(path) { stack.append(path) }
                    case .file:
                        look(at: entry, in: dir)
                        if checked >= fileLimit {
                            capped = true
                            break walk
                        }
                    default:
                        // Links and anything else that is not a plain file or folder.
                        continue
                    }
                }
            }
        }
        progress?(Progress(filesChecked: checked, folder: homePath))
        return Findings(groups: group(found), filesChecked: checked, capped: capped)
    }

    /// Folders never looked into: hidden ones, packages, ~/Library and cloud folders.
    func isSkippedFolder(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return true }
        if Self.isPackage(path) { return true }
        let lower = path.lowercased()
        if lower == (homePath + "/Library").lowercased() || lower.hasPrefix((homePath + "/Library/").lowercased()) { return true }
        if isInCloud(path) { return true }
        return false
    }

    func isInCloud(_ path: String) -> Bool {
        providers.contains { path == $0.rootPath || path.hasPrefix($0.rootPath + "/") }
    }

    /// A folder macOS shows as one file: by its extension, or as the system says.
    static func isPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if packageExtensions.contains(ext) { return true }
        #if canImport(Darwin)
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        #else
        return false
        #endif
    }

    private func candidate(_ entry: RawEntry, in dir: String) -> BackupCandidate? {
        guard entry.kind == .file, entry.allocated >= minimumBytes, entry.linkCount <= 1 else { return nil }
        let path = DiskScanner.join(dir, entry.name)
        guard !isInCloud(path), policy.verdict(for: path) == .allowed else { return nil }
        let dates = self.dates.dates(of: path)
        guard BackupRule.isUnused(dates, now: now, months: unusedMonths), let last = BackupRule.lastUsed(dates) else { return nil }
        return BackupCandidate(path: path, name: entry.name, bytes: entry.allocated, length: entry.length, lastUsed: last)
    }

    /// Groups the files by folder, largest folder first, and each folder's files largest first.
    func group(_ items: [BackupCandidate]) -> [BackupFolderGroup] {
        var byFolder: [String: [BackupCandidate]] = [:]
        for item in items { byFolder[item.folderPath, default: []].append(item) }
        return byFolder.map { folder, items in
            BackupFolderGroup(name: Self.folderName(folder, home: homePath), path: folder,
                              items: items.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path })
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    public static let homeName = String(localized: "Home")

    /// "Documents/Renders" for a folder in the home folder, "Home" for the home folder itself.
    public static func folderName(_ folder: String, home: String) -> String {
        if folder == home { return homeName }
        if folder.hasPrefix(home + "/") { return String(folder.dropFirst(home.count + 1)) }
        return folder
    }
}

// MARK: Destinations

/// A cloud folder that backed-up files are moved into, inside a `RoomyDisk Backup` folder.
public struct BackupDestination: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { folderPath }
    public let provider: CloudProvider
    /// The cloud folder itself: iCloud Drive, a provider's root, or a folder the person chose inside one.
    public let folderPath: String

    public init(provider: CloudProvider, folderPath: String) {
        self.provider = provider
        self.folderPath = DiskScanner.standardize(folderPath)
    }

    /// Where the files go: `<folder>/RoomyDisk Backup`.
    public var backupFolder: String { folderPath + "/" + CloudBackupPlaces.folderName }

    /// True when this is the provider's own top folder, rather than a folder chosen inside it.
    public func isTopFolder(_ locations: CloudLocations) -> Bool {
        folderPath == provider.rootPath || folderPath == locations.mobileDocuments + "/" + CloudLocations.iCloudDriveFolder
    }

    /// "iCloud Drive", or "Dropbox › Archive" for a chosen folder.
    public func title(_ locations: CloudLocations) -> String {
        isTopFolder(locations) ? provider.title : provider.title + " › " + (folderPath as NSString).lastPathComponent
    }
}

public enum CloudBackupPlaces {
    /// The folder made inside the cloud folder for backed-up files. A name, so it is not translated.
    public static let folderName = "RoomyDisk Backup"

    /// A destination for each cloud folder: iCloud Drive first, then the File Provider clouds in name order.
    public static func destinations(_ providers: [CloudProvider], locations: CloudLocations) -> [BackupDestination] {
        let all = providers.map { provider -> BackupDestination in
            if provider.kind == .iCloudDrive && provider.rootPath == locations.mobileDocuments {
                return BackupDestination(provider: provider,
                                         folderPath: locations.mobileDocuments + "/" + CloudLocations.iCloudDriveFolder)
            }
            return BackupDestination(provider: provider, folderPath: provider.rootPath)
        }
        return all.filter { $0.provider.kind == .iCloudDrive } + all.filter { $0.provider.kind != .iCloudDrive }
    }

    /// The destination for a folder the person chose, or nil when it is not inside a cloud folder (so files there
    /// would not sync). Choosing ~/Library/Mobile Documents itself means iCloud Drive.
    public static func destination(forChosen rawPath: String, providers: [CloudProvider],
                                   locations: CloudLocations) -> BackupDestination? {
        let path = DiskScanner.standardize(rawPath)
        for provider in providers where path == provider.rootPath || path.hasPrefix(provider.rootPath + "/") {
            if provider.kind == .iCloudDrive && path == locations.mobileDocuments {
                return BackupDestination(provider: provider,
                                         folderPath: locations.mobileDocuments + "/" + CloudLocations.iCloudDriveFolder)
            }
            // Inside a backup folder means its cloud folder, so backups never nest.
            if let range = path.range(of: "/" + folderName, options: .backwards),
               range.upperBound == path.endIndex || path[range.upperBound] == "/" {
                return BackupDestination(provider: provider, folderPath: String(path[..<range.lowerBound]))
            }
            return BackupDestination(provider: provider, folderPath: path)
        }
        return nil
    }

    /// Where a file goes: `<backup folder>/<its path relative to the home folder>`.
    public static func target(for original: String, homePath: String, in destination: BackupDestination) -> String {
        let path = DiskScanner.standardize(original)
        let home = DiskScanner.standardize(homePath)
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : String(path.drop { $0 == "/" })
        return destination.backupFolder + "/" + relative
    }

    /// `path`, or the first of "name 2.ext", "name 3.ext", … that is free, so nothing is ever overwritten.
    public static func unclashed(_ path: String, exists given: ((String) -> Bool)? = nil) -> String {
        let exists = given ?? { DirectoryReader.entry(atPath: $0) != nil }
        guard exists(path) else { return path }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 2...9_999 {
            let candidate = DiskScanner.join(folder, ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return DiskScanner.join(folder, "\(base) \(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

// MARK: Manifest

/// One file Cloud Backup moved: where it was, where it went, how big it was and when.
public struct BackupRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let originalPath: String
    public let destinationPath: String
    public let bytes: Int64
    public let length: Int64
    public let date: Date
    /// The cloud service, such as "iCloud Drive".
    public let provider: String
    /// The Finder alias left in the file's old place. Nil when none was left.
    public var aliasPath: String?

    public init(id: UUID = UUID(), originalPath: String, destinationPath: String, bytes: Int64, length: Int64,
                date: Date, provider: String, aliasPath: String? = nil) {
        self.id = id
        self.originalPath = originalPath
        self.destinationPath = destinationPath
        self.bytes = bytes
        self.length = length
        self.date = date
        self.provider = provider
        self.aliasPath = aliasPath
    }

    public var name: String { (destinationPath as NSString).lastPathComponent }
}

/// The list of backed-up files, kept as JSON (normally ~/Library/Application Support/RoomyDisk/cloud-backup.json).
public struct BackupManifest: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: BackupManifest {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return BackupManifest(fileURL: support.appendingPathComponent("RoomyDisk/cloud-backup.json"))
    }

    private struct File: Codable {
        var version = 1
        var records: [BackupRecord]
    }

    /// The records, oldest first. Empty when there is no file or it cannot be read.
    public func load() -> [BackupRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.records ?? []
    }

    public func save(_ records: [BackupRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(records: records)).write(to: fileURL, options: .atomic)
    }
}

// MARK: Aliases

/// Makes and recognises the Finder aliases left in a file's old place.
public protocol BackupAliasMaking: Sendable {
    func makeAlias(at path: String, to target: String) throws
    func isAlias(_ path: String) -> Bool
}

/// Real Finder aliases, written from bookmark data.
public struct FinderAliases: BackupAliasMaking {
    public init() {}

    public func makeAlias(at path: String, to target: String) throws {
        #if canImport(Darwin)
        let data = try URL(fileURLWithPath: target).bookmarkData(options: .suitableForBookmarkFile,
                                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: URL(fileURLWithPath: path))
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// A small plain file that macOS says is an alias. Links are never taken for aliases.
    public func isAlias(_ path: String) -> Bool {
        guard let entry = DirectoryReader.entry(atPath: path), entry.kind == .file, entry.length < 4_000_000 else { return false }
        #if canImport(Darwin)
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
        #else
        return false
        #endif
    }
}

// MARK: Upload state

/// Where a backed-up file is with its upload.
public enum BackupUploadState: Sendable, Equatable {
    /// Uploaded, with a local copy that can be removed to free space.
    case uploaded
    case uploading
    case waiting
    /// Only in the cloud: its space on this Mac is free.
    case cloudOnly
    case conflicted
    /// The system does not say this is a cloud file.
    case notSyncing
    /// The file is no longer in the cloud folder.
    case missing

    public static func of(_ status: CloudStatus) -> BackupUploadState {
        guard status.isCloudItem == true else { return .notSyncing }
        if status.download == .notDownloaded { return .cloudOnly }
        if status.hasConflicts == true { return .conflicted }
        if status.isUploading == true { return .uploading }
        if status.isUploaded == true { return .uploaded }
        return .waiting
    }

    /// True when its local copy can be removed, by the same rule Cloud Space uses.
    public var canFree: Bool { self == .uploaded }
}

// MARK: Moving and restoring

public struct CloudBackupResult: Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let record: BackupRecord?
    /// Why the file was not moved. Nil when it was.
    public let error: String?
    /// Something worth saying about a file that was moved, such as an alias that could not be made.
    public let note: String?

    public init(path: String, bytes: Int64, record: BackupRecord? = nil, error: String? = nil, note: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.record = record
        self.error = error
        self.note = note
    }

    public var succeeded: Bool { error == nil }
}

public struct CloudBackupReport: Sendable, Equatable {
    public let results: [CloudBackupResult]

    public init(results: [CloudBackupResult]) {
        self.results = results
    }

    public var succeeded: [CloudBackupResult] { results.filter(\.succeeded) }
    public var failed: [CloudBackupResult] { results.filter { !$0.succeeded } }
    public var movedBytes: Int64 { succeeded.reduce(0) { $0 + $1.bytes } }
}

public struct BackupRestoreResult: Sendable, Equatable {
    public let record: BackupRecord
    /// Where the file was put back. Nil when it was not.
    public let restoredTo: String?
    public let error: String?

    public var succeeded: Bool { error == nil }
}

/// Moves files into a cloud folder and back. Each file is checked again just before it moves: it must still be the
/// same plain file, allowed by the safety rules, and outside any cloud folder; the destination must be inside a
/// known cloud folder (and inside the flow test's sandbox when there is one). Nothing is ever overwritten or deleted,
/// except the Finder alias Cloud Backup itself left behind.
public struct CloudBackupService: Sendable {
    public let homePath: String
    public let policy: SafetyPolicy
    public let providers: [CloudProvider]
    public let manifest: BackupManifest
    public var leavesAlias: Bool
    public var aliases: any BackupAliasMaking
    public var status: any CloudStatusReading
    public var now: @Sendable () -> Date

    public init(homePath: String, policy: SafetyPolicy, providers: [CloudProvider], manifest: BackupManifest,
                leavesAlias: Bool = true, aliases: any BackupAliasMaking = FinderAliases(),
                status: any CloudStatusReading = SystemCloudStatus(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.homePath = DiskScanner.standardize(homePath)
        self.policy = policy
        self.providers = providers
        self.manifest = manifest
        self.leavesAlias = leavesAlias
        self.aliases = aliases
        self.status = status
        self.now = now
    }

    public func backUp(_ items: [BackupCandidate], to destination: BackupDestination,
                       onEach: ((CloudBackupResult) -> Void)? = nil) -> CloudBackupReport {
        var results: [CloudBackupResult] = []
        for item in items {
            if Task.isCancelled { break }
            let result = backUp(item, to: destination)
            results.append(result)
            onEach?(result)
        }
        return CloudBackupReport(results: results)
    }

    /// True when `path` is inside a known cloud folder, and inside the policy's confinement when it has one.
    func isUsableCloudPath(_ path: String) -> Bool {
        let path = DiskScanner.standardize(path)
        guard providers.contains(where: { path == $0.rootPath || path.hasPrefix($0.rootPath + "/") }) else { return false }
        if let root = policy.confinedTo, !path.lowercased().hasPrefix(root.lowercased() + "/") { return false }
        return true
    }

    public func backUp(_ item: BackupCandidate, to destination: BackupDestination) -> CloudBackupResult {
        func fail(_ reason: String) -> CloudBackupResult { CloudBackupResult(path: item.path, bytes: item.bytes, error: reason) }
        let fm = FileManager.default

        guard isUsableCloudPath(destination.folderPath), DirectoryReader.entry(atPath: destination.folderPath)?.kind == .directory else {
            return fail(String(localized: "The cloud folder is not available."))
        }
        guard let entry = DirectoryReader.entry(atPath: item.path), entry.kind == .file else {
            return fail(String(localized: "The file is no longer there."))
        }
        guard entry.length == item.length else { return fail(String(localized: "The file changed since it was found.")) }
        let verdict = policy.verdict(for: item.path)
        guard verdict == .allowed else { return fail(verdict.message ?? String(localized: "RoomyDisk does not move this file.")) }
        guard CloudLocations.provider(containing: item.path, in: providers) == nil else {
            return fail(String(localized: "This file is already in a cloud folder."))
        }

        let target = CloudBackupPlaces.unclashed(CloudBackupPlaces.target(for: item.path, homePath: homePath, in: destination))
        guard target.hasPrefix(destination.backupFolder + "/") else { return fail(String(localized: "The cloud folder is not available.")) }
        do {
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: item.path, toPath: target)
        } catch {
            return fail(error.localizedDescription)
        }

        // The file must have arrived whole. If not, it goes back where it was.
        guard let moved = DirectoryReader.entry(atPath: target), moved.kind == .file, moved.length == item.length else {
            if DirectoryReader.entry(atPath: item.path) == nil, (try? fm.moveItem(atPath: target, toPath: item.path)) != nil {
                return fail(String(localized: "The file did not arrive whole in the cloud folder, so it was left in place."))
            }
            return fail(String(format: String(localized: "The file did not arrive whole. What arrived is at %@."), target))
        }

        var record = BackupRecord(originalPath: item.path, destinationPath: target, bytes: item.bytes, length: item.length,
                                  date: now(), provider: destination.provider.name)
        var records = manifest.load()
        records.append(record)
        do {
            try manifest.save(records)
        } catch {
            // Without a record it could not be restored from here, so it goes back.
            if (try? fm.moveItem(atPath: target, toPath: item.path)) != nil {
                return fail(String(format: String(localized: "Could not save the list of backed-up files, so the file was left in place. %@"),
                                   error.localizedDescription))
            }
            return fail(error.localizedDescription)
        }

        var note: String?
        if leavesAlias && DirectoryReader.entry(atPath: item.path) == nil {
            do {
                try aliases.makeAlias(at: item.path, to: target)
                record.aliasPath = item.path
                records[records.count - 1] = record
                try? manifest.save(records)
            } catch {
                note = String(localized: "No alias could be left in its old place.")
            }
        }
        return CloudBackupResult(path: item.path, bytes: item.bytes, record: record, note: note)
    }

    /// Moves a backed-up file back to where it was and removes the alias left there. If a real file has taken its
    /// place since, it is put back next to it with a number added to its name.
    public func restore(_ record: BackupRecord) -> BackupRestoreResult {
        func fail(_ reason: String) -> BackupRestoreResult { BackupRestoreResult(record: record, restoredTo: nil, error: reason) }
        let fm = FileManager.default
        guard isUsableCloudPath(record.destinationPath) else { return fail(String(localized: "This file is not in a cloud folder.")) }
        guard let entry = DirectoryReader.entry(atPath: record.destinationPath), entry.kind == .file else {
            return fail(String(localized: "The file is no longer in the cloud folder."))
        }
        if status.status(of: record.destinationPath).download == .notDownloaded {
            #if canImport(Darwin)
            try? fm.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: record.destinationPath))
            #endif
            return fail(String(localized: "Downloading it from the cloud first. Try again when it has downloaded."))
        }
        let original = DiskScanner.standardize(record.originalPath)
        let verdict = policy.verdict(for: original)
        guard !verdict.isBlocked else { return fail(verdict.message ?? String(localized: "RoomyDisk does not move this file.")) }

        var place = original
        if DirectoryReader.entry(atPath: original) != nil {
            if record.aliasPath == original && aliases.isAlias(original) {
                do { try fm.removeItem(atPath: original) } catch { return fail(error.localizedDescription) }
            } else {
                place = CloudBackupPlaces.unclashed(original)
            }
        }
        do {
            try fm.createDirectory(atPath: (place as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: record.destinationPath, toPath: place)
        } catch {
            return fail(error.localizedDescription)
        }
        let records = manifest.load().filter { $0.id != record.id }
        try? manifest.save(records)
        return BackupRestoreResult(record: record, restoredTo: place, error: nil)
    }

    /// Forgets a record whose file is gone from the cloud folder. Nothing on disk is touched.
    public func forget(_ record: BackupRecord) {
        try? manifest.save(manifest.load().filter { $0.id != record.id })
    }

    public func state(of record: BackupRecord) -> BackupUploadState {
        guard DirectoryReader.entry(atPath: record.destinationPath)?.kind == .file else { return .missing }
        return BackupUploadState.of(status.status(of: record.destinationPath))
    }

    /// Removes the local copies of uploaded backed-up files, through Cloud Space's eviction: each file's status is
    /// read again first, and only files safely in the cloud lose their local copy. This is what frees the space.
    public func freeLocalCopies(_ records: [BackupRecord], evictor: any CloudEvicting = SystemCloudEvictor(),
                                onEach: ((CloudEvictionResult) -> Void)? = nil) -> CloudEvictionReport {
        let items = records.filter { isUsableCloudPath($0.destinationPath) }
            .map { CloudItem(path: $0.destinationPath, bytes: $0.bytes, verdict: .evictable) }
        return CloudEvictionService(providers: providers, status: status, evictor: evictor).evict(items, onEach: onEach)
    }
}
