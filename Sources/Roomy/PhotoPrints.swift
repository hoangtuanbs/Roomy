import CoreML
import CoreServices
import Foundation
import ImageIO
import RoomyCore
import Vision

/// What Vision and ImageIO say about one picture: its feature print, which is compared to tell how alike two
/// pictures look, and the size and date stored in the file.
struct PhotoPrint: @unchecked Sendable {
    let candidate: PhotoCandidate
    let print: VNFeaturePrintObservation

    /// Reads a small copy of the picture (never the full image) and makes its feature print.
    static func make(path: String, bytes: Int64, modified: Date) -> PhotoPrint? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDate)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        runOnCPU(request)
        do {
            try VNImageRequestHandler(cgImage: thumbnail, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let candidate = PhotoCandidate(path: path, bytes: bytes, pixelWidth: width, pixelHeight: height,
                                       taken: taken, modified: modified)
        return PhotoPrint(candidate: candidate, print: observation)
    }

    /// Runs every stage of the request on the CPU. The CPU is quick enough for a small picture, and works on
    /// machines without a usable GPU (a build machine's GPU once hung here).
    private static func runOnCPU(_ request: VNRequest) {
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
    }

    /// Seconds one picture may take before it is skipped.
    static let timeout: Double = 15

    /// `make` on a dispatch queue, so a slow picture never holds up Swift's shared threads, and given up after
    /// `timeout` so one bad file cannot stall the hunt.
    static func makeOffPool(_ file: PhotoSource.File) async -> PhotoPrint? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resume(make(path: file.path, bytes: file.bytes, modified: file.modified))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    func distance(to other: PhotoPrint) -> Float? {
        var value: Float = 0
        do {
            try print.computeDistance(&value, to: other.print)
            return value
        } catch {
            return nil
        }
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static func exifDate(_ text: String) -> Date? {
        exifFormatter.date(from: text)
    }
}

/// Resumes a continuation the first time only.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<PhotoPrint?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<PhotoPrint?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: PhotoPrint?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

enum SpotlightDates {
    /// When the item was last opened, as Spotlight recorded it.
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The file system's dates plus Spotlight's last-used date.
    static func itemDates(_ path: String) -> ItemDates {
        var dates = OldDownloadsFinder.systemDates(path)
        dates.lastUsed = lastUsed(path)
        return dates
    }
}

/// Where Similar photos looks: the pictures in the current scan, or in ~/Pictures when there is no scan.
enum PhotoSource {
    struct File: Sendable {
        let path: String
        let bytes: Int64
        let modified: Date
    }

    static let limit = 3_000

    /// The largest pictures in the scan. Reads the scan on the main actor, since the scan may change.
    @MainActor
    static func files(in tree: ScanTree) -> [File] {
        var found: [File] = []
        for i in 0..<tree.count {
            let index = ScanTree.Index(i)
            guard tree.kind(index) == .file, tree.size(index) >= SimilarPhotoGrouper.minimumBytes,
                  !tree.flags(index).contains(.removed) else { continue }
            let ext = (tree.name(index) as NSString).pathExtension.lowercased()
            guard SimilarPhotoGrouper.extensions.contains(ext) else { continue }
            let path = tree.path(of: index)
            guard SimilarPhotoGrouper.isCandidate(path: path) else { continue }
            found.append(File(path: path, bytes: tree.size(index), modified: tree.modifiedDate(index)))
        }
        return found
    }

    /// The pictures in a folder, skipping packages such as Photos libraries and hidden files.
    static func files(inFolder folder: String) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [File] = []
        for case let url as URL in walker {
            if Task.isCancelled { break }
            guard SimilarPhotoGrouper.isCandidate(path: url.path),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? 0)
            guard bytes >= SimilarPhotoGrouper.minimumBytes else { continue }
            found.append(File(path: url.path, bytes: bytes, modified: values.contentModificationDate ?? .distantPast))
        }
        return found
    }

    /// The `limit` largest files, and whether some were left out.
    static func capped(_ files: [File]) -> (files: [File], capped: Bool) {
        let sorted = files.sorted { $0.bytes > $1.bytes }
        return (Array(sorted.prefix(limit)), sorted.count > limit)
    }
}
