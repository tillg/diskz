import Foundation

public enum GrowthPattern: String, Sendable {
    /// One step between two scans carries at least 80 % of the growth.
    case jump
    /// The growth is spread over several scans.
    case steady
    /// The size moved up and down more than twice as much as it gained in the end.
    case fluctuating
}

/// Helpers for "what grew in the last N days".
public enum Growth {
    /// The scan to compare the latest one with: the newest scan at least `window` older than the
    /// latest, or the oldest scan if the history is shorter. `scans` must be ordered oldest first.
    public static func baseline(in scans: [ScanInfo], window: TimeInterval) -> ScanInfo? {
        guard scans.count >= 2, let latest = scans.last else { return nil }
        let limit = latest.startedAt.addingTimeInterval(-window)
        return scans.dropLast().last { $0.startedAt <= limit } ?? scans.first
    }

    /// False when the history is shorter than the window, so the baseline is younger than asked for.
    public static func coversWindow(_ baseline: ScanInfo, latest: ScanInfo, window: TimeInterval) -> Bool {
        latest.startedAt.timeIntervalSince(baseline.startedAt) >= window
    }

    /// How a folder grew over consecutive scans; nil without net growth or with fewer than three sizes.
    public static func pattern(of sizes: [Int64]) -> GrowthPattern? {
        guard sizes.count >= 3, let first = sizes.first, let last = sizes.last, last > first else { return nil }
        let steps = zip(sizes, sizes.dropFirst()).map { $1 - $0 }
        let gain = last - first
        if steps.reduce(0, { $0 + abs($1) }) > 2 * gain { return .fluctuating }
        return (steps.max() ?? 0) * 5 >= gain * 4 ? .jump : .steady
    }
}
