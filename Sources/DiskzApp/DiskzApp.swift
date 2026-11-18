import DiskzCore
import SwiftUI

@main
struct DiskzApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // The logo from the app bundle; the drive symbol if the app runs outside its bundle.
            if let logo = Bundle.main.image(forResource: "MenuIcon") {
                Image(nsImage: logo)
            } else {
                Image(systemName: "internaldrive")
            }
        }
    }
}

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(model.status)
        if let scan = model.lastScan {
            Text("Last scan: \(AppModel.format(scan.finishedAt))")
            Text("\(bytes(scan.scannedAlloc)) in folders, \(bytes(scan.diskUsed - scan.scannedAlloc)) not attributed")
            if scan.unknownDirs > 0 {
                Text("\(scan.unknownDirs) folders could not be read")
            }
        } else {
            Text("No scan yet")
        }
        if !model.fullDiskAccess {
            Button("Grant Full Disk Access…") { FullDiskAccess.openSettings() }
        }
        Divider()
        Button(model.isScanning ? "Finish scan now" : "Scan now") { model.scanNow() }
        Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
        Divider()
        Button("Quit diskz") { NSApplication.shared.terminate(nil) }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
