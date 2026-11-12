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
    /// 等 `terminal-open -- <命令>` 在窗口里跑的那条命令结束，回退出码与输出。
    case terminalWait = "terminal-wait"

    // MARK: 中继

    /// 用 SFTP 从已保存主机读安装脚本写下的设备配置，直接存进钥匙串。成员密钥不经过客户端。
    case relayImport = "relay-import"
    /// 从这台 Mac 测一遍已导入的中继：TCP、成员认证、UDP（STUN），附带版本。
    case relayCheck = "relay-check"

    // MARK: 收尾

    /// 松开 CLI 连接池对某主机的 exec / SFTP 持有。
    case disconnect = "disconnect"

    // MARK: 远程 Mac（配对过的 Mac，经远控链路；不需要那台 Mac 开 SSH）

    /// 列出配对过的 Mac 与在线情况。
    case macs = "macs"
    /// 在远程 Mac 上跑一条命令（登录 shell）。
    case macRun = "mac-run"
    case macLs = "mac-ls"
    case macStat = "mac-stat"
    case macCat = "mac-cat"
    case macGet = "mac-get"
    case macPut = "mac-put"
    case macMkdir = "mac-mkdir"
    case macRm = "mac-rm"
    case macRmdir = "mac-rmdir"
    case macMv = "mac-mv"
    case macChmod = "mac-chmod"
    /// 按行 / 按字节读一段。
    case macRead = "mac-read"
    case macGrep = "mac-grep"
    case macFind = "mac-find"
    case macTree = "mac-tree"
    case macHash = "mac-hash"
    case macDu = "mac-du"
    case macDf = "mac-df"
    /// 整份写入（可带 `ifMatch` 防覆盖）。
    case macWrite = "mac-write"
    /// 把一段文字换成另一段。
    case macEdit = "mac-edit"
    /// 打 unified diff。
    case macPatch = "mac-patch"
    case macCp = "mac-cp"
    case macTrash = "mac-trash"
    case macLn = "mac-ln"
    case macReadlink = "mac-readlink"
    case macTouch = "mac-touch"
    /// 扩展属性：读（list / get）只要主开关；写（set / remove）另由 handler 核改动开关。
    case macXattr = "mac-xattr"
    /// 等文件或目录有变化。
    case macWaitChange = "mac-wait-change"

    /// 需要主开关 `control.enabled`。只有 `ping` 不需要 —— 否则客户端连开关状态都问不到。
    public var requiresEnabled: Bool {
        self != .ping
    }

    /// 需要改动开关 `control.allowMutations`：一切「会改远端、写本地信任库或触发副作用」的动作。
    ///
    /// **`run` 系列在内**：任意 shell 命令不能视作只读；Agent 的保守审批规则
    /// 不改变 CLI 的写操作授权边界。
    public var requiresMutation: Bool {
        switch self {
        case .trust, .run, .runMany, .quickRun,
             .sftpPut, .sftpMkdir, .sftpRm, .sftpRmdir, .sftpMv, .sftpChmod,
             .forwardStart, .forwardStop,
             .terminalSend, .terminalOpen,
             .relayImport,
             .macRun, .macPut, .macMkdir, .macRm, .macRmdir, .macMv, .macChmod,
             .macWrite, .macEdit, .macPatch, .macCp, .macTrash, .macLn, .macTouch:
            return true
        case .ping, .hosts, .hostKey, .quickCommands,
             .sftpLs, .sftpStat, .sftpCat, .sftpGet,
             .forwardList,
             .terminals, .terminalRead, .terminalWait,
             .relayCheck,
             .disconnect,
             .macs, .macLs, .macStat, .macCat, .macGet, .macRead, .macGrep, .macFind, .macTree,
             .macHash, .macDu, .macDf, .macReadlink, .macXattr, .macWaitChange:
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
        case .terminals, .terminalRead, .terminalSend, .terminalOpen, .terminalWait:
            return .terminal
        case .relayImport, .relayCheck:
            return .relay
        case .ping, .disconnect:
            return .misc
        case .macs, .macRun, .macLs, .macStat, .macCat, .macGet, .macPut, .macMkdir, .macRm, .macRmdir,
             .macMv, .macChmod, .macRead, .macGrep, .macFind, .macTree, .macHash, .macDu, .macDf,
             .macWrite, .macEdit, .macPatch, .macCp, .macTrash, .macLn, .macReadlink, .macTouch,
             .macXattr, .macWaitChange:
            return .mac
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
    case relay
    case misc
    case mac
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
    /// `run*` 的**静默**超时：连续这么多秒没有任何输出才判定卡住并终止。
    public var timeoutSeconds: Int?
    /// `run*` 的总时长上限（兜底，防 `tail -f` 这类永不静默的命令一直占着名额）。
    public var maxDurationSeconds: Int?
    public var maxLines: Int?
    public var maxBytes: Int?
    public var path: String?
    /// `sftp-mv` 的目标路径。
    public var newPath: String?
    /// `sftp-chmod` 的八进制权限（如 `"644"`）。
    public var mode: String?
    /// `sftp-put`：`true` = 覆盖已存在的远端文件；缺省遇到已存在就回 `file_exists`。
    public var force: Bool?
    /// `sftp-get` / `sftp-put` 只传这些区间（续传）。缺省整份。
    public var ranges: [ControlByteRange]?
    /// `sftp-get` / `sftp-put` 这次用几条 SFTP 通道，1…`maxTransferChannels`，缺省
    /// `defaultTransferChannels`。
    public var parallel: Int?
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
    /// `terminal-wait` 最多等多少秒。
    public var waitSeconds: Double?
    /// `mac-*`：哪台 Mac，以及这一组动作专有的参数。
    public var mac: ControlMacArguments?

    public init(
        id: String? = nil,
        action: ControlAction,
        host: String? = nil,
        hosts: [String]? = nil,
        command: String? = nil,
        args: [String]? = nil,
        timeoutSeconds: Int? = nil,
        maxDurationSeconds: Int? = nil,
        maxLines: Int? = nil,
        maxBytes: Int? = nil,
        path: String? = nil,
        newPath: String? = nil,
        mode: String? = nil,
        force: Bool? = nil,
        ranges: [ControlByteRange]? = nil,
        parallel: Int? = nil,
        rule: String? = nil,
        terminal: String? = nil,
        lines: Int? = nil,
        text: String? = nil,
        enter: Bool? = nil,
        fingerprint: String? = nil,
        name: String? = nil,
        waitSeconds: Double? = nil
    ) {
        self.id = id
        self.action = action
        self.host = host
        self.hosts = hosts
        self.command = command
        self.args = args
        self.timeoutSeconds = timeoutSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.maxLines = maxLines
        self.maxBytes = maxBytes
        self.path = path
        self.newPath = newPath
        self.mode = mode
        self.force = force
        self.ranges = ranges
        self.parallel = parallel
        self.rule = rule
        self.terminal = terminal
        self.lines = lines
        self.text = text
        self.enter = enter
        self.fingerprint = fingerprint
        self.name = name
        self.waitSeconds = waitSeconds
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
    public var transfer: ControlTransferResult?
    public var rules: [ControlForwardSnapshot]?
    public var terminals: [ControlTerminalSnapshot]?
    public var screen: ControlScreenSnapshot?
    /// `terminal-open -- <命令>` / `terminal-wait`：窗口里那条命令的状态。
    public var run: ControlTerminalRun?
    /// `relay-import` / `relay-check`：中继的公开信息与测试结果。永远不含成员密钥。
    public var relay: ControlRelayInfo?
    /// `mac-*`：远程 Mac 这一组动作专有的结果（搜索命中、目录树、哈希……）。列目录、属性、读文件、
    /// 传输、跑命令仍然放在 `entries` / `stat` / `file` / `transfer` / `result` 里，和 SSH 主机的同名动作一个形状。
    public var mac: ControlMacPayload?

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
        transfer: ControlTransferResult? = nil,
        rules: [ControlForwardSnapshot]? = nil,
        terminals: [ControlTerminalSnapshot]? = nil,
        screen: ControlScreenSnapshot? = nil,
        run: ControlTerminalRun? = nil,
        relay: ControlRelayInfo? = nil
    ) {
        self.relay = relay
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
        self.transfer = transfer
        self.rules = rules
        self.terminals = terminals
        self.screen = screen
        self.run = run
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
        transfer: ControlTransferResult? = nil,
        rules: [ControlForwardSnapshot]? = nil,
        terminals: [ControlTerminalSnapshot]? = nil,
        screen: ControlScreenSnapshot? = nil,
        run: ControlTerminalRun? = nil,
        relay: ControlRelayInfo? = nil
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
            transfer: transfer,
            rules: rules,
            terminals: terminals,
            screen: screen,
            run: run,
            relay: relay
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
    /// 超时（静默超时或总时长上限，见 `timeoutReason`）。
    public var timedOut: Bool
    /// 超时的原因：`idle`（连续 `timeoutSeconds` 秒没有输出）/ `max_duration`
    /// （跑满 `maxDurationSeconds`）。没超时为 nil。
    public var timeoutReason: String?
    /// 超时后是否已对远端进程组发出终止信号。false = 没能终止，**命令可能还在远端跑**。
    /// 没超时为 nil。
    public var killed: Bool?
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
        timeoutReason: String? = nil,
        killed: Bool? = nil,
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
        self.timeoutReason = timeoutReason
        self.killed = killed
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

/// `sftp-cat` / `sftp-get` 的载荷（`sftp-put` 也用它回报本次写入的字节数）。
/// UTF-8 可解码时给 `text`，否则给 `base64`；`sftp-put` 的响应里两者都是 nil。
nonisolated public struct ControlFilePayload: Codable, Sendable, Equatable {
    public var path: String
    public var bytes: Int
    public var isUTF8: Bool
    public var text: String?
    public var base64: String?
    /// 内容不完整。整文件的 `cat` / `get` 都是**先 stat 再决定**：声明大小超上限
    /// 就直接 `file_too_large`，从不截断着返回。因此这个字段实际只在
    /// 「stat 之后文件又长大了」的竞态里才为 true。
    /// **带 `offset` / `length` 的区间 `get` 恒为 false** —— 少给字节意味着读到了
    /// 文件末尾，不是被削过。
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

/// `terminal-open -- <命令>` 在窗口里跑的那条命令。用户在窗口里交互（输密码、回答提示），
/// 调用方用 `terminal-wait` 等它结束。
nonisolated public struct ControlTerminalRun: Codable, Sendable, Equatable {
    public var terminal: String
    public var command: String
    /// `pending`（还没连上 / 还没开始）/ `running` / `finished` / `disconnected`（没跑完会话就断了）。
    public var state: String
    /// `finished` 时才有。
    public var exitCode: Int?
    /// 命令开始以来窗口里的输出（软折行已拼回）；还没开始为 nil。
    public var output: String?
    /// 输出超过上限只给了最后一段，或开头已滚出回滚缓冲。
    public var truncated: Bool
    /// ISO8601。
    public var requestedAt: String
    public var startedAt: String?
    public var finishedAt: String?

    public init(
        terminal: String,
        command: String,
        state: String,
        exitCode: Int? = nil,
        output: String? = nil,
        truncated: Bool = false,
        requestedAt: String,
        startedAt: String? = nil,
        finishedAt: String? = nil
    ) {
        self.terminal = terminal
        self.command = command
        self.state = state
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
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

// MARK: - 中继

/// 中继的公开信息。**不含成员密钥**——协议里根本没有放它的字段。
nonisolated public struct ControlRelayInfo: Codable, Sendable, Equatable {
    public var name: String
    public var endpoint: String
    public var relayID: String
    /// 装着它的已保存主机名（导入时记下，uTerm 更新中继时用它）。
    public var managedHost: String?
    /// 这台 Mac 的公网接入开着没有、在中继上注册上没有。
    public var internetEnabled: Bool?
    public var registered: Bool?
    public var latestVersion: String?
    public var updateAvailable: Bool?
    public var check: RemoteRelayCheckResult?
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
    /// `sftp-put` 撞上已存在的路径。加 `--force` 才覆盖。
    case file_exists
    /// `sftp-get` / `sftp-put` 读写客户端交过来的本地 fd 失败（磁盘满、文件被改短……）。
    case local_write_failed
    case local_read_failed

    // 转发
    case rule_not_found
    case rule_ambiguous
    case port_in_use
    case forward_failed

    // 终端
    case terminal_not_found
    case terminal_ambiguous
    case terminal_disconnected

    // 中继
    /// 还没导入中继配置（`relay-check`）。
    case relay_not_configured
    /// 已经导入了另一台中继；加 `--replace` 才换。
    case relay_exists
    /// 读到的文件不是 uterm-relay 的设备配置。
    case relay_config_invalid
    /// `relay-check`：这台 Mac 连不上中继或认证没过。逐项结果在 `relay.check` 里。
    case relay_unreachable

    // 服务端兜底
    case handler_timeout
    /// 并发客户端超过 `ControlServer.maxActiveClients`，连接在读请求前就被拒。
    /// 服务端**不读**请求体就回这条，客户端应退避后重试（这是唯一可重试的服务端码）。
    case server_busy
    case invalid_request
    case app_not_ready
    case operation_failed

    /// 骨架期占位：动作已在协议里定死，实现还没落地。
    case not_implemented
}

// MARK: - 常量与编解码

nonisolated public enum ControlProtocol {
    /// 一条请求的字节上限。文件内容不再走请求体（`sftp-put` 传的是 fd），最大的请求是
    /// `terminal-send` 的文本与续传的区间表，1 MiB 绰绰有余。
    public static let maxRequestBytes = 1_048_576

    /// `sockaddr_un.sun_path` 的字节上限（含结尾 NUL）。
    ///
    /// `<Application Support>/uTerm/control.sock` 在沙盒容器里展开是
    /// `~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/control.sock`
    /// —— 用户名 5 字符时 98 字节，超过 10 字符就会炸。`ControlServer.start()` 会先量一次，
    /// 超限则不 bind、把原因写进 `ControlSettings.startupError`。
    public static let maxSunPathLength = 104

    /// `run` 的静默超时（秒）：默认 / 封顶。连续这么久没有任何输出才判定卡住。
    public static let defaultRunTimeoutSeconds = 60
    public static let maxRunTimeoutSeconds = 1800
    /// `run` 的总时长上限（秒）：默认 / 封顶。只是兜底，主判据是静默超时。
    public static let defaultRunMaxDurationSeconds = 3600
    public static let maxRunMaxDurationSeconds = 6 * 3600

    /// `SSHCommandExecutor` 的输出裁剪默认值。
    public static let defaultMaxLines = 200
    public static let defaultMaxBytes = 16_000
    /// `--max-bytes` 的硬顶。
    public static let maxOutputBytes = 1_048_576

    /// `sftp-get` / `sftp-put` 一次传输用几条 SFTP 通道：默认 / 封顶。
    ///
    /// 实测（Docker sshd，50 ms RTT，窗口 16 MiB）：4 路 182 / 8 路 279 / 16 路 287 /
    /// 32 路 182 / 64 路 105 MiB/s —— 8–16 路是顶，再多每条连接的加解密与拥塞窗口争抢
    /// 只会拖慢。所以默认 8，封顶 16，不做成可以开到上百路。
    public static let defaultTransferChannels = 8
    public static let maxTransferChannels = 16
    /// `sftp-cat` 上限（1 MiB）。
    public static let maxCatBytes = 1_048_576

    /// `terminal-wait`：默认 / 封顶等待秒数，与输出字节上限。默认值卡在常见 Agent 工具调用
    /// 超时（2 分钟）以内，没跑完就回 `running`，调用方再等一次。
    public static let defaultTerminalWaitSeconds = 90.0
    public static let maxTerminalWaitSeconds = 1800.0
    public static let maxTerminalRunOutputBytes = 64_000

    /// `terminal-read` 默认行数与字节封顶。
    public static let defaultScreenLines = 80
    public static let maxScreenBytes = 16_000

    /// `run-many` 的有界并发（与 `QuickCommandRunner.maxConcurrent` 对齐）。
    public static let maxParallelHosts = 6

    /// `ControlServer` 的两份连接槽位。传输（`isTransfer`）最多占 `maxTransferClients`；
    /// 其余请求永远有 `maxControlClients` 个留着，并行下载再多也挤不掉 `run` / `ping`。
    public static let maxControlClients = 8
    /// 一个槽位就是一整个并行传输（内部自己开 `defaultTransferChannels` 路），8 个足够；
    /// 最坏情况每个传输在途约 8 × 16 MiB（窗口）的缓冲，内存要有顶。
    public static let maxTransferClients = 8

    /// 占传输槽位的动作。
    public static func isTransfer(_ action: ControlAction) -> Bool {
        action == .sftpGet || action == .sftpPut || action == .macGet || action == .macPut
    }

    /// 这条请求占「长连接」槽位（与传输共用 `maxTransferClients`）：传输，以及
    /// `terminal-wait` —— 一等就是几分钟，不能占着 `run` / `ping` 的名额。
    public static func occupiesLongLivedSlot(_ action: ControlAction) -> Bool {
        isTransfer(action) || action == .terminalWait || action == .macWaitChange || action == .macRun
    }

    /// Debug and Release may share the same sandbox container. Keep their
    /// listeners separate; CLI discovery continues to target Release by default.
    public static var socketURL: URL {
        #if DEBUG
        let filename = "dev.sock"
        #else
        let filename = "control.sock"
        #endif
        return applicationSupportDirectory
            .appending(path: filename)
            .standardizedFileURL
    }

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appending(path: "uTerm", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// 响应编成**一行** JSON（末尾 `\n`）。连接上是「进度行…、最终响应」的逐行流，客户端
    /// 按行切 —— pretty-print 的多行响应会被切碎、一行都解析不了。
    public static func encode(_ response: ControlResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(response)
        data.append(UInt8(ascii: "\n"))
        return data
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

// MARK: - 大文件传输

/// 文件里的一段 `[offset, offset + length)`：续传区间与进度事件里的「已完成段」。
nonisolated public struct ControlByteRange: Codable, Sendable, Equatable {
    public var offset: Int64
    public var length: Int64

    public var end: Int64 { offset + length }

    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}

/// `sftp-get` / `sftp-put` 的成功结果。文件字节本身走客户端交来的 fd，不在响应里。
nonisolated public struct ControlTransferResult: Codable, Sendable, Equatable {
    public var path: String
    /// 这次实际搬的字节数（续传时只算补的那些区间）。
    public var bytes: Int64
    /// 文件总大小。
    public var totalBytes: Int64
    public var seconds: Double
    /// 用了几条 SFTP 通道。
    public var channels: Int

    public init(path: String, bytes: Int64, totalBytes: Int64, seconds: Double, channels: Int) {
        self.path = path
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.seconds = seconds
        self.channels = channels
    }
}

/// 传输进行中服务端往连接里写的进度行（一行一个 JSON，与最终响应同一条连接）：
/// `{"event":"progress","bytes":…,"totalBytes":…,"done":[{"offset":…,"length":…}]}`。
/// `done` 是**自上一行以来**新落盘 / 新写到远端的段，客户端据此记续传账。
nonisolated public struct ControlProgressEvent: Codable, Sendable, Equatable {
    public var event = "progress"
    public var bytes: Int64
    public var totalBytes: Int64?
    public var done: [ControlByteRange]
}

// MARK: - 远程 Mac

/// `mac-*` 动作的参数。全部可选；哪个动作用哪些见 `skills/uterm/references/mac.md`。
nonisolated public struct ControlMacArguments: Codable, Sendable, Equatable {
    /// 配对过的 Mac 的名字或设备 UUID。解析规则同主机：精确 → 忽略大小写 → 唯一前缀。
    public var target: String?
    /// `mac-grep` 的正则 / 字面量；`mac-find` 的文件名通配符。
    public var pattern: String?
    public var include: [String]?
    public var exclude: [String]?
    public var limit: Int?
    public var depth: Int?
    /// 开关，原样交给被控端（见 `RemoteFileOption`）。
    public var options: [String]?
    public var startLine: Int?
    public var endLine: Int?
    public var tail: Int?
    public var offset: Int64?
    public var length: Int?
    public var context: Int?
    public var ifMatch: String?
    public var oldText: String?
    public var newText: String?
    /// `mac-xattr`：`list` / `get` / `set` / `remove`。
    public var attributeAction: String?
    public var attribute: String?
    /// `mac-find`：只要最近这么多秒内改过的。`mac-touch`：要设的修改时间（距 1970 的秒数）。
    public var seconds: Double?
    public var strip: Int?

    public init(target: String? = nil) {
        self.target = target
    }
}

nonisolated public struct ControlMacSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 局域网里此刻找得到。
    public var onLocalNetwork: Bool
    /// 此刻在中继上。没问过中继时为 nil（不代表不在）。
    public var onRelay: Bool?
    /// 命令行这边已经握着到它的连接。
    public var connected: Bool
    /// 连着时走的哪条路（局域网 / 公网直连 / 中继）。
    public var path: String?
    /// 连着时才知道：那台 Mac 上的 uTerm 支不支持文件访问。
    public var supportsFiles: Bool?
}

nonisolated public struct ControlMacMatch: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int
    public var text: String
    public var before: [String]?
    public var after: [String]?
}

nonisolated public struct ControlMacEntry: Codable, Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    /// ISO8601。
    public var modifiedAt: String
    public var permissions: Int
    public var sha256: String?
}

nonisolated public struct ControlMacPayload: Codable, Sendable, Equatable {
    public var macs: [ControlMacSnapshot]?
    /// 这次动作落在哪台 Mac 上。
    public var name: String?
    /// 解析后的绝对路径。
    public var path: String?
    public var matches: [ControlMacMatch]?
    public var found: [ControlMacEntry]?
    /// 目录树、按行读回来的正文、补丁的输出。
    public var text: String?
    /// 正文不是 UTF-8 时。
    public var base64: String?
    public var sha256: String?
    public var count: Int?
    public var totalLines: Int?
    public var bytes: Int64?
    public var totalBytes: Int64?
    public var files: Int?
    public var directories: Int?
    public var names: [String]?
    public var truncated: Bool?
    public var timedOut: Bool?

    public init() {}
}
