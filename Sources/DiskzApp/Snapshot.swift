import AppKit
import DiskzCore
import SwiftUI

/// Development aid: `Diskz --snapshot OUTDIR [--db FILE | --demo SCANS] [--no-access]` renders every section of
/// the window to PNG files (light and dark) and exits. It only reads the given database and never
/// starts the scheduler, so the UI can be checked without touching the real scan history.
enum Snapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count else { return }
        let out = args[flag + 1]
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        do {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            let database = try value("--db") ?? DemoData.make(scans: Int(value("--demo") ?? "") ?? 120)
            let root = try Store(path: database).scans().last?.root ?? AppModel.root
            // Query times on this database, as the window would run them.
            let probe = Library(databasePath: database, root: root)
            for (name, query) in [("growers", { _ = probe.growers(window: 7 * 86_400) }), ("changes", { _ = probe.changes() }),
                                  ("browser", { _ = probe.children(of: root) })] {
                let start = Date()
                query()
                note(String(format: "query %@: %.0f ms", name, Date().timeIntervalSince(start) * 1000))
            }
            for (name, window) in [("last day", 86_400.0), ("7 days", 7 * 86_400), ("30 days", 30 * 86_400), ("all history", nil)] as [(String, TimeInterval?)] {
                let growers = probe.growers(window: window)
                note("growers \(name): baseline \(growers.map { formatDate($0.baseline.startedAt) } ?? "none"), \(growers?.rows.count ?? 0) rows")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                app.appearance = NSAppearance(named: appearance)
                for section in Section.allCases {
                    note("rendering \(section.rawValue) \(name)")
                    let library = Library(databasePath: database, root: root)
                    // An offscreen capture has no window backdrop, so give the content one.
                    let host = NSHostingView(rootView: MainWindow(library: library, model: nil, section: section,
                                                                  assumeNoAccess: args.contains("--no-access"))
                        .background(Color(nsColor: .windowBackgroundColor)))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    window.orderFrontRegardless()
                    RunLoop.main.run(until: Date().addingTimeInterval(1.5)) // let tables and charts load
                    host.layoutSubtreeIfNeeded()
                    host.display()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    note("  table rows: \(tables(in: host).map { String($0.numberOfRows) }.joined(separator: ", "))")
                    let bounds = host.bounds
                    guard let image = host.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
                    host.cacheDisplay(in: bounds, to: image)
                    try image.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(out)/\(section.rawValue.lowercased())-\(name).png"))
                    window.orderOut(nil)
                }
            }
            if value("--db") == nil { try? FileManager.default.removeItem(atPath: (database as NSString).deletingLastPathComponent) }
            print("snapshots written to \(out)")
            exit(0)
        } catch {
            print("snapshot failed: \(error)")
            exit(1)
        }
    }
}

private func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Every table in a view tree, the sidebar list included; a capture cannot show the sidebar, its row count can.
@MainActor
private func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? [] + view.subviews.flatMap { tables(in: $0) }
}

/// A made-up scan history, so charts and lists have something to show.
enum DemoData {
    static func make(scans count: Int) throws -> String {
        let dir = NSTemporaryDirectory() + "diskz-demo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/demo.sqlite"
        let store = try Store(path: path)
        let gb: Int64 = 1_000_000_000
        // (parent index, name, start size in GB, growth in GB per day, unreadable until day)
        let folders: [(Int, String, Double, Double, Int)] = [
            (-1, "/System/Volumes/Data", 0, 0, 0),
            (0, "Users", 0, 0, 0), (1, "ada", 0, 0, 0),
            (2, "Library", 12, 0.02, 0), (3, "Mail", 60, 0.25, 30), (3, "Caches", 6, 0.05, 0),
            (3, "Group Containers", 90, 0.4, 0),
            (2, "Pictures", 40, 0.03, 0), (2, "Projects", 15, 0.12, 0), (8, "simulator-builds", 2, 0.5, 0),
            (2, "Downloads", 8, -0.03, 0),
            (0, "Applications", 30, 0.01, 0), (0, "Library", 15, 0.005, 0), (0, "private", 9, 0.01, 0),
        ]
        let now = Date()
        for day in 0..<count {
            let date = now.addingTimeInterval(Double(day - count + 1) * 86_400)
            let nodes = folders.enumerated().map { index, f in
                let wobble = Double((day * 7 + index * 13) % 5) * 0.05
                let size = max(0.5, f.2 + f.3 * Double(day) + wobble)
                let unknown = day < f.4
                return ScanNode(parent: f.0, name: f.1, ownAlloc: f.2 == 0 || unknown ? 0 : Int64(size * Double(gb)),
                                ownFiles: f.2 == 0 ? 0 : 1000, unknown: unknown)
            }
            var result = ScanResult(nodes: nodes, startedAt: date, finishedAt: date.addingTimeInterval(180),
                                    diskUsed: 0, diskFree: 0, entryErrors: 0)
            result.diskUsed = result.totals()[0].alloc + 250 * gb
            result.diskFree = 1000 * gb - result.diskUsed
            try store.record(result)
        }
        return path
    }
}
