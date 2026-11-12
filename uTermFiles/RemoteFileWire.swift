import Foundation

/// 远控链路上的文件服务：线上格式。主控端（手机、另一台 Mac）、被控 Mac 的主程序和不带沙盒的辅助进程
/// 三处共用这一份，主程序只转发、不解释。
///
/// 一条请求或应答 = `[u32 头长度（大端）][JSON 头][正文]`。头是下面的 `RemoteFileRequest` / `RemoteFileReply`，
/// 正文是文件字节（读回来的、要写下去的、命令的输出、补丁）。正文可以压缩，压没压写在头的 `bodyCompression` 里。
///
/// 服务是无状态的：每条请求自己带路径和偏移，被控端不留打开的文件。断线重连后接着发下一条就是续传。
nonisolated enum RemoteFileOp: String, Codable, Sendable, CaseIterable {
    // 基本操作
    case realpath, list, stat, read, write, mkdir, remove, rmdir, rename, chmod, createFile
    // 读代码
    case readText, grep, find, tree, hash, du, df
    // 写入与杂项
    case copy, trash, symlink, readlink, touch, xattr, edit, patch
    // 等变化、跑命令
    case waitChange, exec
    /// 这条链路上能访问哪些目录（`RemoteFileReply.roots`；没有限定时为 nil）。
    case roots

    /// 会改被控端的东西。主控端的命令行据此过「允许执行命令与写入」那道闸。
    var isMutation: Bool {
        switch self {
        case .realpath, .list, .stat, .read, .readText, .grep, .find, .tree, .hash, .du, .df, .readlink, .waitChange,
             .roots:
            return false
        case .write, .mkdir, .remove, .rmdir, .rename, .chmod, .createFile, .copy, .trash, .symlink, .touch, .xattr,
             .edit, .patch, .exec:
            return true
        }
    }

    /// 可能要等很久的操作，被控端给它们单独的名额，不占普通读写的。
    var isLongRunning: Bool { self == .waitChange || self == .exec }
}

/// 请求里的开关（`RemoteFileRequest.options`）。
nonisolated enum RemoteFileOption {
    static let ignoreCase = "ignoreCase"
    /// `grep`：`pattern` 按字面量匹配，不当正则。
    static let fixed = "fixed"
    /// 包括点文件。
    static let hidden = "hidden"
    /// 不跳过 `.gitignore` 忽略的文件和常见的构建目录。
    static let noIgnore = "noIgnore"
    /// `mkdir`：连同中间目录。
    static let parents = "parents"
    /// `remove`：目录连同内容；`chmod`：整棵树。
    static let recursive = "recursive"
    /// `rename` / `copy` / `symlink`：目标已存在就替换。
    static let replace = "replace"
    /// `edit`：替换全部出现的地方。
    static let all = "all"
    /// `patch`：只检查能不能打上，不改文件。
    static let dryRun = "dryRun"
    /// `write`：先写临时文件再改名，读的人看不到半截内容。
    static let atomic = "atomic"
    /// `find`：只要文件 / 只要目录。
    static let files = "files"
    static let directories = "directories"
    /// `find`：文件带 sha256。
    static let hash = "hash"
    /// `stat`：符号链接不跟过去。
    static let noFollow = "noFollow"
    /// `grep` / `find`：不调 git 列文件（限定了目录的请求一律带上：仓库里的 git 配置能让 git 去跑别的程序）。
    static let noGit = "noGit"
}

nonisolated struct RemoteFileRequest: Codable, Sendable, Equatable {
    var id: UUID
    var op: RemoteFileOp
    /// 绝对路径、`~` 开头或相对主目录的路径。
    var path: String?
    /// `rename` / `copy` 的目标；`symlink` 的指向。
    var newPath: String?
    var offset: UInt64?
    var length: Int?
    /// 权限位（`chmod`、新建文件）。
    var mode: UInt32?
    /// `write`：`create`（已存在就失败）/ `overwrite`（截断）/ `write`（不截断，按偏移写）。
    var writeMode: String?
    /// `grep` 的正则或字面量；`find` 的文件名通配符。
    var pattern: String?
    /// 只看文件名匹配这些通配符的 / 排除匹配这些的。
    var include: [String]?
    var exclude: [String]?
    /// 结果条数上限。
    var limit: Int?
    var depth: Int?
    var options: [String]?
    /// `readText`：从 1 数的行号闭区间；`tailLines` 是最后多少行。
    var startLine: Int?
    var endLine: Int?
    var tailLines: Int?
    /// `grep`：每处匹配带前后多少行。
    var context: Int?
    /// 只有文件现在的 sha256 等于它才动手（`write` / `edit` / `patch`），否则回 `conflict`。
    var ifMatch: String?
    var oldText: String?
    var newText: String?
    /// `xattr`：`list` / `get` / `set` / `remove`。
    var action: String?
    /// `xattr` 的属性名。
    var name: String?
    /// `waitChange` 最多等多少秒；`exec` 连续多少秒没有输出算卡住；`find` 只要最近这么多秒内改过的；
    /// `touch` 要设的修改时间（距 1970 的秒数）。
    var seconds: Double?
    /// `exec` 的总时长上限。
    var maxDuration: Double?
    var command: String?
    /// `exec` 的输出、`readText` 的正文最多多少字节。
    var maxBytes: Int?
    /// `patch`：去掉路径前几级（`patch -p`）。
    var strip: Int?
    /// 发请求的一方能解压缩的应答正文。
    var acceptsCompression: Bool?
    /// 这条请求的正文怎么压的；nil = 没压。
    var bodyCompression: String?

    init(op: RemoteFileOp, path: String? = nil) {
        self.id = UUID()
        self.op = op
        self.path = path
    }

    func has(_ option: String) -> Bool { options?.contains(option) ?? false }
}

nonisolated struct RemoteFileError: Codable, Sendable, Equatable, Error {
    enum Code: String, Codable, Sendable {
        case notFound, permissionDenied, exists, isDirectory, notDirectory, notEmpty, tooLarge
        /// 请求本身不对（缺字段、参数不合法）。
        case invalid
        /// `ifMatch` 对不上：文件在你读过之后被改了。
        case conflict
        /// `edit`：要换的文字没找到，或不止一处又没说全部替换。
        case noMatch, ambiguous
        /// 被控端没打开这个功能。
        case disabled
        /// 对端版本太旧。
        case unsupported
        case timeout
        /// 连接断了、辅助进程不在。重试可能就好。
        case unreachable
        case failed
    }

    var code: Code
    var message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension RemoteFileError: LocalizedError {
    var errorDescription: String? { message }
}

/// 共享出去的一个目录。
nonisolated struct RemoteFileRoot: Codable, Sendable, Equatable, Hashable {
    /// 绝对路径。
    var path: String
    /// 允许改里面的东西。false = 只读。
    var writable: Bool

    init(path: String, writable: Bool) {
        self.path = path
        self.writable = writable
    }
}

/// 一条请求能碰的范围：只有这些目录里的东西。由提供文件的这一端自己定，不从链路上收。
nonisolated struct RemoteFileScope: Codable, Sendable, Equatable {
    var roots: [RemoteFileRoot]

    init(roots: [RemoteFileRoot]) {
        self.roots = roots
    }
}

nonisolated struct RemoteFileEntry: Codable, Sendable, Equatable {
    var name: String
    /// `find`：相对搜索根的路径；`stat`：解析后的绝对路径。
    var path: String?
    var isDirectory: Bool
    var size: Int64
    /// 距 1970 的秒数。
    var mtime: Double
    /// 完整的 POSIX mode，含类型位。
    var mode: UInt32
    var uid: UInt32
    var gid: UInt32
    var owner: String?
    var group: String?
    var linkTarget: String?
    var sha256: String?
}

nonisolated struct RemoteFileMatch: Codable, Sendable, Equatable {
    /// 相对搜索根的路径（搜的是单个文件时就是那个文件）。
    var path: String
    var line: Int
    var text: String
    var before: [String]?
    var after: [String]?
}

nonisolated struct RemoteFileExecResult: Codable, Sendable, Equatable {
    /// 被信号杀掉时为 nil。
    var exitCode: Int32?
    var timedOut: Bool
    /// `idle`（一直没输出）或 `max_duration`（跑太久）。
    var timeoutReason: String?
    /// 超时后进程组确实被终止了。
    var killed: Bool
    /// 输出被截过，只留了最后一段。
    var truncated: Bool
    var durationMs: Int
}

nonisolated struct RemoteFileReply: Codable, Sendable, Equatable {
    var id: UUID
    var error: RemoteFileError?
    /// 解析后的绝对路径（`realpath`、`trash` 之后的新位置、`readlink` 的指向）。
    var path: String?
    var entries: [RemoteFileEntry]?
    var entry: RemoteFileEntry?
    /// `read`：文件现在的总大小。
    var size: Int64?
    var eof: Bool?
    var matches: [RemoteFileMatch]?
    /// 结果被上限或时限截断了。
    var truncated: Bool?
    var sha256: String?
    /// `edit` 换了几处、`tree` 列了几项、`grep` 搜了几个文件。
    var count: Int?
    var totalLines: Int?
    /// `du` 的占用 / `df` 的可用空间。
    var bytes: Int64?
    /// `df` 的总容量。
    var totalBytes: Int64?
    var files: Int?
    var directories: Int?
    /// `xattr list` 的属性名、`waitChange` 里变了的路径。
    var names: [String]?
    /// `waitChange`：等到时限也没有变化。
    var timedOut: Bool?
    var exec: RemoteFileExecResult?
    /// `roots`：能访问的目录。nil = 没有限定（整台 Mac）。
    var roots: [RemoteFileRoot]?
    var bodyCompression: String?

    init(id: UUID) {
        self.id = id
    }

    static func failure(_ id: UUID, _ error: RemoteFileError) -> RemoteFileReply {
        var reply = RemoteFileReply(id: id)
        reply.error = error
        return reply
    }
}

/// 单条请求的上限。链路一帧最多 4 MiB，头和加密开销之外留足余量。
nonisolated enum RemoteFileLimits {
    /// 一次 `read` / `write` 的正文。
    static let maxChunkBytes = 1024 * 1024
    /// 传输时一片多大。
    static let transferChunkBytes = 256 * 1024
    /// 传输时同时在途几片。
    static let transferWindow = 8
    /// `readText` / `edit` 肯处理的文件大小。
    static let maxTextFileBytes = 16 * 1024 * 1024
    /// `grep` 单个文件超过这么大就跳过。
    static let maxGrepFileBytes = 4 * 1024 * 1024
    /// 头的上限。
    static let maxHeaderBytes = 2 * 1024 * 1024
    static let lzfse = "lzfse"
}

/// 打包、拆包、压缩。
nonisolated enum RemoteFileCodec {
    static func encode<Header: Encodable>(_ header: Header, body: Data = Data()) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let head = (try? encoder.encode(header)) ?? Data("{}".utf8)
        var data = Data(capacity: 4 + head.count + body.count)
        let count = UInt32(head.count)
        data.append(contentsOf: [UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                                 UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        data.append(head)
        data.append(body)
        return data
    }

    static func decode<Header: Decodable>(_ type: Header.Type, from data: Data) throws -> (header: Header, body: Data) {
        // 调用方给的可能是切片，下标不从 0 开始。
        let data = Data(data)
        guard data.count >= 4 else { throw RemoteFileError(.invalid, "消息太短") }
        let count = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard count <= RemoteFileLimits.maxHeaderBytes, data.count >= 4 + count else {
            throw RemoteFileError(.invalid, "消息头长度不对")
        }
        let header: Header
        do {
            header = try JSONDecoder().decode(type, from: data.subdata(in: 4..<(4 + count)))
        } catch {
            throw RemoteFileError(.invalid, "消息头解不开：\(error.localizedDescription)")
        }
        return (header, data.subdata(in: (4 + count)..<data.count))
    }

    /// 压了之后小于原来的九成才用压缩的。太小的不值得压。
    static func compress(_ body: Data) -> Data? {
        guard body.count >= 1024, let packed = try? (body as NSData).compressed(using: .lzfse) as Data,
              packed.count * 10 < body.count * 9 else { return nil }
        return packed
    }

    static func decompress(_ body: Data, method: String?) throws -> Data {
        guard let method else { return body }
        guard method == RemoteFileLimits.lzfse else { throw RemoteFileError(.invalid, "不认识的压缩方式 \(method)") }
        guard let plain = try? (body as NSData).decompressed(using: .lzfse) as Data else {
            throw RemoteFileError(.invalid, "正文解压失败")
        }
        return plain
    }

    static func packRequest(_ request: RemoteFileRequest, body: Data = Data(), compress wantsCompression: Bool) -> Data {
        var request = request
        if wantsCompression, let packed = compress(body) {
            request.bodyCompression = RemoteFileLimits.lzfse
            return encode(request, body: packed)
        }
        request.bodyCompression = nil
        return encode(request, body: body)
    }

    static func unpackRequest(_ data: Data) throws -> (request: RemoteFileRequest, body: Data) {
        let (request, body) = try decode(RemoteFileRequest.self, from: data)
        return (request, try decompress(body, method: request.bodyCompression))
    }

    static func packReply(_ reply: RemoteFileReply, body: Data = Data(), compress wantsCompression: Bool) -> Data {
        var reply = reply
        if wantsCompression, let packed = compress(body) {
            reply.bodyCompression = RemoteFileLimits.lzfse
            return encode(reply, body: packed)
        }
        reply.bodyCompression = nil
        return encode(reply, body: body)
    }

    static func unpackReply(_ data: Data) throws -> (reply: RemoteFileReply, body: Data) {
        let (reply, body) = try decode(RemoteFileReply.self, from: data)
        return (reply, try decompress(body, method: reply.bodyCompression))
    }

    /// 只看请求号，不解整条（主程序转发时出错要能回给对的那条请求）。
    static func requestID(of data: Data) -> UUID? {
        struct Head: Decodable { var id: UUID }
        return (try? decode(Head.self, from: data))?.header.id
    }

    /// 只看是什么操作（主程序按它过门禁）。
    static func operation(of data: Data) -> RemoteFileOp? {
        struct Head: Decodable { var op: RemoteFileOp }
        return (try? decode(Head.self, from: data))?.header.op
    }
}
