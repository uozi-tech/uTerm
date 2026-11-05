import AgentKit
import Foundation
import SwiftData
@testable import uTermMobile

/// iOS 探针的**数据夹具**：一句话把一个内存 `ModelContainer` 撑到真实档 / 极端档，
/// 让每个屏幕的评估探针都不必连真环境。
///
/// 三条硬约束（都是踩过的坑，改之前先读）：
///
/// 1. **`cloudKitDatabase: .none` 必须显式写**。宿主 `MobileModelContainer` 走
///    `.automatic`（模拟器上必然回退，见 README 坑③），但**夹具自己建的容器不能靠回退**：
///    `NSPersistentCloudKitContainer` 一旦被建起来，它的 setup / recoverFromError 会把
///    一条本来 100ms 的用例拖到 100 秒（uTable 那边同源的教训）。
/// 2. **`isStoredInMemoryOnly: true`**。落盘会跟宿主 app 自己的
///    `Application Support/default.store` 打架，且跨用例互相污染。
/// 3. **播种后必须 `save()`**。SwiftData 的 `@Query` 读的是已落定的快照，
///    只 `insert` 不 `save` 的话视图里一条都看不见（uTable 同源教训）。
///
/// 确定性：所有随机取值走 `SplitMix64`（`Seed.seedValue` 起头），
/// 同一份 `Seed` 每次播出的数据完全一致——探针的前→后对照才有意义。
///
/// 用法见 `uTermMobileTests/README.md` 的「造数据夹具」一节。
enum MobileFixtures {

    // MARK: - 档位

    /// 一次播种的全部规模参数。改这里而不是改 `populate` 的实现。
    struct Seed: Sendable {
        /// `ServerProfile` 台数。
        var servers: Int
        /// `ServerGroup` 组数（组名即成员键，写进 `ServerProfile.group`）。
        var groups: Int
        /// `SSHKey` 把数。
        var keys: Int
        /// `QuickCommand` 条数。
        var commands: Int
        /// `QuickCommandRun` 条数（全部落在 `runWindowDays` 天窗口内）。
        var runs: Int
        /// `ChatSession` 条数（`updatedAt` 严格递减，最新的在最前）。
        var sessions: Int
        /// 每条会话的 `ChatMessageRecord` 条数（user / assistant 交替）。
        var messagesPerSession: Int
        /// `KnownHost` 条数（指纹页）。
        var knownHosts: Int
        /// `ForwardingRule` 条数。
        var forwardingRules: Int

        /// 「仅 SFTP」主机占比。
        var sftpOnlyRatio: Double
        /// 置顶主机占比。
        var pinnedRatio: Double
        /// 用私钥认证（`keyID` 指向某把 `SSHKey`）的主机占比 —— 密钥页
        /// `usedCount` 的非零值全靠它。
        var keyBackedRatio: Double
        /// 没有分组（`group == nil`）的主机占比。
        var ungroupedRatio: Double
        /// 走跳板机（`jumpHost` 指向另一台）的主机占比。
        var jumpHostRatio: Double

        /// 7 天内连接过的主机占比（欢迎页 / 主机页「最近」段靠它有内容）。
        var recentlyConnectedRatio: Double
        /// 90 天内（但不在 7 天内）连接过的主机占比。
        var staleConnectedRatio: Double

        /// 运行日志的时间窗口（天）。产品侧 `QuickCommandStore.pruneExpiredRuns`
        /// 只保留 30 天，所以默认 30——播出窗口外的数据没有意义。
        var runWindowDays: Int
        /// 一条运行日志涉及的服务器台数上限（1...此值）。
        var maxServersPerRun: Int
        /// 整体失败（至少一台非 0 退出）的运行占比。
        var failedRunRatio: Double
        /// 带 `aiRecord` 的运行占比。
        var aiRunRatio: Double

        /// 确定性随机的起始种子。
        var seedValue: UInt64

        init(servers: Int, groups: Int, keys: Int, commands: Int, runs: Int,
             sessions: Int, messagesPerSession: Int = 8,
             knownHosts: Int? = nil, forwardingRules: Int? = nil,
             sftpOnlyRatio: Double = 0.15, pinnedRatio: Double = 0.08,
             keyBackedRatio: Double = 0.55, ungroupedRatio: Double = 0.10,
             jumpHostRatio: Double = 0.04,
             recentlyConnectedRatio: Double = 0.25, staleConnectedRatio: Double = 0.35,
             runWindowDays: Int = 30, maxServersPerRun: Int = 5,
             failedRunRatio: Double = 0.25, aiRunRatio: Double = 0.20,
             seedValue: UInt64 = 0x5EED_1CE5) {
            self.servers = servers
            self.groups = groups
            self.keys = keys
            self.commands = commands
            self.runs = runs
            self.sessions = sessions
            self.messagesPerSession = messagesPerSession
            // 指纹默认「大部分主机连过就留一条」，转发规则默认每 5 台一条。
            self.knownHosts = knownHosts ?? Int(Double(servers) * 0.8)
            self.forwardingRules = forwardingRules ?? max(1, servers / 5)
            self.sftpOnlyRatio = sftpOnlyRatio
            self.pinnedRatio = pinnedRatio
            self.keyBackedRatio = keyBackedRatio
            self.ungroupedRatio = ungroupedRatio
            self.jumpHostRatio = jumpHostRatio
            self.recentlyConnectedRatio = recentlyConnectedRatio
            self.staleConnectedRatio = staleConnectedRatio
            self.runWindowDays = runWindowDays
            self.maxServersPerRun = maxServersPerRun
            self.failedRunRatio = failedRunRatio
            self.aiRunRatio = aiRunRatio
            self.seedValue = seedValue
        }

        /// 真实档：一个运维团队用了大半年的库。100 台 / 10 组 / 20 密钥 /
        /// 50 命令 / 200 日志 / 50 会话。
        static let realistic = Seed(servers: 100, groups: 10, keys: 20, commands: 50,
                                    runs: 200, sessions: 50, messagesPerSession: 8)

        /// 极端档：故意压到产品从没设过上限的地方。2000 台 / 60 组 / 50 密钥 /
        /// 300 命令 / 3000 日志 / 1000 会话。
        /// 会话消息压到 4 条 —— 极端档要的是**会话条数**，逐条消息的极端档
        /// 归 `MobileFakeAgent.replayHistory`（200 / 1000 条）管。
        static let extreme = Seed(servers: 2000, groups: 60, keys: 50, commands: 300,
                                  runs: 3000, sessions: 1000, messagesPerSession: 4)

        /// 冒烟档：自证测试 / 快速迭代用，播种 100ms 内完成。
        static let smoke = Seed(servers: 12, groups: 3, keys: 4, commands: 5,
                                runs: 8, sessions: 4, messagesPerSession: 2)
    }

    /// 播种结果的实际条数 + 耗时。断言用这个，别再去数一遍。
    struct Counts: Sendable, Equatable {
        var servers = 0
        var groups = 0
        var keys = 0
        var commands = 0
        var runs = 0
        var sessions = 0
        var messages = 0
        var knownHosts = 0
        var forwardingRules = 0
        /// 私钥认证（`keyID != nil`）的主机数 —— 密钥页 `usedCount` 的总和。
        var keyBackedServers = 0
        /// `sftpOnly == true` 的主机数。
        var sftpOnlyServers = 0
        /// `lastConnectedAt != nil` 的主机数。
        var connectedServers = 0
        /// 至少一台失败的运行日志数。
        var failedRuns = 0
        /// 带 `aiRecord` 的运行日志数。
        var aiRuns = 0
        /// 播种耗时（毫秒，含 `save()`）。只打印，不当闸门。
        var elapsedMS: Double = 0
    }

    // MARK: - 建容 + 播种

    /// 建一个**只在内存里、不连 CloudKit** 的容器并按 `seed` 播满。
    ///
    /// 注册的 `@Model` 全集与宿主 `MobileModelContainer` 完全一致 —— 少一个
    /// 类型，`@Query` 那一侧会在运行时炸 "无法找到实体"。
    @MainActor
    static func modelContainer(seed: Seed) throws -> ModelContainer {
        let container = try emptyContainer()
        _ = populate(container, seed: seed)
        return container
    }

    /// 按 `key` 记忆化的共享容器 —— **只给只读探针用**。
    ///
    /// extreme 档一次播种 3~5.5 秒（读数见 README）。一个探针类里常常要开
    /// 4~6 个 fixture，每个都重播一遍就是半分钟的纯等待。共享一份则只付一次。
    ///
    /// 代价：容器跨用例存活，**任何往里写的用例都不能用它**（会污染后面的档）。
    /// 要写就老老实实 `modelContainer(seed:)` 现建一个。
    @MainActor
    static func shared(_ key: String, seed: Seed) throws -> ModelContainer {
        if let existing = sharedContainers[key] { return existing }
        let container = try modelContainer(seed: seed)
        sharedContainers[key] = container
        return container
    }

    @MainActor
    private static var sharedContainers: [String: ModelContainer] = [:]

    /// 建一个空的内存容器（自己控制播种时机时用）。
    @MainActor
    static func emptyContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let config = ModelConfiguration("uTermFixtures", schema: schema,
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// 与宿主同一份注册表（`ModelRegistry.types`）。
    static var modelTypes: [any PersistentModel.Type] { ModelRegistry.types }

    /// 往容器的 `mainContext` 播种（`@Query` 读的就是它），并 `save()`。
    @MainActor
    @discardableResult
    static func populate(_ container: ModelContainer, seed: Seed) -> Counts {
        let context = container.mainContext
        context.autosaveEnabled = false
        return populate(context, seed: seed)
    }

    /// 往指定 `ModelContext` 播种并 `save()`。返回实际条数与耗时。
    @MainActor
    @discardableResult
    static func populate(_ context: ModelContext, seed: Seed) -> Counts {
        let start = CFAbsoluteTimeGetCurrent()
        var rng = SplitMix64(seed: seed.seedValue)
        var counts = Counts()
        let now = Date()

        // 1) 分组：颜色走产品自己的 10 色板，前两组置顶。
        var groupNames: [String] = []
        for i in 0..<seed.groups {
            let name = Self.groupName(i)
            groupNames.append(name)
            let group = ServerGroup(name: name,
                                    colorHex: ServerGroup.palette[i % ServerGroup.palette.count],
                                    isPinned: i < 2,
                                    sortOrder: i)
            context.insert(group)
        }
        counts.groups = seed.groups

        // 2) 密钥：算法轮转（ed25519 / rsa / ecdsa 三族都出现），
        //    约 1/3 带口令，约 2/3 用过（lastUsedAt 非 nil）。
        var keys: [SSHKey] = []
        for i in 0..<seed.keys {
            let key = SSHKey()
            key.name = Self.keyName(i)
            let spec = Self.keySpec(i)
            key.typeRaw = spec.raw
            key.bits = spec.bits
            key.comment = "\(Self.person(i % Self.people.count))@\(Self.device(i))"
            key.fingerprint = "SHA256:" + Self.base64Blob(length: 32, rng: &rng)
            key.publicKey = "\(spec.sshName) AAAA\(Self.base64Blob(length: 48, rng: &rng)) \(key.comment)"
            key.createdAt = now.addingTimeInterval(-Double(60 + i * 17) * 86_400)
            key.hasPassphrase = (i % 3 == 0)
            key.lastUsedAt = (i % 3 == 2) ? nil
                : now.addingTimeInterval(-Double(Int.random(in: 0...45, using: &rng)) * 86_400)
            context.insert(key)
            keys.append(key)
        }
        counts.keys = seed.keys

        // 3) 主机。
        var servers: [ServerProfile] = []
        for i in 0..<seed.servers {
            let profile = ServerProfile()
            profile.name = Self.serverName(i)
            profile.host = Self.serverHost(i)
            profile.port = Self.port(i)
            profile.username = Self.username(i)
            profile.sortOrder = i
            profile.createdAt = now.addingTimeInterval(-Double(seed.servers - i) * 3_600)

            if !groupNames.isEmpty, Self.roll(seed.ungroupedRatio, &rng) == false {
                profile.group = groupNames[i % groupNames.count]
            }
            profile.isPinned = Self.roll(seed.pinnedRatio, &rng)
            profile.sftpOnly = Self.roll(seed.sftpOnlyRatio, &rng)
            if profile.sftpOnly { counts.sftpOnlyServers += 1 }

            if !keys.isEmpty, Self.roll(seed.keyBackedRatio, &rng) {
                profile.authMethodRaw = AuthMethod.privateKey.rawValue
                profile.keyID = keys[i % keys.count].id
                counts.keyBackedServers += 1
            } else {
                profile.authMethodRaw = AuthMethod.password.rawValue
            }

            // lastConnectedAt 的三档分布：最近 7 天 / 8~90 天 / 从没连过。
            if Self.roll(seed.recentlyConnectedRatio, &rng) {
                profile.lastConnectedAt = now.addingTimeInterval(
                    -Double(Int.random(in: 0..<(7 * 86_400), using: &rng)))
                counts.connectedServers += 1
            } else if Self.roll(seed.staleConnectedRatio, &rng) {
                profile.lastConnectedAt = now.addingTimeInterval(
                    -Double(Int.random(in: (8 * 86_400)..<(90 * 86_400), using: &rng)))
                counts.connectedServers += 1
            }

            context.insert(profile)
            servers.append(profile)
        }
        counts.servers = seed.servers

        // 跳板机：指向排在自己前面的某一台（避免自引用成环）。
        if servers.count > 1 {
            for i in 1..<servers.count where Self.roll(seed.jumpHostRatio, &rng) {
                servers[i].jumpHost = servers[Int.random(in: 0..<i, using: &rng)]
            }
        }

        // 4) 快捷命令：绑定 1...4 台（多台 · 并行），约 1/4 开 AI 介入。
        var commands: [QuickCommand] = []
        for i in 0..<seed.commands {
            let bound = min(servers.count, 1 + Int.random(in: 0...3, using: &rng))
            var ids: [UUID] = []
            for _ in 0..<bound where !servers.isEmpty {
                ids.append(servers[Int.random(in: 0..<servers.count, using: &rng)].id)
            }
            let ai = (i % 4 == 1)
            let spec = Self.commandSpec(i)
            let cmd = QuickCommand(name: spec.name,
                                   serverIDs: Array(Set(ids)),
                                   command: ai && i % 8 == 1 ? "" : spec.command,
                                   intent: ai ? spec.intent : "",
                                   aiAssisted: ai,
                                   sortOrder: i,
                                   createdAt: now.addingTimeInterval(-Double(i) * 7_200))
            context.insert(cmd)
            commands.append(cmd)
        }
        counts.commands = seed.commands

        // 5) 运行日志：全部落在 runWindowDays 窗口内，成功 / 失败混合，
        //    results / aiRecord 走真实 JSON 编码（不是手糊字符串）。
        let window = Double(seed.runWindowDays) * 86_400
        for i in 0..<seed.runs where !commands.isEmpty {
            let cmd = commands[i % commands.count]
            let pool = cmd.serverIDs.isEmpty
                ? servers.prefix(1).map(\.id)
                : cmd.serverIDs
            let lanes = max(1, min(seed.maxServersPerRun, pool.count))
            let shouldFail = Self.roll(seed.failedRunRatio, &rng)
            var results: [QuickCommandServerResult] = []
            for lane in 0..<lanes {
                let sid = pool[lane % pool.count]
                let profile = servers.first { $0.id == sid }
                // 失败的那一次里只让第一台挂，其余成功——真实排障日志就是这个形状。
                let ok = !(shouldFail && lane == 0)
                results.append(QuickCommandServerResult(
                    serverID: sid,
                    serverName: profile?.name ?? "host-\(lane)",
                    endpoint: profile.map { "\($0.username)@\($0.host):\($0.port)" } ?? "root@10.0.0.\(lane):22",
                    exitCode: ok ? 0 : [1, 2, 127, 137].randomElement(using: &rng)!,
                    durationMs: Int.random(in: 120...9_800, using: &rng),
                    ok: ok))
            }
            let ai: QuickCommandAIRecord? = Self.roll(seed.aiRunRatio, &rng)
                ? QuickCommandAIRecord(
                    summary: "第 \(i) 次运行：\(shouldFail ? "首台失败，已定位到磁盘水位" : "全部成功，无需处置")。",
                    steps: (0..<Int.random(in: 2...5, using: &rng)).map { "步骤 \($0 + 1)：检查 \(Self.checkTarget($0))" })
                : nil
            let run = QuickCommandRun(
                commandID: cmd.id,
                startedAt: now.addingTimeInterval(-Double.random(in: 0..<window, using: &rng)),
                durationMs: results.map(\.durationMs).max() ?? 0,
                results: results,
                aiRecord: ai)
            context.insert(run)
            counts.runs += 1
            if shouldFail { counts.failedRuns += 1 }
            if ai != nil { counts.aiRuns += 1 }
        }

        // 6) 会话：updatedAt 严格递减（`@Query(sort: .updatedAt, order: .reverse)`
        //    正好按插入顺序出来），每条挂 messagesPerSession 条消息。
        for i in 0..<seed.sessions {
            let created = now.addingTimeInterval(-Double(i) * 3_600 - 600)
            let session = ChatSession(title: Self.sessionTitle(i), createdAt: created)
            session.updatedAt = now.addingTimeInterval(-Double(i) * 3_600)
            context.insert(session)
            var records: [ChatMessageRecord] = []
            for m in 0..<seed.messagesPerSession {
                let isUser = m % 2 == 0
                let record = ChatMessageRecord(
                    roleRaw: isUser ? "user" : "assistant",
                    text: isUser ? MobileFakeAgent.userText(index: i * 100 + m)
                                 : MobileFakeAgent.assistantMarkdown(index: i * 100 + m, blocks: 6),
                    orderIndex: m,
                    createdAt: created.addingTimeInterval(Double(m) * 20))
                record.session = session
                context.insert(record)
                records.append(record)
                counts.messages += 1
            }
            session.messages = records
        }
        counts.sessions = seed.sessions

        // 7) 指纹（KnownHost）。
        for i in 0..<seed.knownHosts {
            let known = KnownHost()
            let profile = servers.isEmpty ? nil : servers[i % servers.count]
            known.host = profile?.host ?? Self.serverHost(i)
            known.port = profile?.port ?? 22
            known.keyTypeRaw = ["ssh-ed25519", "rsa-sha2-256", "ecdsa-sha2-nistp256"][i % 3]
            known.keyBlob = Self.blob(length: 32, rng: &rng)
            known.fingerprint = "SHA256:" + Self.base64Blob(length: 32, rng: &rng)
            known.firstTrustedAt = now.addingTimeInterval(-Double(i) * 5_400 - 3_600)
            context.insert(known)
        }
        counts.knownHosts = seed.knownHosts

        // 8) 转发规则：local / remote / dynamic 三种都出现。
        for i in 0..<seed.forwardingRules {
            let profile = servers.isEmpty ? nil : servers[i % servers.count]
            let kind = ForwardKind.allCases[i % ForwardKind.allCases.count]
            let rule = ForwardingRule(
                serverID: profile?.id ?? UUID(),
                name: Self.forwardName(i, kind: kind),
                kind: kind,
                listenHost: "127.0.0.1",
                listenPort: 10_000 + i,
                destHost: kind.needsDest ? "10.\(i % 250).0.\(1 + i % 250)" : nil,
                destPort: kind.needsDest ? [5432, 3306, 6379, 8080, 9200][i % 5] : 0,
                destLabel: kind.needsDest ? Self.forwardDestLabel(i) : nil,
                autostart: i % 4 == 0,
                sortOrder: i,
                launchAtAppStart: i % 7 == 0)
            context.insert(rule)
        }
        counts.forwardingRules = seed.forwardingRules

        // **必须 save()**：只 insert 的话 `@Query` 一条都读不到（见文件头约束 3）。
        try? context.save()

        counts.elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return counts
    }

    // MARK: - 取一条现成的数据（探针挂载时要真的 model 对象）

    /// 取排序最前的一台主机。播种后必然非 nil。
    @MainActor
    static func firstServer(in container: ModelContainer) -> ServerProfile? {
        var descriptor = FetchDescriptor<ServerProfile>(
            sortBy: [SortDescriptor(\ServerProfile.sortOrder)])
        descriptor.fetchLimit = 1
        return (try? container.mainContext.fetch(descriptor))?.first
    }

    /// 计数（自证测试与探针共用；`@Query` 之外的第二个证人）。
    @MainActor
    static func count<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) -> Int {
        (try? container.mainContext.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    // MARK: - 名字与取值（都要「长短混合」，排版成本才进得了账）

    static let people = ["sz", "bobby", "ops", "alice", "wei", "deploy-bot", "li.si"]

    private static func person(_ i: Int) -> String { people[i % people.count] }
    private static func device(_ i: Int) -> String {
        ["laptop", "mbp-16", "ci-runner", "工位台式机", "iphone"][i % 5] + (i > 4 ? "-\(i)" : "")
    }

    private static func groupName(_ i: Int) -> String {
        let base = ["生产", "预发", "测试", "数据库", "网关", "监控", "存储", "边缘节点", "内网工具", "灾备"]
        if i < base.count { return base[i] }
        return "\(base[i % base.count])-\(i / base.count + 1)"
    }

    private static func keyName(_ i: Int) -> String {
        let base = ["个人主力", "生产只读", "CI 部署", "id_ed25519_backup",
                    "老 RSA（待淘汰）", "跳板机专用", "客户 A 交付"]
        if i < base.count { return base[i] }
        return "\(base[i % base.count]) \(i)"
    }

    private static func keySpec(_ i: Int) -> (raw: String, bits: Int, sshName: String) {
        switch i % 5 {
        case 0: return ("ed25519", 256, "ssh-ed25519")
        case 1: return ("rsa", 4096, "ssh-rsa")
        case 2: return ("ecdsaP256", 256, "ecdsa-sha2-nistp256")
        case 3: return ("rsa", 2048, "ssh-rsa")
        default: return ("ecdsaP384", 384, "ecdsa-sha2-nistp384")
        }
    }

    /// 主机名：短名 / 中名 / 长名 / 中文名混排 —— 单行截断与自适应宽度的成本
    /// 只有在名字长度真的散开时才量得准。
    private static func serverName(_ i: Int) -> String {
        switch i % 6 {
        case 0: return "web-\(String(format: "%02d", i % 100))"
        case 1: return "db-shard-\(i % 32)"
        case 2: return "k8s-worker-node-\(i)-cn-hangzhou-\(["a", "b", "c"][i % 3])"
        case 3: return "杭州机房 · 网关 \(i)"
        case 4: return "cache\(i)"
        default: return "bastion-prod-\(i)-\(["sh", "bj", "sz", "hk", "sg"][i % 5])"
        }
    }

    private static func serverHost(_ i: Int) -> String {
        switch i % 4 {
        case 0: return "10.\(i / 250 % 250).\(i % 250).\(1 + i % 250)"
        case 1: return "node-\(i).internal.example.com"
        case 2: return "172.16.\(i % 250).\(1 + (i * 7) % 250)"
        default: return "\(["sh", "bj", "sz"][i % 3])-\(i).prod.example.net"
        }
    }

    private static func port(_ i: Int) -> Int {
        [22, 22, 22, 2222, 22, 60022][i % 6]
    }

    private static func username(_ i: Int) -> String {
        ["root", "ubuntu", "deploy", "ops", "admin", "ec2-user"][i % 6]
    }

    private static func commandSpec(_ i: Int) -> (name: String, command: String, intent: String) {
        let table: [(String, String, String)] = [
            ("重启 Nginx 并健康检查", "systemctl restart nginx && curl -sf localhost/healthz", "重启网关并确认健康检查通过"),
            ("看磁盘水位", "df -h | sort -k5 -r | head -20", "找出磁盘快满的挂载点并给出清理建议"),
            ("拉最近 5 分钟错误日志", "journalctl -p err --since -5min | tail -80", "分析最近的错误日志，定位根因"),
            ("清理 Docker 悬空镜像", "docker image prune -f && docker system df", "回收 Docker 占用的磁盘"),
            ("查连接数与 TIME_WAIT", "ss -s && netstat -an | grep -c TIME_WAIT", "判断连接数是否异常"),
            ("滚动重启应用", "systemctl restart app && sleep 3 && systemctl is-active app", "安全地滚动重启业务进程"),
            ("同步时间", "chronyc makestep && chronyc tracking", "确认时钟同步正常"),
            ("导出 Nginx 访问 TOP IP", "awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head", "找出刷量最凶的来源 IP"),
        ]
        let base = table[i % table.count]
        let suffix = i < table.count ? "" : " #\(i / table.count + 1)"
        return (base.0 + suffix, base.1, base.2)
    }

    private static func checkTarget(_ i: Int) -> String {
        ["磁盘水位", "内存余量", "连接数", "进程状态", "日志尾部", "证书有效期"][i % 6]
    }

    private static func sessionTitle(_ i: Int) -> String {
        let base = ["排查 5xx 突增", "为什么内存一直涨", "帮我写个清理脚本", "证书要过期了怎么办",
                    "Nginx 502 定位", "慢查询分析", "磁盘满了", "k8s pod 反复重启"]
        if i < base.count { return base[i] }
        return "\(base[i % base.count])（第 \(i / base.count + 1) 次）"
    }

    private static func forwardName(_ i: Int, kind: ForwardKind) -> String {
        switch kind {
        case .local: return "生产 PG \(i)"
        case .remote: return "回连本机预览 \(i)"
        case .dynamic: return "内网 SOCKS \(i)"
        }
    }

    private static func forwardDestLabel(_ i: Int) -> String {
        ["PostgreSQL 主库", "MySQL 只读", "Redis 缓存", "内部管理后台", "ES 集群"][i % 5]
    }

    // MARK: - 确定性随机

    /// `Bool`：以 `p` 的概率为 true。
    private static func roll(_ p: Double, _ rng: inout SplitMix64) -> Bool {
        Double.random(in: 0..<1, using: &rng) < p
    }

    private static func blob(length: Int, rng: inout SplitMix64) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for _ in 0..<length { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
        return Data(bytes)
    }

    private static func base64Blob(length: Int, rng: inout SplitMix64) -> String {
        blob(length: length, rng: &rng).base64EncodedString()
    }
}

/// SplitMix64 —— 8 行的确定性 PRNG。用它而不是系统 RNG，是为了让同一份 `Seed`
/// 每次播出**完全一致**的数据：探针的前→后对照才有意义，读数波动才只剩机器抖动。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
