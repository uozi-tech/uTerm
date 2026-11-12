import CryptoKit
import Darwin
import Foundation

/// 远控文件服务在被控 Mac 上的执行体。跑在不带沙盒的辅助进程里（主程序是沙盒 app，读不到主目录）；
/// 主程序里也编了一份，只给测试用。
///
/// 全部是同步调用、无状态：一条请求进来，做完，回一条应答。调用方负责放到后台线程上。
nonisolated enum RemoteFileService {
    /// 处理一条打包好的请求，回打包好的应答。阻塞调用线程。
    static func handle(_ payload: Data) -> Data {
        let request: RemoteFileRequest
        let body: Data
        do {
            (request, body) = try RemoteFileCodec.unpackRequest(payload)
        } catch {
            let id = RemoteFileCodec.requestID(of: payload) ?? UUID()
            let failure = (error as? RemoteFileError) ?? RemoteFileError(.invalid, error.localizedDescription)
            return RemoteFileCodec.packReply(.failure(id, failure), compress: false)
        }
        var reply = RemoteFileReply(id: request.id)
        var output = Data()
        do {
            try perform(request, body: body, reply: &reply, output: &output)
        } catch let error as RemoteFileError {
            reply = .failure(request.id, error)
            output = Data()
        } catch {
            reply = .failure(request.id, RemoteFileError(.failed, error.localizedDescription))
            output = Data()
        }
        return RemoteFileCodec.packReply(reply, body: output, compress: request.acceptsCompression == true)
    }

    private static func perform(_ request: RemoteFileRequest, body: Data, reply: inout RemoteFileReply,
                                output: inout Data) throws {
        switch request.op {
        case .realpath:
            reply.path = try realPath(resolve(request.path ?? "~"))
        case .list:
            let path = try resolve(request.path)
            reply.path = path
            reply.entries = try list(path)
        case .stat:
            let path = try resolve(request.path)
            reply.entry = try entry(at: path, follow: !request.has(RemoteFileOption.noFollow))
        case .read:
            try read(request, reply: &reply, output: &output)
        case .write:
            try write(request, body: body, reply: &reply)
        case .mkdir:
            try makeDirectory(resolve(request.path), parents: request.has(RemoteFileOption.parents), mode: request.mode)
        case .remove:
            try remove(resolve(request.path), recursive: request.has(RemoteFileOption.recursive))
        case .rmdir:
            let path = try resolve(request.path)
            guard rmdir(path) == 0 else { throw posixError(path) }
        case .rename:
            try rename(resolve(request.path), to: resolve(request.newPath), replace: request.has(RemoteFileOption.replace))
        case .chmod:
            try changeMode(request)
        case .createFile:
            let path = try resolve(request.path)
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(request.mode ?? 0o644))
            guard fd >= 0 else { throw posixError(path) }
            close(fd)
        case .readText:
            try readText(request, reply: &reply, output: &output)
        case .grep:
            try grep(request, reply: &reply)
        case .find:
            try find(request, reply: &reply)
        case .tree:
            try tree(request, reply: &reply, output: &output)
        case .hash:
            let path = try resolve(request.path)
            reply.sha256 = try sha256(of: path)
            reply.size = try fileSize(path)
        case .du:
            try diskUsage(request, reply: &reply)
        case .df:
            try diskFree(resolve(request.path ?? "~"), reply: &reply)
        case .copy:
            try copy(resolve(request.path), to: resolve(request.newPath), replace: request.has(RemoteFileOption.replace))
        case .trash:
            reply.path = try trash(resolve(request.path))
        case .symlink:
            try makeSymlink(at: resolve(request.path), target: request.newPath, replace: request.has(RemoteFileOption.replace))
        case .readlink:
            let path = try resolve(request.path)
            guard let target = linkTarget(path) else { throw posixError(path) }
            reply.path = target
        case .touch:
            try touch(resolve(request.path), seconds: request.seconds)
        case .xattr:
            try extendedAttribute(request, body: body, reply: &reply, output: &output)
        case .edit:
            try edit(request, reply: &reply)
        case .patch:
            try patch(request, body: body, reply: &reply, output: &output)
        case .waitChange:
            try waitChange(request, reply: &reply)
        case .exec:
            try exec(request, reply: &reply, output: &output)
        }
    }

    // MARK: - 路径与错误

    /// `~`、相对主目录的路径都解析成绝对路径。不解析符号链接。
    static func resolve(_ raw: String?) throws -> String {
        guard let raw, !raw.isEmpty else { throw RemoteFileError(.invalid, "缺少路径") }
        guard !raw.utf8.contains(0) else { throw RemoteFileError(.invalid, "路径里有空字符") }
        let home = NSHomeDirectory()
        var path = raw
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = home + "/" + path
        }
        return (path as NSString).standardizingPath
    }

    static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw posixError(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func posixError(_ path: String, _ code: Int32 = errno) -> RemoteFileError {
        let reason = String(cString: strerror(code))
        switch code {
        case ENOENT: return RemoteFileError(.notFound, "\(path)：不存在")
        case EACCES: return RemoteFileError(.permissionDenied, "\(path)：没有权限")
        case EPERM:
            return RemoteFileError(.permissionDenied,
                                   "\(path)：系统不允许（\(reason)）。文稿、桌面、下载这些目录受隐私保护，"
                                   + "要在那台 Mac 的「系统设置 › 隐私与安全性 › 文件与文件夹」里给 uTerm 授权")
        case EEXIST: return RemoteFileError(.exists, "\(path)：已经存在")
        case EISDIR: return RemoteFileError(.isDirectory, "\(path)：是目录")
        case ENOTDIR: return RemoteFileError(.notDirectory, "\(path)：路径里有一段不是目录")
        case ENOTEMPTY: return RemoteFileError(.notEmpty, "\(path)：目录不是空的")
        default: return RemoteFileError(.failed, "\(path)：\(reason)")
        }
    }

    /// Foundation 抛的错（`FileManager`）翻成同一套错误码。
    static func foundationError(_ path: String, _ error: Error) -> RemoteFileError {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return posixError(path, Int32(underlying.code))
        }
        if nsError.domain == NSPOSIXErrorDomain { return posixError(path, Int32(nsError.code)) }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return posixError(path, ENOENT)
            case NSFileWriteFileExistsError: return posixError(path, EEXIST)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return posixError(path, EACCES)
            default: break
            }
        }
        return RemoteFileError(.failed, "\(path)：\(error.localizedDescription)")
    }

    // MARK: - 列目录、属性

    static func directoryNames(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw posixError(path) }
        defer { closedir(directory) }
        var names: [String] = []
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    static func list(_ path: String) throws -> [RemoteFileEntry] {
        var names = OwnerNames()
        // 按名字排（Finder 那种：不分大小写、数字按大小），不然是文件系统里的原始顺序，每次看着都不一样。
        let sorted = try directoryNames(path).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return sorted.compactMap { name in
            var info = Darwin.stat()
            guard lstat(path + "/" + name, &info) == 0 else { return nil }
            var item = entry(name: name, info, names: &names)
            if info.st_mode & S_IFMT == S_IFLNK { item.linkTarget = linkTarget(path + "/" + name) }
            return item
        }
    }

    static func entry(at path: String, follow: Bool) throws -> RemoteFileEntry {
        var info = Darwin.stat()
        var link = Darwin.stat()
        guard lstat(path, &link) == 0 else { throw posixError(path) }
        let isLink = link.st_mode & S_IFMT == S_IFLNK
        if follow, isLink {
            // 悬空链接：退回链接本身。
            if stat(path, &info) != 0 { info = link }
        } else {
            info = link
        }
        var names = OwnerNames()
        var item = entry(name: (path as NSString).lastPathComponent, info, names: &names)
        item.path = path
        if isLink { item.linkTarget = linkTarget(path) }
        return item
    }

    static func entry(name: String, _ info: Darwin.stat, names: inout OwnerNames) -> RemoteFileEntry {
        RemoteFileEntry(name: name, path: nil, isDirectory: info.st_mode & S_IFMT == S_IFDIR, size: Int64(info.st_size),
                        mtime: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                        mode: UInt32(info.st_mode), uid: info.st_uid, gid: info.st_gid,
                        owner: names.user(info.st_uid), group: names.group(info.st_gid), linkTarget: nil, sha256: nil)
    }

    /// 一次列目录里用户名 / 组名只查一遍。
    nonisolated struct OwnerNames {
        private var users: [uid_t: String?] = [:]
        private var groups: [gid_t: String?] = [:]

        mutating func user(_ id: uid_t) -> String? {
            if let known = users[id] { return known }
            let name = getpwuid(id).flatMap { $0.pointee.pw_name }.map { String(cString: $0) }
            users[id] = name
            return name
        }

        mutating func group(_ id: gid_t) -> String? {
            if let known = groups[id] { return known }
            let name = getgrgid(id).flatMap { $0.pointee.gr_name }.map { String(cString: $0) }
            groups[id] = name
            return name
        }
    }

    static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, Int(PATH_MAX))
        guard count >= 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    static func fileSize(_ path: String) throws -> Int64 {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { throw posixError(path) }
        return Int64(info.st_size)
    }

    // MARK: - 读写

    private static func read(_ request: RemoteFileRequest, reply: inout RemoteFileReply, output: inout Data) throws {
        let path = try resolve(request.path)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw posixError(path) }
        guard info.st_mode & S_IFMT != S_IFDIR else { throw posixError(path, EISDIR) }
        let offset = request.offset ?? 0
        let length = min(max(0, request.length ?? RemoteFileLimits.transferChunkBytes), RemoteFileLimits.maxChunkBytes)
        output = try readBytes(fd, offset: offset, length: length, path: path)
        reply.size = Int64(info.st_size)
        reply.eof = offset + UInt64(output.count) >= UInt64(info.st_size)
    }

    static func readBytes(_ fd: Int32, offset: UInt64, length: Int, path: String) throws -> Data {
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        var done = 0
        while done < length {
            let got = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + done, length - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw posixError(path)
            }
            if got == 0 { break }
            done += got
        }
        data.removeSubrange(done..<length)
        return data
    }

    private static func write(_ request: RemoteFileRequest, body: Data, reply: inout RemoteFileReply) throws {
        let path = try resolve(request.path)
        guard body.count <= RemoteFileLimits.maxChunkBytes else {
            throw RemoteFileError(.tooLarge, "一次最多写 \(RemoteFileLimits.maxChunkBytes) 字节，分片再发")
        }
        if let expected = request.ifMatch { try requireMatch(path, expected) }
        if request.has(RemoteFileOption.atomic) {
            if request.writeMode == "create", access(path, F_OK) == 0 { throw posixError(path, EEXIST) }
            try writeAtomically(body, to: path, mode: request.mode)
            reply.sha256 = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            reply.size = Int64(body.count)
            return
        }
        var flags = O_WRONLY | O_CREAT | O_CLOEXEC
        switch request.writeMode ?? "write" {
        case "create": flags |= O_EXCL
        case "overwrite": flags |= O_TRUNC
        case "write": break
        default: throw RemoteFileError(.invalid, "writeMode 只能是 create / overwrite / write")
        }
        let fd = open(path, flags, mode_t(request.mode ?? 0o644))
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        try writeBytes(fd, body, offset: request.offset ?? 0, path: path)
        // 续传到最后一片时把多出来的尾巴切掉（上一次传的是更长的旧版本）。
        if let total = request.length, total >= 0 { ftruncate(fd, off_t(total)) }
    }

    static func writeBytes(_ fd: Int32, _ data: Data, offset: UInt64, path: String) throws {
        var done = 0
        while done < data.count {
            let wrote = data.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress! + done, data.count - done, off_t(offset) + off_t(done))
            }
            if wrote < 0 {
                if errno == EINTR { continue }
                throw posixError(path)
            }
            done += wrote
        }
    }

    /// 写到同目录的临时文件再改名。原文件的权限保留。
    static func writeAtomically(_ data: Data, to path: String, mode: UInt32?) throws {
        var existing = Darwin.stat()
        let exists = stat(path, &existing) == 0
        if exists, existing.st_mode & S_IFMT == S_IFDIR { throw posixError(path, EISDIR) }
        let temporary = path + ".uterm-\(UUID().uuidString.prefix(8))"
        let permissions = mode ?? (exists ? UInt32(existing.st_mode & 0o7777) : 0o644)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(permissions))
        guard fd >= 0 else { throw posixError(path) }
        do {
            try writeBytes(fd, data, offset: 0, path: path)
            fchmod(fd, mode_t(permissions))
            close(fd)
        } catch {
            close(fd)
            unlink(temporary)
            throw error
        }
        guard Darwin.rename(temporary, path) == 0 else {
            let failure = posixError(path)
            unlink(temporary)
            throw failure
        }
    }

    static func requireMatch(_ path: String, _ expected: String) throws {
        let actual = try sha256(of: path)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw RemoteFileError(.conflict, "\(path)：文件已经变了（现在的 sha256 是 \(actual)），重新读一遍再改")
        }
    }

    static func sha256(of path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw posixError(path) }
        guard info.st_mode & S_IFMT != S_IFDIR else { throw posixError(path, EISDIR) }
        var hasher = SHA256()
        var offset: UInt64 = 0
        while true {
            let chunk = try readBytes(fd, offset: offset, length: 1024 * 1024, path: path)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            offset += UInt64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 目录、改名、删除、权限

    private static func makeDirectory(_ path: String, parents: Bool, mode: UInt32?) throws {
        if parents {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                        attributes: mode.map { [.posixPermissions: Int($0 & 0o7777)] })
            } catch {
                throw foundationError(path, error)
            }
            return
        }
        guard mkdir(path, mode_t(mode ?? 0o755)) == 0 else { throw posixError(path) }
    }

    private static func remove(_ path: String, recursive: Bool) throws {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw posixError(path) }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard recursive else { throw posixError(path, EISDIR) }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                throw foundationError(path, error)
            }
            return
        }
        guard unlink(path) == 0 else { throw posixError(path) }
    }

    private static func rename(_ path: String, to newPath: String, replace: Bool) throws {
        if replace {
            guard Darwin.rename(path, newPath) == 0 else { throw posixError(path) }
            return
        }
        guard renamex_np(path, newPath, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? posixError(newPath, EEXIST) : posixError(path)
        }
    }

    private static func changeMode(_ request: RemoteFileRequest) throws {
        let path = try resolve(request.path)
        guard let mode = request.mode else { throw RemoteFileError(.invalid, "缺少 mode") }
        let bits = mode_t(mode & 0o7777)
        guard chmod(path, bits) == 0 else { throw posixError(path) }
        guard request.has(RemoteFileOption.recursive) else { return }
        var walker = Walker(root: path, includeHidden: true, respectIgnore: false, maxDepth: nil)
        try walker.run { item in
            // 符号链接不改：chmod 会跟过去改到树外面的东西。
            if item.info.st_mode & S_IFMT != S_IFLNK { chmod(item.absolutePath, bits) }
            return .next
        }
    }

    private static func copy(_ path: String, to newPath: String, replace: Bool) throws {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw posixError(path) }
        if access(newPath, F_OK) == 0 {
            guard replace else { throw posixError(newPath, EEXIST) }
            do {
                try FileManager.default.removeItem(atPath: newPath)
            } catch {
                throw foundationError(newPath, error)
            }
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
        guard copyfile(path, newPath, nil, flags) == 0 else { throw posixError(path) }
    }

    private static func trash(_ path: String) throws -> String {
        guard access(path, F_OK) == 0 else { throw posixError(path) }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch {
            throw foundationError(path, error)
        }
        return resulting?.path ?? ""
    }

    private static func makeSymlink(at path: String, target: String?, replace: Bool) throws {
        guard let target, !target.isEmpty else { throw RemoteFileError(.invalid, "缺少链接的指向") }
        if replace {
            var info = Darwin.stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { unlink(path) }
        }
        guard symlink(target, path) == 0 else { throw posixError(path) }
    }

    private static func touch(_ path: String, seconds: Double?) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NONBLOCK, 0o644)
        if fd >= 0 {
            close(fd)
        } else if errno != EISDIR {
            throw posixError(path)
        }
        guard let seconds else {
            guard utimes(path, nil) == 0 else { throw posixError(path) }
            return
        }
        let stamp = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        var times = [stamp, stamp]
        guard utimes(path, &times) == 0 else { throw posixError(path) }
    }

    private static func diskFree(_ path: String, reply: inout RemoteFileReply) throws {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw posixError(path) }
        reply.path = path
        reply.bytes = Int64(info.f_bavail) * Int64(info.f_bsize)
        reply.totalBytes = Int64(info.f_blocks) * Int64(info.f_bsize)
    }

    // MARK: - 扩展属性

    private static func extendedAttribute(_ request: RemoteFileRequest, body: Data, reply: inout RemoteFileReply,
                                          output: inout Data) throws {
        let path = try resolve(request.path)
        switch request.action ?? "list" {
        case "list":
            let size = listxattr(path, nil, 0, 0)
            guard size >= 0 else { throw posixError(path) }
            guard size > 0 else {
                reply.names = []
                return
            }
            var buffer = [CChar](repeating: 0, count: size)
            let got = listxattr(path, &buffer, size, 0)
            guard got >= 0 else { throw posixError(path) }
            reply.names = buffer.prefix(got).split(separator: 0).map { String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) }
        case "get":
            let name = try attributeName(request)
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size >= 0 else { throw attributeError(path, name) }
            var data = Data(count: size)
            let got = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            guard got >= 0 else { throw attributeError(path, name) }
            output = data.prefix(got)
        case "set":
            let name = try attributeName(request)
            let result = body.withUnsafeBytes { setxattr(path, name, $0.baseAddress, body.count, 0, 0) }
            guard result == 0 else { throw attributeError(path, name) }
        case "remove":
            let name = try attributeName(request)
            guard removexattr(path, name, 0) == 0 else { throw attributeError(path, name) }
        default:
            throw RemoteFileError(.invalid, "xattr 的 action 只能是 list / get / set / remove")
        }
    }

    private static func attributeName(_ request: RemoteFileRequest) throws -> String {
        guard let name = request.name, !name.isEmpty else { throw RemoteFileError(.invalid, "缺少属性名") }
        return name
    }

    private static func attributeError(_ path: String, _ name: String) -> RemoteFileError {
        errno == ENOATTR ? RemoteFileError(.notFound, "\(path)：没有扩展属性 \(name)") : posixError(path)
    }
}
