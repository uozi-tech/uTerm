import Darwin
import Foundation

/// 远程 Mac 组：`macs` 与 `mac-*`。对象是配对过的 Mac，走远控链路（局域网、打洞或中继），那台 Mac 不用开 SSH。
///
/// - 文件操作在那台 Mac 上由 uTerm 的辅助程序执行，所以它得开着 uTerm、打开了「允许打开本机终端」。
/// - 列目录、属性、读文件、传输、跑命令的响应形状和 SSH 主机的同名动作一样（`entries` / `stat` / `file` /
///   `transfer` / `result`）；搜索、目录树、哈希这些放在 `mac` 里。
/// - 传输同 `sftp-get` / `sftp-put`：本地文件由客户端打开，fd 经 `SCM_RIGHTS` 交来。
extension ControlHandler {

    func handleMac(_ request: ControlRequest, _ deps: Dependencies) async throws -> ControlResponse {
        guard let macs = deps.macs else {
            throw ControlFailure(code: .app_not_ready, message: "远程 Mac 的入口还没准备好，稍后重试")
        }
        let arguments = request.mac ?? ControlMacArguments()
        let caller = arguments.session.flatMap(UUID.init(uuidString:))
        if request.action == .macs {
            let snapshots = macs.snapshots(session: caller)
            var payload = ControlMacPayload()
            payload.macs = snapshots
            let controllers = snapshots.filter { $0.role == ControlMacRole.controller }.count
            let message = controllers == 0
                ? "\(snapshots.count) 台配对过的 Mac"
                : "\(snapshots.count - controllers) 台配对过的 Mac，\(controllers) 台设备正连着这台 Mac"
            return Self.macResponse(request, message: message, payload)
        }
        // 写扩展属性也是改动，但读不是：动作级的门禁分不开，在这里补判。
        if request.action == .macXattr, ["set", "remove"].contains(arguments.attributeAction ?? "list"),
           !deps.settings.allowMutations {
            throw ControlFailure(code: .mutations_disabled,
                                 message: "写入未启用：在 uTerm「设置 › 命令行与技能」里打开「允许执行命令与写入」")
        }
        let session = try await macs.provider(for: arguments.target ?? "", session: caller)
        defer { macs.finished(session) }
        do {
            return try await Self.performMac(request, arguments, session)
        } catch let failure as ControlFailure {
            throw failure
        } catch let error as RemoteFileError {
            throw ControlFailure(code: Self.macErrorCode(error), message: error.message)
        } catch is CancellationError {
            throw ControlFailure(code: .operation_failed, message: "已取消（客户端断开或 uTerm 关闭了命令行接口）")
        }
    }

    nonisolated static func macErrorCode(_ error: RemoteFileError) -> ControlErrorCode {
        switch error.code {
        case .notFound: return .file_not_found
        case .permissionDenied, .disabled: return .permission_denied
        case .exists: return .file_exists
        case .isDirectory: return .is_directory
        case .tooLarge: return .file_too_large
        case .invalid: return .invalid_request
        case .unreachable: return .connect_failed
        case .timeout: return .command_timeout
        case .notDirectory, .notEmpty, .conflict, .noMatch, .ambiguous, .unsupported, .failed: return .operation_failed
        }
    }

    private nonisolated static func macResponse(_ request: ControlRequest, message: String,
                                                _ payload: ControlMacPayload? = nil) -> ControlResponse {
        var response = ControlResponse.success(id: request.id, message: message)
        response.mac = payload
        return response
    }

    // MARK: - 分发

    private nonisolated static func performMac(_ request: ControlRequest, _ arguments: ControlMacArguments,
                                               _ session: ControlMacSession) async throws -> ControlResponse {
        let provider = session.provider
        var payload = ControlMacPayload()
        payload.name = session.name
        payload.role = session.role

        func send(_ file: RemoteFileRequest, body: Data = Data()) async throws -> (reply: RemoteFileReply, body: Data) {
            var file = file
            if file.options == nil { file.options = arguments.options }
            return try await withHeartbeat { try await provider.perform(file, body: body) }
        }

        switch request.action {
        case .macLs:
            let (reply, _) = try await send(RemoteFileRequest(op: .list, path: request.path ?? "~"))
            let entries = (reply.entries ?? []).map(RemoteMacFileProvider.entry)
            payload.path = reply.path
            var response = macResponse(request, message: "\(reply.path ?? ""): \(entries.count) 项", payload)
            response.entries = ControlFilePayloadBuilder.entries(entries)
            return response

        case .macStat:
            let entry = try await stat(try path(request), send)
            var response = macResponse(request, message: entry.path ?? "", payload)
            response.stat = ControlRemoteStat(path: entry.path ?? "", size: entry.size,
                                              modifiedAt: ControlProtocol.iso8601(Date(timeIntervalSince1970: entry.mtime)) ?? "",
                                              permissions: Int(entry.mode), kind: ControlFilePayloadBuilder.kind(mode: entry.mode))
            return response

        case .macCat:
            let target = try path(request)
            let entry = try await stat(target, send)
            guard !entry.isDirectory else { throw RemoteFileError(.isDirectory, "\(target)：是目录") }
            let limit = min(max(1, request.maxBytes ?? ControlProtocol.maxCatBytes), ControlProtocol.maxCatBytes)
            guard entry.size <= Int64(limit) else {
                throw ControlFailure(code: .file_too_large,
                                     message: "\(target) 有 \(entry.size) 字节，超过本次上限 \(limit) 字节；用 mac read 读一段，或 mac get 下载")
            }
            let data = try await withHeartbeat { try await provider.readRange(target, offset: 0, length: limit) }
            var response = macResponse(request, message: "\(target)（\(data.count) 字节）", payload)
            response.file = ControlFilePayloadBuilder.payload(path: entry.path ?? target, data: data, declaredSize: entry.size)
            return response

        case .macRead:
            return try await read(request, arguments, payload, provider, send)

        case .macGet, .macPut:
            return try await transfer(request, payload, provider, send)

        case .macMkdir:
            let target = try path(request)
            _ = try await send(RemoteFileRequest(op: .mkdir, path: target))
            return macResponse(request, message: "已创建目录 \(target)", payload)

        case .macRm:
            let target = try path(request)
            _ = try await send(RemoteFileRequest(op: .remove, path: target))
            return macResponse(request, message: "已删除 \(target)", payload)

        case .macRmdir:
            let target = try path(request)
            _ = try await send(RemoteFileRequest(op: .rmdir, path: target))
            return macResponse(request, message: "已删除目录 \(target)", payload)

        case .macMv, .macCp:
            let target = try path(request)
            let destination = try newPath(request)
            var file = RemoteFileRequest(op: request.action == .macMv ? .rename : .copy, path: target)
            file.newPath = destination
            file.options = (arguments.options ?? []) + (request.force == true ? [RemoteFileOption.replace] : [])
            _ = try await send(file)
            return macResponse(request, message: "\(request.action == .macMv ? "已移动" : "已复制") \(target) → \(destination)", payload)

        case .macChmod:
            let target = try path(request)
            guard let mode = ControlFileMode.parse(request.mode) else {
                throw ControlFailure(code: .invalid_request, message: "mode 无法解析：期望八进制（如 644 / 0755）或十进制整数")
            }
            var file = RemoteFileRequest(op: .chmod, path: target)
            file.mode = mode
            _ = try await send(file)
            return macResponse(request, message: "已设置权限 \(String(mode, radix: 8)) → \(target)", payload)

        case .macGrep:
            guard let pattern = arguments.pattern, !pattern.isEmpty else {
                throw ControlFailure(code: .invalid_request, message: "缺少要搜的内容")
            }
            var file = RemoteFileRequest(op: .grep, path: request.path ?? "~")
            file.pattern = pattern
            file.include = arguments.include
            file.exclude = arguments.exclude
            file.limit = arguments.limit
            file.depth = arguments.depth
            file.context = arguments.context
            let (reply, _) = try await send(file)
            payload.path = reply.path
            payload.matches = (reply.matches ?? []).map {
                ControlMacMatch(path: $0.path, line: $0.line, text: $0.text, before: $0.before, after: $0.after)
            }
            payload.count = reply.count
            payload.truncated = reply.truncated
            let note = reply.truncated == true ? "（结果被截断，缩小范围再搜）" : ""
            return macResponse(request, message: "搜了 \(reply.count ?? 0) 个文件，\(payload.matches?.count ?? 0) 处匹配\(note)", payload)

        case .macFind:
            var file = RemoteFileRequest(op: .find, path: request.path ?? "~")
            file.pattern = arguments.pattern
            file.include = arguments.include
            file.exclude = arguments.exclude
            file.limit = arguments.limit
            file.depth = arguments.depth
            file.seconds = arguments.seconds
            let (reply, _) = try await send(file)
            payload.path = reply.path
            payload.found = (reply.entries ?? []).map {
                ControlMacEntry(path: $0.path ?? $0.name, isDirectory: $0.isDirectory, size: $0.size,
                                modifiedAt: ControlProtocol.iso8601(Date(timeIntervalSince1970: $0.mtime)) ?? "",
                                permissions: Int($0.mode), sha256: $0.sha256)
            }
            payload.truncated = reply.truncated
            let note = reply.truncated == true ? "（结果被截断，缩小范围再找）" : ""
            return macResponse(request, message: "\(payload.found?.count ?? 0) 项\(note)", payload)

        case .macTree:
            var file = RemoteFileRequest(op: .tree, path: request.path ?? "~")
            file.depth = arguments.depth
            file.limit = arguments.limit
            let (reply, body) = try await send(file)
            payload.path = reply.path
            payload.text = String(decoding: body, as: UTF8.self)
            payload.count = reply.count
            payload.truncated = reply.truncated
            return macResponse(request, message: "\(reply.path ?? "")：\(reply.count ?? 0) 项", payload)

        case .macHash:
            let target = try path(request)
            let (reply, _) = try await send(RemoteFileRequest(op: .hash, path: target))
            payload.path = target
            payload.sha256 = reply.sha256
            payload.bytes = reply.size
            return macResponse(request, message: reply.sha256 ?? "", payload)

        case .macDu:
            let (reply, _) = try await send(RemoteFileRequest(op: .du, path: request.path ?? "~"))
            payload.path = reply.path
            payload.bytes = reply.bytes
            payload.files = reply.files
            payload.directories = reply.directories
            payload.truncated = reply.truncated
            return macResponse(request, message: "\(reply.path ?? "")：\(reply.bytes ?? 0) 字节，\(reply.files ?? 0) 个文件", payload)

        case .macShares:
            let (reply, _) = try await send(RemoteFileRequest(op: .roots))
            guard let roots = reply.roots else {
                return macResponse(request, message: "「\(session.name)」没有限定目录：整台 Mac 都能访问", payload)
            }
            payload.roots = roots.map { ControlMacRoot(path: $0.path, writable: $0.writable) }
            let message = roots.isEmpty
                ? "「\(session.name)」没有给这台 Mac 共享任何文件夹（得由用户在那台 Mac 的 uTerm「动作 › 我的 Mac」里添加）"
                : "「\(session.name)」共享了 \(roots.count) 个文件夹"
            return macResponse(request, message: message, payload)

        case .macDf:
            let (reply, _) = try await send(RemoteFileRequest(op: .df, path: request.path ?? "~"))
            payload.path = reply.path
            payload.bytes = reply.bytes
            payload.totalBytes = reply.totalBytes
            return macResponse(request, message: "可用 \(reply.bytes ?? 0) / 共 \(reply.totalBytes ?? 0) 字节", payload)

        case .macWrite:
            let target = try path(request)
            guard let text = request.text else { throw ControlFailure(code: .invalid_request, message: "缺少要写入的内容") }
            var file = RemoteFileRequest(op: .write, path: target)
            file.options = [RemoteFileOption.atomic]
            file.ifMatch = arguments.ifMatch
            // 没说覆盖、也没给 ifMatch：只肯新建，免得把已有的文件悄悄盖掉。
            file.writeMode = request.force == true || arguments.ifMatch != nil ? "overwrite" : "create"
            file.mode = ControlFileMode.parse(request.mode)
            let (reply, _) = try await send(file, body: Data(text.utf8))
            payload.path = target
            payload.sha256 = reply.sha256
            payload.bytes = reply.size
            return macResponse(request, message: "已写入 \(target)（\(reply.size ?? 0) 字节）", payload)

        case .macEdit:
            let target = try path(request)
            var file = RemoteFileRequest(op: .edit, path: target)
            file.oldText = arguments.oldText
            file.newText = arguments.newText
            file.ifMatch = arguments.ifMatch
            let (reply, _) = try await send(file)
            payload.path = reply.path
            payload.sha256 = reply.sha256
            payload.count = reply.count
            payload.bytes = reply.size
            return macResponse(request, message: "已替换 \(reply.count ?? 0) 处：\(target)", payload)

        case .macPatch:
            guard let diff = request.text, !diff.isEmpty else { throw ControlFailure(code: .invalid_request, message: "缺少补丁内容") }
            var file = RemoteFileRequest(op: .patch, path: request.path ?? "~")
            file.strip = arguments.strip
            let (reply, body) = try await send(file, body: Data(diff.utf8))
            payload.path = reply.path
            payload.text = String(decoding: body, as: UTF8.self)
            let dryRun = arguments.options?.contains(RemoteFileOption.dryRun) == true
            return macResponse(request, message: dryRun ? "补丁可以打上（没有改文件）" : "补丁已打上", payload)

        case .macTrash:
            let target = try path(request)
            let (reply, _) = try await send(RemoteFileRequest(op: .trash, path: target))
            payload.path = reply.path
            return macResponse(request, message: "已移到废纸篓：\(target)", payload)

        case .macLn:
            let target = try path(request)
            var file = RemoteFileRequest(op: .symlink, path: target)
            file.newPath = try newPath(request)
            file.options = (arguments.options ?? []) + (request.force == true ? [RemoteFileOption.replace] : [])
            _ = try await send(file)
            return macResponse(request, message: "已建链接 \(target) → \(file.newPath ?? "")", payload)

        case .macReadlink:
            let target = try path(request)
            let (reply, _) = try await send(RemoteFileRequest(op: .readlink, path: target))
            payload.path = reply.path
            return macResponse(request, message: reply.path ?? "", payload)

        case .macTouch:
            let target = try path(request)
            var file = RemoteFileRequest(op: .touch, path: target)
            file.seconds = arguments.seconds
            _ = try await send(file)
            return macResponse(request, message: "已更新 \(target)", payload)

        case .macXattr:
            let target = try path(request)
            let action = arguments.attributeAction ?? "list"
            var file = RemoteFileRequest(op: .xattr, path: target)
            file.action = action
            file.name = arguments.attribute
            let (reply, body) = try await send(file, body: Data((request.text ?? "").utf8))
            payload.path = target
            payload.names = reply.names
            if action == "get" {
                if let text = String(data: body, encoding: .utf8) { payload.text = text } else { payload.base64 = body.base64EncodedString() }
            }
            return macResponse(request, message: "\(target)：xattr \(action)", payload)

        case .macWaitChange:
            let target = try path(request)
            var file = RemoteFileRequest(op: .waitChange, path: target)
            file.seconds = request.waitSeconds
            let (reply, _) = try await send(file)
            payload.path = reply.path
            payload.names = reply.names
            payload.timedOut = reply.timedOut
            return macResponse(request, message: reply.timedOut == true ? "到时限也没有变化" : "有变化：\(reply.names?.count ?? 0) 处", payload)

        case .macRun:
            return try await run(request, session, payload, send)

        default:
            throw ControlFailure(code: .invalid_request, message: "动作 \(request.action.rawValue) 不属于远程 Mac 组")
        }
    }

    private typealias MacSend = (RemoteFileRequest, Data) async throws -> (reply: RemoteFileReply, body: Data)

    private nonisolated static func stat(_ path: String, _ send: (RemoteFileRequest, Data) async throws -> (reply: RemoteFileReply, body: Data)) async throws -> RemoteFileEntry {
        let (reply, _) = try await send(RemoteFileRequest(op: .stat, path: path), Data())
        guard let entry = reply.entry else { throw RemoteFileError(.failed, "\(path)：那台 Mac 没有回属性") }
        return entry
    }

    // MARK: - 读一段

    /// 给了 `offset` / `length` 按字节读；否则按行读（`startLine` / `endLine` / `tail`）。
    private nonisolated static func read(
        _ request: ControlRequest, _ arguments: ControlMacArguments, _ base: ControlMacPayload,
        _ provider: RemoteMacFileProvider,
        _ send: (RemoteFileRequest, Data) async throws -> (reply: RemoteFileReply, body: Data)
    ) async throws -> ControlResponse {
        let target = try path(request)
        var payload = base
        if arguments.offset != nil || arguments.length != nil {
            let length = min(max(1, arguments.length ?? ControlProtocol.maxCatBytes), ControlProtocol.maxCatBytes)
            let offset = UInt64(max(0, arguments.offset ?? 0))
            let data = try await withHeartbeat { try await provider.readRange(target, offset: offset, length: length) }
            var response = macResponse(request, message: "\(target)：从 \(offset) 起 \(data.count) 字节", payload)
            response.file = ControlFilePayloadBuilder.payload(path: target, data: data, declaredSize: nil)
            return response
        }
        var file = RemoteFileRequest(op: .readText, path: target)
        file.startLine = arguments.startLine
        file.endLine = arguments.endLine
        file.tailLines = arguments.tail
        file.maxBytes = request.maxBytes
        let (reply, body) = try await send(file, Data())
        payload.path = reply.path ?? target
        payload.text = String(decoding: body, as: UTF8.self)
        payload.count = reply.count
        payload.totalLines = reply.totalLines
        payload.sha256 = reply.sha256
        payload.bytes = reply.size
        payload.truncated = reply.truncated
        let note = reply.truncated == true ? "（被截断，分段再读）" : ""
        return macResponse(request, message: "\(target)：\(reply.count ?? 0) 行 / 共 \(reply.totalLines ?? 0) 行\(note)", payload)
    }

    // MARK: - 跑命令

    private nonisolated static func run(
        _ request: ControlRequest, _ session: ControlMacSession, _ base: ControlMacPayload,
        _ send: (RemoteFileRequest, Data) async throws -> (reply: RemoteFileReply, body: Data)
    ) async throws -> ControlResponse {
        let command = try commandText(request)
        let limits = limits(request)
        var file = RemoteFileRequest(op: .exec, path: request.path)
        file.command = command
        file.seconds = Double(limits.timeoutSeconds)
        file.maxDuration = Double(limits.maxDurationSeconds)
        file.maxBytes = limits.maxBytes
        let (reply, body) = try await send(file, Data())
        guard let exec = reply.exec else { throw RemoteFileError(.failed, "那台 Mac 没有回执行结果") }
        var output = String(decoding: body, as: UTF8.self)
        var truncated = exec.truncated
        // 行数上限：只留最后这么多行（同字节上限，结尾最有用）。
        let endsWithNewline = output.hasSuffix("\n")
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if endsWithNewline { lines.removeLast() }      // 结尾换行后面那段空的不算一行
        if lines.count > limits.maxLines {
            output = lines.suffix(limits.maxLines).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
            truncated = true
        }
        let result = ControlRunResult(host: session.name, hostID: session.id, output: output,
                                      exitCode: exec.exitCode.map(Int.init), truncated: truncated,
                                      durationMs: exec.durationMs, timedOut: exec.timedOut,
                                      timeoutReason: exec.timeoutReason, killed: exec.timedOut ? exec.killed : nil)
        var payload = base
        payload.path = reply.path
        if exec.timedOut {
            var response = ControlResponse.failure(
                id: request.id, code: .command_timeout,
                message: exec.timeoutReason == "idle"
                    ? "连续 \(limits.timeoutSeconds) 秒没有输出，已判定卡住" + (exec.killed ? "并终止" : "，但没能终止，命令可能还在跑")
                    : "跑满 \(limits.maxDurationSeconds) 秒的总时长上限" + (exec.killed ? "，已终止" : "，但没能终止，命令可能还在跑"),
                results: [result])
            response.mac = payload
            return response
        }
        var response = macResponse(request, message: "退出码 \(exec.exitCode.map(String.init) ?? "无（被信号终止）")", payload)
        response.result = result
        return response
    }

    // MARK: - 传输

    /// `mac-get`（远端 → fd）/ `mac-put`（fd → 远端）。fd、续传区间、进度的约定同 `sftp-get` / `sftp-put`。
    private nonisolated static func transfer(
        _ request: ControlRequest, _ base: ControlMacPayload, _ provider: RemoteMacFileProvider,
        _ send: (RemoteFileRequest, Data) async throws -> (reply: RemoteFileReply, body: Data)
    ) async throws -> ControlResponse {
        let target = try path(request)
        let window = min(max(1, request.parallel ?? ControlProtocol.defaultTransferChannels), ControlProtocol.maxTransferChannels)
        guard let context = ControlRequestContext.current, let fd = context.takeFileDescriptor() else {
            throw ControlFailure(code: .invalid_request,
                                 message: "\(request.action.rawValue) 需要随请求用 SCM_RIGHTS 交来本地文件的 fd（utermctl 会自动做）")
        }
        defer { Darwin.close(fd) }
        let isGet = request.action == .macGet
        let ranges = request.ranges?.map { RemoteMacTransfer.Range(offset: $0.offset, length: $0.length) }
        let perform: RemoteMacTransfer.Perform = { file, body in try await provider.perform(file, body: body) }
        let onPiece: @Sendable (RemoteMacTransfer.Range) -> Void = {
            context.recordSegment(ControlByteRange(offset: $0.offset, length: $0.length))
        }
        let started = Date()
        let size: Int64
        if isGet {
            let entry = try await stat(target, send)
            guard !entry.isDirectory else { throw RemoteFileError(.isDirectory, "\(target)：是目录") }
            size = entry.size
            try validate(ranges, size: size)
            context.setTotal(size)
            do {
                try await RemoteMacTransfer.download(path: target, size: size, ranges: ranges, window: window, perform: perform,
                                                     sink: { offset, data in try RemoteMacFileProvider.pwriteAll(fd, data, at: offset) },
                                                     onPiece: onPiece)
            } catch let error as RemoteFileError where error.message.hasPrefix("写本地文件失败") {
                throw ControlFailure(code: .local_write_failed, message: error.message)
            }
        } else {
            var info = Darwin.stat()
            guard fstat(fd, &info) == 0 else {
                throw ControlFailure(code: .local_read_failed, message: "读不了本地文件的属性：\(String(cString: strerror(errno)))")
            }
            size = Int64(info.st_size)
            try validate(ranges, size: size)
            context.setTotal(size)
            if ranges == nil {
                // 整份上传：先建好（或截断）目标。续传时不动它已有的内容。
                var create = RemoteFileRequest(op: .write, path: target)
                create.writeMode = request.force == true ? "overwrite" : "create"
                _ = try await send(create, Data())
            }
            do {
                try await RemoteMacTransfer.upload(path: target, size: size, ranges: ranges, window: window, perform: perform,
                                                   source: { offset, length in try RemoteMacFileProvider.preadAll(fd, at: offset, length: length) },
                                                   onPiece: onPiece)
            } catch let error as RemoteFileError where error.message.hasPrefix("读本地文件失败") || error.message.hasPrefix("本地文件") {
                throw ControlFailure(code: .local_read_failed, message: error.message)
            }
            let remote = try await stat(target, send).size
            guard remote == size else {
                throw ControlFailure(code: .operation_failed, message: "\(target)：传完之后远端是 \(remote) 字节，本地是 \(size) 字节")
            }
        }
        let seconds = Date().timeIntervalSince(started)
        let moved = ranges.map { $0.reduce(0) { $0 + $1.length } } ?? size
        var response = macResponse(request, message: "\(isGet ? "已下载" : "已上传") \(target)（\(moved) 字节，"
                                       + String(format: "%.1f 秒）", seconds), base)
        response.transfer = ControlTransferResult(path: target, bytes: moved, totalBytes: size, seconds: seconds, channels: window)
        return response
    }

    private nonisolated static func validate(_ ranges: [RemoteMacTransfer.Range]?, size: Int64) throws(ControlFailure) {
        for range in ranges ?? [] where range.offset < 0 || range.length <= 0 || range.offset + range.length > size {
            throw ControlFailure(code: .invalid_request, message: "区间 \(range.offset)+\(range.length) 超出了文件大小 \(size)")
        }
    }

    // MARK: - 参数与心跳

    private nonisolated static func path(_ request: ControlRequest) throws(ControlFailure) -> String {
        guard let path = request.path, !path.isEmpty else { throw ControlFailure(code: .invalid_request, message: "缺少路径") }
        return path
    }

    private nonisolated static func newPath(_ request: ControlRequest) throws(ControlFailure) -> String {
        guard let path = request.newPath, !path.isEmpty else { throw ControlFailure(code: .invalid_request, message: "缺少目标路径") }
        return path
    }

    /// 等那台 Mac 回话的时候每 10 秒报一次「还在等」：跑命令、等变化可以静默很久，而命令行服务端
    /// 连续 120 秒没有进展就会判超时。真卡住了由请求自己的时限兜底。
    private nonisolated static func withHeartbeat<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                IOActivity.touch()
            }
        }
        defer { ticker.cancel() }
        return try await work()
    }
}
