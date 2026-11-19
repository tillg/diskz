import Foundation
import Testing
@testable import DiskzCore

/// "Recently added": bytes in files whose date added lies in the 7 or 30 days before the scan.
@Suite struct RecentTests {
    /// fresh (now), week (5 days), month (20 days), old (100 days), mixed (1 MB now + 3 MB old)
    func agedFixture() throws -> Fixture {
        let f = try Fixture()
        try f.write("fresh/a", bytes: 2 * MB)
        try f.write("week/b", bytes: 2 * MB)
        try f.setAdded("week/b", daysAgo: 5)
        try f.write("month/c", bytes: 2 * MB)
        try f.setAdded("month/c", daysAgo: 20)
        try f.write("old/d", bytes: 2 * MB)
        try f.setAdded("old/d", daysAgo: 100)
        try f.write("mixed/new", bytes: MB)
        try f.write("mixed/old", bytes: 3 * MB)
        try f.setAdded("mixed/old", daysAgo: 100)
        return f
    }

    func added(_ r: ScanResult, _ f: Fixture, _ rel: String) throws -> (Int64, Int64) {
        let t = r.totals()[try #require(r.index(of: f.path(rel)))]
        return (t.added7, t.added30)
    }

    @Test func bytesAreBucketedByDateAdded() throws {
        let f = try agedFixture()
        let r = try f.scan()

        #expect(try added(r, f, "fresh") == (Int64(2 * MB), Int64(2 * MB)))
        #expect(try added(r, f, "week") == (Int64(2 * MB), Int64(2 * MB)))
        #expect(try added(r, f, "month") == (0, Int64(2 * MB)))
        #expect(try added(r, f, "old") == (0, 0))
        #expect(try added(r, f, "mixed") == (Int64(MB), Int64(MB)))
        #expect(try added(r, f, "") == (Int64(5 * MB), Int64(7 * MB)))
        #expect(r.undatedFiles == 0)
    }

    /// The scanner's reading of the dates agrees with what Foundation reports for the same files.
    @Test func totalsMatchAnIndependentFoundationWalk() throws {
        let f = try agedFixture()
        let r = try f.scan()
        let root = r.totals()[0]
        #expect(root.added7 == (try f.bytesAddedPerFoundation(withinDays: 7)))
        #expect(root.added30 == (try f.bytesAddedPerFoundation(withinDays: 30)))
        #expect(root.added30 > root.added7 && root.added7 > 0)
    }

    /// A date more than a day in the future cannot be right; such files count as undated, not as recent.
    @Test func futureDatesAreUndated() throws {
        let f = try Fixture()
        try f.write("dir/fine", bytes: 2 * MB)
        try f.write("dir/future", bytes: 3 * MB)
        try f.setAdded("dir/future", daysAgo: -10)
        let r = try f.scan()

        #expect(try added(r, f, "dir") == (Int64(2 * MB), Int64(2 * MB)))
        #expect(r.undatedFiles == 1)
        #expect(r.undatedBytes == Int64(3 * MB))
    }

    /// The windows count back from the scan time.
    @Test func windowsCountBackFromTheScan() throws {
        let f = try Fixture()
        try f.write("dir/file", bytes: 2 * MB)
        let in10Days = try f.scan(now: Date().addingTimeInterval(10 * 86_400))
        #expect(try added(in10Days, f, "dir") == (0, Int64(2 * MB)))
        let in40Days = try f.scan(now: Date().addingTimeInterval(40 * 86_400))
        #expect(try added(in40Days, f, "dir") == (0, 0))
        #expect(in40Days.undatedFiles == 0)
    }

    @Test func hardLinkedFileCountsOnce() throws {
        let f = try Fixture()
        try f.write("zeta/big", bytes: 2 * MB)
        try f.mkdir("alpha")
        try FileManager.default.linkItem(atPath: f.path("zeta/big"), toPath: f.path("alpha/link"))
        let r = try f.scan()
        #expect(try added(r, f, "") == (Int64(2 * MB), Int64(2 * MB)))
        #expect(try added(r, f, "alpha") == (Int64(2 * MB), Int64(2 * MB)))
        #expect(try added(r, f, "zeta") == (0, 0))
    }

    // MARK: Store

    /// Ranked by bytes added; a folder is left out when one subfolder holds at least 80 % of them.
    @Test func recentlyAddedNamesTheFolderThatReceivedTheFiles() throws {
        let f = try Fixture()
        try f.write("big/deep/file", bytes: 8 * MB)
        try f.write("side/file", bytes: MB)
        try f.write("old/file", bytes: 4 * MB)
        try f.setAdded("old/file", daysAgo: 100)
        let s = try f.store()
        try s.record(try f.scan())

        let rows = try s.recentlyAdded(ofRoot: f.root, days: 7)
        #expect(rows.map(\.path) == [f.path("big/deep"), f.path("side")])
        #expect(rows.first?.added == Int64(8 * MB))
        #expect(rows.first?.alloc == Int64(8 * MB))
    }

    @Test func thirtyDayFiguresIncludeOlderFiles() throws {
        let f = try agedFixture()
        let s = try f.store()
        try s.record(try f.scan())

        #expect(try s.recentlyAdded(ofRoot: f.root, days: 7).contains { $0.path == f.path("month") } == false)
        let month = try #require(try s.recentlyAdded(ofRoot: f.root, days: 30).first { $0.path == f.path("month") })
        #expect(month.added == Int64(2 * MB))
        #expect(try s.recentlyAdded(ofRoot: f.root, days: 30).contains { $0.path == f.path("old") } == false)
    }

    /// Only the latest scan's figures are kept; an older scan's figures never linger.
    @Test func figuresBelongToTheLatestScan() throws {
        let f = try Fixture()
        try f.write("dir/file", bytes: 4 * MB)
        let s = try f.store()
        #expect(try s.recentFigures(ofRoot: f.root) == nil)
        let first = try s.record(try f.scan())
        #expect(try s.recentFigures(ofRoot: f.root)?.scan.id == first)
        #expect(try s.recentlyAdded(ofRoot: f.root, days: 7).map(\.path) == [f.path("dir")])

        let second = try s.record(try f.scan(now: Date().addingTimeInterval(40 * 86_400)))
        #expect(try s.recentFigures(ofRoot: f.root)?.scan.id == second)
        #expect(try s.recentlyAdded(ofRoot: f.root, days: 7).isEmpty)
        #expect(try s.recentlyAdded(ofRoot: f.root, days: 30).isEmpty)
    }

    @Test func undatedFilesAreReported() throws {
        let f = try Fixture()
        try f.write("dir/future", bytes: 3 * MB)
        try f.setAdded("dir/future", daysAgo: -10)
        let s = try f.store()
        try s.record(try f.scan())
        let figures = try #require(try s.recentFigures(ofRoot: f.root))
        #expect(figures.undatedFiles == 1)
        #expect(figures.undatedBytes == Int64(3 * MB))
    }
}
