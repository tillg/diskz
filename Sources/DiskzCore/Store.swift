import Foundation

public struct ScanInfo: Sendable {
    public var id: Int64
    public var root: String
    public var startedAt: Date
    public var finishedAt: Date
    public var diskUsed: Int64
    public var diskFree: Int64
    public var scannedAlloc: Int64
    public var dirCount: Int64
    public var unknownDirs: Int64
    public var entryErrors: Int64
}

public struct DirSize: Sendable {
    public var path: String
    public var alloc: Int64
    public var logical: Int64
    public var files: Int64
    public var unknown: Bool
}

/// A directory's size at one scan; `alloc` is nil while the directory was unreadable.
public struct HistoryPoint: Sendable {
    public var scan: Int64
    public var date: Date
    public var alloc: Int64?
}

/// A subdirectory with its change since an earlier scan. `delta` is nil when there is no
/// comparison, or when the directory only became readable or unreadable in between.
public struct ChildChange: Sendable {
    public var path: String
    public var alloc: Int64
    public var unknown: Bool
    public var delta: Int64?
}

public struct DiskSample: Sendable {
    public var at: Date
    public var usage: DiskUsage
}

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
}

public struct Change: Sendable {
    public var path: String
    public var before: Int64
    public var after: Int64
    public var delta: Int64 { after - before }
}

/// History of directory sizes. A `sizes` row is written only when a directory's value changes,
/// so the size at scan N is the latest row with `scan_id <= N`.
public final class Store {
    private let db: Database
    private let cutoff: Int64

    /// The database shared by the app and the command-line tool.
    public static var defaultPath: String {
        get throws {
            let dir = NSHomeDirectory() + "/Library/Application Support/diskz"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return dir + "/diskz.sqlite"
        }
    }

    /// Directories whose subtree is smaller than `cutoff` bytes get no history of their own.
    public init(path: String, cutoff: Int64 = 1 << 20) throws {
        db = try Database(path: path)
        self.cutoff = cutoff
        try db.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS scans(
                id INTEGER PRIMARY KEY, root TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL NOT NULL,
                disk_used INTEGER NOT NULL, disk_free INTEGER NOT NULL, scanned_alloc INTEGER NOT NULL,
                dir_count INTEGER NOT NULL, unknown_dirs INTEGER NOT NULL, entry_errors INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS dirs(
                id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE(parent_id, name));
            CREATE TABLE IF NOT EXISTS sizes(
                dir_id INTEGER NOT NULL, scan_id INTEGER NOT NULL, alloc INTEGER NOT NULL, logical INTEGER NOT NULL,
                files INTEGER NOT NULL, unknown INTEGER NOT NULL, PRIMARY KEY(dir_id, scan_id)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS sizes_scan ON sizes(scan_id);
            CREATE TABLE IF NOT EXISTS disk_samples(at REAL PRIMARY KEY, used INTEGER NOT NULL, free INTEGER NOT NULL);
            """)
    }

    // MARK: Recording

    private struct DirKey: Hashable {
        var parent: Int64
        var name: String
    }

    private struct State: Equatable {
        var alloc: Int64 = 0
        var logical: Int64 = 0
        var files: Int64 = 0
        var unknown = false
        var isEmpty: Bool { alloc == 0 && !unknown }
    }

    @discardableResult
    public func record(_ result: ScanResult) throws -> Int64 {
        let totals = result.totals()
        let nodes = result.nodes

        // A directory containing an unreadable one is always tracked, so the unknown stays visible.
        var holdsUnknown = nodes.map(\.unknown)
        for i in stride(from: nodes.count - 1, to: 0, by: -1) where holdsUnknown[i] {
            holdsUnknown[nodes[i].parent] = true
        }

        var ids: [DirKey: Int64] = [:]
        var childrenOf: [Int64: [Int64]] = [:]
        _ = try db.query("SELECT id, parent_id, name FROM dirs") { row in
            ids[DirKey(parent: row.int(1), name: row.text(2))] = row.int(0)
            childrenOf[row.int(1), default: []].append(row.int(0))
        }
        var last: [Int64: State] = [:]
        _ = try db.query("""
            SELECT s.dir_id, s.alloc, s.logical, s.files, s.unknown FROM sizes s
            JOIN (SELECT dir_id, MAX(scan_id) AS latest FROM sizes GROUP BY dir_id) l
              ON l.dir_id = s.dir_id AND l.latest = s.scan_id
            """) { row in
            last[row.int(0)] = State(alloc: row.int(1), logical: row.int(2), files: row.int(3), unknown: row.int(4) != 0)
        }

        var scanID: Int64 = 0
        try db.transaction {
            try db.run("""
                INSERT INTO scans(root, started_at, finished_at, disk_used, disk_free, scanned_alloc,
                                  dir_count, unknown_dirs, entry_errors)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [result.root, result.startedAt.timeIntervalSince1970, result.finishedAt.timeIntervalSince1970,
                      result.diskUsed, result.diskFree, totals[0].alloc, nodes.count,
                      nodes.count(where: \.unknown), result.entryErrors])
            scanID = db.lastInsertID
            let insertDir = try db.prepare("INSERT INTO dirs(parent_id, name) VALUES (?, ?)")
            let insertSize = try db.prepare(
                "INSERT INTO sizes(dir_id, scan_id, alloc, logical, files, unknown) VALUES (?, ?, ?, ?, ?, ?)")

            // Parents precede children, so a parent's id is known before its children are handled.
            var dirID = [Int64](repeating: -1, count: nodes.count)
            var seen = Set<Int64>()
            for i in nodes.indices {
                let parentID: Int64 = i == 0 ? 0 : dirID[nodes[i].parent]
                if parentID < 0 { continue } // parent has no history, so neither has this one
                let key = DirKey(parent: parentID, name: nodes[i].name)
                let existing = ids[key]
                let hasHistory = existing.flatMap { last[$0] }.map { !$0.isEmpty } ?? false
                guard i == 0 || totals[i].alloc >= cutoff || holdsUnknown[i] || hasHistory else { continue }

                let id: Int64
                if let existing {
                    id = existing
                } else {
                    try insertDir.run([parentID, nodes[i].name])
                    id = db.lastInsertID
                }
                dirID[i] = id
                seen.insert(id)
                let now = State(alloc: totals[i].alloc, logical: totals[i].logical, files: totals[i].files,
                                unknown: nodes[i].unknown)
                if last[id] != now {
                    try insertSize.run([id, scanID, now.alloc, now.logical, now.files, now.unknown])
                }
            }

            // Directories under this root that had a size and were not found again are gone.
            var pending = [dirID[0]]
            while let id = pending.popLast() {
                if !seen.contains(id), let state = last[id], !state.isEmpty {
                    try insertSize.run([id, scanID, 0, 0, 0, false])
                }
                pending.append(contentsOf: childrenOf[id] ?? [])
            }
        }
        try thin(now: result.finishedAt)
        return scanID
    }

    func rowsWritten(byScan scan: Int64) throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM sizes WHERE scan_id = ?", [scan]) { $0.int(0) }[0])
    }

    // MARK: Disk usage samples

    /// Stores disk used/free on its own, so the figure survives even if the scan that follows is cancelled.
    public func recordSample(_ usage: DiskUsage, at date: Date = Date()) throws {
        try db.run("INSERT OR REPLACE INTO disk_samples(at, used, free) VALUES (?, ?, ?)",
                   [date.timeIntervalSince1970, usage.used, usage.free])
    }

    public func samples() throws -> [DiskSample] {
        try db.query("SELECT at, used, free FROM disk_samples ORDER BY at") { row in
            DiskSample(at: Date(timeIntervalSince1970: row.double(0)), usage: DiskUsage(used: row.int(1), free: row.int(2)))
        }
    }

    // MARK: Reading

    public func lastScan(ofRoot root: String) throws -> ScanInfo? {
        try scans().last { $0.root == root }
    }

    public func scans() throws -> [ScanInfo] {
        try db.query("""
            SELECT id, root, started_at, finished_at, disk_used, disk_free, scanned_alloc,
                   dir_count, unknown_dirs, entry_errors FROM scans ORDER BY id
            """) { row in
            ScanInfo(id: row.int(0), root: row.text(1),
                     startedAt: Date(timeIntervalSince1970: row.double(2)),
                     finishedAt: Date(timeIntervalSince1970: row.double(3)),
                     diskUsed: row.int(4), diskFree: row.int(5), scannedAlloc: row.int(6),
                     dirCount: row.int(7), unknownDirs: row.int(8), entryErrors: row.int(9))
        }
    }

    /// The latest scan and the one before it of the same root; nil if there is no such pair.
    public func latestPair() throws -> (from: Int64, to: Int64)? {
        let all = try scans()
        guard let last = all.last else { return nil }
        let sameRoot = all.filter { $0.root == last.root }
        guard sameRoot.count >= 2 else { return nil }
        return (sameRoot[sameRoot.count - 2].id, last.id)
    }

    /// Size of one directory at a scan; nil if it has no history (never seen, or below the cutoff).
    public func size(of path: String, atScan scan: Int64) throws -> DirSize? {
        guard let id = try dirID(forPath: path) else { return nil }
        return try db.query("""
            SELECT alloc, logical, files, unknown FROM sizes
            WHERE dir_id = ? AND scan_id <= ? ORDER BY scan_id DESC LIMIT 1
            """, [id, scan]) { row in
            DirSize(path: path, alloc: row.int(0), logical: row.int(1), files: row.int(2), unknown: row.int(3) != 0)
        }.first
    }

    /// Direct subdirectories that exist at a scan, largest first.
    public func children(of path: String, atScan scan: Int64) throws -> [DirSize] {
        guard let id = try dirID(forPath: path) else { return [] }
        return try childRows(of: id, atScan: scan).map {
            DirSize(path: joinPath(path, [$0.name]), alloc: $0.alloc, logical: $0.logical, files: $0.files, unknown: $0.unknown)
        }
    }

    private struct ChildRow {
        var id: Int64
        var name: String
        var alloc: Int64
        var logical: Int64
        var files: Int64
        var unknown: Bool
    }

    private func childRows(of id: Int64, atScan scan: Int64) throws -> [ChildRow] {
        try db.query("""
            SELECT d.id, d.name, s.alloc, s.logical, s.files, s.unknown FROM dirs d
            JOIN sizes s ON s.dir_id = d.id
             AND s.scan_id = (SELECT MAX(scan_id) FROM sizes WHERE dir_id = d.id AND scan_id <= ?2)
            WHERE d.parent_id = ?1 AND (s.alloc > 0 OR s.unknown = 1)
            ORDER BY s.alloc DESC, d.name
            """, [id, scan]) { row in
            ChildRow(id: row.int(0), name: row.text(1), alloc: row.int(2), logical: row.int(3),
                     files: row.int(4), unknown: row.int(5) != 0)
        }
    }

    /// One point per scan of the directory's root, oldest first; empty if the directory has no history.
    public func history(of path: String) throws -> [HistoryPoint] {
        guard let id = try dirID(forPath: path), let root = try rootPath(containing: path) else { return [] }
        let rows = try db.query("SELECT scan_id, alloc, unknown FROM sizes WHERE dir_id = ? ORDER BY scan_id", [id]) {
            ($0.int(0), $0.int(1), $0.int(2) != 0)
        }
        var next = 0
        var current: Int64? = 0 // before its first row a directory counts as 0
        return try scans().filter { $0.root == root }.map { scan in
            while next < rows.count, rows[next].0 <= scan.id {
                current = rows[next].2 ? nil : rows[next].1
                next += 1
            }
            return HistoryPoint(scan: scan.id, date: scan.startedAt, alloc: current)
        }
    }

    /// Paths of the directories that could not be read at a scan.
    public func unknownDirectories(atScan scan: Int64) throws -> [String] {
        guard let root = try scans().first(where: { $0.id == scan })?.root,
              let rootID = try dirID(forPath: root) else { return [] }
        var parentOf: [Int64: Int64] = [:], nameOf: [Int64: String] = [:]
        _ = try db.query("SELECT id, parent_id, name FROM dirs") { row in
            parentOf[row.int(0)] = row.int(1)
            nameOf[row.int(0)] = row.text(2)
        }
        let c = Comparison(entries: [:], inaccessible: [], parentOf: parentOf, nameOf: nameOf)
        return try db.query("""
            SELECT s.dir_id FROM sizes s
            WHERE s.unknown = 1 AND s.scan_id = (SELECT MAX(scan_id) FROM sizes WHERE dir_id = s.dir_id AND scan_id <= ?)
            """, [scan]) { $0.int(0) }
            .filter { (c.ancestors(of: $0).last ?? $0) == rootID }
            .map { c.path(of: $0) }
            .sorted()
    }

    private func rootPath(containing path: String) throws -> String? {
        try db.query("SELECT name FROM dirs WHERE parent_id = 0") { $0.text(0) }.first { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private func dirID(forPath path: String) throws -> Int64? {
        let roots = try db.query("SELECT id, name FROM dirs WHERE parent_id = 0") { ($0.int(0), $0.text(1)) }
        for (rootID, rootPath) in roots {
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path == rootPath || path.hasPrefix(prefix) else { continue }
            var id = rootID
            for part in path.dropFirst(prefix.count).split(separator: "/") {
                guard let next = try db.query("SELECT id FROM dirs WHERE parent_id = ? AND name = ?",
                                              [id, String(part)], { $0.int(0) }).first else { return nil }
                id = next
            }
            return id
        }
        return nil
    }

    // MARK: Changes

    /// Directories whose size differs between two scans, largest change first.
    ///
    /// - A directory is left out when a single subdirectory explains at least 80 % of its change,
    ///   so the list names the folder that grew rather than every ancestor up to the root.
    /// - Below a directory that is entirely new or entirely gone, nothing is listed: the top folder says it all.
    /// - A directory that merely became readable or unreadable is not a change, and its size is
    ///   taken out of its ancestors' changes.
    public func changes(from: Int64, to: Int64, limit: Int = 50) throws -> [Change] {
        let c = try comparison(from: from, to: to)
        // A tree that is entirely new or entirely gone is listed as its top folder only.
        var hidden = c.inaccessible
        for id in c.entries.keys {
            let insideWholeTree = c.ancestors(of: id).contains { ancestor in
                guard let entry = c.entries[ancestor], !c.inaccessible.contains(ancestor) else { return false }
                return entry.delta != 0 && (entry.before == 0 || entry.after == 0)
            }
            if insideWholeTree { hidden.insert(id) }
        }
        // Pass-through ancestors: one child explains at least 80 % of the change.
        // (A folder hidden by this rule still hides its own parent, so whole chains collapse.)
        let unlisted = hidden
        for (id, entry) in c.entries where !unlisted.contains(id) {
            guard let parent = c.parentOf[id], let parentEntry = c.entries[parent] else { continue }
            let (child, whole) = (entry.delta, parentEntry.delta)
            if child != 0, (child > 0) == (whole > 0), abs(child) * 5 >= abs(whole) * 4 {
                hidden.insert(parent)
            }
        }
        return c.entries
            .filter { !hidden.contains($0.key) && $0.value.delta != 0 }
            .map { Change(path: c.path(of: $0.key), before: $0.value.before, after: $0.value.after) }
            .sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.path < $1.path }
            .prefix(limit)
            .map { $0 }
    }

    /// Direct subdirectories at scan `scan`, largest first, each with its change since scan `since`.
    public func children(of path: String, atScan scan: Int64, since: Int64?) throws -> [ChildChange] {
        guard let id = try dirID(forPath: path) else { return [] }
        let comparison = try since.map { try self.comparison(from: $0, to: scan) }
        return try childRows(of: id, atScan: scan).map { row in
            var delta: Int64?
            if let comparison {
                if comparison.inaccessible.contains(row.id) {
                    delta = nil
                } else {
                    delta = comparison.entries[row.id]?.delta ?? 0
                }
            }
            return ChildChange(path: joinPath(path, [row.name]), alloc: row.alloc, unknown: row.unknown, delta: delta)
        }
    }

    private struct Comparison {
        struct Entry {
            var before: Int64
            var after: Int64
            var accessChanged: Bool
            var delta: Int64 { after - before }
        }
        /// Directories whose value changed between the two scans, access changes already taken out of `before`.
        var entries: [Int64: Entry]
        /// Directories that became readable or unreadable, and everything below them.
        var inaccessible: Set<Int64>
        var parentOf: [Int64: Int64]
        var nameOf: [Int64: String]

        func ancestors(of id: Int64) -> [Int64] {
            var out: [Int64] = []
            var current = parentOf[id] ?? 0
            while current != 0 {
                out.append(current)
                current = parentOf[current] ?? 0
            }
            return out
        }

        func path(of id: Int64) -> String {
            let chain = ([id] + ancestors(of: id)).reversed().map { nameOf[$0] ?? "?" }
            return joinPath(chain[0], Array(chain.dropFirst()))
        }
    }

    private func comparison(from: Int64, to: Int64) throws -> Comparison {
        let found = try db.query("SELECT id, root FROM scans WHERE id IN (?1, ?2)", [from, to]) { ($0.int(0), $0.text(1)) }
        guard Set(found.map(\.0)) == [from, to] else {
            throw StoreError(description: "scan \(from) or \(to) does not exist")
        }
        guard Set(found.map(\.1)).count == 1, let root = found.first?.1 else {
            throw StoreError(description: "scans \(from) and \(to) cover different folders")
        }
        var c = Comparison(entries: [:], inaccessible: [], parentOf: [:], nameOf: [:])
        _ = try db.query("""
            WITH changed AS (SELECT DISTINCT dir_id FROM sizes WHERE scan_id > ?1 AND scan_id <= ?2)
            SELECT c.dir_id, b.alloc, b.unknown, a.alloc, a.unknown FROM changed c
            LEFT JOIN sizes b ON b.dir_id = c.dir_id
             AND b.scan_id = (SELECT MAX(scan_id) FROM sizes WHERE dir_id = c.dir_id AND scan_id <= ?1)
            LEFT JOIN sizes a ON a.dir_id = c.dir_id
             AND a.scan_id = (SELECT MAX(scan_id) FROM sizes WHERE dir_id = c.dir_id AND scan_id <= ?2)
            """, [from, to]) { row in
            c.entries[row.int(0)] = Comparison.Entry(before: row.int(1), after: row.int(3),
                                                     accessChanged: (row.int(2) != 0) != (row.int(4) != 0))
        }
        if c.entries.isEmpty { return c }
        _ = try db.query("SELECT id, parent_id, name FROM dirs") { row in
            c.parentOf[row.int(0)] = row.int(1)
            c.nameOf[row.int(0)] = row.text(2)
        }
        // Scans of other folders may lie between the two; their directories are not part of this comparison.
        let rootID = try db.query("SELECT id FROM dirs WHERE parent_id = 0 AND name = ?", [root]) { $0.int(0) }.first
        c.entries = c.entries.filter { (c.ancestors(of: $0.key).last ?? $0.key) == rootID }

        // Access changes: drop the subtree and treat its size as if it had been there before.
        for (id, entry) in c.entries {
            let above = c.ancestors(of: id)
            if above.contains(where: { c.entries[$0]?.accessChanged == true }) {
                c.inaccessible.insert(id)
            } else if entry.accessChanged {
                c.inaccessible.insert(id)
                for ancestor in above { c.entries[ancestor]?.before += entry.delta }
            }
        }
        return c
    }

    // MARK: Retention

    /// Keeps every scan of the last 30 days, then the last scan of each week for a year, then the
    /// last of each 30-day period. A dropped scan's rows move to the next kept scan, so no change is lost.
    public func thin(now: Date = Date()) throws {
        let day = 86_400.0
        let all = try db.query("SELECT id, started_at FROM scans ORDER BY id") { ($0.int(0), $0.double(1)) }
        var keptBuckets = Set<String>()
        var dropped: [(id: Int64, next: Int64)] = []
        var nextKept: Int64 = 0
        for (id, started) in all.reversed() {
            let age = now.timeIntervalSince1970 - started
            var keep = age <= 30 * day
            if !keep {
                let bucket = age <= 365 * day ? "w\(Int(started / (7 * day)))" : "m\(Int(started / (30 * day)))"
                keep = keptBuckets.insert(bucket).inserted
            }
            if keep || nextKept == 0 {
                nextKept = id
            } else {
                dropped.append((id, nextKept))
            }
        }
        if dropped.isEmpty { return }
        // Newest dropped scan first, so the most recent value wins when several merge into one.
        try db.transaction {
            for (id, next) in dropped {
                try db.run("DELETE FROM sizes WHERE scan_id = ?1 AND dir_id IN (SELECT dir_id FROM sizes WHERE scan_id = ?2)",
                           [id, next])
                try db.run("UPDATE sizes SET scan_id = ?2 WHERE scan_id = ?1", [id, next])
                try db.run("DELETE FROM scans WHERE id = ?", [id])
            }
        }
    }
}
