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

    // MARK: 交互会话（命令行自己的后台 PTY）

    /// 列出命令行开着的交互会话。
    case sessions = "sessions"
    /// 在一台主机上开一个后台 PTY 会话（不给命令就是登录 shell）。
    case sessionStart = "session-start"
    /// 往会话里写文本 / 按键；`secret` 时由 uTerm 弹安全输入框，让用户自己输。
    case sessionSend = "session-send"
    /// 读会话自上次以来的新输出（可等到某段文字出现）。
    case sessionRead = "session-read"
    /// 关会话（远端进程随 PTY 挂断收到 SIGHUP）。
    case sessionClose = "session-close"

    // MARK: 收尾

    /// 松开 CLI 连接池对某主机的 exec / SFTP 持有。
    case disconnect = "disconnect"

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
             .sessionStart, .sessionSend:
            return true
        // `session-close` 只会让命令行自己开的会话停下来，开关关了也得能收拾残局。
        case .ping, .hosts, .hostKey, .quickCommands,
             .sftpLs, .sftpStat, .sftpCat, .sftpGet,
             .forwardList,
             .terminals, .terminalRead,
             .sessions, .sessionRead, .sessionClose,
             .disconnect:
            return false
        }
    }

    /// 主机级硬规则：`ServerProfile.sftpOnly == true` 的主机拒绝这些动作（`host_sftp_only`）。
    /// 这是用户在主机档案上做的定性，CLI 不绕。
    public var requiresExecCapableHost: Bool {
        switch self {
        // `session-send` 不在内：会话开起来时主机已经判过（`session-start`）。
        case .run, .runMany, .quickRun, .terminalSend, .terminalOpen, .sessionStart:
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
        case .sessions, .sessionStart, .sessionSend, .sessionRead, .sessionClose:
            return .session
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
    case session
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
    /// `run`：开 PTY、把客户端交来的 stdin / stdout（`SCM_RIGHTS`）直通远端，人在终端里
    /// 实时交互（`utermctl run -t`）。
    public var tty: Bool?
    /// PTY 的终端类型 / 列 / 行（`run -t`、`session-start`）。
    public var term: String?
    public var cols: Int?
    public var rows: Int?
    /// 交互会话 id 或其唯一前缀。
    public var session: String?
    /// `session-send`：按顺序追加的按键名（`enter` / `tab` / `ctrl-c` / `up` …）。
    public var keys: [String]?
    /// `session-send`：不带文本，由 uTerm 弹安全输入框让用户输（密码），输入直接写进 PTY。
    public var secret: Bool?
    /// `session-send --secret` 时给用户看的说明（为什么要输、输的是什么）。
    public var prompt: String?
    /// `session-*`：最多等多少秒（等输出静下来 / 等 `waitFor` 出现 / 等进程退出）。
    public var waitSeconds: Double?
    /// `session-*`：等到新输出里出现这段正则才返回。
    public var waitFor: String?
    /// `session-read`：额外回传虚拟终端当前画面（TUI 程序看这个）。
    public var screen: Bool?

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
        tty: Bool? = nil,
        term: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        session: String? = nil,
        keys: [String]? = nil,
        secret: Bool? = nil,
        prompt: String? = nil,
        waitSeconds: Double? = nil,
        waitFor: String? = nil,
        screen: Bool? = nil
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
        self.tty = tty
        self.term = term
        self.cols = cols
        self.rows = rows
        self.session = session
        self.keys = keys
        self.secret = secret
        self.prompt = prompt
        self.waitSeconds = waitSeconds
        self.waitFor = waitFor
        self.screen = screen
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
    /// `session-start` / `session-send` / `session-read` / `session-close`。
    public var session: ControlSessionSnapshot?
    /// `sessions`。
    public var sessions: [ControlSessionSnapshot]?

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
        session: ControlSessionSnapshot? = nil,
        sessions: [ControlSessionSnapshot]? = nil
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
        self.transfer = transfer
        self.rules = rules
        self.terminals = terminals
        self.screen = screen
        self.session = session
        self.sessions = sessions
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
        session: ControlSessionSnapshot? = nil,
        sessions: [ControlSessionSnapshot]? = nil
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
            session: session,
            sessions: sessions
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
        rules: [ControlForwardSnapshot]? = nil,
        session: ControlSessionSnapshot? = nil
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
            terminals: terminals,
            session: session
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

/// 命令行的一个交互会话（后台 PTY，不在任何窗口里）。
///
/// `output` 是**自上次读取以来**的新输出，已去掉终端控制序列、按 `\r` 覆盖收成纯文本；
/// 读过就不会再给第二次（是流，不是快照）。TUI 程序的画面看 `screen`。
nonisolated public struct ControlSessionSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var host: String
    public var hostID: String
    /// 开会话时给的命令；nil = 登录 shell。
    public var command: String?
    public var term: String
    public var cols: Int
    public var rows: Int
    /// ISO8601。
    public var startedAt: String
    public var running: Bool
    /// 进程退出后才有。被信号杀掉时 sshd 不报退出码，也会是 0。
    public var exitCode: Int?
    /// 结束原因：`exited` / `closed`（被 `session-close` 或开关关闭）/ `failed`（连接断了）/
    /// `idle_timeout`（太久没人读写，自动回收）/ `max_duration`。还在跑为 nil。
    public var endReason: String?
    public var endMessage: String?
    /// 新输出（只在 start / send / read 的响应里）。
    public var output: String?
    /// 这次的新输出超过上限，只给了最后那部分。
    public var truncated: Bool
    /// 两次读取之间输出太多、会话的缓冲装不下而被挤掉的字节数（从开始累计）。
    public var droppedBytes: Int
    /// 虚拟终端当前画面（去尾部空行），只在要求时给。
    public var screen: [String]?
    /// 光标所在行的文字（通常就是提示符：`Password:`、`$ `、`[Y/n]`）。
    public var promptLine: String?
    /// 进程还活着、输出已经静下来、且最后一行没换行 —— 多半在等输入。
    public var awaitingInput: Bool
    /// `promptLine` 像密码提示（`password` / `passphrase` / `密码` / `口令` 结尾带冒号）。
    /// 是的话用 `session send --secret` 让用户自己输，**不要**自己编密码。
    public var passwordPrompt: Bool
    /// 给了 `waitFor` 时：是否等到了。没给为 nil。
    public var matched: Bool?
    /// 距离上一次有输出过了几秒。
    public var quietSeconds: Double

    public init(
        id: String,
        host: String,
        hostID: String,
        command: String? = nil,
        term: String,
        cols: Int,
        rows: Int,
        startedAt: String,
        running: Bool,
        exitCode: Int? = nil,
        endReason: String? = nil,
        endMessage: String? = nil,
        output: String? = nil,
        truncated: Bool = false,
        droppedBytes: Int = 0,
        screen: [String]? = nil,
        promptLine: String? = nil,
        awaitingInput: Bool = false,
        passwordPrompt: Bool = false,
        matched: Bool? = nil,
        quietSeconds: Double = 0
    ) {
        self.id = id
        self.host = host
        self.hostID = hostID
        self.command = command
        self.term = term
        self.cols = cols
        self.rows = rows
        self.startedAt = startedAt
        self.running = running
        self.exitCode = exitCode
        self.endReason = endReason
        self.endMessage = endMessage
        self.output = output
        self.truncated = truncated
        self.droppedBytes = droppedBytes
        self.screen = screen
        self.promptLine = promptLine
        self.awaitingInput = awaitingInput
        self.passwordPrompt = passwordPrompt
        self.matched = matched
        self.quietSeconds = quietSeconds
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

    // 交互会话
    case session_not_found
    case session_ambiguous
    /// 命令行开着的会话已到上限（总数或单台主机），先 `session-close` 掉不用的。
    case session_limit
    /// 会话已经结束，写不进去了（响应里带结束原因与最后的输出）。
    case session_ended
    /// `session-send --secret`：用户在 uTerm 的安全输入框里点了取消 / 超时没输。
    case secret_cancelled

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

    /// `terminal-read` 默认行数与字节封顶。
    public static let defaultScreenLines = 80
    public static let maxScreenBytes = 16_000

    /// 命令行交互会话的上限：总数 / 每台主机。每台的上限卡的是 sshd 的 `MaxSessions`
    /// （默认 10，数的是**一条连接上的通道**）：会话与 `run` 的 exec 共用那条复用连接。
    public static let maxSessions = 16
    public static let maxSessionsPerHost = 4
    /// 交互会话的默认 PTY 尺寸。宽一点，少让程序按 80 列折行。
    public static let defaultSessionCols = 160
    public static let defaultSessionRows = 48
    /// `session-*` 的等待：默认 / 封顶（秒）。
    public static let defaultSessionWaitSeconds = 10.0
    public static let maxSessionWaitSeconds = 600.0
    /// 输出静下来多久算「这一波输出完了」（秒）。
    public static let sessionSettleSeconds = 0.8
    /// 一次响应里 `output` 的字节上限（超了只给最后这么多）。
    public static let maxSessionOutputBytes = 64_000
    /// 太久没有任何 `session-*` 调用碰过就自动关（秒）。
    public static let sessionIdleSeconds: TimeInterval = 30 * 60
    /// 会话总时长上限（秒）。
    public static let sessionMaxSeconds: TimeInterval = 6 * 3600
    /// 进程结束后会话还留多久，好让调用方读到最后的输出与退出码（秒）。
    public static let endedSessionRetentionSeconds: TimeInterval = 10 * 60
    /// `session-send --secret` 的输入框最多等用户多久（秒）。
    public static let secretPromptSeconds: TimeInterval = 300

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
        action == .sftpGet || action == .sftpPut
    }

    /// 这条请求占「长连接」槽位（与传输共用 `maxTransferClients`）：传输，以及
    /// `run -t` —— 人在终端里交互，一条连接可能挂几个小时，不能占着短请求的名额。
    public static func occupiesLongLivedSlot(_ request: ControlRequest) -> Bool {
        isTransfer(request.action) || (request.action == .run && request.tty == true)
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
