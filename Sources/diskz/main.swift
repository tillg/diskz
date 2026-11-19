import DiskzCore
import Foundation

let usage = """
    usage: diskz <command> [options]

      scan [ROOT]          scan ROOT (default: /System/Volumes/Data) and record the result
      scans                list recorded scans
      top [PATH]           largest subdirectories of PATH (default: the scanned root)
      diff [FROM TO]       directories that changed between two scans (default: the last two)
      recent               directories that received the most new files before the latest scan

    options:
      --db FILE            database file (default: ~/Library/Application Support/diskz/diskz.sqlite)
      --scan ID            scan to show with `top` (default: the latest)
      -n COUNT             number of lines for `top`, `diff` and `recent` (default: 25)
      --days 7|30          period for `recent` (default: 7)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func bytes(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(abs(n)), unit = 0
    // Decimal units, like Finder and Disk Utility.
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    return (n < 0 ? "-" : "") + String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
}

func pad(_ s: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - s.count)) + s
}

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}

var dbPath = option("--db")
@MainActor func number(_ name: String) -> Int64? {
    guard let text = option(name) else { return nil }
    guard let value = Int64(text) else { fail("\(name) needs a number") }
    return value
}

let scanOption = number("--scan")
let count = Int(number("-n") ?? 25)
let days = Int(number("--days") ?? 7)
guard let command = args.first else { fail(usage) }
args.removeFirst()

if dbPath == nil { dbPath = try Store.defaultPath }

let dateFormat = DateFormatter()
dateFormat.dateFormat = "yyyy-MM-dd HH:mm"

do {
    let store = try Store(path: dbPath!)
    switch command {
    case "scan":
        let result = try Scanner.scan(root: args.first ?? "/System/Volumes/Data")
        let totals = result.totals()[0]
        let id = try store.record(result)
        let seconds = result.finishedAt.timeIntervalSince(result.startedAt)
        print("scan \(id) of \(result.root)")
        print("  disk used      \(bytes(result.diskUsed))  (free \(bytes(result.diskFree)))")
        print("  scanned        \(bytes(totals.alloc)) in \(totals.files) files, \(result.nodes.count) directories")
        print("  not attributed \(bytes(result.diskUsed - totals.alloc))")
        print("  unknown        \(result.nodes.count(where: \.unknown)) unreadable directories, \(result.entryErrors) unreadable entries")
        print("  added          \(bytes(totals.added7)) in the last 7 days, \(bytes(totals.added30)) in the last 30 days"
            + " (\(result.undatedFiles) files without a usable date, \(bytes(result.undatedBytes)))")
        print(String(format: "  took           %.1f s", seconds))

    case "scans":
        for s in try store.scans() {
            print("\(pad(String(s.id), 5))  \(dateFormat.string(from: s.startedAt))  used \(pad(bytes(s.diskUsed), 9))  "
                + "scanned \(pad(bytes(s.scannedAlloc), 9))  unknown dirs \(s.unknownDirs)  \(s.root)")
        }

    case "top":
        guard let latest = try store.scans().last else { fail("no scans recorded yet") }
        let scan = scanOption ?? latest.id
        let path = args.first ?? latest.root
        guard let own = try store.size(of: path, atScan: scan) else { fail("no history for \(path)") }
        print("\(pad(bytes(own.alloc), 10))  \(path)")
        for child in try store.children(of: path, atScan: scan).prefix(count) {
            print("\(pad(child.unknown ? "unknown" : bytes(child.alloc), 10))  \(child.path)")
        }

    case "diff":
        let from: Int64, to: Int64
        if args.count >= 2 {
            guard let a = Int64(args[0]), let b = Int64(args[1]) else { fail("diff needs two scan numbers") }
            (from, to) = (a, b)
        } else {
            guard let pair = try store.latestPair() else { fail("need two scans of the same folder") }
            (from, to) = pair
        }
        let changes = try store.changes(from: from, to: to, limit: count)
        if changes.isEmpty { print("no changes between scan \(from) and scan \(to)") }
        for c in changes {
            print("\(pad((c.delta > 0 ? "+" : "") + bytes(c.delta), 11))  \(pad(bytes(c.after), 10))  \(c.path)")
        }

    case "recent":
        guard let latest = try store.scans().last else { fail("no scans recorded yet") }
        guard let figures = try store.recentFigures(ofRoot: latest.root) else {
            fail("the latest scan has no figures on recently added files; scan again with this version")
        }
        print("files added in the \(days <= 7 ? 7 : 30) days before the scan of \(dateFormat.string(from: figures.scan.startedAt))")
        for row in try store.recentlyAdded(ofRoot: latest.root, days: days, limit: count) {
            print("\(pad("+" + bytes(row.added), 11))  \(pad(bytes(row.alloc), 10))  \(row.path)")
        }

    default:
        fail(usage)
    }
} catch {
    fail("diskz: \(error)")
}
