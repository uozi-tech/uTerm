import Foundation

/// 文件组：`sftp-ls` / `sftp-stat` / `sftp-cat` / `sftp-get` /
/// `sftp-put` / `sftp-mkdir` / `sftp-rm` / `sftp-rmdir` / `sftp-mv` / `sftp-chmod`。
///
/// 硬约束：
/// - **本地文件 I/O 由 CLI 做**。uTerm 是沙盒 app，写不了任意本地路径；socket 上
///   只传 base64（`sftp-put`）或文本 / base64（`sftp-cat` / `sftp-get`）。
/// - 上限：`cat` 1 MiB（`maxCatBytes`），`get` / `put` 8 MiB（`maxFileBytes`），
///   超限一律 `file_too_large`，不要先整个读进内存再判 —— 用
///   `SFTPProviding.download(remotePath:maximumBytes:)` 的有界入口，`get` 更是
///   **先 stat 再决定**，绝不先拉后拒。
/// - 删除类动作在技能文档层面要求先问用户。
/// - `sftpOnly` 主机**允许**全部文件动作（`requiresExecCapableHost` 对本组恒 false）。
/// - 路径不做本地化 / 展开，原样传给远端；只有 `ls` 缺省路径时用 `realPath(".")`。
extension ControlHandler {

    func handleSFTP(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let profile = try resolveHost(try Self.requiredHostNeedle(request))
        try requireExecCapable(profile, action: request.action)

        // 建连失败要把 fingerprint 一并回给 CLI（`ControlFailure` 带不了 hostKey），
        // 所以这一段走「直接返回响应」而不是抛。
        let sftp: any SFTPProviding
        do {
            sftp = try await sftpSession(for: profile, deps)
        } catch {
            return connectFailureResponse(error, id: request.id, profile: profile)
        }

        do {
            return try await perform(request, on: sftp)
        } catch let failure as ControlFailure {
            throw failure
        } catch {
            throw ControlFailure(
                code: ControlFilePayloadBuilder.errorCode(for: error),
                message: Self.sftpMessage(request: request, error: error)
            )
        }
    }

    // MARK: - 十个动作

    private func perform(
        _ request: ControlRequest,
        on sftp: any SFTPProviding
    ) async throws -> ControlResponse {
        switch request.action {

        case .sftpLs:
            // 缺省路径走远端的 `realPath(".")`（登录目录），显式空串是请求错误。
            let path: String
            if let requested = try Self.optionalPath(request.path) {
                path = requested
            } else {
                path = try await sftp.realPath(".")
            }
            let entries = try await sftp.list(path: path)
            return .success(
                id: request.id,
                message: "\(path)：\(entries.count) 项",
                entries: ControlFilePayloadBuilder.entries(entries)
            )

        case .sftpStat:
            let path = try Self.requiredPath(request.path)
            let stat = try await sftp.stat(path)
            return .success(
                id: request.id,
                message: path,
                stat: ControlFilePayloadBuilder.stat(path: path, stat)
            )

        case .sftpCat:
            let path = try Self.requiredPath(request.path)
            let limit = Self.readLimit(request.maxBytes, cap: ControlProtocol.maxCatBytes)
            return try await readFile(request, path: path, limit: limit, on: sftp)

        case .sftpGet:
            let path = try Self.requiredPath(request.path)
            return try await readFile(
                request, path: path, limit: ControlProtocol.maxFileBytes, on: sftp)

        case .sftpPut:
            let path = try Self.requiredPath(request.path)
            guard let encoded = request.contentBase64 else {
                throw ControlFailure(code: .invalid_request, message: "sftp-put 需要 contentBase64")
            }
            guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
                throw ControlFailure(code: .invalid_request, message: "contentBase64 不是合法的 base64")
            }
            guard data.count <= ControlProtocol.maxFileBytes else {
                throw ControlFailure(
                    code: .file_too_large,
                    message: "内容 \(data.count) 字节，超过上限 \(ControlProtocol.maxFileBytes) 字节"
                )
            }
            try await sftp.upload(data: data, toRemotePath: path)
            return .success(id: request.id, message: "已写入 \(path)（\(data.count) 字节）")

        case .sftpMkdir:
            let path = try Self.requiredPath(request.path)
            try await sftp.createDirectory(path)
            return .success(id: request.id, message: "已创建目录 \(path)")

        case .sftpRm:
            let path = try Self.requiredPath(request.path)
            try await sftp.removeFile(path)
            return .success(id: request.id, message: "已删除 \(path)")

        case .sftpRmdir:
            let path = try Self.requiredPath(request.path)
            try await sftp.removeDirectory(path)
            return .success(id: request.id, message: "已删除目录 \(path)")

        case .sftpMv:
            let path = try Self.requiredPath(request.path)
            guard let newPath = try Self.optionalPath(request.newPath) else {
                throw ControlFailure(code: .invalid_request, message: "sftp-mv 需要 newPath")
            }
            try await sftp.rename(path, to: newPath)
            return .success(id: request.id, message: "已重命名 \(path) → \(newPath)")

        case .sftpChmod:
            let path = try Self.requiredPath(request.path)
            guard let mode = ControlFileMode.parse(request.mode) else {
                throw ControlFailure(
                    code: .invalid_request,
                    message: "mode 无法解析：期望八进制（如 644 / 0755）或十进制整数"
                )
            }
            try await sftp.setPermissions(path: path, mode: mode)
            return .success(
                id: request.id,
                message: "已设置权限 \(String(mode, radix: 8)) → \(path)"
            )

        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于文件组"
            )
        }
    }

    /// `cat` / `get` 共用：**先 stat 再决定**，超限直接拒（绝不先拉后拒），
    /// 然后走有界下载。`declaredSize` 交给载荷构造器判 `truncated`。
    private func readFile(
        _ request: ControlRequest,
        path: String,
        limit: Int,
        on sftp: any SFTPProviding
    ) async throws -> ControlResponse {
        let declaredSize: Int64?
        do {
            declaredSize = try await sftp.stat(path).size
        } catch {
            // stat 失败通常就是最终答案（不存在 / 无权限 / 是目录），原样上抛。
            throw ControlFailure(
                code: ControlFilePayloadBuilder.errorCode(for: error),
                message: "\(path)：\(FriendlyError.describe(error))"
            )
        }
        if let declaredSize, declaredSize > Int64(limit) {
            throw ControlFailure(
                code: .file_too_large,
                message: "\(path) 有 \(declaredSize) 字节，超过本次上限 \(limit) 字节"
            )
        }
        let data = try await sftp.download(remotePath: path, maximumBytes: limit)
        return .success(
            id: request.id,
            message: "\(path)（\(data.count) 字节）",
            file: ControlFilePayloadBuilder.payload(
                path: path, data: data, declaredSize: declaredSize)
        )
    }

    // MARK: - 连接

    private func sftpSession(
        for profile: ServerProfile,
        _ deps: Dependencies
    ) async throws -> any SFTPProviding {
        let spec = try HostConnectionSpec.resolve(
            profile: profile, container: deps.modelContainer)
        return try await deps.pool.sftp(for: spec)
    }

    // MARK: - 参数

    private static func requiredHostNeedle(_ request: ControlRequest) throws(ControlFailure) -> String {
        let needle = (request.host ?? "").trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 需要 --host"
            )
        }
        return needle
    }

    /// 路径原样传给远端（不展开 `~`、不做本地化）；给了空串是请求错误。
    private static func optionalPath(_ raw: String?) throws(ControlFailure) -> String? {
        guard let raw else { return nil }
        guard !raw.isEmpty else {
            throw ControlFailure(code: .invalid_request, message: "路径不能为空")
        }
        return raw
    }

    private static func requiredPath(_ raw: String?) throws(ControlFailure) -> String {
        guard let path = try optionalPath(raw) else {
            throw ControlFailure(code: .invalid_request, message: "缺少 --path")
        }
        return path
    }

    /// `cat` 的读取上限：客户端可以调小，但封顶在协议常量上。
    private static func readLimit(_ requested: Int?, cap: Int) -> Int {
        guard let requested, requested > 0 else { return cap }
        return min(requested, cap)
    }

    // MARK: - 错误文案

    private static func sftpMessage(request: ControlRequest, error: Error) -> String {
        let where_ = request.path.map { "\($0)：" } ?? ""
        return "\(where_)\(FriendlyError.describe(error))"
    }
}
