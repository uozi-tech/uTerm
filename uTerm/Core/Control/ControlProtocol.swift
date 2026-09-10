import Foundation

/// 本机 IPC 的动作集。外部 AI CLI（`utermctl`）把请求编成一行 JSON 发到
/// `ControlProtocol.socketURL`，uTerm 用**用户已保存的主机档案**代为执行 ——
/// 密码 / 私钥 / 口令始终留在 app 和钥匙串里，CLI 一个字节也拿不到。
///
/// `rawValue` 一律用 kebab-case（客户端子命令名与它逐字一致），Swift case 名用
/// camelCase。新增动作必须同时补 `requiresEnabled` / `requiresMutation` /
/// `requiresExecCapableHost` / `group` 四个分类属性 —— `ControlProtocolTests`
/// 会遍历 `allCases` 校验。
nonisolated public enum ControlAction: String, Codable, Sendable, CaseIterable {

    // MARK: 探活

    /// 探活 + 报 app 版本 / socket 路径 / 两个开关 / CLI 当前持有的主机。唯一不需要主开关的动作。
    case ping = "ping"

    // MARK: 主机

    /// 列出已保存的 `ServerProfile`。
    case hosts = "hosts"
    /// 查某主机在 `KnownHost` 里的记录（fingerprint / 算法 / 首次信任时间）。
    case hostKey = "host-key"
    /// 按 fingerprint 钉住写入 `KnownHost`。fingerprint 不匹配当前挑战 → `host_key_mismatch`。
    case trust = "trust"

    // MARK: 执行

    /// 单主机一次性 exec。
    case run = "run"
    /// 多主机并行 exec（有界并发 `maxParallelHosts`）。
    case runMany = "run-many"
    /// 列快捷命令。
    case quickCommands = "quick-commands"
    /// 按名字 / id 跑一条快捷命令，并写入 30 天运行日志。
    case quickRun = "quick-run"

    // MARK: 文件（SFTP）

    case sftpLs = "sftp-ls"
    case sftpStat = "sftp-stat"
    case sftpCat = "sftp-cat"
    case sftpGet = "sftp-get"
    case sftpPut = "sftp-put"
    case sftpMkdir = "sftp-mkdir"
    case sftpRm = "sftp-rm"
    case sftpRmdir = "sftp-rmdir"
    case sftpMv = "sftp-mv"
    case sftpChmod = "sftp-chmod"

    // MARK: 端口转发

    case forwardList = "forward-list"
    case forwardStart = "forward-start"
    case forwardStop = "forward-stop"

    // MARK: 终端会话

    case terminals = "terminals"
    case terminalRead = "terminal-read"
    case terminalSend = "terminal-send"
    case terminalOpen = "terminal-open"

    // MARK: 收尾

    /// 松开 CLI 连接池对某主机的 exec / SFTP 持有。
    case disconnect = "disconnect"

    /// 需要主开关 `control.enabled`。只有 `ping` 不需要 —— 否则客户端连开关状态都问不到。
    public var requiresEnabled: Bool {
        self != .ping
    }

    /// 需要改动开关 `control.allowMutations`：一切「会改远端、写本地信任库或触发副作用」的动作。
    ///
    /// **`run` 系列在内**：shell 命令无法可靠分类读写（`AgentSafety.readAuto` 至今没实现
    /// 只读白名单就是这个原因），假的只读开关比没有更糟。
    public var requiresMutation: Bool {
        switch self {
        case .trust, .run, .runMany, .quickRun,
             .sftpPut, .sftpMkdir, .sftpRm, .sftpRmdir, .sftpMv, .sftpChmod,
             .forwardStart, .forwardStop,
             .terminalSend, .terminalOpen:
            return true
        case .ping, .hosts, .hostKey, .quickCommands,
             .sftpLs, .sftpStat, .sftpCat, .sftpGet,
             .forwardList,
             .terminals, .terminalRead,
             .disconnect:
            return false
        }
    }

    /// 主机级硬规则：`ServerProfile.sftpOnly == true` 的主机拒绝这些动作（`host_sftp_only`）。
    /// 这是用户在主机档案上做的定性，CLI 不绕。
    public var requiresExecCapableHost: Bool {
        switch self {
        case .run, .runMany, .quickRun, .terminalSend, .terminalOpen:
            return true
        default:
            return false
        }
    }

    /// 分发到 `ControlHandler` 的哪一组 extension。
    public var group: ControlActionGroup {
        switch self {
        case .hosts, .hostKey, .trust:
            return .hosts
        case .run, .runMany, .quickCommands, .quickRun:
            return .exec
        case .sftpLs, .sftpStat, .sftpCat, .sftpGet, .sftpPut,
             .sftpMkdir, .sftpRm, .sftpRmdir, .sftpMv, .sftpChmod:
            return .sftp
        case .forwardList, .forwardStart, .forwardStop:
            return .forward
        case .terminals, .terminalRead, .terminalSend, .terminalOpen:
            return .terminal
        case .ping, .disconnect:
            return .misc
        }
    }
}

/// 动作的归组。`ControlHandler.handle` 按它分发到对应的 extension 文件。
nonisolated public enum ControlActionGroup: String, Codable, Sendable, CaseIterable {
    case hosts
    case exec
    case sftp
    case forward
    case terminal
    case misc
}

// MARK: - 请求

/// 一个扁平结构 + 全可选字段（与 uTable 一致）：Codable 简单，Python 客户端零依赖。
nonisolated public struct ControlRequest: Codable, Sendable, Equatable {
    public var id: String?
    public var action: ControlAction
    /// 主机名 / UUID（单主机动作）。解析顺序：精确 → 忽略大小写 → 唯一前缀。
    public var host: String?
    /// 多主机（`run-many` / `quick-run` 覆盖目标）。
    public var hosts: [String]?
    /// shell 命令整串，或快捷命令的名字 / id。
    public var command: String?
    /// 命令 argv（客户端 `--` 之后原样传来，服务端按需 join）。
    public var args: [String]?
    public var timeoutSeconds: Int?
    public var maxLines: Int?
    public var maxBytes: Int?
    public var path: String?
    /// `sftp-mv` 的目标路径。
    public var newPath: String?
    /// `sftp-chmod` 的八进制权限（如 `"644"`）。
    public var mode: String?
    /// `sftp-put` 的文件内容（base64）。
    public var contentBase64: String?
    /// 转发规则 id / name。
    public var rule: String?
    /// 终端会话 id 或其唯一前缀。
    public var terminal: String?
    public var lines: Int?
    public var text: String?
    /// `terminal-send` 是否追加 `\r`。
    public var enter: Bool?
    /// `trust` 要钉住的指纹（必须与当前挑战一致）。
    public var fingerprint: String?
    /// 备用名字字段（快捷命令 / 转发规则按名字指定时的显式入口）。
    public var name: String?

    public init(
        id: String? = nil,
        action: ControlAction,
        host: String? = nil,
        hosts: [String]? = nil,
        command: String? = nil,
        args: [String]? = nil,
        timeoutSeconds: Int? = nil,
        maxLines: Int? = nil,
        maxBytes: Int? = nil,
        path: String? = nil,
        newPath: String? = nil,
        mode: String? = nil,
        contentBase64: String? = nil,
        rule: String? = nil,
        terminal: String? = nil,
        lines: Int? = nil,
        text: String? = nil,
        enter: Bool? = nil,
        fingerprint: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.action = action
        self.host = host
        self.hosts = hosts
        self.command = command
        self.args = args
        self.timeoutSeconds = timeoutSeconds
        self.maxLines = maxLines
        self.maxBytes = maxBytes
        self.path = path
        self.newPath = newPath
        self.mode = mode
        self.contentBase64 = contentBase64
        self.rule = rule
        self.terminal = terminal
        self.lines = lines
        self.text = text
        self.enter = enter
        self.fingerprint = fingerprint
        self.name = name
    }
}

// MARK: - 响应

/// `ok / code / message` 三件套永远在，其余按动作填。
nonisolated public struct ControlResponse: Codable, Sendable, Equatable {
    public var id: String?
    public var ok: Bool
    public var code: String
    public var message: String
    public var app: ControlAppInfo?
    public var hosts: [ControlHostSnapshot]?
    public var hostKey: ControlHostKeyInfo?
    public var result: ControlRunResult?
    public var results: [ControlRunResult]?
    public var quickCommands: [ControlQuickCommandSnapshot]?
    public var entries: [ControlRemoteEntry]?
    public var stat: ControlRemoteStat?
    public var file: ControlFilePayload?
    public var rules: [ControlForwardSnapshot]?
    public var terminals: [ControlTerminalSnapshot]?
    public var screen: ControlScreenSnapshot?

    public init(
        id: String? = nil,
        ok: Bool,
        code: String,
        message: String,
        app: ControlAppInfo? = nil,
        hosts: [ControlHostSnapshot]? = nil,
        hostKey: ControlHostKeyInfo? = nil,
        result: ControlRunResult? = nil,
        results: [ControlRunResult]? = nil,
        quickCommands: [ControlQuickCommandSnapshot]? = nil,
        entries: [ControlRemoteEntry]? = nil,
        stat: ControlRemoteStat? = nil,
        file: ControlFilePayload? = nil,
        rules: [ControlForwardSnapshot]? = nil,
        terminals: [ControlTerminalSnapshot]? = nil,
        screen: ControlScreenSnapshot? = nil
    ) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.app = app
        self.hosts = hosts
        self.hostKey = hostKey
        self.result = result
        self.results = results
        self.quickCommands = quickCommands
        self.entries = entries
        self.stat = stat
        self.file = file
        self.rules = rules
        self.terminals = terminals
        self.screen = screen
    }

    public static func success(
        id: String?,
        code: String = ControlErrorCode.ok.rawValue,
        message: String,
        app: ControlAppInfo? = nil,
        hosts: [ControlHostSnapshot]? = nil,
        hostKey: ControlHostKeyInfo? = nil,
        result: ControlRunResult? = nil,
        results: [ControlRunResult]? = nil,
        quickCommands: [ControlQuickCommandSnapshot]? = nil,
        entries: [ControlRemoteEntry]? = nil,
        stat: ControlRemoteStat? = nil,
        file: ControlFilePayload? = nil,
        rules: [ControlForwardSnapshot]? = nil,
        terminals: [ControlTerminalSnapshot]? = nil,
        screen: ControlScreenSnapshot? = nil
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: true,
            code: code,
            message: message,
            app: app,
            hosts: hosts,
            hostKey: hostKey,
            result: result,
            results: results,
            quickCommands: quickCommands,
            entries: entries,
            stat: stat,
            file: file,
            rules: rules,
            terminals: terminals,
            screen: screen
        )
    }

    public static func failure(
        id: String?,
        code: ControlErrorCode,
        message: String,
        app: ControlAppInfo? = nil,
        hosts: [ControlHostSnapshot]? = nil,
        hostKey: ControlHostKeyInfo? = nil,
        results: [ControlRunResult]? = nil,
        terminals: [ControlTerminalSnapshot]? = nil,
        rules: [ControlForwardSnapshot]? = nil
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: false,
            code: code.rawValue,
            message: message,
            app: app,
            hosts: hosts,
            hostKey: hostKey,
            results: results,
            rules: rules,
            terminals: terminals
        )
    }

    /// 服务端（`ControlServer`）自己产生的错误码是裸字符串（`handler_timeout` 等），
    /// 不经 `ControlErrorCode`。这条重载给它用。
    public static func failure(
        id: String?,
        code: String,
        message: String
    ) -> ControlResponse {
        ControlResponse(id: id, ok: false, code: code, message: message)
    }
}

// MARK: - 快照类型

nonisolated public struct ControlAppInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var build: String
    public var socket: String
    /// 主开关（设置 ▸ 命令行与技能）。关掉时除 `ping` 外一律拒绝。
    public var controlEnabled: Bool
    /// 改动开关。关掉时 `run` / SFTP 写 / 转发启停 / 终端注入一律拒绝。
    public var mutationsEnabled: Bool
    /// CLI 连接池当前持有的主机名（判断「慢是不是因为首连」）。
    public var openHosts: [String]

    public init(
        name: String,
        version: String,
        build: String,
        socket: String,
        controlEnabled: Bool,
        mutationsEnabled: Bool,
        openHosts: [String]
    ) {
        self.name = name
        self.version = version
        self.build = build
        self.socket = socket
        self.controlEnabled = controlEnabled
        self.mutationsEnabled = mutationsEnabled
        self.openHosts = openHosts
    }
}

/// 一台已保存主机。`id` 是 UUID 字符串 —— CloudKit 同步下同名主机是常态，
/// 技能文档要教模型在歧义时改用 UUID。
nonisolated public struct ControlHostSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    /// `password` / `privateKey`。
    public var authMethod: String
    public var group: String?
    /// 跳板机的**名字**（不暴露它的完整档案）。
    public var jumpHost: String?
    public var sftpOnly: Bool
    public var pinned: Bool
    /// ISO8601。
    public var lastConnectedAt: String?
    /// CLI 连接池当前是否持有这台（exec 或 SFTP）。
    public var cliConnected: Bool
    /// `ForwardingCoordinator.activeCount(forServer:)`。
    public var activeForwards: Int

    public init(
        id: String,
        name: String,
        host: String,
        port: Int,
        username: String,
        authMethod: String,
        group: String? = nil,
        jumpHost: String? = nil,
        sftpOnly: Bool,
        pinned: Bool,
        lastConnectedAt: String? = nil,
        cliConnected: Bool,
        activeForwards: Int
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.group = group
        self.jumpHost = jumpHost
        self.sftpOnly = sftpOnly
        self.pinned = pinned
        self.lastConnectedAt = lastConnectedAt
        self.cliConnected = cliConnected
        self.activeForwards = activeForwards
    }
}

/// 一台主机上一次命令执行的结果。`run-many` 逐主机返回一条。
nonisolated public struct ControlRunResult: Codable, Sendable, Equatable {
    /// 主机档案名。
    public var host: String
    public var hostID: String
    public var output: String
    /// 远端真实退出码；拿不到（超时 / 建连失败）为 nil。
    public var exitCode: Int?
    /// 输出被 `maxLines` / `maxBytes` 削过。
    public var truncated: Bool
    public var durationMs: Int
    /// 超时。**语句本身可能还在远端跑**（Citadel exec 不可取消）。
    public var timedOut: Bool
    /// 该主机单独失败时的错误码（`run-many` 里其它台照跑）。
    public var errorCode: String?
    public var errorMessage: String?
    /// 该主机的主机密钥状态。只在 `host_key_unknown` / `host_key_changed` 时非 nil ——
    /// `run-many` 的顶层只能挑一台报，逐条带上模型才知道到底是哪几台要 `trust`。
    public var hostKey: ControlHostKeyInfo?

    public init(
        host: String,
        hostID: String,
        output: String,
        exitCode: Int? = nil,
        truncated: Bool = false,
        durationMs: Int = 0,
        timedOut: Bool = false,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        hostKey: ControlHostKeyInfo? = nil
    ) {
        self.host = host
        self.hostID = hostID
        self.output = output
        self.exitCode = exitCode
        self.truncated = truncated
        self.durationMs = durationMs
        self.timedOut = timedOut
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.hostKey = hostKey
    }
}

/// 主机密钥状态。`status` 三态：`known` / `unknown` / `changed`。
nonisolated public struct ControlHostKeyInfo: Codable, Sendable, Equatable {
    public var host: String
    public var algorithm: String?
    public var fingerprint: String?
    /// ISO8601。
    public var firstTrustedAt: String?
    /// `known` / `unknown` / `changed`
    public var status: String

    public init(
        host: String,
        algorithm: String? = nil,
        fingerprint: String? = nil,
        firstTrustedAt: String? = nil,
        status: String
    ) {
        self.host = host
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.firstTrustedAt = firstTrustedAt
        self.status = status
    }
}

/// 与 `uTerm/Features/Files/RemoteEntry.swift` 的 `RemoteEntry` 对齐的线上形状。
/// 时间用 ISO8601 字符串，权限用数字 mode（含类型位）—— 格式化成 `rwxr-xr-x` 由客户端做。
nonisolated public struct ControlRemoteEntry: Codable, Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: UInt64?
    /// ISO8601。
    public var modifiedAt: String?
    /// 原始 POSIX mode（含文件类型位）。
    public var permissions: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var ownerName: String?
    public var groupName: String?

    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool,
        size: UInt64? = nil,
        modifiedAt: String? = nil,
        permissions: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        ownerName: String? = nil,
        groupName: String? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.ownerName = ownerName
        self.groupName = groupName
    }
}

/// 与 `RemoteStat`（size + mtime + 权限）对齐，另附解析后的路径。
nonisolated public struct ControlRemoteStat: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    /// ISO8601。
    public var modifiedAt: String
    /// 原始 POSIX mode，**含类型位**（与 `ControlRemoteEntry.permissions` 一致）。
    /// 服务端没给权限位时为 nil。客户端展示时自己 `& 0o7777`。
    public var permissions: Int?
    /// `file` / `directory` / `symlink` / `other`，由 `permissions` 的类型位推出；
    /// 没有权限位时为 nil。`ls` 靠 `isDirectory` / `isSymlink` 两个布尔表达同一件事，
    /// `stat` 只有一行，给个字符串更直观。
    public var kind: String?

    public init(
        path: String,
        size: Int64,
        modifiedAt: String,
        permissions: Int? = nil,
        kind: String? = nil
    ) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.kind = kind
    }
}

/// `sftp-cat` / `sftp-get` 的载荷。UTF-8 可解码时给 `text`，否则给 `base64`。
nonisolated public struct ControlFilePayload: Codable, Sendable, Equatable {
    public var path: String
    public var bytes: Int
    public var isUTF8: Bool
    public var text: String?
    public var base64: String?
    /// 内容不完整。`cat` / `get` 都是**先 stat 再决定**：声明大小超上限就直接
    /// `file_too_large`，从不截断着返回（`SFTPProviding` 没有部分读原语）。
    /// 因此这个字段实际只在「stat 之后文件又长大了」的竞态里才为 true。
    public var truncated: Bool

    public init(
        path: String,
        bytes: Int,
        isUTF8: Bool,
        text: String? = nil,
        base64: String? = nil,
        truncated: Bool = false
    ) {
        self.path = path
        self.bytes = bytes
        self.isUTF8 = isUTF8
        self.text = text
        self.base64 = base64
        self.truncated = truncated
    }
}

/// 一条转发规则 + 它的运行态。`kind`：`local` / `remote` / `dynamic`。
nonisolated public struct ControlForwardSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var serverID: String
    public var serverName: String
    public var name: String
    /// `local` / `remote` / `dynamic`
    public var kind: String
    public var listenHost: String
    public var listenPort: Int
    /// dynamic 为 nil。
    public var destHost: String?
    public var destPort: Int
    /// 连接级自启（连到该主机时拉起）。
    public var autostart: Bool
    /// `inactive` / `starting` / `active` / `error`
    public var status: String
    /// 状态为 error 时的原因，或最近一次连接问题。
    public var issue: String?
    public var bytesIn: UInt64?
    public var bytesOut: UInt64?

    public init(
        id: String,
        serverID: String,
        serverName: String,
        name: String,
        kind: String,
        listenHost: String,
        listenPort: Int,
        destHost: String? = nil,
        destPort: Int,
        autostart: Bool,
        status: String,
        issue: String? = nil,
        bytesIn: UInt64? = nil,
        bytesOut: UInt64? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.name = name
        self.kind = kind
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.destHost = destHost
        self.destPort = destPort
        self.autostart = autostart
        self.status = status
        self.issue = issue
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// 一个跨窗口的终端会话。`windowKind`：`workspace` / `terminal`。
nonisolated public struct ControlTerminalSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var serverID: String
    public var serverName: String
    /// `workspace` / `terminal`
    public var windowKind: String
    public var title: String
    public var isKeyWindowFocused: Bool
    /// ISO8601。
    public var connectedAt: String?

    public init(
        id: String,
        serverID: String,
        serverName: String,
        windowKind: String,
        title: String,
        isKeyWindowFocused: Bool,
        connectedAt: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.windowKind = windowKind
        self.title = title
        self.isKeyWindowFocused = isKeyWindowFocused
        self.connectedAt = connectedAt
    }
}

/// `terminal-read` 的读屏快照 —— 是**快照不是流**，两次之间的输出会丢。
nonisolated public struct ControlScreenSnapshot: Codable, Sendable, Equatable {
    public var terminal: String
    public var lines: [String]
    /// 被 `maxScreenBytes` 削过。
    public var truncated: Bool

    public init(terminal: String, lines: [String], truncated: Bool = false) {
        self.terminal = terminal
        self.lines = lines
        self.truncated = truncated
    }
}

/// 一条快捷命令。
nonisolated public struct ControlQuickCommandSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var command: String
    public var serverIDs: [String]
    public var serverNames: [String]
    /// ISO8601。
    public var lastRunAt: String?

    public init(
        id: String,
        name: String,
        command: String,
        serverIDs: [String],
        serverNames: [String],
        lastRunAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.serverIDs = serverIDs
        self.serverNames = serverNames
        self.lastRunAt = lastRunAt
    }
}

// MARK: - 错误码

/// 协议层错误码。客户端按它映射退出码，技能文档里有总表。
nonisolated public enum ControlErrorCode: String, Codable, Sendable, CaseIterable {
    case ok

    // 客户端本地判定（服务端不会发出，列在这里是为了让总表完整）
    case uterm_not_running
    case uterm_socket_stale

    // 两级开关
    case control_disabled
    case mutations_disabled

    // 主机解析与主机级硬规则
    case host_not_found
    case host_ambiguous
    case host_sftp_only

    // 主机密钥三态（响应里都带 fingerprint）
    case host_key_unknown
    case host_key_mismatch
    case host_key_changed

    // 建连
    case connect_failed
    case auth_failed

    // 执行
    case command_timeout
    /// `run-many` / `quick-run`：有成功也有失败。逐条结果在 `results` 里。
    case run_partial_failure
    /// `run-many` / `quick-run`：**一台都没成功**。
    case run_failed

    // 文件
    case file_not_found
    case file_too_large
    case permission_denied
    case is_directory

    // 转发
    case rule_not_found
    case rule_ambiguous
    case port_in_use
    case forward_failed

    // 终端
    case terminal_not_found
    case terminal_ambiguous
    case terminal_disconnected

    // 服务端兜底
    case handler_timeout
    case invalid_request
    case app_not_ready
    case operation_failed

    /// 骨架期占位：动作已在协议里定死，实现还没落地。
    case not_implemented
}

// MARK: - 常量与编解码

nonisolated public enum ControlProtocol {
    /// 一条请求的字节上限。
    ///
    /// **必须从 `maxFileBytes` 推导**：`sftp-put` 把文件塞进 `contentBase64`，base64
    /// 膨胀 4/3，再加上 JSON 字段与路径的开销。写死 1 MiB 时，超过 ~768 KiB 的上传会在
    /// **发送途中**被服务端拒掉并关连接，客户端只看得到 BrokenPipe，报成毫无线索的
    /// `socket_error`。64 KiB 的富余留给 JSON 外壳（action / path / id / 转义）。
    public static let maxRequestBytes = maxFileBytes * 4 / 3 + 64 * 1024

    /// `sockaddr_un.sun_path` 的字节上限（含结尾 NUL）。
    ///
    /// `<Application Support>/uTerm/control.sock` 在沙盒容器里展开是
    /// `~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/control.sock`
    /// —— 用户名 5 字符时 98 字节，超过 10 字符就会炸。`ControlServer.start()` 会先量一次，
    /// 超限则不 bind、把原因写进 `ControlSettings.startupError`。
    public static let maxSunPathLength = 104

    /// `run` 的默认 / 封顶超时（秒）。
    public static let defaultRunTimeoutSeconds = 60
    public static let maxRunTimeoutSeconds = 300

    /// `SSHCommandExecutor` 的输出裁剪默认值。
    public static let defaultMaxLines = 200
    public static let defaultMaxBytes = 16_000
    /// `--max-bytes` 的硬顶。
    public static let maxOutputBytes = 1_048_576

    /// `sftp-get` / `sftp-put` 单次上限（8 MiB）。
    public static let maxFileBytes = 8 * 1_048_576
    /// `sftp-cat` 上限（1 MiB）。
    public static let maxCatBytes = 1_048_576

    /// `terminal-read` 默认行数与字节封顶。
    public static let defaultScreenLines = 80
    public static let maxScreenBytes = 16_000

    /// `run-many` 的有界并发（与 `QuickCommandRunner.maxConcurrent` 对齐）。
    public static let maxParallelHosts = 6

    /// `<Application Support>/uTerm/control.sock`。
    ///
    /// macOS 端 Debug 与 Release **都开沙盒**，所以这条路径永远落在容器里
    /// （`~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/`）。
    /// 客户端仍保留两候选 + `UTERM_CONTROL_SOCKET` 环境变量覆盖，成本为零。
    public static var socketURL: URL {
        applicationSupportDirectory
            .appending(path: "control.sock")
            .standardizedFileURL
    }

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appending(path: "uTerm", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func encode(_ response: ControlResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response)
    }

    public static func decodeRequest(_ data: Data) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    /// 统一的时间序列化用的 formatter。
    ///
    /// `ISO8601DateFormatter` 的 `string(from:)` 是**线程安全**的（Foundation 的
    /// formatter 只要不在使用中改配置就可并发读），而它的构造并不便宜 —— `hosts` /
    /// `forward-list` 这类列表动作一条快照要调好几次，每次新建一个纯属浪费。
    /// 这里构造完就再也不改配置，故 `nonisolated(unsafe)` 是安全的。
    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

    /// 统一的时间序列化（快照里所有时间字段都用它）。
    public static func iso8601(_ date: Date?) -> String? {
        guard let date else { return nil }
        return iso8601Formatter.string(from: date)
    }
}
