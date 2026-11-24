import Foundation
import NIOCore
import USSHTestServer
@testable import USSHKit

/// 给进程内 SSH 测试服务端（`USSHTestServer`）用的内存文件表：路径按**原样字节**存，所以能放不是 UTF-8 的名字
/// （APFS 不接受，真实临时目录做不到）。几个测试文件共用。
/// 内存文件表，按路径的**原样字节**存（非 UTF-8 的名字也能放）。服务端的请求与测试都经它读写，故用锁保护。
final class SFTPMemoryFileSystem: SFTPServerFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [SFTPPath: [UInt8]] = [:]
    private var directories: Set<SFTPPath> = ["/home/test"]
    /// 还要短给几次（SFTP 允许服务端少给，客户端必须补发）。
    private var shortReadBudget = 0
    /// 从这个 offset 起一律回空 —— 模拟服务端在文件中途谎报 EOF。
    private var lieAboutEOFFrom: Int?

    func setShortReadBudget(_ count: Int) {
        lock.withLock { shortReadBudget = count }
    }

    func setLieAboutEOF(from offset: Int?) {
        lock.withLock { lieAboutEOFFrom = offset }
    }

    func read(_ path: SFTPPath, at offset: Int, length: Int) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let bytes = files[path], offset < bytes.count else { return [] }
        if let lieAboutEOFFrom, offset >= lieAboutEOFFrom { return [] }
        var end = min(offset + length, bytes.count)
        if shortReadBudget > 0, end - offset > 1 {
            shortReadBudget -= 1
            end = offset + (end - offset) / 2   // 只给一半
        }
        return Array(bytes[offset..<end])
    }

    func write(_ path: SFTPPath, at offset: Int, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        var existing = files[path] ?? []
        let end = offset + bytes.count
        if existing.count < end {
            existing.append(contentsOf: [UInt8](repeating: 0, count: end - existing.count))
        }
        existing.replaceSubrange(offset..<end, with: bytes)
        files[path] = existing
    }

    func size(_ path: String) -> Int? { size(SFTPPath(path)) }
    func size(_ path: SFTPPath) -> Int? { lock.withLock { files[path]?.count } }
    func contents(_ path: String) -> [UInt8]? { contents(SFTPPath(path)) }
    func contents(_ path: SFTPPath) -> [UInt8]? { lock.withLock { files[path] } }
    func put(_ path: String, _ bytes: [UInt8]) { put(SFTPPath(path), bytes) }
    func put(_ path: SFTPPath, _ bytes: [UInt8]) { lock.withLock { files[path] = bytes } }
    func exists(_ path: SFTPPath) -> Bool { lock.withLock { files[path] != nil } }
    func makeDirectory(_ path: SFTPPath) { _ = lock.withLock { directories.insert(path) } }

    // MARK: SFTPServerFileSystem

    func realPath(_ path: SFTPPath) async throws -> SFTPPath {
        path.bytes.first == UInt8(ascii: "/") ? path : SFTPPath("/home/test").appending(path)
    }

    func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes {
        try lock.withLock {
            if let bytes = files[path] {
                return SFTPFileAttributes(size: UInt64(bytes.count), permissions: 0o100644)
            }
            if directories.contains(path) { return SFTPFileAttributes(permissions: 0o040755) }
            throw SFTPServerStatusError.noSuchFile()
        }
    }

    func openFile(_ path: SFTPPath, flags: SFTPOpenFlags,
                  attributes: SFTPFileAttributes) async throws -> any SFTPServerFile {
        try lock.withLock {
            let exists = files[path] != nil
            if flags.contains(.exclusive), exists {
                throw SFTPServerStatusError(.fileAlreadyExists, "File exists")
            }
            if !exists, !flags.contains(.create) { throw SFTPServerStatusError.noSuchFile() }
            if flags.contains(.truncate) || !exists { files[path] = [] }
        }
        return SFTPMemoryFile(path: path, fs: self)
    }

    func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory {
        let prefix = path.bytes.last == UInt8(ascii: "/") ? path.bytes : path.bytes + [UInt8(ascii: "/")]
        let entries: [SFTPDirectoryEntry] = lock.withLock {
            files.compactMap { file, bytes in
                guard file.bytes.starts(with: prefix) else { return nil }
                let name = Array(file.bytes.dropFirst(prefix.count))
                guard !name.isEmpty, !name.contains(UInt8(ascii: "/")) else { return nil }
                return SFTPDirectoryEntry(name: SFTPPath(bytes: name), longname: "",
                                          attributes: SFTPFileAttributes(size: UInt64(bytes.count),
                                                                         permissions: 0o100644))
            } + directories.compactMap { directory in
                guard directory.bytes.starts(with: prefix) else { return nil }
                let name = Array(directory.bytes.dropFirst(prefix.count))
                guard !name.isEmpty, !name.contains(UInt8(ascii: "/")) else { return nil }
                return SFTPDirectoryEntry(name: SFTPPath(bytes: name), longname: "",
                                          attributes: SFTPFileAttributes(permissions: 0o040755))
            }
        }
        guard lock.withLock({ directories.contains(path) || directories.contains(SFTPPath(bytes: prefix.dropLast())) }) else {
            throw SFTPServerStatusError.noSuchFile()
        }
        return SFTPMemoryDirectory(entries: entries)
    }

    func removeFile(_ path: SFTPPath) async throws {
        try lock.withLock {
            guard files.removeValue(forKey: path) != nil else { throw SFTPServerStatusError.noSuchFile() }
        }
    }

    func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws {
        _ = lock.withLock { directories.insert(path) }
    }

    func removeDirectory(_ path: SFTPPath) async throws {
        _ = lock.withLock { directories.remove(path) }
    }

    func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws {
        try lock.withLock {
            guard let bytes = files[oldPath] else { throw SFTPServerStatusError.noSuchFile() }
            if files[newPath] != nil, !replacingExisting { throw SFTPServerStatusError.failure("File exists") }
            files[oldPath] = nil
            files[newPath] = bytes
        }
    }
}

private struct SFTPMemoryFile: SFTPServerFile {
    let path: SFTPPath
    let fs: SFTPMemoryFileSystem

    func read(at offset: UInt64, length: Int) async throws -> ByteBuffer? {
        let bytes = fs.read(path, at: Int(offset), length: length)
        return bytes.isEmpty ? nil : ByteBuffer(bytes: bytes)
    }

    func write(_ data: ByteBuffer, at offset: UInt64) async throws {
        fs.write(path, at: Int(offset), bytes: Array(data.readableBytesView))
    }

    func attributes() async throws -> SFTPFileAttributes {
        SFTPFileAttributes(size: UInt64(fs.size(path) ?? 0))
    }

    func close() async throws {}
}

private final class SFTPMemoryDirectory: SFTPServerDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [SFTPDirectoryEntry]?

    init(entries: [SFTPDirectoryEntry]) { pending = entries }

    func nextBatch() async throws -> [SFTPDirectoryEntry]? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}
