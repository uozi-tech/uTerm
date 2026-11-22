import Darwin
import Foundation

/// 文件组：`sftp-ls` / `sftp-stat` / `sftp-cat` / `sftp-get` /
/// `sftp-put` / `sftp-mkdir` / `sftp-rm` / `sftp-rmdir` / `sftp-mv` / `sftp-chmod`。
///
/// 硬约束：
/// - **本地文件由 CLI 打开**。uTerm 是沙盒 app，打不开任意本地路径（自己建的文件还会被
///   打 quarantine）；`sftp-get` / `sftp-put` 由客户端打开 / 建好本地文件，经
///   `SCM_RIGHTS` 把 fd 随请求交过来，`ParallelTransfer` 多通道并行直接读写它 —— 文件
///   字节不走 socket，大小不设上限，进度一行行写回同一条连接。
/// - `cat` 上限 1 MiB（`maxCatBytes`），超限 `file_too_large`，**先 stat 再决定**，
///   绝不先拉后拒。
/// - 小动作**借**一条池里的 SFTP 会话，跑完归还；传输自己按 `parallel` 借多条。
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
        if ControlProtocol.isTransfer(request.action) {
            return try await transfer(request, spec: spec, profile: profile, deps: deps)
        }
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
            // 回 `server_busy`：客户端对这个码有退避重试。
            throw ControlFailure(
                code: .server_busy,
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
                message: String(localized: "\(path)：\(entries.count) 项"),
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

        case .sftpGet, .sftpPut:
            // 传输不借单条会话，在 `handleSFTP` 入口就分流到 `transfer` 了。
            throw ControlFailure(code: .invalid_request, message: String(localized: "\(request.action.rawValue) 走并行传输通道"))

        case .sftpMkdir:
            let path = try Self.requiredPath(request.path)
            try await sftp.createDirectory(path)
            return .success(id: request.id, message: String(localized: "已创建目录 \(path)"))

        case .sftpRm:
            let path = try Self.requiredPath(request.path)
            try await sftp.removeFile(path)
            return .success(id: request.id, message: String(localized: "已删除 \(path)"))

        case .sftpRmdir:
            let path = try Self.requiredPath(request.path)
            try await sftp.removeDirectory(path)
            return .success(id: request.id, message: String(localized: "已删除目录 \(path)"))

        case .sftpMv:
            let path = try Self.requiredPath(request.path)
            guard let newPath = try Self.optionalPath(request.newPath) else {
                throw ControlFailure(code: .invalid_request, message: String(localized: "sftp-mv 需要 newPath"))
            }
            try await sftp.rename(path, to: newPath)
            return .success(id: request.id, message: String(localized: "已重命名 \(path) → \(newPath)"))

        case .sftpChmod:
            let path = try Self.requiredPath(request.path)
            guard let mode = ControlFileMode.parse(request.mode) else {
                throw ControlFailure(
                    code: .invalid_request,
                    message: String(localized: "mode 无法解析：期望八进制（如 644 / 0755）或十进制整数")
                )
            }
            try await sftp.setPermissions(path: path, mode: mode)
            return .success(
                id: request.id,
                message: String(localized: "已设置权限 \(String(mode, radix: 8)) → \(path)")
            )

        default:
            throw ControlFailure(
                code: .invalid_request,
                message: String(localized: "动作 \(request.action.rawValue) 不属于文件组")
            )
        }
    }

    /// `cat`：**先 stat 再决定**，超限直接拒（绝不先拉后拒），
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
                message: String(localized: "\(path)：\(ControlFilePayloadBuilder.errorDetail(for: error))", comment: "路径：出错原因")
            )
        }
        if let declaredSize, declaredSize > Int64(limit) {
            throw ControlFailure(
                code: .file_too_large,
                message: String(localized: "\(path) 有 \(String(declaredSize)) 字节，超过本次上限 \(String(limit)) 字节")
            )
        }
        let data = try await sftp.download(remotePath: path, maximumBytes: limit)
        return .success(
            id: request.id,
            message: String(localized: "\(path)（\(String(data.count)) 字节）"),
            file: ControlFilePayloadBuilder.payload(
                path: path, data: data, declaredSize: declaredSize)
        )
    }

    // MARK: - 大文件传输

    /// `sftp-get`（远端 → fd）/ `sftp-put`（fd → 远端）。
    ///
    /// - fd 必须随请求经 `SCM_RIGHTS` 交来（`ControlRequestContext`），这里负责关它；
    /// - `parallel` 是这次用几条 SFTP 通道（缺省 8，封顶 16）；
    /// - `ranges` 给了就只传这些区间（续传）；`put` 此时不再动远端已有内容；
    /// - `put` 缺省遇到已存在的远端文件回 `file_exists`，`force: true` 覆盖；
    /// - 每落一段就记进上下文，服务端每 0.5 秒把新完成的段写成一行进度发给客户端。
    private func transfer(
        _ request: ControlRequest,
        spec: HostConnectionSpec,
        profile: ServerProfile,
        deps: Dependencies
    ) async throws -> ControlResponse {
        let path = try Self.requiredPath(request.path)
        let channels = try Self.transferChannels(request.parallel)
        guard let context = ControlRequestContext.current, let fd = context.takeFileDescriptor() else {
            throw ControlFailure(
                code: .invalid_request,
                message: String(localized: "\(request.action.rawValue) 需要随请求用 SCM_RIGHTS 交来本地文件的 fd（utermctl 会自动做；自己写客户端见 uterm 技能的 references/files.md）")
            )
        }
        defer { Darwin.close(fd) }

        let isGet = request.action == .sftpGet
        let mode: SFTPWriteMode = request.force == true ? .overwrite : .create
        let tuning = (isGet ? ParallelTransfer.Tuning.download : .upload).with(channels: channels)
        let onSize: @Sendable (Int64) -> Void = { context.setTotal($0) }
        let onSegment: @Sendable (ControlByteRange) -> Void = { context.recordSegment($0) }
        let started = Date()
        let size: Int64
        do {
            if isGet {
                size = try await ParallelTransfer.download(
                    host: spec, pool: deps.pool, remotePath: path, fd: fd, ranges: request.ranges,
                    tuning: tuning, onSize: onSize, onSegment: onSegment)
            } else {
                size = try await ParallelTransfer.upload(
                    host: spec, pool: deps.pool, fd: fd, remotePath: path, mode: mode,
                    ranges: request.ranges, tuning: tuning, onSize: onSize, onSegment: onSegment)
            }
        } catch {
            return try await transferFailure(
                error, request: request, path: path, isGet: isGet, mode: mode,
                spec: spec, profile: profile, deps: deps)
        }
        let seconds = Date().timeIntervalSince(started)
        let moved = request.ranges.map { $0.reduce(0) { $0 + $1.length } } ?? size
        let secondsText = String(format: "%.1f", seconds)
        return .success(
            id: request.id,
            message: isGet
                ? String(localized: "已下载 \(path)（\(String(moved)) 字节，\(channels) 路，\(secondsText) 秒）")
                : String(localized: "已上传 \(path)（\(String(moved)) 字节，\(channels) 路，\(secondsText) 秒）"),
            transfer: ControlTransferResult(
                path: path, bytes: moved, totalBytes: size, seconds: seconds, channels: channels)
        )
    }

    /// 传输失败的归类。建连失败要把 fingerprint 带回去，所以返回响应而不是抛。
    private func transferFailure(
        _ error: any Error,
        request: ControlRequest,
        path: String,
        isGet: Bool,
        mode: SFTPWriteMode,
        spec: HostConnectionSpec,
        profile: ServerProfile,
        deps: Dependencies
    ) async throws -> ControlResponse {
        switch error {
        case let failure as ControlFailure:
            throw failure
        case let busy as SFTPChannelsBusyError:
            throw ControlFailure(code: .server_busy, message: busy.message(host: profile.name))
        case is ControlConnectError:
            return connectFailureResponse(error, id: request.id, profile: profile)
        case is CancellationError:
            throw ControlFailure(code: .operation_failed, message: String(localized: "\(path)：传输已取消（客户端断开或 uTerm 关闭了命令行接口）"))
        case let transfer as ParallelTransfer.TransferError:
            let code: ControlErrorCode
            switch transfer {
            case .localIO: code = isGet ? .local_write_failed : .local_read_failed
            case .invalidRange: code = .invalid_request
            case .shortRead, .sizeMismatch: code = .operation_failed
            }
            throw ControlFailure(code: code, message: String(localized: "\(path)：\(transfer.localizedDescription)", comment: "路径：出错原因"))
        default:
            var code = ControlFilePayloadBuilder.errorCode(for: error)
            if !isGet, request.ranges == nil {
                code = (try? await deps.pool.withSFTP(for: spec) { sftp in
                    await Self.putErrorCode(error, mode: mode, path: path, on: sftp)
                }) ?? code
            }
            throw ControlFailure(
                code: code,
                message: String(localized: "\(path)：\(ControlFilePayloadBuilder.errorDetail(for: error))", comment: "路径：出错原因")
            )
        }
    }

    /// 并行通道数：缺省 `defaultTransferChannels`，1…`maxTransferChannels`。
    private static func transferChannels(_ requested: Int?) throws(ControlFailure) -> Int {
        guard let requested else { return ControlProtocol.defaultTransferChannels }
        guard (1...ControlProtocol.maxTransferChannels).contains(requested) else {
            throw ControlFailure(
                code: .invalid_request,
                message: String(localized: "parallel 要在 1–\(ControlProtocol.maxTransferChannels) 之间，实得 \(requested)")
            )
        }
        return requested
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
                message: String(localized: "动作 \(request.action.rawValue) 需要 --host")
            )
        }
        return needle
    }

    /// 路径原样传给远端（不展开 `~`、不做本地化）；给了空串是请求错误。
    private static func optionalPath(_ raw: String?) throws(ControlFailure) -> String? {
        guard let raw else { return nil }
        guard !raw.isEmpty else {
            throw ControlFailure(code: .invalid_request, message: String(localized: "路径不能为空"))
        }
        return raw
    }

    private static func requiredPath(_ raw: String?) throws(ControlFailure) -> String {
        guard let path = try optionalPath(raw) else {
            throw ControlFailure(code: .invalid_request, message: String(localized: "缺少 --path"))
        }
        return path
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
        let detail = ControlFilePayloadBuilder.errorDetail(for: error)
        guard let path = request.path else { return detail }
        return String(localized: "\(path)：\(detail)", comment: "路径：出错原因")
    }
}
