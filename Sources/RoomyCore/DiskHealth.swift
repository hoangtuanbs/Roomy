import Foundation

/// What a disk says about its own health through S.M.A.R.T.
public enum SMARTStatus: String, Sendable, Equatable {
    case verified
    case failing
    case notSupported
    case unknown

    /// Reads the words diskutil, system_profiler and the I/O Registry use, such as "Verified", "Failing" or
    /// "Not Supported".
    public init(text: String?) {
        let words = (text ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if words.isEmpty {
            self = .unknown
        } else if words.contains("fail") {
            self = .failing
        } else if words.contains("verified") || words == "ok" {
            self = .verified
        } else if words.contains("not supported") || words.contains("unsupported") {
            self = .notSupported
        } else {
            self = .unknown
        }
    }

    /// The more telling of two answers: failing wins over verified, which wins over not supported.
    func combined(with other: SMARTStatus) -> SMARTStatus {
        let order: [SMARTStatus] = [.failing, .verified, .notSupported, .unknown]
        return order.first { $0 == self || $0 == other } ?? .unknown
    }

    /// How the status reads in a list, such as "Verified".
    public var title: String {
        switch self {
        case .verified: return String(localized: "Verified")
        case .failing: return String(localized: "Failing")
        case .notSupported: return String(localized: "Not supported by this disk")
        case .unknown: return String(localized: "Not reported")
        }
    }
}

/// The overall answer for one disk.
public enum DiskHealthVerdict: String, Sendable, Equatable, CaseIterable {
    case good
    case warning
    case failing
    case unknown

    public var title: String {
        switch self {
        case .good: return String(localized: "Good")
        case .warning: return String(localized: "Warning")
        case .failing: return String(localized: "Failing")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

/// Everything RoomyDisk could read about one physical disk without admin rights. Fields stay nil when no source
/// said anything; nothing is guessed.
public struct DiskHealthReport: Sendable, Equatable, Identifiable {
    /// The whole disk's BSD name, such as "disk0".
    public var id: String
    public var model: String?
    public var serial: String?
    public var revision: String?
    /// How the disk is connected, such as "PCI-Express", "Apple Fabric", "USB", "SATA" or "Thunderbolt".
    public var interconnect: String?
    public var isInternal: Bool?
    public var isSolidState: Bool?
    public var smart: SMARTStatus = .unknown
    /// The disk's size in bytes.
    public var capacity: Int64?
    /// Space used on the mounted volumes of this disk, nil when none is mounted.
    public var used: Int64?
    public var volumeNames: [String] = []
    /// Mount points of the volumes on this disk, such as "/" or "/Volumes/Backup".
    public var volumePaths: [String] = []
    /// Wear, hours and heat. macOS only gives these to admin tools, so they are normally nil.
    public var percentageUsed: Int?
    public var powerOnHours: Int?
    public var temperatureCelsius: Int?

    public init(id: String) {
        self.id = id
    }

    /// The model, or a plain name when the disk didn't give one.
    public var name: String {
        if let model, !model.isEmpty { return model }
        return isInternal == false ? String(localized: "External disk") : String(localized: "Disk")
    }

    /// The serial with all but its last four characters hidden, such as "••••••••5XYZ".
    public var maskedSerial: String? {
        guard let serial = serial?.trimmingCharacters(in: .whitespaces), !serial.isEmpty else { return nil }
        let shown = serial.count <= 4 ? 1 : 4
        return String(repeating: "•", count: max(4, serial.count - shown)) + serial.suffix(shown)
    }

    /// "Solid state", "Hard disk", or nil when unknown.
    public var mediumTitle: String? {
        isSolidState.map { $0 ? String(localized: "Solid state (SSD)") : String(localized: "Spinning hard disk") }
    }

    /// Why the disk gets a Warning; empty when nothing is worrying.
    public var warnings: [String] {
        var result: [String] = []
        if let percentageUsed, percentageUsed >= 80 {
            result.append(String(format: String(localized: "It reports %lld%% of its rated life used."), percentageUsed))
        }
        if let temperatureCelsius, temperatureCelsius >= 70 {
            result.append(String(format: String(localized: "It runs hot (%lld °C)."), temperatureCelsius))
        }
        return result
    }

    public var verdict: DiskHealthVerdict {
        switch smart {
        case .failing: return .failing
        case .verified: return warnings.isEmpty ? .good : .warning
        case .notSupported, .unknown: return warnings.isEmpty ? .unknown : .warning
        }
    }

    /// One or two plain sentences on what the verdict means.
    public var explanation: String {
        switch verdict {
        case .good:
            return String(localized: "The disk checks itself and tells macOS it is healthy (S.M.A.R.T. status verified).")
        case .warning:
            return String(localized: "The disk still works, but something is worth watching. ") + warnings.joined(separator: " ")
        case .failing:
            return String(localized: "The disk itself reports that it is failing. It can stop working at any moment, and files on it can be lost.")
        case .unknown:
            if smart == .notSupported {
                return String(localized: "This disk doesn't report its health to macOS. That is normal for many USB drives, card readers and virtual disks.")
            }
            return String(localized: "macOS didn't say how this disk is doing, so RoomyDisk can't tell.")
        }
    }

    /// What to do about it.
    public var advice: String {
        switch verdict {
        case .good: return String(localized: "Nothing to do. Keep your Time Machine backups going anyway.")
        case .warning: return String(localized: "Make sure your Time Machine backup is current, and plan to replace this disk.")
        case .failing: return String(localized: "Back up now with Time Machine, then replace this disk.")
        case .unknown: return String(localized: "Keep a current backup of anything on it that matters.")
        }
    }

    /// A stable name for remembering that a failing disk was already announced. The masked serial keeps the full
    /// serial out of the settings file.
    public var alertKey: String {
        [model ?? id, maskedSerial ?? ""].joined(separator: "|")
    }
}

// MARK: Parsing

/// Turns what diskutil, system_profiler and the I/O Registry say into a `DiskHealthReport`. Pure functions, so
/// they can be tested with made-up dictionaries.
public enum DiskHealthParser {
    /// The start of a report from an IOBlockStorageDevice's "Device Characteristics" and "Protocol Characteristics".
    public static func report(bsdName: String, deviceCharacteristics: [String: Any],
                              protocolCharacteristics: [String: Any]) -> DiskHealthReport {
        var report = DiskHealthReport(id: bsdName)
        report.model = text(deviceCharacteristics["Product Name"])
        report.serial = text(deviceCharacteristics["Serial Number"])
        report.revision = text(deviceCharacteristics["Product Revision Level"])
        if let medium = text(deviceCharacteristics["Medium Type"]) {
            report.isSolidState = medium.lowercased().contains("solid")
        }
        report.smart = SMARTStatus(text: text(deviceCharacteristics["SMART Status"]))
        report.interconnect = text(protocolCharacteristics["Physical Interconnect"])
        if let location = text(protocolCharacteristics["Physical Interconnect Location"])?.lowercased() {
            if location == "internal" { report.isInternal = true }
            if location == "external" { report.isInternal = false }
        }
        return report
    }

    /// True for disk images and RAM disks, which are files or memory rather than disks.
    public static func isDiskImage(protocolCharacteristics: [String: Any]) -> Bool {
        let location = text(protocolCharacteristics["Physical Interconnect Location"])?.lowercased()
        let interconnect = text(protocolCharacteristics["Physical Interconnect"])?.lowercased()
        return location == "file" || location == "ram" || interconnect == "virtual interface"
    }

    /// Adds what `diskutil info -plist <disk>` says, keeping what is already known unless diskutil is clearer.
    public static func merging(_ report: DiskHealthReport, diskutil info: [String: Any]) -> DiskHealthReport {
        var report = report
        if report.model == nil { report.model = text(info["MediaName"]) ?? text(info["IORegistryEntryName"]) }
        if report.isSolidState == nil, let solid = info["SolidState"] as? Bool { report.isSolidState = solid }
        if let isInternal = info["Internal"] as? Bool {
            report.isInternal = isInternal
        } else if report.isInternal == nil, let location = text(info["DeviceLocation"])?.lowercased() {
            report.isInternal = location == "internal" ? true : location == "external" ? false : nil
        }
        if report.interconnect == nil { report.interconnect = text(info["BusProtocol"]) }
        if report.capacity == nil, let size = int64(info["TotalSize"]) ?? int64(info["Size"]), size > 0 {
            report.capacity = size
        }
        report.smart = report.smart.combined(with: SMARTStatus(text: text(info["SMARTStatus"])))
        return report
    }

    /// Extra fields from system_profiler (SPNVMeDataType, SPSerialATADataType or SPUSBDataType as JSON), by whole
    /// disk BSD name.
    public struct ProfileEntry: Sendable, Equatable {
        public var model: String?
        public var serial: String?
        public var revision: String?
        public var smart: SMARTStatus = .unknown
        public var isSolidState: Bool?
        public var capacity: Int64?

        public init() {}
    }

    /// Finds every whole disk ("disk0", not "disk0s1") anywhere in a system_profiler JSON answer.
    public static func profileEntries(_ json: Any) -> [String: ProfileEntry] {
        var result: [String: ProfileEntry] = [:]
        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
            } else if let dict = value as? [String: Any] {
                if let bsd = text(dict["bsd_name"]), isWholeDisk(bsd) {
                    var entry = ProfileEntry()
                    entry.model = text(dict["device_model"]) ?? text(dict["_name"])
                    entry.serial = text(dict["device_serial"]) ?? text(dict["serial_num"])
                    entry.revision = text(dict["device_revision"])
                    entry.smart = SMARTStatus(text: text(dict["smart_status"]))
                    if let medium = text(dict["spsata_medium_type"]) { entry.isSolidState = medium.lowercased().contains("solid") }
                    entry.capacity = int64(dict["size_in_bytes"])
                    result[bsd] = entry
                }
                dict.values.forEach(walk)
            }
        }
        walk(json)
        return result
    }

    /// Fills the gaps of a report with a system_profiler entry. A failing status from any source wins.
    public static func merging(_ report: DiskHealthReport, profile: ProfileEntry) -> DiskHealthReport {
        var report = report
        report.model = report.model ?? profile.model
        report.serial = report.serial ?? profile.serial
        report.revision = report.revision ?? profile.revision
        report.isSolidState = report.isSolidState ?? profile.isSolidState
        report.capacity = report.capacity ?? profile.capacity
        report.smart = report.smart.combined(with: profile.smart)
        return report
    }

    /// "disk0" or "disk12", but not "disk0s1".
    public static func isWholeDisk(_ name: String) -> Bool {
        guard name.hasPrefix("disk") else { return false }
        let number = name.dropFirst(4)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    /// The names to try when looking up a volume's device, from the most to the least specific:
    /// "disk3s1s1" gives "disk3s1s1", "disk3s1", "disk3".
    public static func bsdCandidates(_ name: String) -> [String] {
        var result = [name]
        var current = name
        while let range = current.range(of: "s[0-9]+$", options: .regularExpression),
              current[..<range.lowerBound].count > 4 {
            current = String(current[..<range.lowerBound])
            result.append(current)
        }
        return result
    }

    static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let int = value as? Int64 { return int }
        return nil
    }
}

// MARK: Space per disk

/// One mounted volume and the disks under it, for adding up how much of each physical disk is used.
public struct DiskVolumeUsage: Sendable, Equatable {
    public var path: String
    public var name: String
    /// The physical disk, such as "disk0".
    public var physicalDisk: String
    /// The disk or APFS container the volume lives in, such as "disk3". Volumes in one container share its space.
    public var container: String
    public var total: Int64
    public var available: Int64

    public init(path: String, name: String, physicalDisk: String, container: String, total: Int64, available: Int64) {
        self.path = path
        self.name = name
        self.physicalDisk = physicalDisk
        self.container = container
        self.total = total
        self.available = available
    }
}

extension DiskHealthParser {
    /// Adds the volumes to their disks: names and paths, and the used space, counting each container once.
    public static func applying(_ volumes: [DiskVolumeUsage], to reports: [DiskHealthReport]) -> [DiskHealthReport] {
        reports.map { report in
            var report = report
            let mine = volumes.filter { $0.physicalDisk == report.id }
            guard !mine.isEmpty else { return report }
            report.volumeNames = mine.map(\.name)
            report.volumePaths = mine.map(\.path)
            var seen = Set<String>()
            var used: Int64 = 0
            for volume in mine where seen.insert(volume.container).inserted {
                used += max(0, volume.total - volume.available)
            }
            report.used = used
            return report
        }
    }
}

// MARK: Alert

/// Decides when to say that a disk is failing: once when it turns Failing, and again only if it recovers and fails
/// later.
public enum DiskHealthAlert {
    /// The disks to announce now, and the keys to remember as already announced.
    public static func decide(_ reports: [DiskHealthReport], alreadyAnnounced: Set<String>)
        -> (announce: [DiskHealthReport], announced: Set<String>) {
        let failing = reports.filter { $0.verdict == .failing }
        let announce = failing.filter { !alreadyAnnounced.contains($0.alertKey) }
        return (announce, Set(failing.map(\.alertKey)))
    }
}
