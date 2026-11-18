import Foundation
import Testing
@testable import DiskzCore

@Suite struct ScannerTests {
    /// A1: every directory total equals `du` on a tree with sparse files and symlinks.
    @Test func directoryTotalsMatchDu() throws {
        let f = try Fixture()
        try f.write("a/one.bin", bytes: 3 * MB)
        try f.write("a/b/two.bin", bytes: 70_000)
        try f.write("a/b/c/three.bin", bytes: 1)
        try f.write("d/four.bin", bytes: 2 * MB)
        try f.mkdir("empty")
        // Sparse file: 50 MB logical, almost nothing allocated.
        let h = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: f.path("d/sparse"), contents: nil); return f.path("d/sparse") }())!
        try h.truncate(atOffset: UInt64(50 * MB))
        try h.close()
        // Symlinks to a directory and a file must not be followed.
        try FileManager.default.createSymbolicLink(atPath: f.path("d/link-to-a"), withDestinationPath: f.path("a"))
        try FileManager.default.createSymbolicLink(atPath: f.path("link-to-file"), withDestinationPath: f.path("a/one.bin"))

        let r = try f.scan()
        let totals = r.totals()
        let expected = try du(f.root)

        #expect(r.nodes.count == expected.count)
        for (path, bytes) in expected {
            let i = try #require(r.index(of: path), "missing \(path)")
            #expect(totals[i].alloc == bytes, "\(path)")
            #expect(!r.nodes[i].unknown)
        }
        let d = try #require(r.index(of: f.path("d")))
        #expect(totals[d].logical >= Int64(52 * MB))
        #expect(totals[d].alloc < Int64(10 * MB))
        #expect(totals[0].files == 7) // 4 regular + sparse + 2 symlinks
        #expect(r.entryErrors == 0)
    }

    /// A1: a hard-linked file counts once, in the directory with the lowest path.
    @Test func hardLinksCountOnceInLowestPath() throws {
        let f = try Fixture()
        try f.write("zeta/big.bin", bytes: 2 * MB)
        try f.mkdir("alpha")
        try f.mkdir("mid")
        try FileManager.default.linkItem(atPath: f.path("zeta/big.bin"), toPath: f.path("mid/link1"))
        try FileManager.default.linkItem(atPath: f.path("zeta/big.bin"), toPath: f.path("alpha/link2"))

        let r = try f.scan()
        let totals = r.totals()
        let rootDu = try #require(try du(f.root)[f.root])

        #expect(totals[0].alloc == rootDu)
        #expect(totals[0].files == 1)
        #expect(totals[try #require(r.index(of: f.path("alpha")))].alloc >= Int64(2 * MB))
        #expect(totals[try #require(r.index(of: f.path("mid")))].alloc == 0)
        #expect(totals[try #require(r.index(of: f.path("zeta")))].alloc == 0)
    }

    /// Thousands of entries with long and non-ASCII names: exercises several bulk batches and name parsing.
    @Test func largeDirectoryWithUnicodeNames() throws {
        let f = try Fixture()
        let long = String(repeating: "x", count: 180)
        for i in 0..<3000 {
            try f.write("many/日本語-ä-\(i)-\(long)", bytes: 10)
        }
        for i in 0..<300 {
            try f.write("many/sub-ü-\(i)-\(long)/file", bytes: 5000)
        }

        let r = try f.scan()
        let totals = r.totals()
        let expected = try du(f.root)

        #expect(r.nodes.count == 302, "\(r.nodes.count) directories")
        #expect(totals[0].files == 3300, "\(totals[0].files) files, \(r.entryErrors) entry errors, \(r.nodes.count(where: \.unknown)) unknown")
        let scanned = Set(r.nodes.indices.map { r.path(of: $0) })
        let onlyScan = scanned.subtracting(expected.keys), onlyDu = Set(expected.keys).subtracting(scanned)
        func show(_ s: Set<String>) -> String {
            "\(s.count): " + s.prefix(3).map { $0.dropFirst(f.root.count).prefix(16).unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ") }.joined(separator: " | ")
        }
        #expect(onlyScan.isEmpty && onlyDu.isEmpty, "scan-only \(show(onlyScan)) ; du-only \(show(onlyDu))")
        for (path, bytes) in expected {
            let i = try #require(r.index(of: path), "missing \(path)")
            #expect(totals[i].alloc == bytes, "\(path)")
        }
    }

    /// An unreadable directory is reported as unknown, never as a known 0.
    @Test func unreadableDirectoryIsUnknown() throws {
        let f = try Fixture()
        try f.write("open/file", bytes: MB)
        try f.write("secret/file", bytes: MB)
        chmod(f.path("secret"), 0)
        defer { chmod(f.path("secret"), 0o755) }

        let r = try f.scan()

        let secret = try #require(r.index(of: f.path("secret")))
        #expect(r.nodes[secret].unknown)
        #expect(!r.nodes[try #require(r.index(of: f.path("open")))].unknown)
        #expect(!r.nodes[0].unknown)
    }

    /// The scan never crosses into another mounted volume.
    @Test func mountPointsAreNotCrossed() throws {
        let f = try Fixture()
        let images = try Fixture()
        try f.write("local/file", bytes: 100_000)
        try f.mkdir("mnt")
        let image = images.path("vol.dmg")
        try sh("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "HFS+", "-volname", "diskztest", image])
        try sh("/usr/bin/hdiutil", ["attach", image, "-mountpoint", f.path("mnt"), "-nobrowse"])
        defer { _ = try? sh("/usr/bin/hdiutil", ["detach", f.path("mnt"), "-force"]) }
        try f.write("mnt/inside/big.bin", bytes: 3 * MB)
        try #require(FileManager.default.fileExists(atPath: f.path("mnt/inside/big.bin")))

        let r = try f.scan()

        #expect(r.index(of: f.path("mnt")) == nil)
        #expect(r.index(of: f.path("mnt/inside")) == nil)
        #expect(r.index(of: f.path("local")) != nil)
        #expect(r.totals()[0].alloc < Int64(MB))
    }

    @Test func reportsWholeDiskFigures() throws {
        let f = try Fixture()
        let r = try f.scan()
        #expect(r.diskUsed > 0)
        #expect(r.diskFree > 0)
        #expect(r.finishedAt >= r.startedAt)
    }
}
