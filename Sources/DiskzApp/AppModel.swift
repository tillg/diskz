import DiskzCore
import Foundation
import ServiceManagement

/// Decides when to scan, runs the scan on its own thread, and holds what the menu shows.
@MainActor @Observable
final class AppModel {
    static let root = "/System/Volumes/Data"

    var status = "Starting…"
    var lastScan: ScanInfo?
    var fullDiskAccess = FullDiskAccess.isGranted
    var isScanning: Bool { running != nil }
    var startAtLogin = SMAppService.mainApp.status == .enabled

    private struct Running {
        let control: ScanControl
        let started: Date
        var wasPaused = false
    }

    private var running: Running?
    private var timer: Timer?
    private var lastBlocker: String?
    private var lastFailure: Date?
    private var ticks = 0
    private let policy: SchedulePolicy
    private let databasePath: String?
    /// What the window shows; nil if the database cannot be opened.
    let library: Library?

    init() {
        // Both values can be changed with `defaults write com.github.tillg.diskz <key> <number>`.
        var policy = SchedulePolicy()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "minIdleSeconds") != nil { policy.minIdleSeconds = defaults.double(forKey: "minIdleSeconds") }
        if defaults.object(forKey: "minIntervalHours") != nil { policy.minInterval = defaults.double(forKey: "minIntervalHours") * 3600 }
        self.policy = policy
        databasePath = try? Store.defaultPath
        library = databasePath.map { Library(databasePath: $0, root: Self.root) }

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.write("launched, build \(build), Full Disk Access \(fullDiskAccess ? "granted" : "denied"), "
            + "idle threshold \(Int(policy.minIdleSeconds)) s, interval \(policy.minInterval / 3600) h")
        reloadLastScan()
        // Common run-loop modes, so the status keeps updating while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Scheduling

    private func tick() {
        let access = FullDiskAccess.isGranted
        if access != fullDiskAccess {
            fullDiskAccess = access
            Log.write("Full Disk Access \(access ? "granted" : "denied")")
        }
        let now = Date()
        // Every second while a scan runs; every 30 seconds otherwise.
        defer { ticks += 1 }
        if running == nil && ticks % 30 != 0 { return }
        if var scan = running {
            let paused = scan.control.isPaused
            if paused != scan.wasPaused {
                Log.write(paused ? "scan paused after \(scan.control.directoriesVisited) folders" : "scan resumed")
                scan.wasPaused = paused
                running = scan
            }
            let folders = scan.control.directoriesVisited.formatted()
            status = paused ? "Scan paused (\(folders) folders so far)" : "Scanning… \(folders) folders"
            if policy.shouldDiscard(scanStarted: scan.started, now: now) {
                Log.write("scan discarded: not finished within \(Int(policy.maxScanDuration / 3600)) h")
                scan.control.cancel()
            }
            return
        }

        let conditions = SystemConditions.read()
        if policy.shouldStart(conditions, lastScanFinished: lastScan?.finishedAt, lastFailure: lastFailure, now: now) {
            startScan(manual: false)
            return
        }
        // Say why no scan starts, and log it whenever the reason changes.
        let reason: String
        if let failure = lastFailure, now.timeIntervalSince(failure) < policy.retryDelay {
            reason = "last scan did not finish; retry after \(Self.format(failure.addingTimeInterval(policy.retryDelay)))"
        } else if let last = lastScan, now.timeIntervalSince(last.finishedAt) < policy.minInterval {
            reason = "next scan after \(Self.format(last.finishedAt.addingTimeInterval(policy.minInterval)))"
        } else {
            reason = "waiting: \(policy.blocker(conditions)?.rawValue ?? "?")"
        }
        if reason != lastBlocker {
            lastBlocker = reason
            Log.write("no scan: \(reason)")
        }
        status = reason.prefix(1).uppercased() + reason.dropFirst()
    }

    /// "Scan now": starts a scan, or lets a running one finish regardless of the idle conditions.
    func scanNow() {
        if let scan = running {
            Log.write("scan forced to continue by user")
            scan.control.force()
            status = "Scanning… \(scan.control.directoriesVisited.formatted()) folders"
        } else {
            startScan(manual: true) // deliberately ignores the retry delay
        }
    }

    private func startScan(manual: Bool) {
        guard let databasePath else {
            status = "Cannot open the database"
            return
        }
        let policy = policy
        let pauseLog = PauseLog()
        let control = ScanControl(mayRun: {
            let conditions = SystemConditions.read()
            let blocker = policy.blocker(conditions)
            pauseLog.note(blocker, conditions)
            return blocker == nil
        })
        if manual { control.force() }
        running = Running(control: control, started: Date())
        lastBlocker = nil
        Log.write("scan started (\(manual ? "manual" : "idle"))")
        status = "Scanning…"

        let root = Self.root
        let thread = Thread {
            let outcome: String
            var succeeded = false
            do {
                let store = try Store(path: databasePath)
                // Disk used/free is written first, so it is kept even if this scan never finishes.
                try store.recordSample(try DiskUsage.current(of: root))
                let result = try Scanner.scan(root: root, control: control)
                let walked = result.finishedAt.timeIntervalSince(result.startedAt)
                let recordStart = Date()
                let id = try store.record(result)
                outcome = String(format: "scan %lld finished: %d folders, %d unreadable, walk %.1f s, save %.1f s",
                                 id, result.nodes.count, result.nodes.count(where: \.unknown), walked,
                                 Date().timeIntervalSince(recordStart))
                succeeded = true
            } catch is ScanCancelled {
                outcome = "scan cancelled"
            } catch {
                outcome = "scan failed: \(error)"
            }
            let ok = succeeded
            Task { @MainActor in self.finished(outcome, succeeded: ok) }
        }
        thread.name = "diskz-scan"
        thread.stackSize = 16 << 20 // the walk recurses once per directory level
        thread.qualityOfService = manual ? .utility : .background
        thread.start()
    }

    private func finished(_ outcome: String, succeeded: Bool) {
        Log.write(outcome)
        running = nil
        lastFailure = succeeded ? nil : Date()
        ticks = 0
        reloadLastScan()
    }

    private func reloadLastScan() {
        library?.reload()
        guard let databasePath else { return }
        lastScan = try? Store(path: databasePath).lastScan(ofRoot: Self.root)
    }

    // MARK: Start at login

    func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("start at login \(on ? "enabled" : "disabled")")
        } catch {
            Log.write("start at login could not be changed: \(error)")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func format(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }
}

/// Logs each time the scan thread finds it has to pause, with how long ago the user input was.
private final class PauseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false

    func note(_ blocker: Blocker?, _ conditions: Conditions) {
        let changed = lock.withLock {
            let changed = (blocker != nil) != blocked
            blocked = blocker != nil
            return changed
        }
        guard changed, let blocker else { return }
        let detail = blocker == .userActive ? String(format: ", %.2f s after the input", conditions.idleSeconds) : ""
        Log.write("pausing: \(blocker.rawValue)\(detail)")
    }
}
