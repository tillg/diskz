import CoreGraphics
import DiskzCore
import Foundation
import AppKit
import IOKit.ps

enum SystemConditions {
    /// Safe to call from any thread.
    static func read() -> Conditions {
        let anyInput = CGEventType(rawValue: ~0)! // kCGAnyInputEventType
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)

        var onAC = true
        var battery: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
                onAC = type == kIOPMACPowerKey
            }
            let sources = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      let current = info[kIOPSCurrentCapacityKey] as? Int,
                      let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                battery = current * 100 / max
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        return Conditions(idleSeconds: idle, onACPower: onAC, batteryPercent: battery,
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                          thermalOK: thermal == .nominal || thermal == .fair)
    }
}

enum FullDiskAccess {
    /// These folders can be listed only with Full Disk Access.
    static var isGranted: Bool {
        for folder in ["Safari", "Mail", "Messages"] {
            let fd = open(NSHomeDirectory() + "/Library/" + folder, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno != ENOENT { return false } // exists but is protected
        }
        return false
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
