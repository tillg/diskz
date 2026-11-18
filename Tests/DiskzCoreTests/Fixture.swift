import Foundation
import Testing
@testable import DiskzCore

let MB = 1 << 20

/// A real directory tree in a temp folder. No mocks: tests scan the actual file system.
final class Fixture {
    let root: String
    private let fm = FileManager.default
    private var databases: [String] = []

    init() throws {
        let dir = NSTemporaryDirectory() + "diskz-" + UUID().uuidString
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        root = String(cString: realpath(dir, nil))
    }

    deinit {
        try? fm.removeItem(atPath: root)
        for db in databases { try? fm.removeItem(atPath: db) }
    }

    func path(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    func mkdir(_ rel: String) throws {
        try fm.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
    }

    /// Writes a file of `bytes` bytes, creating parent directories.
    func write(_ rel: String, bytes: Int) throws {
        let p = path(rel)
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: p, contents: nil))
        let h = try #require(FileHandle(forWritingAtPath: p))
        try h.write(contentsOf: Data(repeating: 0x5A, count: bytes))
        try h.synchronize() // allocated size is only final once the data is on disk
        try h.close()
    }

    func remove(_ rel: String) throws { try fm.removeItem(atPath: path(rel)) }

    /// Scans the fixture after flushing pending writes, so allocated sizes are final.
    func scan() throws -> ScanResult {
        sync()
        return try Scanner.scan(root: root)
    }

    func store(cutoff: Int64 = Int64(MB)) throws -> Store {
        let dir = NSTemporaryDirectory() + "diskz-db-" + UUID().uuidString
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        databases.append(dir)
        return try Store(path: dir + "/diskz.sqlite", cutoff: cutoff)
    }
}

@discardableResult
func sh(_ tool: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.environment = ["BLOCKSIZE": "512", "LC_ALL": "en_US.UTF-8"] // du prints "?" for non-ASCII otherwise
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Allocated bytes per directory as reported by one `du` run over `path`.
func du(_ path: String) throws -> [String: Int64] {
    sync()
    var out: [String: Int64] = [:]
    for line in try sh("/usr/bin/du", [path]).split(separator: "\n") {
        let cols = line.split(separator: "\t", maxSplits: 1)
        out[String(cols[1])] = Int64(cols[0])! * 512
    }
    return out
}

extension ScanResult {
    func index(of path: String) -> Int? { nodes.indices.first { self.path(of: $0) == path } }
}
