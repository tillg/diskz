import Foundation

public struct ScanCancelled: Error {}

/// Lets the owner of a scan pause, resume and cancel it.
///
/// The scan thread itself asks `mayRun` at every directory and every batch of entries (at most
/// once per `recheckInterval`). While the answer is no, the scan thread waits where it is, with
/// all its state intact, and continues from there once the answer is yes again.
public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private let mayRun: @Sendable () -> Bool
    private let recheckInterval: TimeInterval
    private var cancelled = false
    private var forced = false
    private var paused = false
    private var visited = 0
    private var lastCheck = DispatchTime(uptimeNanoseconds: 0)

    public init(mayRun: @escaping @Sendable () -> Bool = { true }, recheckInterval: TimeInterval = 0.5) {
        self.mayRun = mayRun
        self.recheckInterval = recheckInterval
    }

    public var isPaused: Bool { lock.withLock { paused } }
    public var directoriesVisited: Int { lock.withLock { visited } }

    /// Makes the scan stop with `ScanCancelled` at its next checkpoint.
    public func cancel() { lock.withLock { cancelled = true } }

    /// From now on the scan runs regardless of `mayRun` ("Scan now").
    public func force() { lock.withLock { forced = true } }

    func checkpoint(enteringDirectory: Bool) throws {
        let due: Bool = try lock.withLock {
            if enteringDirectory { visited += 1 }
            if cancelled { throw ScanCancelled() }
            if forced { return false }
            let now = DispatchTime.now()
            if Double(now.uptimeNanoseconds - lastCheck.uptimeNanoseconds) < recheckInterval * 1e9 { return false }
            lastCheck = now
            return true
        }
        if !due || mayRun() { return }

        lock.withLock { paused = true }
        defer { lock.withLock { paused = false } }
        while true {
            Thread.sleep(forTimeInterval: max(recheckInterval, 0.02))
            let (isCancelled, isForced) = lock.withLock { (cancelled, forced) }
            if isCancelled { throw ScanCancelled() }
            if isForced || mayRun() { return }
        }
    }
}

/// What the Mac is doing right now, as far as scheduling a scan is concerned.
public struct Conditions: Sendable {
    public var idleSeconds: Double
    public var onACPower: Bool
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    /// Thermal state is nominal or fair (not serious or critical).
    public var thermalOK: Bool

    public init(idleSeconds: Double, onACPower: Bool, batteryPercent: Int?, lowPowerMode: Bool, thermalOK: Bool) {
        self.idleSeconds = idleSeconds
        self.onACPower = onACPower
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.thermalOK = thermalOK
    }
}

public enum Blocker: String, Sendable {
    case userActive = "user is active"
    case onBattery = "on battery at 50 % or less"
    case lowPowerMode = "Low Power Mode is on"
    case thermalPressure = "the Mac is hot"
}

public struct SchedulePolicy: Sendable {
    public var minIdleSeconds: Double = 300
    public var minBatteryPercent = 50
    public var minInterval: TimeInterval = 24 * 3600
    public var maxScanDuration: TimeInterval = 24 * 3600
    /// No automatic start this soon after a scan that failed or was discarded.
    public var retryDelay: TimeInterval = 3600

    public init() {}

    /// The reason an automatic scan may not run right now; nil if it may.
    public func blocker(_ c: Conditions) -> Blocker? {
        if c.idleSeconds < minIdleSeconds { return .userActive }
        if !c.onACPower && (c.batteryPercent ?? 0) <= minBatteryPercent { return .onBattery }
        if c.lowPowerMode { return .lowPowerMode }
        if !c.thermalOK { return .thermalPressure }
        return nil
    }

    public func shouldStart(_ c: Conditions, lastScanFinished: Date?, lastFailure: Date? = nil, now: Date) -> Bool {
        if let failure = lastFailure, now.timeIntervalSince(failure) < retryDelay { return false }
        if let last = lastScanFinished, now.timeIntervalSince(last) < minInterval { return false }
        return blocker(c) == nil
    }

    /// A scan that has not finished within the maximum duration is thrown away and restarted.
    public func shouldDiscard(scanStarted: Date, now: Date) -> Bool {
        now.timeIntervalSince(scanStarted) > maxScanDuration
    }
}
