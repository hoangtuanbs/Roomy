import Foundation

/// What a backup's Info.plist and Manifest.plist say about it. Every field is optional: Finder and iTunes
/// have written these files differently over the years, and some backups are missing one of them.
public struct BackupInfo: Sendable, Equatable {
    public var deviceName: String?
    public var productType: String?
    public var osVersion: String?
    public var lastBackup: Date?
    public var isEncrypted: Bool?
    /// The device's identifier, used to tell which backups belong to the same device.
    public var deviceID: String?

    public init(deviceName: String? = nil, productType: String? = nil, osVersion: String? = nil,
                lastBackup: Date? = nil, isEncrypted: Bool? = nil, deviceID: String? = nil) {
        self.deviceName = deviceName
        self.productType = productType
        self.osVersion = osVersion
        self.lastBackup = lastBackup
        self.isEncrypted = isEncrypted
        self.deviceID = deviceID
    }

    /// Reads whichever of the two files there are. Unknown or wrongly typed values are ignored, never fatal.
    public static func parse(info: Data?, manifest: Data?) -> BackupInfo {
        let infoDict = dictionary(info)
        let manifestDict = dictionary(manifest)
        let lockdown = manifestDict["Lockdown"] as? [String: Any] ?? [:]

        var result = BackupInfo()
        result.deviceName = string(infoDict["Device Name"]) ?? string(infoDict["Display Name"])
            ?? string(lockdown["DeviceName"])
        result.productType = string(infoDict["Product Type"]) ?? string(lockdown["ProductType"])
        result.osVersion = string(infoDict["Product Version"]) ?? string(lockdown["ProductVersion"])
        result.lastBackup = date(infoDict["Last Backup Date"]) ?? date(manifestDict["Date"])
        result.isEncrypted = bool(manifestDict["IsEncrypted"])
        result.deviceID = string(infoDict["Target Identifier"]) ?? string(infoDict["Unique Identifier"])
            ?? string(lockdown["UniqueDeviceID"])
        return result
    }

    private static func dictionary(_ data: Data?) -> [String: Any] {
        guard let data, !data.isEmpty,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["true", "yes", "1"].contains(text.lowercased()) }
        return nil
    }
}

/// One iPhone or iPad backup folder in ~/Library/Application Support/MobileSync/Backup.
public struct DeviceBackup: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let info: BackupInfo
    /// When the folder was last changed, used when the backup does not say when it was made.
    public let folderModified: Date
    public let bytes: Int64

    public init(path: String, info: BackupInfo, folderModified: Date, bytes: Int64) {
        self.path = path
        self.info = info
        self.folderModified = folderModified
        self.bytes = bytes
    }

    public var folderName: String { (path as NSString).lastPathComponent }
    public var date: Date { info.lastBackup ?? folderModified }
    public var deviceName: String { info.deviceName ?? "Unknown device" }
    /// Groups backups of one device. Folders of the same device usually start with its identifier.
    public var deviceKey: String {
        if let id = info.deviceID { return id.uppercased() }
        if let name = info.deviceName { return "name:" + name }
        let folder = folderName
        return String(folder.split(separator: "-").first ?? Substring(folder)).uppercased()
    }
    public var isIPad: Bool { info.productType?.hasPrefix("iPad") == true }
}

public enum BackupRules {
    /// A backup has to be at least this old before it can start ticked.
    public static let oldAge: TimeInterval = 90 * 86_400

    /// The newest backup of each device. These are never ticked for you.
    public static func newestPerDevice(_ backups: [DeviceBackup]) -> Set<String> {
        var newest: [String: DeviceBackup] = [:]
        for backup in backups {
            if let current = newest[backup.deviceKey], current.date >= backup.date { continue }
            newest[backup.deviceKey] = backup
        }
        return Set(newest.values.map(\.path))
    }

    /// Backups that can start ticked: an older backup of a device that has a newer one, made 90 days ago or more.
    /// Everything else starts unticked ("Review first").
    public static func preselected(_ backups: [DeviceBackup], now: Date = Date()) -> Set<String> {
        let newest = newestPerDevice(backups)
        return Set(backups.filter { backup in
            !newest.contains(backup.path) && now.timeIntervalSince(backup.date) >= oldAge
        }.map(\.path))
    }
}

/// Lists the backups in MobileSync/Backup. The folder is protected by macOS, so this needs Full Disk Access.
public struct BackupFinder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case found([DeviceBackup])
        /// The folder is there but RoomyDisk may not read it.
        case noAccess
    }

    public let backupFolder: String

    public init(homePath: String = NSHomeDirectory()) {
        backupFolder = DiskScanner.standardize(homePath) + "/Library/Application Support/MobileSync/Backup"
    }

    public static func backupFolder(homePath: String) -> String {
        BackupFinder(homePath: homePath).backupFolder
    }

    /// Reads each backup's details and size, newest first.
    public func find() -> Outcome {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: backupFolder)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .found([]) }
            if !fm.fileExists(atPath: backupFolder) { return .found([]) }
            return .noAccess
        }
        var backups: [DeviceBackup] = []
        for name in names where !name.hasPrefix(".") {
            if Task.isCancelled { break }
            let path = backupFolder + "/" + name
            guard let entry = DirectoryReader.entry(atPath: path), entry.kind == .directory else { continue }
            let info = BackupInfo.parse(
                info: fm.contents(atPath: path + "/Info.plist"),
                manifest: fm.contents(atPath: path + "/Manifest.plist")
            )
            backups.append(DeviceBackup(
                path: path,
                info: info,
                folderModified: Date(timeIntervalSince1970: TimeInterval(entry.modified)),
                bytes: DiskUsage.allocatedSize(atPath: path)
            ))
        }
        return .found(backups.sorted { $0.date > $1.date })
    }
}
