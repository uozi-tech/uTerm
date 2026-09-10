import Foundation

/// 文件组：`sftp-ls` / `sftp-stat` / `sftp-cat` / `sftp-get` /
/// `sftp-put` / `sftp-mkdir` / `sftp-rm` / `sftp-rmdir` / `sftp-mv` / `sftp-chmod`。
///
/// 硬约束：
/// - **本地文件 I/O 由 CLI 做**。uTerm 是沙盒 app，写不了任意本地路径；socket 上
///   只传 base64（`sftp-put`）或文本 / base64（`sftp-cat` / `sftp-get`）。
/// - 上限：`cat` 1 MiB（`maxCatBytes`），`get` / `put` **单次请求** 8 MiB
///   （`maxFileBytes`），超限一律 `file_too_large`，不要先整个读进内存再判 —— 用
///   `SFTPProviding.download(remotePath:maximumBytes:)` 的有界入口，整文件 `get`
///   更是**先 stat 再决定**，绝不先拉后拒。大文件靠客户端分片：`get` 带
///   `offset`/`length` 取区间，`put` 带 `offset` + `mode: write` 并行写。
/// - 一次动作**借**一条池里的 SFTP 会话（每主机最多 4 条并行），跑完归还。
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

        let spec = try HostConnectionSpec.resolve(
            profile: profile, container: deps.modelContainer)
        do {
            // 借一条 SFTP 会话跑完这次动作再归还（池子每主机最多 4 条并行）。
            // `perform` 的失败在闭包里就被包成 `ControlFailure`，所以外层 catch 到的
            // 非 `ControlFailure` 只可能来自**借出阶段**（建连）。
            return try await deps.pool.withSFTP(for: spec) { sftp in
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
        } catch let failure as ControlFailure {
            throw failure
        } catch let busy as SFTPChannelsBusyError {
            // 这台主机的 SFTP 通道全忙且等到超时 —— 不是连不上，是排队没排到。
            // TODO（与 `fix/control-server-busy` 合并后）：换成 `ControlErrorCode.server_busy`。
            throw ControlFailure(
                code: .operation_failed,
                message: busy.message(host: profile.name)
            )
        } catch {
            // 建连失败要把 fingerprint 一并回给 CLI（`ControlFailure` 带不了 hostKey），
            // 所以这一段走「直接返回响应」而不是抛。
            return connectFailureResponse(error, id: request.id, profile: profile)
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
            // 给了 offset 或 length = 区间读（分片下载）；都没给才是原来的整文件语义。
            if request.offset != nil || request.length != nil {
                return try await readRange(request, path: path, on: sftp)
            }
            return try await readFile(
                request, path: path, limit: ControlProtocol.maxFileBytes, on: sftp)

        case .sftpPut:
            return try await writeFile(request, on: sftp)

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
                message: "\(path)：\(ControlFilePayloadBuilder.errorDetail(for: error))"
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

    /// `sftp-get` 的**区间**读：`offset` / `length` 至少给了一个就走这条。
    ///
    /// 语义（`utermctl` 的分片下载照这个来）：
    /// - `offset` 缺省 0，负数是 `invalid_request`；
    /// - `length` 缺省 `maxFileBytes`（= 单次封顶），超过它是 `file_too_large`；
    /// - 不做整文件的 stat 上限检查 —— 大文件正是靠一段段取回来的；
    /// - `file.bytes` 是**实际**返回的字节数。
    ///
    /// `truncated` 也先 `stat` 再判，口径按「客户端到底要的是多少」分两种：
    /// - **给了 `length`**：要的是这一段，期望 `min(length, 剩余)`。拿满 = 完整，
    ///   到 EOF 短了也是完整（`truncated: false`）。
    /// - **只给了 `offset`**：要的是「从这里到文件尾」，期望 = 剩余全部。被 8 MiB
    ///   单次上限截断时 `truncated: true`，并在 message 里给出下一次的 `offset`
    ///   —— 早先这里恒 false，50 MiB 的文件只回了头 8 MiB 却说「没被削」。
    private func readRange(
        _ request: ControlRequest,
        path: String,
        on sftp: any SFTPProviding
    ) async throws -> ControlResponse {
        let offset = try Self.requiredOffset(request.offset)
        let length = try Self.rangeLength(request.length)
        // stat 拿不到就退回 nil（宁可少报也不谎报）—— 真正的失败会由随后的读抛出来。
        let remaining: Int64? = (try? await sftp.stat(path)).map {
            max(0, $0.size - Int64(clamping: offset))
        }
        let data = try await sftp.readRange(path, offset: offset, length: length)
        let declaredSize: Int64? = remaining.map { rest in
            request.length == nil ? rest : min(rest, Int64(length))
        }
        let payload = ControlFilePayloadBuilder.payload(
            path: path, data: data, declaredSize: declaredSize)
        let next = offset + UInt64(data.count)
        var message = "\(path)[\(offset)..<\(next)]（\(data.count) 字节）"
        if payload.truncated, let remaining {
            message += "；本次封顶 \(ControlProtocol.maxFileBytes) 字节，还剩 "
                + "\(remaining - Int64(data.count)) 字节，用 offset \(next) 继续取"
        }
        return .success(id: request.id, message: message, file: payload)
    }

    /// `sftp-put`：按 `mode` + `offset` 写一段。
    ///
    /// - `mode` 缺省 `create`（已存在 → `file_exists`）；没给 `mode` 但 `force: true`
    ///   等价 `overwrite`；`write` 不截断，供分片并行写同一文件。
    /// - `offset` 缺省 0，负数是 `invalid_request`。
    /// - 单次内容仍受 `maxFileBytes`（8 MiB）约束 —— 客户端负责分片。
    /// - 响应的 `file.bytes` 是**本次**写入的字节数。
    private func writeFile(
        _ request: ControlRequest,
        on sftp: any SFTPProviding
    ) async throws -> ControlResponse {
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
        let offset = try Self.requiredOffset(request.offset)
        let mode = try Self.writeMode(request)
        do {
            try await sftp.writeRange(path, offset: offset, data: data, mode: mode)
        } catch {
            throw ControlFailure(
                code: await Self.putErrorCode(error, mode: mode, path: path, on: sftp),
                message: "\(path)：\(ControlFilePayloadBuilder.errorDetail(for: error))"
            )
        }
        return .success(
            id: request.id,
            message: "已写入 \(path)（\(data.count) 字节 @ \(offset)，\(mode.rawValue)）",
            file: ControlFilePayloadBuilder.written(path: path, bytes: data.count)
        )
    }

    /// `create` 撞已存在文件时服务端的回法五花八门（SFTP v3 只有 `SSH_FX_FAILURE`，
    /// 文案还依实现而定）。所以：先按常规映射；只有落到兜底的 `operation_failed` 时，
    /// 才多花一次 `stat` 确认路径确实已存在 —— 存在就报 `file_exists`。
    ///
    /// ⚠️ 这次兜底**只对打开阶段的失败**成立（`SFTPWriteStageError.stage == .open`）。
    /// EXCL 打开成功之后的写失败（磁盘满、配额、连接断）时文件已经被建出来了，
    /// 那次 `stat` 必然成功 —— 不加这道门就会把「No space left on device」报成
    /// `file_exists`，用户照提示加 `--force` 重传，然后再次失败。
    private static func putErrorCode(
        _ error: Error,
        mode: SFTPWriteMode,
        path: String,
        on sftp: any SFTPProviding
    ) async -> ControlErrorCode {
        let mapped = ControlFilePayloadBuilder.errorCode(for: error)
        guard mode == .create, mapped == .operation_failed,
              SFTPWriteStageError.isOpenFailure(error) else { return mapped }
        return (try? await sftp.stat(path)) != nil ? .file_exists : mapped
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

    /// 区间传输的起点。缺省 0，负数是请求错误（`UInt64(bitPattern:)` 会把 -1 变成
    /// 天文数字，绝不能默默放过去）。
    private static func requiredOffset(_ raw: Int64?) throws(ControlFailure) -> UInt64 {
        guard let raw else { return 0 }
        guard raw >= 0 else {
            throw ControlFailure(code: .invalid_request, message: "offset 不能为负：\(raw)")
        }
        return UInt64(raw)
    }

    /// `sftp-get` 的区间长度。缺省整段上限；> 0 且 ≤ `maxFileBytes`，超了让客户端自己分片。
    private static func rangeLength(_ raw: Int?) throws(ControlFailure) -> Int {
        guard let raw else { return ControlProtocol.maxFileBytes }
        guard raw > 0 else {
            throw ControlFailure(code: .invalid_request, message: "length 必须为正：\(raw)")
        }
        guard raw <= ControlProtocol.maxFileBytes else {
            throw ControlFailure(
                code: .file_too_large,
                message: "length \(raw) 字节，超过单次上限 \(ControlProtocol.maxFileBytes) 字节"
            )
        }
        return raw
    }

    /// `sftp-put` 的写入模式。显式 `mode` 优先；没给时 `force: true` 等价 `overwrite`，
    /// 否则 `create`（拒绝覆盖）。
    private static func writeMode(_ request: ControlRequest) throws(ControlFailure) -> SFTPWriteMode {
        guard let raw = trimmed(request.mode) else {
            return request.force == true ? .overwrite : .create
        }
        guard let mode = SFTPWriteMode(rawValue: raw.lowercased()) else {
            let all = SFTPWriteMode.allCases.map(\.rawValue).joined(separator: " / ")
            throw ControlFailure(
                code: .invalid_request,
                message: "sftp-put 的 mode 无法解析：\(raw)（期望 \(all)）"
            )
        }
        return mode
    }

    /// `cat` 的读取上限：客户端可以调小，但封顶在协议常量上。
    private static func readLimit(_ requested: Int?, cap: Int) -> Int {
        guard let requested, requested > 0 else { return cap }
        return min(requested, cap)
    }

    // MARK: - 错误文案

    /// CLI 的 message 给**原话**，不给 `FriendlyError` 洗过的「操作未能完成，请稍后
    /// 重试」—— 那句对界面合适，对模型 / 开发者等于什么都没说。
    private static func sftpMessage(request: ControlRequest, error: Error) -> String {
        let where_ = request.path.map { "\($0)：" } ?? ""
        return "\(where_)\(ControlFilePayloadBuilder.errorDetail(for: error))"
    }
}
