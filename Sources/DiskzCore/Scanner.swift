import Darwin
import Foundation

public struct ScanError: Error, CustomStringConvertible {
    public let description: String
}

public enum Scanner {
    /// Walks `root` without following symlinks or crossing into other mounted volumes.
    public static func scan(root: String) throws -> ScanResult {
        guard let resolved = realpath(root, nil) else {
            throw ScanError(description: "cannot resolve \(root): \(String(cString: strerror(errno)))")
        }
        let rootPath = String(cString: resolved)
        free(resolved)

        // Never download cloud-only ("dataless") files or folders while scanning.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

        let started = Date()
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw ScanError(description: "cannot open \(rootPath): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)

        // Disk used and free are measured first, before the walk.
        var fs = statfs()
        statfs(rootPath, &fs)
        let blockSize = Int64(fs.f_bsize)

        let walker = Walker(device: st.st_dev)
        walker.nodes.append(ScanNode(parent: -1, name: rootPath))
        walker.walk(fd: fd, node: 0)
        walker.attributeHardLinks()

        return ScanResult(
            nodes: walker.nodes,
            startedAt: started,
            finishedAt: Date(),
            diskUsed: (Int64(fs.f_blocks) - Int64(fs.f_bfree)) * blockSize,
            diskFree: Int64(fs.f_bfree) * blockSize,
            entryErrors: walker.entryErrors)
    }
}

// Attribute bits from <sys/attr.h>, as UInt32 so they combine without casts.
private let cmnName: UInt32 = 0x0000_0001
private let cmnObjType: UInt32 = 0x0000_0008
private let cmnFileID: UInt32 = 0x0200_0000
private let cmnError: UInt32 = 0x2000_0000
private let cmnReturnedAttrs: UInt32 = 0x8000_0000
private let fileLinkCount: UInt32 = 0x0000_0001
private let fileAllocSize: UInt32 = 0x0000_0004
private let fileDataLength: UInt32 = 0x0000_0200
private let typeRegular: UInt32 = 1 // VREG
private let typeDirectory: UInt32 = 2 // VDIR

private final class Walker {
    var nodes: [ScanNode] = []
    var entryErrors = 0
    private let device: dev_t
    /// Files with several hard links, by inode: counted once, in the lowest-path directory.
    private var hardLinks: [UInt64: (node: Int, alloc: Int64, logical: Int64)] = [:]
    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var request = attrlist()

    init(device: dev_t) {
        self.device = device
        buffer = .allocate(byteCount: bufferSize, alignment: 8)
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnFileID
        request.fileattr = fileLinkCount | fileAllocSize | fileDataLength
    }

    deinit { buffer.deallocate() }

    func walk(fd: Int32, node: Int) {
        var subdirs: [String] = []
        var alloc: Int64 = 0, logical: Int64 = 0, files: Int64 = 0

        // The buffer is shared with recursive calls, so each directory is read completely first.
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                // A cloud-only folder holds nothing locally; anything else leaves the size unknown.
                if errno != EDEADLK { nodes[node].unknown = true }
                break
            }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var error: UInt32 = 0
                if returned.commonattr & cmnError != 0 {
                    error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var name = ""
                if returned.commonattr & cmnName != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                }
                if error != 0 {
                    entryErrors += 1
                    continue
                }
                var type: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var inode: UInt64 = 0
                if returned.commonattr & cmnFileID != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if type == typeDirectory {
                    subdirs.append(name)
                    continue
                }
                var links: UInt32 = 1
                var fileAlloc: Int64 = 0, fileLogical: Int64 = 0
                if returned.fileattr & fileLinkCount != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.fileattr & fileAllocSize != 0 {
                    fileAlloc = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if returned.fileattr & fileDataLength != 0 {
                    fileLogical = field.loadUnaligned(as: Int64.self)
                }
                if links > 1 && type == typeRegular {
                    noteHardLink(inode: inode, node: node, alloc: fileAlloc, logical: fileLogical)
                } else {
                    alloc += fileAlloc
                    logical += fileLogical
                    files += 1
                }
            }
        }
        nodes[node].ownAlloc = alloc
        nodes[node].ownLogical = logical
        nodes[node].ownFiles = files

        for name in subdirs {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if child < 0 {
                let code = errno
                if code == ENOENT { continue } // vanished while scanning
                nodes.append(ScanNode(parent: node, name: name, unknown: code != EDEADLK))
                continue
            }
            defer { close(child) }
            var st = stat()
            if fstat(child, &st) != 0 || st.st_dev != device { continue } // another volume is mounted here
            nodes.append(ScanNode(parent: node, name: name))
            walk(fd: child, node: nodes.count - 1)
        }
    }

    private func noteHardLink(inode: UInt64, node: Int, alloc: Int64, logical: Int64) {
        if let seen = hardLinks[inode], path(of: seen.node) <= path(of: node) { return }
        hardLinks[inode] = (node, alloc, logical)
    }

    func attributeHardLinks() {
        for link in hardLinks.values {
            nodes[link.node].ownAlloc += link.alloc
            nodes[link.node].ownLogical += link.logical
            nodes[link.node].ownFiles += 1
        }
    }

    private func path(of index: Int) -> String {
        var parts: [String] = []
        var i = index
        while i > 0 {
            parts.append(nodes[i].name)
            i = nodes[i].parent
        }
        return parts.reversed().joined(separator: "/")
    }
}
