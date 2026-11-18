import DiskzCore
import SwiftUI

@main
struct DiskzApp: App {
    @State private var model: AppModel

    init() {
        Snapshot.runIfRequested() // development aid; exits if it was asked for
        _model = State(initialValue: AppModel())
    }

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
        Window("diskz", id: "main") {
            if let library = model.library {
                MainWindow(library: library, model: model)
            } else {
                Text("The database could not be opened.").padding(40)
            }
        }
        .defaultSize(width: 1000, height: 680)
    }
}

struct MenuView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open diskz") {
            openWindow(id: "main")
            // The app has no Dock icon, so it must be brought forward explicitly.
            NSApplication.shared.activate(ignoringOtherApps: true)
            Log.write("window opened, app active: \(NSApplication.shared.isActive)")
        }
        Divider()
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
