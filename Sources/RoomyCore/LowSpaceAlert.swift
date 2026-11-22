import Foundation

/// When Roomy should warn that the startup disk is almost full.
public enum LowSpaceAlert {
    /// At most one alert per this interval.
    public static let repeatInterval: TimeInterval = 24 * 60 * 60

    /// True when `free` is below `threshold` and no alert was sent in the last day.
    /// A last alert in the future (the clock went back) does not block the alert.
    public static func shouldAlert(free: Int64, threshold: Int64, lastAlert: Date?, now: Date) -> Bool {
        guard threshold > 0, free < threshold else { return false }
        guard let lastAlert else { return true }
        let elapsed = now.timeIntervalSince(lastAlert)
        return elapsed < 0 || elapsed >= repeatInterval
    }
}
