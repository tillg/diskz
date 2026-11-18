import Charts
import DiskzCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case changes = "Changes", browser = "Browser", overview = "Overview", status = "Status"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .changes: "arrow.up.arrow.down"
        case .browser: "folder"
        case .overview: "chart.xyaxis.line"
        case .status: "info.circle"
        }
    }
}

struct MainWindow: View {
    let library: Library
    let model: AppModel?
    @State var section: Section = .changes
    /// Snapshot mode has no running app to ask, so it can state that access is missing.
    var assumeNoAccess = false

    private var accessMissing: Bool { model.map { !$0.fullDiskAccess } ?? assumeNoAccess }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { section }, set: { section = $0 ?? .changes })) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(160)
        } detail: {
            Group {
                if library.scans.isEmpty {
                    ContentUnavailableView("No scan yet", systemImage: "internaldrive",
                                           description: Text("diskz scans by itself when the Mac is idle. You can also choose “Scan now” from its menu bar icon."))
                } else {
                    switch section {
                    case .changes: ChangesView(library: library)
                    case .browser: BrowserView(library: library)
                    case .overview: OverviewView(library: library)
                    case .status: StatusView(library: library, model: model, accessMissing: accessMissing)
                    }
                }
            }
            .navigationTitle(section.rawValue)
        }
        .frame(minWidth: 820, minHeight: 540)
    }
}

// MARK: Comparing two scans

struct ScanPickers: View {
    @Bindable var library: Library

    var body: some View {
        HStack {
            Picker("Compare", selection: picked(\.fromScan)) { options }
            Picker("with", selection: picked(\.toScan)) { options }
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Picking a scan by hand stops the comparison from moving on to newer scans.
    private func picked(_ side: ReferenceWritableKeyPath<Library, Int64>) -> Binding<Int64> {
        Binding(get: { library[keyPath: side] }, set: {
            library[keyPath: side] = $0
            library.followsLatest = false
        })
    }

    private var options: some View {
        ForEach(library.scans, id: \.id) { scan in
            Text(formatDate(scan.startedAt)).tag(scan.id)
        }
    }
}

struct ChangesView: View {
    let library: Library
    @State private var rows: [Row] = []
    @State private var selection: String?

    struct Row: Identifiable {
        let change: Change
        var id: String { change.path }
    }

    private struct Key: Equatable {
        var from: Int64, to: Int64, revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            ScanPickers(library: library)
            Divider()
            if library.scans.count < 2 {
                ContentUnavailableView("Only one scan so far", systemImage: "clock",
                                       description: Text("Changes appear after the second scan."))
                    .frame(maxHeight: .infinity)
            } else if library.fromScan == library.toScan {
                ContentUnavailableView("Same scan on both sides", systemImage: "equal.circle",
                                       description: Text("Pick two different scans to compare."))
                    .frame(maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                       description: Text("No folder grew or shrank between these two scans."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Folder") { row in
                        Text(library.display(row.change.path))
                            .lineLimit(1).truncationMode(.middle).help(row.change.path)
                    }
                    TableColumn("Change") { row in
                        Label(formatSigned(row.change.delta), systemImage: row.change.delta > 0 ? "arrow.up" : "arrow.down")
                            .monospacedDigit()
                    }
                    .width(130)
                    TableColumn("Now") { row in Text(formatBytes(row.change.after)).monospacedDigit() }.width(90)
                    TableColumn("Before") { row in
                        Text(row.change.before == 0 ? "new" : formatBytes(row.change.before)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(90)
                }
                if let selection {
                    Divider()
                    FolderDetail(library: library, path: selection).frame(height: 230)
                }
            }
        }
        .task(id: Key(from: library.fromScan, to: library.toScan, revision: library.revision)) {
            rows = library.changes().map(Row.init)
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
        }
    }
}

// MARK: Browsing

struct BrowserView: View {
    let library: Library
    @State private var rows: [Row] = []
    @State private var selection: String?
    @State private var order = [KeyPathComparator(\Row.alloc, order: .reverse)]

    struct Row: Identifiable {
        let id: String
        let name: String
        let alloc: Int64
        let unknown: Bool
        let delta: Int64?
        var deltaKey: Int64 { delta ?? 0 }
    }

    private struct Key: Equatable {
        var path: String, from: Int64, to: Int64, revision: Int
    }

    private var path: String { library.navigation.current }

    var body: some View {
        VStack(spacing: 0) {
            ScanPickers(library: library)
            breadcrumb
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("No subfolders with a history", systemImage: "folder",
                                       description: Text("Folders under 1 MB are counted in their parent."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("Folder", value: \.name) { row in
                        Label(row.name, systemImage: row.unknown ? "lock" : "folder").lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Size", value: \.alloc) { row in
                        Text(row.unknown ? "unreadable" : formatBytes(row.alloc)).monospacedDigit()
                            .foregroundStyle(row.unknown ? .secondary : .primary)
                    }
                    .width(110)
                    TableColumn("Change", value: \.deltaKey) { row in
                        if let delta = row.delta {
                            Text(delta == 0 ? "—" : formatSigned(delta)).monospacedDigit()
                                .foregroundStyle(delta == 0 ? .secondary : .primary)
                        } else {
                            Text(library.fromScan != library.toScan ? "newly readable" : "").foregroundStyle(.secondary)
                        }
                    }
                    .width(130)
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    if let first = ids.first { library.navigation.open(first) }
                }
                .onChange(of: order) { rows.sort(using: order) }
                if let selection {
                    Divider()
                    FolderDetail(library: library, path: selection).frame(height: 230)
                }
            }
        }
        .toolbar {
            // Back and forward as in Finder, with the same shortcuts.
            ToolbarItemGroup(placement: .navigation) {
                Button { library.navigation.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!library.navigation.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to the previous folder (⌘[)")
                Button { library.navigation.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!library.navigation.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward to the next folder (⌘])")
            }
        }
        .task(id: Key(path: path, from: library.fromScan, to: library.toScan, revision: library.revision)) {
            rows = library.children(of: path).map {
                Row(id: $0.path, name: ($0.path as NSString).lastPathComponent, alloc: $0.alloc, unknown: $0.unknown, delta: $0.delta)
            }
            rows.sort(using: order)
            if !rows.contains(where: { $0.id == selection }) { selection = nil }
        }
    }

    /// One button per folder from the root down to the current folder.
    private var breadcrumb: some View {
        let parts = path.dropFirst(library.root.count).split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button(library.display(library.root)) { library.navigation.open(library.root) }
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    Button(part) { library.navigation.open(library.root + "/" + parts[...index].joined(separator: "/")) }
                }
                Text("Double-click a folder to open it").font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
            }
            .buttonStyle(.link)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

// MARK: One folder over time

struct FolderDetail: View {
    let library: Library
    let path: String
    @State private var points: [HistoryPoint] = []
    @State private var hover: Date?

    private struct Key: Equatable {
        var path: String, revision: Int
    }

    private struct Mark: Identifiable {
        let id: Int64
        let date: Date
        let bytes: Int64
        let run: Int
    }

    /// Known sizes only; a new run starts after every unreadable scan, so the line shows a gap there.
    private var marks: [Mark] {
        var run = 0
        var out: [Mark] = []
        for point in points {
            if let bytes = point.alloc {
                out.append(Mark(id: point.scan, date: point.date, bytes: bytes, run: run))
            } else {
                run += 1
            }
        }
        return out
    }

    var body: some View {
        let marks = marks
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(library.display(path)).font(.headline).lineLimit(1).truncationMode(.middle)
                if let last = marks.last { Text(formatBytes(last.bytes)).foregroundStyle(.secondary) }
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .disabled(!FileManager.default.fileExists(atPath: path))
            }
            if marks.count < 2 {
                Text(marks.isEmpty ? "No readable size recorded for this folder." : "A timeline appears after the second scan.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(marks) { mark in
                        AreaMark(x: .value("Scan", mark.date), y: .value("Size", mark.bytes), series: .value("Run", mark.run))
                            .foregroundStyle(Color.series1.opacity(0.15))
                        LineMark(x: .value("Scan", mark.date), y: .value("Size", mark.bytes), series: .value("Run", mark.run))
                            .foregroundStyle(Color.series1).lineStyle(StrokeStyle(lineWidth: 2))
                        if marks.count <= 40 {
                            PointMark(x: .value("Scan", mark.date), y: .value("Size", mark.bytes))
                                .foregroundStyle(Color.series1).symbolSize(40)
                        }
                    }
                    if let hover, let nearest = marks.min(by: { abs($0.date.timeIntervalSince(hover)) < abs($1.date.timeIntervalSince(hover)) }) {
                        RuleMark(x: .value("Scan", nearest.date))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(formatDate(nearest.date))  \(formatBytes(nearest.bytes))")
                                    .font(.caption).padding(4).background(.background, in: RoundedRectangle(cornerRadius: 4))
                            }
                    }
                }
                .chartXSelection(value: $hover)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let bytes = value.as(Int64.self) { Text(formatBytes(bytes)) } }
                    }
                }
                if marks.count < points.count {
                    Text("Gaps: the folder was unreadable at \(points.count - marks.count) scan(s).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .task(id: Key(path: path, revision: library.revision)) { points = library.history(of: path) }
    }
}

// MARK: Overview

struct OverviewView: View {
    let library: Library
    @State private var hover: Date?

    private struct Mark: Identifiable {
        let id: String
        let series: String
        let date: Date
        let bytes: Int64
    }

    private var marks: [Mark] {
        library.scans.flatMap { scan in
            [Mark(id: "u\(scan.id)", series: "Disk used", date: scan.startedAt, bytes: scan.diskUsed),
             Mark(id: "f\(scan.id)", series: "In folders", date: scan.startedAt, bytes: scan.scannedAlloc)]
        }
    }

    var body: some View {
        ScrollView {
            content.padding(16)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let scan = library.latest {
                HStack(spacing: 12) {
                    tile("Disk used", scan.diskUsed)
                    tile("Free", scan.diskFree)
                    tile("In folders", scan.scannedAlloc)
                    tile("Not attributed", scan.diskUsed - scan.scannedAlloc)
                }
                Text("“Not attributed” is space the disk reports as used but that is in no readable folder: unreadable folders, the system volume, and space the file system holds outside any file. In the chart it is the gap between the two lines.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if library.scans.count < 2 {
                ContentUnavailableView("Only one scan so far", systemImage: "chart.xyaxis.line",
                                       description: Text("A trend appears after the second scan."))
                    .frame(height: 300)
            } else {
                chart
            }
        }
    }

    private func tile(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(formatBytes(bytes)).font(.title2).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var chart: some View {
        let marks = marks
        return Chart {
            ForEach(marks) { mark in
                LineMark(x: .value("Scan", mark.date), y: .value("Bytes", mark.bytes))
                    .foregroundStyle(by: .value("Series", mark.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if library.scans.count <= 40 {
                    PointMark(x: .value("Scan", mark.date), y: .value("Bytes", mark.bytes))
                        .foregroundStyle(by: .value("Series", mark.series)).symbolSize(40)
                }
            }
            ForEach(marks.suffix(2)) { mark in
                PointMark(x: .value("Scan", mark.date), y: .value("Bytes", mark.bytes))
                    .foregroundStyle(by: .value("Series", mark.series)).symbolSize(40)
                    .annotation(position: .topLeading, spacing: 4) {
                        Text("\(mark.series) \(formatBytes(mark.bytes))").font(.caption).foregroundStyle(.secondary)
                    }
            }
            if let hover, let nearest = library.scans.min(by: { abs($0.startedAt.timeIntervalSince(hover)) < abs($1.startedAt.timeIntervalSince(hover)) }) {
                RuleMark(x: .value("Scan", nearest.startedAt))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatDate(nearest.startedAt)).bold()
                            Text("Disk used \(formatBytes(nearest.diskUsed))")
                            Text("In folders \(formatBytes(nearest.scannedAlloc))")
                            Text("Not attributed \(formatBytes(nearest.diskUsed - nearest.scannedAlloc))")
                        }
                        .font(.caption).padding(6).background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartForegroundStyleScale(["Disk used": Color.series1, "In folders": Color.series2])
        .chartXSelection(value: $hover)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let bytes = value.as(Int64.self) { Text(formatBytes(bytes)) } }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 380)
    }
}

// MARK: Status

struct StatusView: View {
    let library: Library
    let model: AppModel?
    let accessMissing: Bool
    @State private var unreadable: [String] = []

    private struct Unreadable: Identifiable {
        let id: String
    }

    private struct Key: Equatable {
        var to: Int64, revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                if let model { row("Now", model.status) }
                GridRow {
                    Text("Full Disk Access").foregroundStyle(.secondary)
                    if accessMissing {
                        HStack {
                            Text("Missing: Mail, Messages, Safari and other apps’ data cannot be read and count as “not attributed”.")
                            Button("Open Settings…") { FullDiskAccess.openSettings() }
                        }
                    } else {
                        Text("Granted")
                    }
                }
                if let scan = library.latest {
                    row("Last scan", "\(formatDate(scan.startedAt)), took \(duration(scan))")
                    row("Folders scanned", scan.dirCount.formatted())
                    row("Scans kept", library.scans.count.formatted())
                }
                row("Database", "\(formatBytes(library.databaseSize)) at \(library.databasePath)")
                row("Log", Log.path)
            }
            .padding(20)
            Divider()
            Text("\(unreadable.count) folders could not be read at the last scan")
                .font(.headline).padding(.horizontal, 20).padding(.vertical, 10)
            Table(unreadable.map(Unreadable.init)) {
                TableColumn("Unreadable folder") { row in
                    Label(library.display(row.id), systemImage: "lock").lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .task(id: Key(to: library.latest?.id ?? 0, revision: library.revision)) { unreadable = library.unknownDirectories() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    private func duration(_ scan: ScanInfo) -> String {
        let seconds = Int(scan.finishedAt.timeIntervalSince(scan.startedAt))
        return seconds >= 120 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}
