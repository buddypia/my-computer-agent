import Darwin
import Foundation

/// The mutation boundary owns opening, locking and comparing the file. A file
/// created while approval is pending cannot become an accidental overwrite.
enum GuardedFileWriter {
    final class Destination: @unchecked Sendable {
        let parent: Int32
        let parentPath: String
        let logicalParent: URL
        let name: String
        let device: dev_t
        let inode: ino_t
        var path: String { URL(fileURLWithPath: parentPath).appendingPathComponent(name).path }

        init(_ path: String) throws {
            let url = URL(fileURLWithPath: path)
            logicalParent = url.deletingLastPathComponent()
            parentPath = try GuardedFileWriter.canonicalDirectory(logicalParent.path)
            name = url.lastPathComponent
            let descriptor = try GuardedFileWriter.openDirectory(parentPath)
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { close(descriptor); throw ActionAuthorizationError.staleTarget }
            parent = descriptor; device = info.st_dev; inode = info.st_ino
        }
        deinit { close(parent) }

        func isCurrent() -> Bool {
            guard (try? GuardedFileWriter.canonicalDirectory(logicalParent.path)) == parentPath,
                  let current = try? GuardedFileWriter.openDirectory(parentPath) else { return false }
            defer { close(current) }
            var info = stat()
            return fstat(current, &info) == 0 && info.st_dev == device && info.st_ino == inode
        }
    }

    /// Missing parents are frozen before approval and created through a held ancestor.
    /// A directory inserted while approval is pending is refused, even if it is ordinary.
    struct ParentCreation: Sendable {
        let anchor: Destination
        let components: [String]
        let targetPath: String

        init(_ path: String) throws {
            targetPath = path
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: parent.path) {
                guard parent.path != "/" else { throw ActionAuthorizationError.staleTarget }
                missing.insert(parent.lastPathComponent, at: 0)
                parent.deleteLastPathComponent()
            }
            guard let first = missing.first else { throw ActionAuthorizationError.staleTarget }
            components = missing
            anchor = try Destination(parent.appendingPathComponent(first).path)
        }

        func isCurrent() -> Bool {
            var info = stat()
            return anchor.isCurrent()
                && fstatat(anchor.parent, anchor.name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
        }

        func create() throws -> Destination {
            try Task.checkCancellation()
            guard isCurrent() else { throw ActionAuthorizationError.staleTarget }
            var current = openat(anchor.parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard current >= 0 else { throw ActionAuthorizationError.staleTarget }
            defer { close(current) }
            for component in components {
                try Task.checkCancellation()
                guard mkdirat(current, component, 0o700) == 0 else { throw ActionAuthorizationError.staleTarget }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ActionAuthorizationError.staleTarget }
                close(current); current = next
            }
            let destination = try Destination(targetPath)
            var created = stat()
            guard anchor.isCurrent(), fstat(current, &created) == 0,
                  created.st_dev == destination.device, created.st_ino == destination.inode else {
                throw ActionAuthorizationError.staleTarget
            }
            return destination
        }
    }

    private static func canonicalDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw ActionAuthorizationError.staleTarget }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Walk canonical ancestors without following a symlink inserted after approval.
    private static func openDirectory(_ path: String) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw ActionAuthorizationError.staleTarget }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw ActionAuthorizationError.staleTarget }
            current = next
        }
        return current
    }
    struct Snapshot: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        let contents: Data
    }

    // These tools produce notes/screenshots, not arbitrary-size file edits. Refuse
    // large existing destinations before approval and bound every comparison read.
    static let maxSnapshotBytes = 8 * 1024 * 1024
    private enum SnapshotError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "The existing destination is too large (maximum 8 MiB); save to a new output file instead." }
    }
    private static func boundedContents(_ handle: FileHandle, descriptor: Int32) throws -> Data {
        try Task.checkCancellation()
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ActionAuthorizationError.staleTarget }
        guard info.st_size >= 0, info.st_size <= maxSnapshotBytes else { throw SnapshotError.tooLarge }
        var contents = Data()
        while true {
            try Task.checkCancellation()
            let block = try handle.read(upToCount: min(64 * 1024, maxSnapshotBytes - contents.count + 1)) ?? Data()
            guard contents.count + block.count <= maxSnapshotBytes else { throw SnapshotError.tooLarge }
            if block.isEmpty { break }
            contents.append(block)
        }
        try Task.checkCancellation()
        return contents
    }

    static func snapshot(_ destination: Destination) throws -> Snapshot? {
        try Task.checkCancellation()
        guard destination.isCurrent() else { throw ActionAuthorizationError.staleTarget }
        let descriptor = openat(destination.parent, destination.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ActionAuthorizationError.staleTarget
        }
        return Snapshot(device: info.st_dev, inode: info.st_ino,
                        contents: try boundedContents(handle, descriptor: descriptor))
    }

    static func write(_ contents: Data, to destination: Destination, append: Bool, expected: Snapshot?) throws {
        try Task.checkCancellation()
        guard destination.isCurrent() else { throw ActionAuthorizationError.staleTarget }
        let flags = expected == nil ? O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW : O_RDWR | O_NOFOLLOW | O_NONBLOCK
        let descriptor = openat(destination.parent, destination.name, flags | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST || errno == ENOENT || errno == ELOOP { throw ActionAuthorizationError.staleTarget }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ActionAuthorizationError.staleTarget }
        defer { _ = flock(descriptor, LOCK_UN) }
        if let expected {
            var info = stat(), pathInfo = stat()
            guard fstat(descriptor, &info) == 0, fstatat(destination.parent, destination.name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_dev == expected.device, info.st_ino == expected.inode,
                  pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino,
                  (try boundedContents(handle, descriptor: descriptor)) == expected.contents else {
                throw ActionAuthorizationError.staleTarget
            }
        }
        try Task.checkCancellation()
        if append { try handle.seekToEnd() }
        else { try handle.seek(toOffset: 0) }
        try handle.write(contentsOf: contents)
        if !append { try handle.truncate(atOffset: UInt64(contents.count)) }
        try handle.synchronize()
    }
}
