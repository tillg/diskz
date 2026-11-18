import Foundation
import Testing
@testable import DiskzCore

/// Queries behind the window UI.
@Suite struct ViewQueryTests {
    /// root/a (2 MB) /a/b (2 MB), root/c (2 MB), root/c/secret/inner (6 MB, unreadable at first)
    func fixture() throws -> Fixture {
        let f = try Fixture()
        try f.write("a/file", bytes: 2 * MB)
        try f.write("a/b/file", bytes: 2 * MB)
        try f.write("c/file", bytes: 2 * MB)
        try f.write("c/secret/inner/file", bytes: 6 * MB)
        chmod(f.path("c/secret"), 0)
        return f
    }

    @Test func historyCarriesValuesForwardAndShowsUnknownAsGap() throws {
        let f = try fixture()
        defer { chmod(f.path("c/secret"), 0o755) }
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.write("a/more", bytes: 2 * MB)
        chmod(f.path("c/secret"), 0o755)
        let second = try s.record(try f.scan())
        let third = try s.record(try f.scan())

        let a = try s.history(of: f.path("a"))
        #expect(a.map(\.scan) == [first, second, third])
        #expect(a.map(\.alloc) == [Int64(4 * MB), Int64(6 * MB), Int64(6 * MB)])
        // Unreadable is a gap, never 0.
        #expect(try s.history(of: f.path("c/secret")).map(\.alloc) == [nil, Int64(6 * MB), Int64(6 * MB)])
        // A folder that appears later counts as 0 before.
        try f.write("late/file", bytes: 2 * MB)
        try s.record(try f.scan())
        #expect(try s.history(of: f.path("late")).map(\.alloc) == [0, 0, 0, Int64(2 * MB)])
        #expect(try s.history(of: f.path("nowhere")).isEmpty)
    }

    @Test func unknownDirectoriesAreListedPerScan() throws {
        let f = try fixture()
        defer { chmod(f.path("c/secret"), 0o755) }
        let s = try f.store()
        let first = try s.record(try f.scan())
        chmod(f.path("c/secret"), 0o755)
        let second = try s.record(try f.scan())

        #expect(try s.unknownDirectories(atScan: first) == [f.path("c/secret")])
        #expect(try s.unknownDirectories(atScan: second).isEmpty)
    }

    /// The browser's change column follows the same rule as the Changes list:
    /// a folder that merely became readable is not growth, neither for itself nor for its parents.
    @Test func childrenWithChangeIgnoreAccessChanges() throws {
        let f = try fixture()
        defer { chmod(f.path("c/secret"), 0o755) }
        let s = try f.store()
        let first = try s.record(try f.scan())
        try f.write("a/b/more", bytes: 2 * MB)
        chmod(f.path("c/secret"), 0o755)
        let second = try s.record(try f.scan())

        let top = try s.children(of: f.root, atScan: second, since: first)
        #expect(top.map(\.path) == [f.path("c"), f.path("a")])
        let c = top[0], a = top[1]
        #expect(c.alloc == Int64(8 * MB))
        #expect(c.delta == 0) // the 6 MB only became visible
        #expect(a.alloc == Int64(6 * MB))
        #expect(a.delta == Int64(2 * MB))

        let inC = try s.children(of: f.path("c"), atScan: second, since: first)
        #expect(inC.map(\.path) == [f.path("c/secret")])
        #expect(inC[0].delta == nil) // access changed: no meaningful comparison
        #expect(inC[0].alloc == Int64(6 * MB))
    }

    @Test func childrenWithoutComparisonHaveNoDelta() throws {
        let f = try fixture()
        defer { chmod(f.path("c/secret"), 0o755) }
        let s = try f.store()
        let first = try s.record(try f.scan())
        let top = try s.children(of: f.root, atScan: first, since: nil)
        #expect(top.map(\.path) == [f.path("a"), f.path("c")])
        #expect(top.allSatisfy { $0.delta == nil })
    }
}
