import Foundation

/// Asks macOS to release purgeable space on a disk. The app uses `TimeMachineThinner`; tests and the flow test use a
/// fake, so they never touch the real disk.
public protocol PurgeableSpaceReleaser: Sendable {
    /// Free space on the disk right now, and what macOS could free on top of it. Nil when macOS does not say.
    func space(volume: String) -> (available: Int64, purgeable: Int64)?
    /// Asks macOS to free up to `bytes`. Returns once macOS has answered; the space may show up a moment later.
    func release(mountPoint: String, bytes: Int64) async throws
}

/// What one "Free Purgeable Space" did.
public enum PurgeOutcome: Equatable, Sendable {
    /// Free space grew from `before` to `after`.
    case freed(before: Int64, after: Int64)
    /// macOS answered but free space did not grow (by more than noise).
    case nothingFreed(before: Int64, after: Int64)
    /// There was no purgeable space to ask for, so nothing was asked.
    case nothingToFree(available: Int64)
    case failed(String)

    public var freedBytes: Int64 {
        if case .freed(let before, let after) = self { return after - before }
        return 0
    }
}

/// Runs a release and measures it: free space before, the request, then free space again a few times, because APFS
/// frees the blocks of removed snapshots in the background.
public struct PurgeableSpaceFreer: Sendable {
    public let releaser: PurgeableSpaceReleaser
    /// How many times free space is read after the request.
    public var checks: Int
    /// Waits between those reads.
    public var pause: @Sendable () async -> Void
    /// Growth below this is other apps writing and deleting, not the release.
    public var noise: Int64

    public init(releaser: PurgeableSpaceReleaser, checks: Int = 4, noise: Int64 = 10_000_000,
                pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }) {
        self.releaser = releaser
        self.checks = max(1, checks)
        self.noise = noise
        self.pause = pause
    }

    public func run(volume: String, mountPoint: String) async -> PurgeOutcome {
        guard let start = releaser.space(volume: volume) else {
            return .failed(String(localized: "macOS did not say how much space the disk has."))
        }
        guard start.purgeable > 0 else { return .nothingToFree(available: start.available) }
        do {
            try await releaser.release(mountPoint: mountPoint, bytes: start.purgeable)
        } catch {
            return .failed(error.localizedDescription)
        }
        var after = start.available
        for check in 0..<checks {
            if check > 0 { await pause() }
            if let now = releaser.space(volume: volume) { after = max(after, now.available) }
        }
        return after - start.available > noise ? .freed(before: start.available, after: after)
                                               : .nothingFreed(before: start.available, after: after)
    }
}

/// Frees purgeable space the most conservative way that works without admin rights: it asks Time Machine to thin
/// its own local snapshots (`tmutil thinlocalsnapshots <disk> <bytes> 4`), the same call macOS makes when a disk runs
/// low. User files are never touched, and only Time Machine's snapshots of this disk can go, oldest first; snapshots
/// made by macOS updates are left alone.
///
/// Not chosen: filling the disk with a temporary file so macOS purges on its own. macOS only starts purging when free
/// space falls near its low-space thresholds, so it would have to fill the disk far below any safe floor, write many
/// gigabytes to the SSD, and could make other apps fail to save while it runs. The private CacheDelete framework that
/// Storage Settings uses is not public API. iCloud files and caches that macOS counts as purgeable are freed by macOS
/// itself when an app needs room, so the app offers Storage Settings for those.
public struct TimeMachineThinner: PurgeableSpaceReleaser {
    public init() {}

    public func space(volume: String) -> (available: Int64, purgeable: Int64)? {
        guard let space = DiskSpace.read(forPath: volume, scanned: 0) else { return nil }
        return (space.available, space.purgeable)
    }

    public func release(mountPoint: String, bytes: Int64) async throws {
        try await LocalSnapshots.thin(mountPoint: mountPoint, bytes: bytes)
    }
}
