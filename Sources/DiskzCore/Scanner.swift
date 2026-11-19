import Darwin
import Foundation

public struct ScanError: Error, CustomStringConvertible {
    public let description: String
}

public enum Scanner {
    /// Walks `root` without following symlinks or crossing into other mounted volumes.
    /// `control` can pause or cancel the walk; a cancelled scan throws `ScanCancelled`.
    /// `now` is the moment the "added in the last 7 / 30 days" windows count back from.
    public static func scan(root: String, control: ScanControl = ScanControl(), now: Date = Date()) throws -> ScanResult {
        guard let resolved = realpath(root, nil) else {
            throw ScanError(description: "cannot resolve \(root): \(String(cString: strerror(errno)))")
        }
        let rootPath = String(cString: resolved)
        free(resolved)

        // Never download cloud-only ("dataless") files or folders while scanning. The setting covers
        // only the scanning thread, so the rest of the app can still open cloud files normally.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

        let started = Date()
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw ScanError(description: "cannot open \(rootPath): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)

        // Disk used and free are measured first, before the walk.
        let usage = try DiskUsage.current(of: rootPath)

        let walker = Walker(device: st.st_dev, control: control, now: now)
        walker.nodes.append(ScanNode(parent: -1, name: rootPath))
        try walker.walk(fd: fd, node: 0)
        walker.attributeHardLinks()

        return ScanResult(
            nodes: walker.nodes,
            startedAt: started,
            finishedAt: Date(),
            diskUsed: usage.used,
            diskFree: usage.free,
            entryErrors: walker.entryErrors,
            undatedFiles: walker.undatedFiles,
            undatedBytes: walker.undatedBytes)
    }
}

// Attribute bits from <sys/attr.h>, as UInt32 so they combine without casts.
private let cmnName: UInt32 = 0x0000_0001
private let cmnObjType: UInt32 = 0x0000_0008
private let cmnFileID: UInt32 = 0x0200_0000
private let cmnAddedTime: UInt32 = 0x1000_0000
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
    var undatedFiles: Int64 = 0
    var undatedBytes: Int64 = 0
    /// "Date added" limits in seconds since 1970: later than `latest` cannot be right.
    private let since7: Int
    private let since30: Int
    private let latest: Int
    private let device: dev_t
    private let control: ScanControl
    /// Files with several hard links, by inode: counted once, in the lowest-path directory.
    private var hardLinks: [UInt64: (node: Int, alloc: Int64, logical: Int64, added: Int?)] = [:]
    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var request = attrlist()

    init(device: dev_t, control: ScanControl, now: Date) {
        self.device = device
        self.control = control
        let seconds = Int(now.timeIntervalSince1970)
        since7 = seconds - 7 * 86_400
        since30 = seconds - 30 * 86_400
        latest = seconds + 86_400
        buffer = .allocate(byteCount: bufferSize, alignment: 8)
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnFileID | cmnAddedTime
        request.fileattr = fileLinkCount | fileAllocSize | fileDataLength
    }

    deinit { buffer.deallocate() }

    func walk(fd: Int32, node: Int) throws {
        try control.checkpoint(enteringDirectory: true)
        var subdirs: [String] = []
        var alloc: Int64 = 0, logical: Int64 = 0, files: Int64 = 0
        var added7: Int64 = 0, added30: Int64 = 0
        var batches = 0

        // The buffer is shared with recursive calls, so each directory is read completely first.
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            defer { batches += 1 }
            if batches > 0 { try control.checkpoint(enteringDirectory: false) } // huge directories
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
                var added: Int?
                if returned.commonattr & cmnAddedTime != 0 {
                    added = field.loadUnaligned(as: timespec.self).tv_sec
                    field += MemoryLayout<timespec>.size
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
                    noteHardLink(inode: inode, node: node, alloc: fileAlloc, logical: fileLogical, added: added)
                } else {
                    alloc += fileAlloc
                    logical += fileLogical
                    files += 1
                    let recent = recency(of: added, bytes: fileAlloc)
                    added7 += recent.in7
                    added30 += recent.in30
                }
            }
        }
        nodes[node].ownAlloc = alloc
        nodes[node].ownLogical = logical
        nodes[node].ownFiles = files
        nodes[node].ownAdded7 = added7
        nodes[node].ownAdded30 = added30

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
            try walk(fd: child, node: nodes.count - 1)
        }
    }

    /// The file's bytes if its date added falls into the 7-day and the 30-day window.
    private func recency(of added: Int?, bytes: Int64) -> (in7: Int64, in30: Int64) {
        guard let added, added > 0, added <= latest else {
            undatedFiles += 1
            undatedBytes += bytes
            return (0, 0)
        }
        return (added >= since7 ? bytes : 0, added >= since30 ? bytes : 0)
    }

    private func noteHardLink(inode: UInt64, node: Int, alloc: Int64, logical: Int64, added: Int?) {
        if let seen = hardLinks[inode], path(of: seen.node) <= path(of: node) { return }
        hardLinks[inode] = (node, alloc, logical, added)
    }

    func attributeHardLinks() {
        for link in hardLinks.values {
            nodes[link.node].ownAlloc += link.alloc
            nodes[link.node].ownLogical += link.logical
            nodes[link.node].ownFiles += 1
            let recent = recency(of: link.added, bytes: link.alloc)
            nodes[link.node].ownAdded7 += recent.in7
            nodes[link.node].ownAdded30 += recent.in30
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
