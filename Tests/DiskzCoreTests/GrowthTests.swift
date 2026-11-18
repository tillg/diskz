import Foundation
import Testing
@testable import DiskzCore

@Suite struct GrowthTests {
    let day = 86_400.0
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Scans `daysAgo` days before `now`, oldest first, with ids 1, 2, 3 …
    func scans(_ daysAgo: [Double]) -> [ScanInfo] {
        daysAgo.enumerated().map { index, ago in
            let date = now.addingTimeInterval(-ago * day)
            return ScanInfo(id: Int64(index + 1), root: "/", startedAt: date, finishedAt: date, diskUsed: 0, diskFree: 0,
                            scannedAlloc: 0, dirCount: 0, unknownDirs: 0, entryErrors: 0)
        }
    }

    /// "Last 7 days" compares with the newest scan that is at least 7 days older than the latest one.
    @Test func baselineIsTheNewestScanOutsideTheWindow() {
        let all = scans([30, 10, 8, 6, 3, 0])
        #expect(Growth.baseline(in: all, window: 7 * day)?.id == 3) // 8 days ago
        #expect(Growth.baseline(in: all, window: 1 * day)?.id == 5) // 3 days ago
        #expect(Growth.baseline(in: all, window: 30 * day)?.id == 1)
    }

    /// With a shorter history the oldest scan is the best available baseline.
    @Test func baselineFallsBackToTheOldestScan() {
        let all = scans([2, 1, 0])
        let base = Growth.baseline(in: all, window: 7 * day)
        #expect(base?.id == 1)
        #expect(Growth.coversWindow(base!, latest: all.last!, window: 7 * day) == false)
        #expect(Growth.coversWindow(Growth.baseline(in: all, window: 1 * day)!, latest: all.last!, window: 1 * day))
    }

    @Test func noBaselineWithFewerThanTwoScans() {
        #expect(Growth.baseline(in: scans([0]), window: 7 * day) == nil)
        #expect(Growth.baseline(in: [], window: 7 * day) == nil)
    }

    /// One step carrying at least 80 % of the growth is a jump; growth spread over steps is steady.
    @Test func patternTellsJumpFromSteadyGrowth() {
        #expect(Growth.pattern(of: [10, 10, 30, 31]) == .jump)
        #expect(Growth.pattern(of: [10, 15, 20, 25, 30]) == .steady)
        #expect(Growth.pattern(of: [10, 30, 20, 40]) == .steady) // up, down, up: no single step explains it
    }

    /// A size that moves up and down much more than it gains is neither a jump nor steady growth.
    @Test func patternCallsNoisySizesFluctuating() {
        #expect(Growth.pattern(of: [100, 108, 99, 107, 98, 102]) == .fluctuating)
        #expect(Growth.pattern(of: [100, 90, 101]) == .fluctuating)
    }

    @Test func patternNeedsGrowthAndThreeSizes() {
        #expect(Growth.pattern(of: [10, 30]) == nil) // two scans cannot tell
        #expect(Growth.pattern(of: [30, 20, 10]) == nil)
        #expect(Growth.pattern(of: []) == nil)
    }
}
