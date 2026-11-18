import Foundation

/// One directory found by a scan. `parent` indexes into `ScanResult.nodes`; parents always precede children.
public struct ScanNode: Sendable {
    public var parent: Int
    public var name: String
    /// Sizes of the files directly inside this directory (subdirectories excluded).
    public var ownAlloc: Int64 = 0
    public var ownLogical: Int64 = 0
    public var ownFiles: Int64 = 0
    /// The directory could not be read (completely), so its size is not known.
    public var unknown = false
}

public struct DirTotals: Sendable, Equatable {
    public var alloc: Int64 = 0
    public var logical: Int64 = 0
    public var files: Int64 = 0
}

public struct ScanResult: Sendable {
    public var nodes: [ScanNode]
    public var startedAt: Date
    public var finishedAt: Date
    /// Whole-disk figures (capacity − free, and free), not just the scanned tree.
    public var diskUsed: Int64
    public var diskFree: Int64
    /// Directory entries whose attributes could not be read.
    public var entryErrors: Int

    public var root: String { nodes[0].name }

    /// Recursive totals per node, same indexing as `nodes`.
    public func totals() -> [DirTotals] {
        var t = nodes.map { DirTotals(alloc: $0.ownAlloc, logical: $0.ownLogical, files: $0.ownFiles) }
        for i in stride(from: nodes.count - 1, to: 0, by: -1) {
            let p = nodes[i].parent
            t[p].alloc += t[i].alloc
            t[p].logical += t[i].logical
            t[p].files += t[i].files
        }
        return t
    }

    public func path(of index: Int) -> String {
        var parts: [String] = []
        var i = index
        while i > 0 {
            parts.append(nodes[i].name)
            i = nodes[i].parent
        }
        return joinPath(root, parts.reversed())
    }
}

func joinPath(_ root: String, _ parts: [String]) -> String {
    if parts.isEmpty { return root }
    return (root.hasSuffix("/") ? root : root + "/") + parts.joined(separator: "/")
}
