import DiskzCore
import SwiftUI

/// What the window shows: the recorded scans of one root, the two scans being compared, and the queries on them.
@MainActor @Observable
final class Library {
    let root: String
    let databasePath: String
    private(set) var scans: [ScanInfo] = []
    /// Changes whenever the data was reloaded, so views know to query again.
    private(set) var revision = 0
    var fromScan: Int64 = 0
    var toScan: Int64 = 0
    /// Where the browser is, kept here so it survives switching to another section.
    var navigation: NavigationHistory
    /// True until the user picks scans; while true, both sides move on to each new scan.
    var followsLatest = true
    private let store: Store?

    init(databasePath: String, root: String) {
        self.databasePath = databasePath
        self.root = root
        navigation = NavigationHistory(start: root)
        store = try? Store(path: databasePath)
        reload()
    }

    /// Called at launch and whenever a scan has finished.
    func reload() {
        scans = ((try? store?.scans()) ?? []).filter { $0.root == root }
        let ids = scans.map(\.id)
        // Compare the last two scans, unless the user picked others and those still exist.
        if followsLatest || !ids.contains(toScan) || !ids.contains(fromScan) {
            toScan = ids.last ?? 0
            fromScan = ids.dropLast().last ?? ids.last ?? 0
            followsLatest = true
        }
        revision += 1
    }

    var latest: ScanInfo? { scans.last }

    func changes() -> [Change] {
        guard fromScan != toScan else { return [] }
        return (try? store?.changes(from: olderScan, to: newerScan, limit: 200)) ?? []
    }

    /// The later of the two picked scans; the order of the two pickers does not matter.
    var newerScan: Int64 { max(fromScan, toScan) }
    var olderScan: Int64 { min(fromScan, toScan) }

    func children(of path: String) -> [ChildChange] {
        (try? store?.children(of: path, atScan: newerScan, since: olderScan == newerScan ? nil : olderScan)) ?? []
    }

    struct Grower: Identifiable {
        let change: Change
        /// Known sizes at the scans since the baseline, oldest first.
        let sizes: [Int64]
        let pattern: GrowthPattern?
        /// Another listed folder that contains this one; its gain already includes this row's.
        var inside: String?
        /// How many listed folders contain this one; rows are indented by it.
        var depth = 0
        var id: String { change.path }

        /// In words, how the folder grew.
        var how: String {
            if change.before == 0 { return "was < 1 MB" } // new, or too small to have a history
            switch pattern {
            case .jump: return "one jump"
            case .steady: return "steady"
            case .fluctuating: return "up and down"
            case nil: return ""
            }
        }
    }

    struct Growers {
        let baseline: ScanInfo
        /// False when the history is shorter than the window asked for.
        let coversWindow: Bool
        let latest: ScanInfo
        /// The whole volume's gain; shown in the header, not in the ranking.
        let total: Int64?
        let rows: [Grower]
    }

    /// Folders that grew between the baseline for `window` (nil: the oldest scan) and the latest scan, largest first.
    func growers(window: TimeInterval?) -> Growers? {
        guard let latest, let baseline = window.map({ Growth.baseline(in: scans, window: $0) }) ?? (scans.count >= 2 ? scans.first : nil)
        else { return nil }
        let all = (try? store?.changes(from: baseline.id, to: latest.id, limit: 2000)) ?? []
        let changes = all.filter { $0.delta > 0 && $0.path != root }.prefix(50)
        let rows = changes.map { change in
            let sizes = history(of: change.path).filter { $0.scan >= baseline.id }.compactMap(\.alloc)
            let containers = changes.map(\.path).filter { change.path.hasPrefix($0 + "/") }
            return Grower(change: change, sizes: sizes, pattern: Growth.pattern(of: sizes),
                          inside: containers.max { $0.count < $1.count }, depth: containers.count)
        }
        return Growers(baseline: baseline, coversWindow: window.map { Growth.coversWindow(baseline, latest: latest, window: $0) } ?? true,
                       latest: latest, total: all.first { $0.path == root }?.delta, rows: Array(rows))
    }

    struct RecentFolder: Identifiable {
        let row: RecentRow
        /// Another listed folder that contains this one; its figure already includes this row's.
        let inside: String?
        /// How many listed folders contain this one; rows are indented by it.
        let depth: Int
        var id: String { row.path }
    }

    /// The scan the "recently added" figures come from; nil until a scan has collected them.
    func recentFigures() -> RecentFigures? { (try? store?.recentFigures(ofRoot: root)) ?? nil }

    /// The whole volume's figure is the grand total; it goes into the header, not into the ranking.
    func recentlyAdded(days: Int) -> (total: Int64?, folders: [RecentFolder]) {
        let all = (try? store?.recentlyAdded(ofRoot: root, days: days)) ?? []
        let rows = all.filter { $0.path != root }
        let folders = rows.map { row in
            let containers = rows.map(\.path).filter { row.path.hasPrefix($0 + "/") }
            return RecentFolder(row: row, inside: containers.max { $0.count < $1.count }, depth: containers.count)
        }
        return (all.first { $0.path == root }?.added, folders)
    }

    func history(of path: String) -> [HistoryPoint] { (try? store?.history(of: path)) ?? [] }
    func samples() -> [DiskSample] { (try? store?.samples()) ?? [] }
    func unknownDirectories() -> [String] { (try? store?.unknownDirectories(atScan: latest?.id ?? 0)) ?? [] }

    var databaseSize: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: databasePath))?[.size] as? Int64) ?? 0
    }

    // MARK: Paths

    @ObservationIgnored private var sameAsShortPath: [String: Bool] = [:]

    /// `/System/Volumes/Data/Users/x` is shown as `/Users/x` where both name the same folder.
    /// That holds for most top-level folders but not all (`/System` and `/usr` are different folders).
    func display(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        guard root == prefix, path.hasPrefix(prefix + "/") else { return path == prefix ? "/ (Data volume)" : path }
        let short = String(path.dropFirst(prefix.count))
        let top = short.split(separator: "/").first.map(String.init) ?? ""
        if let known = sameAsShortPath[top] { return known ? short : path }
        var a = stat(), b = stat()
        let same = stat(prefix + "/" + top, &a) == 0 && stat("/" + top, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
        sameAsShortPath[top] = same
        return same ? short : path
    }
}

func formatBytes(_ n: Int64) -> String {
    if n == 0 { return "0" } // the system formatter says "Zero KB"
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func formatSigned(_ n: Int64) -> String {
    (n > 0 ? "+" : n < 0 ? "−" : "") + formatBytes(abs(n))
}

func formatDate(_ date: Date) -> String {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH:mm"
    return format.string(from: date)
}

/// Chart colours: slots 1 and 2 of the reference palette, with their own dark-mode steps.
extension Color {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let series1 = adaptive(light: 0x2A78D6, dark: 0x3987E5)
    static let series2 = adaptive(light: 0xEB6834, dark: 0xD95926)
}
