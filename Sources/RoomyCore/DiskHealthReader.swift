#if canImport(IOKit)
import Foundation
import IOKit

/// Reads the health of every physical disk, internal and external, without admin rights. Read-only: it looks at
/// the I/O Registry and asks `diskutil` and `system_profiler`, and never writes anything.
public enum DiskHealthReader {
    /// Reads every disk. Each command gets `timeout` seconds; the work runs on a background queue.
    public static func readAll(timeout: TimeInterval = 10) async -> [DiskHealthReport] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readAllNow(timeout: timeout))
            }
        }
    }

    /// The blocking version of `readAll`. Don't call it on the main thread.
    public static func readAllNow(timeout: TimeInterval) -> [DiskHealthReport] {
        var reports = registryDisks()

        // diskutil for each disk, and system_profiler once per kind of bus, side by side.
        let group = DispatchGroup()
        let lock = NSLock()
        var infos: [String: [String: Any]] = [:]
        var profiles: [String: DiskHealthParser.ProfileEntry] = [:]
        for report in reports {
            DispatchQueue.global(qos: .utility).async(group: group) {
                guard let data = run("/usr/sbin/diskutil", ["info", "-plist", report.id], timeout: timeout),
                      let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { return }
                lock.withLock { infos[report.id] = info }
            }
        }
        var types = ["SPNVMeDataType", "SPSerialATADataType"]
        if reports.contains(where: { ($0.interconnect ?? "").uppercased() == "USB" }) { types.append("SPUSBDataType") }
        for type in types {
            DispatchQueue.global(qos: .utility).async(group: group) {
                guard let data = run("/usr/sbin/system_profiler", ["-json", type], timeout: timeout),
                      let json = try? JSONSerialization.jsonObject(with: data)
                else { return }
                let entries = DiskHealthParser.profileEntries(json)
                lock.withLock { profiles.merge(entries) { first, _ in first } }
            }
        }
        group.wait()

        reports = reports.map { report in
            var report = report
            if let info = infos[report.id] { report = DiskHealthParser.merging(report, diskutil: info) }
            if let entry = profiles[report.id] { report = DiskHealthParser.merging(report, profile: entry) }
            return report
        }
        reports = DiskHealthParser.applying(mountedVolumes(), to: reports)
        // Internal disks first, then by name, so the order stays the same between reads.
        return reports.sorted {
            let a = $0.isInternal == true ? 0 : 1, b = $1.isInternal == true ? 0 : 1
            return a != b ? a < b : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    // MARK: I/O Registry

    /// Every IOBlockStorageDevice that is a real disk (not a disk image), with its whole disk's BSD name.
    static func registryDisks() -> [DiskHealthReport] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DiskHealthReport] = []
        var seen = Set<String>()
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            let characteristics = dictionary(device, "Device Characteristics")
            let protocolInfo = dictionary(device, "Protocol Characteristics")
            guard !DiskHealthParser.isDiskImage(protocolCharacteristics: protocolInfo),
                  let bsd = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "BSD Name" as CFString,
                                                            kCFAllocatorDefault,
                                                            IOOptionBits(kIORegistryIterateRecursively)) as? String,
                  DiskHealthParser.isWholeDisk(bsd), seen.insert(bsd).inserted
            else { continue }
            var report = DiskHealthParser.report(bsdName: bsd, deviceCharacteristics: characteristics,
                                                 protocolCharacteristics: protocolInfo)
            if let size = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "Size" as CFString,
                                                          kCFAllocatorDefault,
                                                          IOOptionBits(kIORegistryIterateRecursively)) as? NSNumber,
               size.int64Value > 0 {
                report.capacity = size.int64Value
            }
            result.append(report)
        }
        return result
    }

    private static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any] {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] ?? [:]
    }

    /// The mounted volumes with the physical disk and container under each.
    static func mountedVolumes() -> [DiskVolumeUsage] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
                  let device = deviceName(of: url.path),
                  let disks = physicalDisk(forBSDName: device)
            else { return nil }
            return DiskVolumeUsage(path: url.path, name: values.volumeName ?? url.lastPathComponent,
                                   physicalDisk: disks.physical, container: disks.container,
                                   total: Int64(total), available: Int64(available))
        }
    }

    /// The BSD name a volume is mounted from, such as "disk3s1s1".
    private static func deviceName(of path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let from = withUnsafeBytes(of: &info.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst(5))
    }

    /// Walks up the I/O Registry from a volume to the IOBlockStorageDevice it lives on. Returns that disk's BSD name
    /// and the first whole disk on the way (the APFS container for APFS volumes).
    private static func physicalDisk(forBSDName name: String) -> (physical: String, container: String)? {
        for candidate in DiskHealthParser.bsdCandidates(name) {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, candidate))
            guard service != 0 else { continue }
            var entry = service
            var container: String?
            var lastWhole: String?
            for _ in 0..<40 {
                if IOObjectConformsTo(entry, "IOMedia") != 0,
                   let whole = IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool, whole,
                   let bsd = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String {
                    if container == nil { container = bsd }
                    lastWhole = bsd
                }
                if IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                    IOObjectRelease(entry)
                    guard let lastWhole else { return nil }
                    return (lastWhole, container ?? lastWhole)
                }
                var parent: io_registry_entry_t = 0
                let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
                IOObjectRelease(entry)
                guard found else { return nil }
                entry = parent
            }
            IOObjectRelease(entry)
            return nil
        }
        return nil
    }

    // MARK: Commands

    /// Runs a command directly (no shell) and returns what it printed, or nil when it failed or took longer than
    /// `timeout` seconds, in which case it is stopped.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }
}
#endif
