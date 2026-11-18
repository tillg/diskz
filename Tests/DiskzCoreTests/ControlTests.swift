import Foundation
import Testing
@testable import DiskzCore

@Suite struct ControlTests {
    func wideFixture() throws -> Fixture {
        let f = try Fixture()
        for i in 0..<400 {
            try f.write("d\(i)/sub/file", bytes: 3000)
        }
        return f
    }

    /// Runs a scan on its own thread and hands back the outcome.
    final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<ScanResult, Error>?
        let done = DispatchSemaphore(value: 0)

        func start(root: String, control: ScanControl) {
            let thread = Thread { [self] in
                let r = Result { try Scanner.scan(root: root, control: control) }
                lock.withLock { outcome = r }
                done.signal()
            }
            thread.stackSize = 8 << 20
            thread.start()
        }

        var result: Result<ScanResult, Error>? { lock.withLock { outcome } }
    }

    /// A4: a pause takes effect within 2 seconds, and the resumed scan equals an uninterrupted one.
    @Test func pausedScanResumesWithSameTotals() throws {
        let f = try wideFixture()
        let expected = try f.scan()

        // The walk asks at every directory whether it may go on; refuse from the 100th on.
        let gate = Gate(allowAfter: 100)
        let control = ScanControl(mayRun: { gate.mayRun() }, recheckInterval: 0)
        let runner = Runner()
        runner.start(root: f.root, control: control)

        let pausedAt = Date()
        while !control.isPaused && Date().timeIntervalSince(pausedAt) < 2 { usleep(10_000) }
        #expect(control.isPaused, "scan did not pause within 2 s")
        let progress = control.directoriesVisited
        #expect(progress > 0 && progress < 801)
        usleep(300_000)
        #expect(control.directoriesVisited == progress, "scan kept walking while paused")
        #expect(runner.result == nil)

        gate.open()
        #expect(runner.done.wait(timeout: .now() + 10) == .success)
        let resumed = try #require(runner.result).get()
        #expect(!control.isPaused)
        #expect(resumed.nodes.count == expected.nodes.count)
        #expect(resumed.totals() == expected.totals())
    }

    @Test func cancelledScanThrows() throws {
        let f = try wideFixture()
        let gate = Gate(allowAfter: 50)
        let control = ScanControl(mayRun: { gate.mayRun() }, recheckInterval: 0)
        let runner = Runner()
        runner.start(root: f.root, control: control)
        while !control.isPaused { usleep(10_000) }

        control.cancel()
        #expect(runner.done.wait(timeout: .now() + 2) == .success)
        #expect(throws: ScanCancelled.self) { try #require(runner.result).get() }
    }

    /// "Scan now" on a paused scan: the override lets it finish although conditions still say no.
    @Test func forcedScanIgnoresConditions() throws {
        let f = try wideFixture()
        let control = ScanControl(mayRun: { false }, recheckInterval: 0)
        let runner = Runner()
        runner.start(root: f.root, control: control)
        while !control.isPaused { usleep(10_000) }

        control.force()
        #expect(runner.done.wait(timeout: .now() + 10) == .success)
        #expect(try #require(runner.result).get().nodes.count == 801)
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var opened = false
        private let allowAfter: Int
        init(allowAfter: Int) { self.allowAfter = allowAfter }
        func mayRun() -> Bool { lock.withLock { calls += 1; return opened || calls < allowAfter } }
        func open() { lock.withLock { opened = true } }
    }
}

@Suite struct PolicyTests {
    let policy = SchedulePolicy()
    let idle = Conditions(idleSeconds: 600, onACPower: true, batteryPercent: nil, lowPowerMode: false, thermalOK: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func runsWhenIdleOnPower() {
        #expect(policy.blocker(idle) == nil)
    }

    @Test func eachConditionBlocks() {
        var c = idle; c.idleSeconds = 10
        #expect(policy.blocker(c) == .userActive)
        c = idle; c.onACPower = false; c.batteryPercent = 30
        #expect(policy.blocker(c) == .onBattery)
        c = idle; c.onACPower = false; c.batteryPercent = 80
        #expect(policy.blocker(c) == nil)
        c = idle; c.lowPowerMode = true
        #expect(policy.blocker(c) == .lowPowerMode)
        c = idle; c.thermalOK = false
        #expect(policy.blocker(c) == .thermalPressure)
    }

    @Test func startsOnlyAfterMinimumInterval() {
        #expect(policy.shouldStart(idle, lastScanFinished: nil, now: now))
        #expect(!policy.shouldStart(idle, lastScanFinished: now.addingTimeInterval(-3600), now: now))
        #expect(policy.shouldStart(idle, lastScanFinished: now.addingTimeInterval(-25 * 3600), now: now))
        var busy = idle; busy.idleSeconds = 5
        #expect(!policy.shouldStart(busy, lastScanFinished: nil, now: now))
    }

    /// A scan that failed is not retried at once, or a lasting fault would restart it every second.
    @Test func failedScanIsRetriedOnlyAfterADelay() {
        #expect(!policy.shouldStart(idle, lastScanFinished: nil, lastFailure: now.addingTimeInterval(-600), now: now))
        #expect(policy.shouldStart(idle, lastScanFinished: nil, lastFailure: now.addingTimeInterval(-3700), now: now))
    }

    @Test func scanOlderThanADayIsDiscarded() {
        #expect(!policy.shouldDiscard(scanStarted: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(policy.shouldDiscard(scanStarted: now.addingTimeInterval(-25 * 3600), now: now))
    }
}

@Suite struct SampleTests {
    /// Disk used/free is stored at scan start, independent of whether the scan completes.
    @Test func diskSamplesAreStoredWithoutAScan() throws {
        let f = try Fixture()
        let s = try f.store()
        let t = Date(timeIntervalSince1970: 2_000_000_000)
        try s.recordSample(DiskUsage(used: 800, free: 200), at: t)
        try s.recordSample(DiskUsage(used: 810, free: 190), at: t.addingTimeInterval(60))

        let samples = try s.samples()
        #expect(samples.map(\.usage.used) == [800, 810])
        #expect(samples.first?.at == t)
        #expect(try s.scans().isEmpty)
    }

    @Test func currentDiskUsageIsPlausible() throws {
        let usage = try DiskUsage.current(of: "/System/Volumes/Data")
        #expect(usage.used > 0 && usage.free > 0)
    }

    @Test func lastScanIsFilteredByRoot() throws {
        let f = try Fixture()
        let other = try Fixture()
        let s = try f.store()
        #expect(try s.lastScan(ofRoot: f.root) == nil)
        let mine = try s.record(try f.scan())
        try s.record(try other.scan())
        #expect(try s.lastScan(ofRoot: f.root)?.id == mine)
    }
}
