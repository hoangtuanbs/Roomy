import Foundation
import XCTest
@testable import RoomyCore

/// Disk health: parsing made-up answers from the I/O Registry, diskutil and system_profiler, the verdict, and when
/// to announce a failing disk. Real disks are never read.
final class DiskHealthTests: XCTestCase {
    private let internalNVMe: [String: Any] = [
        "DeviceIdentifier": "disk0", "MediaName": "APPLE SSD AP0512Z", "SMARTStatus": "Verified",
        "SolidState": true, "Internal": true, "DeviceLocation": "Internal", "BusProtocol": "Apple Fabric",
        "TotalSize": 500_277_790_720, "VirtualOrPhysical": "Physical",
    ]

    func testVerifiedInternalDiskIsGood() {
        let report = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), diskutil: internalNVMe)
        XCTAssertEqual(report.model, "APPLE SSD AP0512Z")
        XCTAssertEqual(report.smart, .verified)
        XCTAssertEqual(report.isSolidState, true)
        XCTAssertEqual(report.isInternal, true)
        XCTAssertEqual(report.interconnect, "Apple Fabric")
        XCTAssertEqual(report.capacity, 500_277_790_720)
        XCTAssertEqual(report.verdict, .good)
        XCTAssertTrue(report.advice.contains("Nothing to do"))
    }

    func testFailingDiskSaysBackUpNow() {
        var info = internalNVMe
        info["SMARTStatus"] = "Failing"
        let report = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), diskutil: info)
        XCTAssertEqual(report.verdict, .failing)
        XCTAssertTrue(report.advice.contains("Back up now with Time Machine"))
    }

    func testNotSupportedIsUnknownWithReason() {
        let info: [String: Any] = ["MediaName": "Generic Flash Disk", "SMARTStatus": "Not Supported", "Internal": false,
                                   "BusProtocol": "USB", "SolidState": false, "TotalSize": 32_000_000_000]
        let report = DiskHealthParser.merging(DiskHealthReport(id: "disk4"), diskutil: info)
        XCTAssertEqual(report.smart, .notSupported)
        XCTAssertEqual(report.verdict, .unknown)
        XCTAssertEqual(report.isInternal, false)
        XCTAssertTrue(report.explanation.contains("doesn't report its health"))
    }

    func testExternalUSBFromRegistryWithoutSMART() {
        let report = DiskHealthParser.report(
            bsdName: "disk5",
            deviceCharacteristics: ["Product Name": "Portable SSD T7", "Product Revision Level": "0",
                                    "Medium Type": "Solid State"],
            protocolCharacteristics: ["Physical Interconnect": "USB", "Physical Interconnect Location": "External"]
        )
        XCTAssertEqual(report.model, "Portable SSD T7")
        XCTAssertEqual(report.interconnect, "USB")
        XCTAssertEqual(report.isInternal, false)
        XCTAssertEqual(report.isSolidState, true)
        XCTAssertEqual(report.smart, .unknown)
        XCTAssertEqual(report.verdict, .unknown)
        XCTAssertNil(report.serial)
        XCTAssertNil(report.maskedSerial)
    }

    func testMissingFieldsStayNil() {
        let report = DiskHealthParser.merging(DiskHealthReport(id: "disk2"), diskutil: [:])
        XCTAssertNil(report.model)
        XCTAssertNil(report.isInternal)
        XCTAssertNil(report.isSolidState)
        XCTAssertNil(report.capacity)
        XCTAssertNil(report.mediumTitle)
        XCTAssertNil(report.percentageUsed)
        XCTAssertNil(report.powerOnHours)
        XCTAssertNil(report.temperatureCelsius)
        XCTAssertEqual(report.verdict, .unknown)
        XCTAssertEqual(report.name, "Disk")
    }

    func testDeviceLocationUsedWhenInternalIsMissing() {
        let report = DiskHealthParser.merging(DiskHealthReport(id: "disk3"), diskutil: ["DeviceLocation": "External"])
        XCTAssertEqual(report.isInternal, false)
        XCTAssertEqual(report.name, "External disk")
    }

    func testRegistryFields() {
        let report = DiskHealthParser.report(
            bsdName: "disk0",
            deviceCharacteristics: ["Product Name": "APPLE SSD AP0512Z ", "Serial Number": "0ba0123456789abc",
                                    "Product Revision Level": "1161.100", "Medium Type": "Solid State",
                                    "SMART Status": "Verified"],
            protocolCharacteristics: ["Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal"]
        )
        XCTAssertEqual(report.model, "APPLE SSD AP0512Z")
        XCTAssertEqual(report.revision, "1161.100")
        XCTAssertEqual(report.maskedSerial, "••••••••••••9abc")
        XCTAssertEqual(report.smart, .verified)
        XCTAssertEqual(report.isInternal, true)
        XCTAssertEqual(report.mediumTitle, "Solid state (SSD)")
    }

    func testRotationalMedium() {
        let report = DiskHealthParser.report(bsdName: "disk1", deviceCharacteristics: ["Medium Type": "Rotational"],
                                             protocolCharacteristics: ["Physical Interconnect": "SATA"])
        XCTAssertEqual(report.isSolidState, false)
        XCTAssertEqual(report.interconnect, "SATA")
    }

    func testShortSerialIsStillMasked() {
        var report = DiskHealthReport(id: "disk0")
        report.serial = "AB12"
        XCTAssertEqual(report.maskedSerial, "••••2")
        report.serial = "   "
        XCTAssertNil(report.maskedSerial)
    }

    func testDiskImagesAreSkipped() {
        XCTAssertTrue(DiskHealthParser.isDiskImage(protocolCharacteristics: ["Physical Interconnect Location": "File"]))
        XCTAssertTrue(DiskHealthParser.isDiskImage(protocolCharacteristics: ["Physical Interconnect": "Virtual Interface"]))
        XCTAssertFalse(DiskHealthParser.isDiskImage(protocolCharacteristics: ["Physical Interconnect": "USB",
                                                                              "Physical Interconnect Location": "External"]))
    }

    func testSMARTWords() {
        XCTAssertEqual(SMARTStatus(text: "Verified"), .verified)
        XCTAssertEqual(SMARTStatus(text: "Failing"), .failing)
        XCTAssertEqual(SMARTStatus(text: "About to Fail"), .failing)
        XCTAssertEqual(SMARTStatus(text: "Not Supported"), .notSupported)
        XCTAssertEqual(SMARTStatus(text: nil), .unknown)
        XCTAssertEqual(SMARTStatus(text: "Something else"), .unknown)
    }

    func testFailingFromAnySourceWins() {
        let verified = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), diskutil: internalNVMe)
        var entry = DiskHealthParser.ProfileEntry()
        entry.smart = .failing
        XCTAssertEqual(DiskHealthParser.merging(verified, profile: entry).verdict, .failing)
        entry.smart = .notSupported
        XCTAssertEqual(DiskHealthParser.merging(verified, profile: entry).smart, .verified)
    }

    func testProfileEntriesFromNVMeJSON() throws {
        let json = """
        {"SPNVMeDataType": [{"_name": "Apple SSD Controller", "_items": [
          {"_name": "APPLE SSD AP0512Z", "bsd_name": "disk0", "device_model": "APPLE SSD AP0512Z",
           "device_revision": "1161.100", "device_serial": "0ba0123456789abc", "smart_status": "Verified",
           "size_in_bytes": 500277790720,
           "volumes": [{"_name": "Macintosh HD", "bsd_name": "disk0s2"}]}]}]}
        """
        let entries = DiskHealthParser.profileEntries(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertEqual(entries.keys.sorted(), ["disk0"])
        let entry = try XCTUnwrap(entries["disk0"])
        XCTAssertEqual(entry.model, "APPLE SSD AP0512Z")
        XCTAssertEqual(entry.serial, "0ba0123456789abc")
        XCTAssertEqual(entry.smart, .verified)
        XCTAssertEqual(entry.capacity, 500_277_790_720)

        let filled = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), profile: entry)
        XCTAssertEqual(filled.revision, "1161.100")
        XCTAssertEqual(filled.verdict, .good)
    }

    func testProfileEntriesFromSATAJSON() throws {
        let json = """
        {"SPSerialATADataType": [{"_items": [{"bsd_name": "disk1", "device_model": "WDC WD10EZEX",
          "spsata_medium_type": "Rotational", "smart_status": "Failing"}]}]}
        """
        let entries = DiskHealthParser.profileEntries(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertEqual(entries["disk1"]?.isSolidState, false)
        XCTAssertEqual(entries["disk1"]?.smart, .failing)
    }

    func testEmptyProfile() throws {
        let json = #"{"SPNVMeDataType": []}"#
        XCTAssertTrue(DiskHealthParser.profileEntries(try JSONSerialization.jsonObject(with: Data(json.utf8))).isEmpty)
    }

    func testWarningFromWearOrHeat() {
        var report = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), diskutil: internalNVMe)
        report.percentageUsed = 85
        XCTAssertEqual(report.verdict, .warning)
        XCTAssertTrue(report.explanation.contains("85%"))
        report.percentageUsed = 10
        report.temperatureCelsius = 40
        XCTAssertEqual(report.verdict, .good)
    }

    func testWholeDiskNames() {
        XCTAssertTrue(DiskHealthParser.isWholeDisk("disk0"))
        XCTAssertTrue(DiskHealthParser.isWholeDisk("disk12"))
        XCTAssertFalse(DiskHealthParser.isWholeDisk("disk0s1"))
        XCTAssertFalse(DiskHealthParser.isWholeDisk("disk"))
        XCTAssertEqual(DiskHealthParser.bsdCandidates("disk3s1s1"), ["disk3s1s1", "disk3s1", "disk3"])
        XCTAssertEqual(DiskHealthParser.bsdCandidates("disk4"), ["disk4"])
    }

    func testVolumesCountEachContainerOnce() {
        let gb: Int64 = 1_000_000_000
        let volumes = [
            DiskVolumeUsage(path: "/", name: "Macintosh HD", physicalDisk: "disk0", container: "disk3", total: 500 * gb, available: 200 * gb),
            DiskVolumeUsage(path: "/System/Volumes/Data", name: "Data", physicalDisk: "disk0", container: "disk3", total: 500 * gb, available: 200 * gb),
            DiskVolumeUsage(path: "/Volumes/Backup", name: "Backup", physicalDisk: "disk4", container: "disk4", total: 1000 * gb, available: 400 * gb),
        ]
        let reports = DiskHealthParser.applying(volumes, to: [DiskHealthReport(id: "disk0"), DiskHealthReport(id: "disk4"),
                                                              DiskHealthReport(id: "disk6")])
        XCTAssertEqual(reports[0].used, 300 * gb)
        XCTAssertEqual(reports[0].volumeNames, ["Macintosh HD", "Data"])
        XCTAssertEqual(reports[1].used, 600 * gb)
        XCTAssertEqual(reports[1].volumePaths, ["/Volumes/Backup"])
        XCTAssertNil(reports[2].used)
    }

    func testAlertOnceWhenADiskTurnsFailing() {
        let good = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), diskutil: internalNVMe)
        var failingInfo = internalNVMe
        failingInfo["SMARTStatus"] = "Failing"
        let failing = DiskHealthParser.merging(DiskHealthReport(id: "disk0"), diskutil: failingInfo)

        let first = DiskHealthAlert.decide([good], alreadyAnnounced: [])
        XCTAssertTrue(first.announce.isEmpty)
        XCTAssertTrue(first.announced.isEmpty)

        let second = DiskHealthAlert.decide([failing], alreadyAnnounced: first.announced)
        XCTAssertEqual(second.announce.map(\.id), ["disk0"])

        let third = DiskHealthAlert.decide([failing], alreadyAnnounced: second.announced)
        XCTAssertTrue(third.announce.isEmpty, "A failing disk is announced only once")

        let recovered = DiskHealthAlert.decide([good], alreadyAnnounced: third.announced)
        XCTAssertTrue(recovered.announced.isEmpty)
        XCTAssertEqual(DiskHealthAlert.decide([failing], alreadyAnnounced: recovered.announced).announce.count, 1)
    }
}
