import Foundation

/// A picture that may have near-duplicates. The app fills in its size and the date it was taken.
public struct PhotoCandidate: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// When the photo was taken (EXIF), if it says.
    public let taken: Date?
    public let modified: Date

    public init(path: String, bytes: Int64, pixelWidth: Int = 0, pixelHeight: Int = 0, taken: Date? = nil,
                modified: Date = Date(timeIntervalSince1970: 0)) {
        self.path = path
        self.bytes = bytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.taken = taken
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var pixels: Int { pixelWidth * pixelHeight }
    public var date: Date { taken ?? modified }
}

/// Photos that look alike, with the one suggested to keep.
public struct SimilarPhotoGroup: Sendable, Identifiable, Equatable {
    public var id: String { suggestedKeep.path }
    /// The suggested keeper first, then the others largest first.
    public let photos: [PhotoCandidate]
    public let suggestedKeep: PhotoCandidate

    public var others: [PhotoCandidate] { Array(photos.dropFirst()) }
    /// What removing every photo but the suggested one would free.
    public var extraBytes: Int64 { others.reduce(0) { $0 + $1.bytes } }

    public func removing(_ removed: Set<String>) -> SimilarPhotoGroup? {
        let left = photos.filter { !removed.contains($0.path) }
        guard left.count > 1 else { return nil }
        return SimilarPhotoGrouper.makeGroup(left)
    }
}

public enum SimilarPhotoGrouper {
    /// Feature print distances below this count as "looks the same".
    public static let threshold: Float = 0.35
    /// Photos with known dates must be taken within this time of each other.
    public static let timeWindow: TimeInterval = 60 * 60
    /// Without dates to back it up, the pictures must look even closer.
    public static let undatedFactor: Float = 0.7
    public static let extensions: Set<String> = ["jpg", "jpeg", "heic", "png"]
    /// Smaller pictures are icons and artwork more often than photos.
    public static let minimumBytes: Int64 = 100_000

    /// True for a JPEG, HEIC or PNG that is not inside a Photos library or another app's library, the Trash or a
    /// hidden folder. Photos libraries must only be changed in Photos.
    public static func isCandidate(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { return false }
        let parts = path.split(separator: "/")
        for part in parts.dropLast() {
            if part.hasPrefix(".") { return false }
            if part == "Library" { return false }
            let lower = part.lowercased()
            if lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".photolibrary") || lower.hasSuffix(".aplibrary")
                || lower.hasSuffix(".migratedphotolibrary") || lower.hasSuffix(".app") { return false }
        }
        return !(parts.last?.hasPrefix(".") ?? true)
    }

    /// Joins photos that look alike into groups. `distance(i, j)` is the feature print distance of photos i and j,
    /// or nil when it is unknown; it is only asked for pairs whose dates are close. Groups of two or more come back,
    /// largest saving first.
    public static func group(_ photos: [PhotoCandidate], threshold: Float = threshold,
                             timeWindow: TimeInterval = timeWindow,
                             isCancelled: () -> Bool = { false },
                             distance: (Int, Int) -> Float?) -> [SimilarPhotoGroup] {
        var parent = Array(photos.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }

        // Dated photos in time order, so each one is only compared with its neighbours in time.
        let dated = photos.indices.filter { photos[$0].taken != nil }
            .sorted { photos[$0].taken! < photos[$1].taken! }
        let undated = photos.indices.filter { photos[$0].taken == nil }

        func link(_ i: Int, _ j: Int, limit: Float) {
            guard root(i) != root(j), let d = distance(i, j), d < limit else { return }
            parent[root(i)] = root(j)
        }

        for (n, i) in dated.enumerated() {
            if isCancelled() { return [] }
            for j in dated[(n + 1)...] {
                if photos[j].taken!.timeIntervalSince(photos[i].taken!) > timeWindow { break }
                link(i, j, limit: threshold)
            }
        }
        for (n, i) in undated.enumerated() {
            if isCancelled() { return [] }
            for j in undated[(n + 1)...] { link(i, j, limit: threshold * undatedFactor) }
            for j in dated { link(i, j, limit: threshold * undatedFactor) }
        }

        var buckets: [Int: [PhotoCandidate]] = [:]
        for i in photos.indices { buckets[root(i), default: []].append(photos[i]) }
        return buckets.values
            .filter { $0.count > 1 }
            .map(makeGroup)
            .sorted { $0.extraBytes != $1.extraBytes ? $0.extraBytes > $1.extraBytes : $0.id < $1.id }
    }

    /// The photo to keep: the most pixels, then the newest, then the largest file.
    public static func best(_ photos: [PhotoCandidate]) -> PhotoCandidate? {
        photos.max { a, b in
            if a.pixels != b.pixels { return a.pixels < b.pixels }
            if a.date != b.date { return a.date < b.date }
            if a.bytes != b.bytes { return a.bytes < b.bytes }
            return a.path > b.path
        }
    }

    static func makeGroup(_ photos: [PhotoCandidate]) -> SimilarPhotoGroup {
        let keep = best(photos)!
        let rest = photos.filter { $0.path != keep.path }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return SimilarPhotoGroup(photos: [keep] + rest, suggestedKeep: keep)
    }
}
