import Foundation
import Testing
@testable import DiskzCore

@Suite struct StoreTests {
    /// root/a (2 MB) /a/b (2 MB), root/c (2 MB), root/tiny (10 KB, below the cutoff)
    func baseFixture() throws -> Fixture {
        let f = try Fixture()
        try f.write("a/file", bytes: 2 * MB)
        try f.write("a/b/file", bytes: 2 * MB)
        try f.write("c/file", bytes: 2 * MB)
        try f.write("tiny/file", bytes: 10_000)
        return f
    }

    @Test func recordsScanAndSizes() throws {
        let f = try baseFixture()
        let s = try f.store()
        let r = try f.scan()
        let id = try s.record(r)

        let info = try #require(try s.scans().first)
        #expect(info.id == id)
        #expect(info.root == f.root)
        #expect(info.scannedAlloc == r.totals()[0].alloc)
        #expect(info.diskUsed == r.diskUsed)
        #expect(info.unknownDirs == 0)

        let a = try #require(try s.size(of: f.path("a"), atScan: id))
        #expect(a.alloc == Int64(4 * MB))
        #expect(a.files == 2)
        let root = try #require(try s.size(of: f.root, atScan: id))
        #expect(root.alloc == r.totals()[0].alloc)
    }

    @Test func childrenAreSortedBySizeAndOmitSmallDirs() throws {
        let f = try baseFixture()
        let s = try f.store()
        let id = try s.record(try f.scan())

        let kids = try s.children(of: f.root, atScan: id)
        #expect(kids.map(\.path) == [f.path("a"), f.path("c")])
        // The small directory has no history of its own but counts toward its parent.
        #expect(try s.size(of: f.path("tiny"), atScan: id) == nil)
        let root = try #require(try s.size(of: f.root, atScan: id))
        #expect(root.alloc > Int64(6 * MB))
    }

    @Test func identicalRescanWritesNoRows() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        let second = try s.record(try f.scan())

        #expect(try s.rowsWritten(byScan: first) == 4) // root, a, a/b, c
        #expect(try s.rowsWritten(byScan: second) == 0)
        #expect(try s.size(of: f.path("a"), atScan: second)?.alloc == Int64(4 * MB))
    }

    @Test func changeWritesRowsOnlyForAncestorChain() throws {
        let f = try baseFixture()
        let s = try f.store()
        try s.record(try f.scan())
        try f.write("a/b/more", bytes: 2 * MB)
        let second = try s.record(try f.scan())

        #expect(try s.rowsWritten(byScan: second) == 3) // a/b, a, root
        #expect(try s.size(of: f.path("a/b"), atScan: second)?.alloc == Int64(4 * MB))
        #expect(try s.size(of: f.path("c"), atScan: second)?.alloc == Int64(2 * MB))
    }

    @Test func deletedDirectoryDropsToZeroButKeepsHistory() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.remove("c")
        let second = try s.record(try f.scan())

        #expect(try s.size(of: f.path("c"), atScan: first)?.alloc == Int64(2 * MB))
        #expect(try s.size(of: f.path("c"), atScan: second)?.alloc == 0)
        #expect(try s.children(of: f.root, atScan: second).map(\.path) == [f.path("a")])
    }

    /// A tracked directory that shrinks below the cutoff keeps its exact history.
    @Test func shrinkingBelowCutoffIsStillRecorded() throws {
        let f = try baseFixture()
        let s = try f.store()
        try s.record(try f.scan())
        try f.remove("c/file")
        try f.write("c/small", bytes: 100_000)
        let second = try s.record(try f.scan())

        let c = try #require(try s.size(of: f.path("c"), atScan: second))
        #expect(c.alloc > 0 && c.alloc < Int64(MB))
    }

    /// A7: the directory that grew is listed first, not its ancestors.
    @Test func changesListGrownDirectoryFirst() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.write("a/b/grown", bytes: 8 * MB)
        let second = try s.record(try f.scan())

        let changes = try s.changes(from: first, to: second)
        let top = try #require(changes.first)
        #expect(top.path == f.path("a/b"), "\(changes.map { "\($0.path.dropFirst(f.root.count)) \($0.before)->\($0.after)" })")
        #expect(top.delta == Int64(8 * MB))
        #expect(top.before == Int64(2 * MB))
        // Ancestors that only pass the growth through are not listed.
        #expect(changes.count == 1)
    }

    /// A tree that is entirely new is listed as its top folder only; its subfolders are implied.
    @Test func newTreeIsListedAsItsTopFolderOnly() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        for i in 0..<10 {
            try f.write("fresh/sub\(i)/file", bytes: 2 * MB)
        }
        let second = try s.record(try f.scan())

        let changes = try s.changes(from: first, to: second)
        #expect(changes.map(\.path) == [f.path("fresh")])
        #expect(changes.first?.delta == Int64(20 * MB))
        #expect(changes.first?.before == 0)
    }

    /// A new folder whose content sits in one nested subfolder still shows up, as its top folder.
    @Test func newNestedChainIsListedAsItsTopFolder() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.write("fresh/deep/deeper/file", bytes: 4 * MB)
        let second = try s.record(try f.scan())

        #expect(try s.changes(from: first, to: second).map(\.path) == [f.path("fresh")])
    }

    /// The same for a tree that is entirely gone.
    @Test func deletedTreeIsListedAsItsTopFolderOnly() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.remove("a") // holds a/file and a/b/file
        let second = try s.record(try f.scan())

        let changes = try s.changes(from: first, to: second)
        #expect(changes.map(\.path) == [f.path("a")])
        #expect(changes.first?.delta == -Int64(4 * MB))
        #expect(changes.first?.after == 0)
    }

    /// A folder that grew is still listed next to a new subfolder inside it when neither explains the other.
    @Test func growthInsideAnExistingFolderKeepsBothRows() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.write("a/more", bytes: 4 * MB)
        try f.write("a/fresh/file", bytes: 4 * MB)
        let second = try s.record(try f.scan())

        #expect(try s.changes(from: first, to: second).map(\.path) == [f.path("a"), f.path("a/fresh")])
    }

    @Test func changesListShrinkage() throws {
        let f = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.remove("c")
        let second = try s.record(try f.scan())

        let changes = try s.changes(from: first, to: second)
        #expect(changes.map(\.path) == [f.path("c")])
        #expect(changes.first?.delta == -Int64(2 * MB))
    }

    /// A folder that becomes readable (e.g. after granting Full Disk Access) is not growth.
    @Test func unknownBecomingKnownIsNotGrowth() throws {
        let f = try baseFixture()
        try f.write("secret/inner/file", bytes: 6 * MB)
        chmod(f.path("secret"), 0)
        defer { chmod(f.path("secret"), 0o755) }
        let s = try f.store()
        let first = try s.record(try f.scan())
        #expect(try s.size(of: f.path("secret"), atScan: first)?.unknown == true)
        #expect(try s.scans().first?.unknownDirs == 1)

        chmod(f.path("secret"), 0o755)
        try f.write("c/grown", bytes: 2 * MB)
        let second = try s.record(try f.scan())

        #expect(try s.size(of: f.path("secret"), atScan: second)?.unknown == false)
        #expect(try s.size(of: f.path("secret"), atScan: second)?.alloc == Int64(6 * MB))
        let changes = try s.changes(from: first, to: second)
        #expect(changes.map(\.path) == [f.path("c")])
        #expect(changes.first?.delta == Int64(2 * MB))
    }

    /// Thinning old scans keeps one per week and loses no change.
    @Test func thinningKeepsChanges() throws {
        let day = 86_400.0
        let weekStart = Date(timeIntervalSince1970: 7 * day * 2900)
        let now = weekStart.addingTimeInterval(60 * day)
        let f = try baseFixture()
        let s = try f.store()

        func record(at date: Date) throws -> Int64 {
            var r = try f.scan()
            r.startedAt = date
            r.finishedAt = date.addingTimeInterval(60)
            return try s.record(r)
        }
        _ = try record(at: weekStart.addingTimeInterval(1 * day))
        try f.write("a/more", bytes: 2 * MB)
        _ = try record(at: weekStart.addingTimeInterval(2 * day))
        try f.write("c/more", bytes: 2 * MB)
        let third = try record(at: weekStart.addingTimeInterval(3 * day))
        let recent = try record(at: now.addingTimeInterval(-1 * day))

        try s.thin(now: now)

        #expect(try s.scans().map(\.id) == [third, recent])
        #expect(try s.size(of: f.path("a"), atScan: third)?.alloc == Int64(6 * MB))
        #expect(try s.size(of: f.path("a/b"), atScan: third)?.alloc == Int64(2 * MB))
        #expect(try s.size(of: f.path("c"), atScan: third)?.alloc == Int64(4 * MB))
        #expect(try s.size(of: f.path("c"), atScan: recent)?.alloc == Int64(4 * MB))
        #expect(try s.changes(from: third, to: recent).isEmpty)
    }

    /// Scans of different folders in one database are never compared with each other.
    @Test func scansOfDifferentRootsAreNotCompared() throws {
        let f = try baseFixture()
        let other = try baseFixture()
        let s = try f.store()
        let first = try s.record(try f.scan())
        #expect(try s.latestPair() == nil)
        let foreign = try s.record(try other.scan())
        #expect(try s.latestPair() == nil)
        #expect(throws: StoreError.self) { try s.changes(from: first, to: foreign) }
        #expect(throws: StoreError.self) { try s.changes(from: first, to: 99) }

        try f.write("c/grown", bytes: 2 * MB)
        let third = try s.record(try f.scan())
        let pair = try #require(try s.latestPair())
        #expect(pair == (first, third))
        #expect(try s.changes(from: pair.from, to: pair.to).map(\.path) == [f.path("c")])
    }

    /// The app and the command-line tool may finish a scan at the same moment; both must be saved.
    @Test func twoProcessesCanRecordAtTheSameTime() throws {
        let f = try Fixture()
        for i in 0..<300 {
            try f.write("d\(i)/sub/file", bytes: 3000)
        }
        let result = try f.scan()
        let path = f.path("") + "-shared.sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        // Two connections, as two processes would have; a cutoff of 0 gives every folder a history.
        let stores = [try Store(path: path, cutoff: 0), try Store(path: path, cutoff: 0)]

        for round in 0..<5 {
            let failures = Failures()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                do { try stores[index].record(result) } catch { failures.add("\(error)") }
            }
            #expect(failures.all.isEmpty, "round \(round): \(failures.all)")
        }
        #expect(try stores[0].scans().count == 10)
        #expect(try stores[0].size(of: f.path("d7"), atScan: 10)?.files == 1)
    }

    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    @Test func recentScansAreNotThinned() throws {
        let f = try baseFixture()
        let s = try f.store()
        let a = try s.record(try f.scan())
        let b = try s.record(try f.scan())
        try s.thin()
        #expect(try s.scans().map(\.id) == [a, b])
    }
}
