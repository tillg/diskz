import Charts
import DiskzCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", growers = "Growers", recent = "Recently added", changes = "Changes", browser = "Browser", status = "Status"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .growers: "chart.line.uptrend.xyaxis"
        case .recent: "tray.and.arrow.down"
        case .changes: "arrow.up.arrow.down"
        case .browser: "folder"
        case .status: "info.circle"
        }
    }
}

struct MainWindow: View {
    let library: Library
    let model: AppModel?
    @State var section: Section = .dashboard
    /// Snapshot mode has no running app to ask, so it can state that access is missing.
    var assumeNoAccess = false

    private var accessMissing: Bool { model.map { !$0.fullDiskAccess } ?? assumeNoAccess }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { section }, set: { section = $0 ?? .dashboard })) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(190) // wide enough for "Recently added"
        } detail: {
            Group {
                if library.scans.isEmpty {
                    ContentUnavailableView("No scan yet", systemImage: "internaldrive",
                                           description: Text("diskz scans by itself when the Mac is idle. You can also choose “Scan now” from its menu bar icon."))
                } else {
                    switch section {
                    case .dashboard: DashboardView(library: library)
                    case .growers: GrowersView(library: library)
                    case .recent: RecentView(library: library, model: model)
                    case .changes: ChangesView(library: library)
                    case .browser: BrowserView(library: library)
                    case .status: StatusView(library: library, model: model, accessMissing: accessMissing)
                    }
                }
            }
            .navigationTitle(section.rawValue)
        }
        .frame(minWidth: 820, minHeight: 540)
    }
}

// MARK: What grew lately

struct GrowersView: View {
    let library: Library
    @State private var window = Window.week
    @State private var result: Library.Growers?
    @State private var rows: [Library.Grower] = []
    @State private var order = [KeyPathComparator(\Library.Grower.change.delta, order: .reverse)]
    @State private var selection: String?

    enum Window: String, CaseIterable, Identifiable {
        case day = "Last day", week = "Last 7 days", month = "Last 30 days", all = "All history"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            case .all: nil
            }
        }
    }

    private struct Key: Equatable {
        var window: Window, revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Grew in the", selection: $window) {
                    ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if let result {
                    // Both scan dates, on a line of their own so they are never cut off.
                    Text("Comparing the scans of \(formatDate(result.baseline.startedAt)) and \(formatDate(result.latest.startedAt))"
                        + (result.coversWindow ? "" : " (the history does not go back further)")
                        + (result.total.map { ". Volume: \(formatSigned($0))" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if library.scans.count < 2 {
                ContentUnavailableView("Only one scan so far", systemImage: "clock",
                                       description: Text("Growth appears after the second scan."))
                    .frame(maxHeight: .infinity)
            } else if !rows.isEmpty {
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("Folder", value: \.change.path) { row in
                        HStack(spacing: 4) {
                            if row.inside != nil {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                            }
                            Text(library.display(row.change.path)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.leading, nestingIndent(row.depth))
                        .help(row.inside.map { "Part of \(library.display($0)), which is listed too. Its gain already includes this one." } ?? row.change.path)
                    }
                    TableColumn("Grew by", value: \.change.delta) { row in Text(formatSigned(row.change.delta)).monospacedDigit() }.width(110)
                    TableColumn("Now", value: \.change.after) { row in Text(formatBytes(row.change.after)).monospacedDigit() }.width(90)
                    TableColumn("How", value: \.how) { row in
                        HStack(spacing: 8) {
                            Sparkline(sizes: row.sizes).frame(width: 70, height: 16)
                            Text(row.how).foregroundStyle(.secondary)
                        }
                    }
                    .width(170)
                }
                .revealsInFinder()
                .onChange(of: order) { rows.sort(using: order) }
                if rows.contains(where: { $0.inside != nil }) {
                    Label("Rows marked with this arrow lie inside another listed folder, whose gain already includes theirs. Do not add them up.",
                          systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                }
                if let selection {
                    Divider()
                    FolderDetail(library: library, path: selection).frame(height: 230)
                }
            } else {
                ContentUnavailableView("Nothing grew", systemImage: "checkmark.circle",
                                       description: Text("No folder is larger than it was at the earlier scan."))
                    .frame(maxHeight: .infinity)
            }
        }
        .task(id: Key(window: window, revision: library.revision)) {
            result = library.growers(window: window.seconds)
            rows = (result?.rows ?? []).sorted(using: order)
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
        }
    }
}

// MARK: Recently added files

struct RecentView: View {
    let library: Library
    /// The running app, for "Scan now"; nil in snapshots.
    let model: AppModel?
    @State private var days = 7
    @State private var figures: RecentFigures?
    @State private var rows: [Library.RecentFolder] = []
    @State private var total: Int64?
    @State private var order = [KeyPathComparator(\Library.RecentFolder.row.added, order: .reverse)]
    @State private var selection: String?

    private struct Key: Equatable {
        var days: Int, revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Files added in the", selection: $days) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if let figures {
                    // Single lines on purpose: a wrapping text block above a table breaks the layout.
                    Text((total.map { "\(formatBytes($0)) in total, counted" } ?? "Counted")
                        + " back from the scan of \(formatDate(figures.scan.startedAt))."
                        + (figures.undatedFiles > 0 ? " \(figures.undatedFiles.formatted()) files (\(formatBytes(figures.undatedBytes))) had no usable date." : ""))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Text("“Added” is the size of files that arrived (new, downloaded, copied, moved in, re-saved). It is not net growth.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if figures == nil {
                ContentUnavailableView {
                    Label("No figures yet", systemImage: "tray.and.arrow.down")
                } description: {
                    Text(model?.isScanning == true
                        ? "A scan is running. The figures appear when it has finished."
                        : "These figures are collected during a scan, and the last scan was made before diskz could collect them. A scan takes a few minutes.")
                } actions: {
                    if let model, !model.isScanning {
                        Button("Scan now") { model.scanNow() }
                    }
                }
                .frame(maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("Nothing added", systemImage: "checkmark.circle",
                                       description: Text("No folder received 1 MB or more of new files in this period."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("Folder", value: \.row.path) { item in
                        HStack(spacing: 4) {
                            if item.inside != nil {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                            }
                            Text(library.display(item.row.path)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.leading, nestingIndent(item.depth))
                        .help(item.inside.map { "Part of \(library.display($0)), which is listed too. Its figure already includes this one." } ?? item.row.path)
                    }
                    TableColumn("Added", value: \.row.added) { item in Text(formatSigned(item.row.added)).monospacedDigit() }.width(110)
                    TableColumn("Folder size", value: \.row.alloc) { item in Text(formatBytes(item.row.alloc)).monospacedDigit() }.width(110)
                }
                .revealsInFinder()
                .onChange(of: order) { rows.sort(using: order) }
                if rows.contains(where: { $0.inside != nil }) {
                    Label("Rows marked with this arrow lie inside another listed folder, whose figure already includes theirs. Do not add them up.",
                          systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                }
                if let selection {
                    Divider()
                    FolderDetail(library: library, path: selection).frame(height: 230)
                }
            }
        }
        .task(id: Key(days: days, revision: library.revision)) {
            figures = library.recentFigures()
            (total, rows) = library.recentlyAdded(days: days)
            rows.sort(using: order)
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
        }
    }
}

/// Rows inside another listed folder step in, one more step per level of nesting.
private func nestingIndent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 4)) * 22 }

/// Shows a folder in Finder. A folder that no longer exists cannot be selected, so the nearest
/// folder above it that still exists is shown instead.
@MainActor
func revealInFinder(_ path: String) {
    var existing = path
    while !FileManager.default.fileExists(atPath: existing), existing != "/" {
        existing = (existing as NSString).deletingLastPathComponent
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: existing)])
}

extension View {
    /// For a table of folders: double-click (or Return) and a right-click menu item reveal the folder in Finder.
    func revealsInFinder() -> some View {
        contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first {
                Button("Reveal in Finder") { revealInFinder(path) }
            }
        } primaryAction: { paths in
            if let path = paths.first { revealInFinder(path) }
        }
    }
}

/// A folder's sizes over the scans in the window, as a small line: flat then a step is a jump, a slope is creep.
struct Sparkline: View {
    let sizes: [Int64]

    var body: some View {
        Canvas { context, size in
            // Two sizes would always draw the same straight line, which says nothing.
            guard sizes.count >= 3, let low = sizes.min(), let high = sizes.max() else { return }
            let range = Double(max(high - low, 1))
            var line = Path()
            for (index, value) in sizes.enumerated() {
                let point = CGPoint(x: size.width * Double(index) / Double(sizes.count - 1),
                                    y: 1 + (size.height - 2) * (1 - Double(value - low) / range))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(.series1), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
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
        /// Size of the change regardless of direction: the default order, largest change first.
        var magnitude: Int64 { abs(change.delta) }
    }

    @State private var order = [KeyPathComparator(\Row.magnitude, order: .reverse)]

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
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("Folder", value: \.change.path) { row in
                        Text(library.display(row.change.path))
                            .lineLimit(1).truncationMode(.middle).help(row.change.path)
                    }
                    TableColumn("Change", value: \.change.delta) { row in
                        Label(formatSigned(row.change.delta), systemImage: row.change.delta > 0 ? "arrow.up" : "arrow.down")
                            .monospacedDigit()
                    }
                    .width(130)
                    TableColumn("Now", value: \.change.after) { row in Text(formatBytes(row.change.after)).monospacedDigit() }.width(90)
                    TableColumn("Before", value: \.change.before) { row in
                        // No earlier size means new, or too small to have a history.
                        Text(row.change.before == 0 ? "< 1 MB" : formatBytes(row.change.before)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(90)
                }
                .revealsInFinder()
                .onChange(of: order) { rows.sort(using: order) }
                if let selection {
                    Divider()
                    FolderDetail(library: library, path: selection).frame(height: 230)
                }
            }
        }
        .task(id: Key(from: library.fromScan, to: library.toScan, revision: library.revision)) {
            rows = library.changes().map(Row.init).sorted(using: order)
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
                // Double-click opens the folder here, as in Finder; revealing it is on the right-click menu.
                .contextMenu(forSelectionType: String.self) { ids in
                    if let first = ids.first {
                        Button("Open") { library.navigation.open(first) }
                        Button("Reveal in Finder") { revealInFinder(first) }
                    }
                } primaryAction: { ids in
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
                Button("Reveal in Finder") { revealInFinder(path) }
                    .help(FileManager.default.fileExists(atPath: path) ? "" : "This folder no longer exists; Finder shows the nearest folder above it.")
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

// MARK: Dashboard

struct DashboardView: View {
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

    @State private var selection: String?
    @State private var order = [KeyPathComparator(\Unreadable.id)]
    private var rows: [Unreadable] { unreadable.map(Unreadable.init).sorted(using: order) }

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
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("Unreadable folder", value: \.id) { row in
                    Label(library.display(row.id), systemImage: "lock").lineLimit(1).truncationMode(.middle)
                }
            }
            .revealsInFinder()
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
