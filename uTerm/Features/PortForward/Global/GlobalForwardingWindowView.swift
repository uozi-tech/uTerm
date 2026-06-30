import SwiftUI
import SwiftData

/// 全局端口转发窗口（单实例，跨主机统一管理面）。对齐原型 `pages/global-forwards.jsx`：
/// 自上而下 = 自绘标题栏 → 启动自动化横幅 → 汇总条 → 按主机分组的规则列表。
///
/// 与单主机 `PortForwardWindowView` 共享同一份 `ForwardingRule`（SwiftData）与 `ForwardingCoordinator`
/// 运行态：任一处增删改 / 起停隧道即时双向反映。本页只是「全部规则」的视图 + 应用级自启编排。
struct GlobalForwardingWindowView: View {
    @Query(sort: \ServerProfile.sortOrder) private var profiles: [ServerProfile]
    @Query(sort: \ForwardingRule.sortOrder) private var rules: [ForwardingRule]
    @Environment(\.modelContext) private var modelContext
    @Environment(ForwardingCoordinator.self) private var coordinator
    @Environment(GlobalForwardingModel.self) private var model
    @Environment(HostKeyChallengeRelay.self) private var relay

    /// 每条规则的展示流量（累计 + 速率），由下方 1s 轮询刷新。
    @State private var traffic: [UUID: GFTrafficStat] = [:]
    /// 上一次拉到的累计字节，用来算每秒速率。
    @State private var lastBytes: [UUID: TunnelBytes] = [:]
    /// 当前正在编辑配置的规则（nil = 关闭）。全局面板只编辑既有规则；新建仍在单主机页。
    @State private var editing: GFEditTarget?

    /// 编辑器目标：携带规则与其所属主机（编辑器需 `ServerProfile` 做端口冲突校验 / 重启）。
    /// `rule == nil` = 在该主机上**新建**一条转发。
    struct GFEditTarget {
        let rule: ForwardingRule?
        let server: ServerProfile
    }

    // MARK: - 派生数据

    private var groups: [GFGroup<ServerProfile, ForwardingRule>] {
        gfGroupByHost(hosts: profiles, rules: rules,
                      hostID: { $0.id }, ruleServerID: { $0.serverID })
    }

    private var summary: GFSummary {
        gfSummary(statuses: rules.map { coordinator.status($0.id) },
                  launchFlags: rules.map(\.launchAtAppStart))
    }

    /// 标记自启的规则 + 其主机（手动「重新连接」用）。按 `groups` 顺序展开 —— 序列推进
    /// 顺序与列表自上而下一致，过程态芯片才会按视觉顺序逐条点亮（规则的全局 sortOrder
    /// 是按主机各自计数的，直接 filter 会跨主机交错）。孤儿规则随 `groups` 一并被丢弃。
    private var launchItems: [GlobalForwardingModel.LaunchItem] {
        groups.flatMap { group in
            group.rules.filter(\.launchAtAppStart).map {
                GlobalForwardingModel.LaunchItem(rule: $0.snapshot, server: group.host)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlobalForwardingTitleBar(hostCount: groups.count)
            StartupAutomationBanner(
                model: model,
                launchCount: summary.launchTotal,
                upCount: summary.upCount,
                failCount: summary.failCount,
                onReconnect: reconnectAll)
            summaryStrip
            listBody
        }
        .frame(minWidth: 680, minHeight: 560)
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "全局端口转发"))
        .hostKeySheet(relay)
        .overlay { editorOverlay }
        .task { await pollTraffic() }
    }

    /// 每秒拉一次累计字节快照，与上次做差得到速率，刷新 `traffic`。窗口可见时运行，
    /// 关闭即随 `.task` 取消。`-L`/`-D` 有数；`-R` 恒 0（UI 标「不统计」）。
    private func pollTraffic() async {
        let clock = ContinuousClock()
        var lastTick = clock.now
        while !Task.isCancelled {
            let now = await coordinator.trafficSnapshot()
            // 按**真实**间隔算速率（不是假定 1s）—— 快照 await + 调度抖动 + 休眠/唤醒间隙都会
            // 让两次采样间隔 >1s；除以实测秒数，`/s` 才名副其实，长间隙后也不会把多秒增量误标成一秒。
            let tick = clock.now
            let d = tick - lastTick
            let elapsed = max(0.25, Double(d.components.seconds)
                              + Double(d.components.attoseconds) * 1e-18)
            lastTick = tick
            var stats: [UUID: GFTrafficStat] = [:]
            for (id, bytes) in now {
                let prev = lastBytes[id]
                // 计数器在隧道重启时会清零 → 差为负时按 0（不显示虚假尖峰）。
                let upDelta = prev.map { bytes.up >= $0.up ? bytes.up - $0.up : 0 } ?? 0
                let downDelta = prev.map { bytes.down >= $0.down ? bytes.down - $0.down : 0 } ?? 0
                stats[id] = GFTrafficStat(
                    up: bytes.up, down: bytes.down,
                    upRate: UInt64(Double(upDelta) / elapsed),
                    downRate: UInt64(Double(downDelta) / elapsed))
            }
            lastBytes = now
            traffic = stats
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - 汇总条

    private var summaryStrip: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(summary.activeTotal > 0 ? UD.success : UD.text4)
                    .frame(width: 6, height: 6)
                Text("\(summary.activeTotal) 条隧道活跃")
            }
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(UD.accent)
                Text("\(summary.launchTotal) 条保持连接")
            }
            Spacer()
            if !profiles.isEmpty { newForwardMenu }
            Text("共 \(summary.ruleTotal) 条规则")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(UD.text3)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    /// 「新建」：列出全部主机，选一台 = 在该主机上新建转发（开既有 ForwardEditorSheet，
    /// 含 -L/-R/-D 三种）。全局面板跨主机，故新建须先选主机；该主机的跳板机 / 连接细节仍在
    /// 其「服务器」表单里配（jumpHost 是连接级共享设置，不在单条转发里改）。
    private var newForwardMenu: some View {
        Menu {
            ForEach(profiles) { p in
                Button(p.name.isEmpty ? p.host : p.name) { beginNew(on: p) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("新建").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(UD.accent)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(UD.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UD.accent.opacity(0.3), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 分组列表

    @ViewBuilder
    private var listBody: some View {
        ScrollView {
            if groups.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(groups, id: \.host.id) { group in
                        groupSection(group)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
        }
    }

    private func groupSection(_ group: GFGroup<ServerProfile, ForwardingRule>) -> some View {
        let host = group.host
        let online = isHostOnline(host.id)
        let activeN = group.rules.filter { coordinator.status($0.id) == .active }.count
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    if online { Circle().fill(UD.success.opacity(0.18)).frame(width: 12, height: 12) }
                    Circle().fill(online ? UD.success : UD.text4).frame(width: 6, height: 6)
                }
                .frame(width: 12, height: 12)
                Text(host.name.isEmpty ? host.host : host.name)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UD.text)
                Text(host.host).font(UD.mono(11)).foregroundStyle(UD.text4)
                if !online {
                    Text("未连接")
                        .font(.system(size: 10.5)).foregroundStyle(UD.text3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(UD.border, lineWidth: 1))
                }
                Spacer()
                Text("\(activeN)/\(group.rules.count) 活跃")
                    .font(.system(size: 11)).foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 7)

            VStack(spacing: 0) {
                ForEach(Array(group.rules.enumerated()), id: \.element.id) { idx, rule in
                    GlobalForwardRow(rule: rule, server: host, relay: relay,
                                     isLast: idx == group.rules.count - 1,
                                     traffic: traffic[rule.id],
                                     onEdit: { beginEdit(rule, on: host) })
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 28)).foregroundStyle(UD.text4)
            Text("还没有端口转发规则")
                .font(.system(size: 14)).foregroundStyle(UD.text2)
            Text("在某台主机的「端口转发」窗口里新建规则，再回到这里统一管理与自启。")
                .font(.system(size: 11.5)).foregroundStyle(UD.text4)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 40)
    }

    // MARK: - 逻辑

    /// 「在线」= 该主机名下有任一隧道处于 active/starting（无 app 级可达性标志，故以运行态为准）。
    private func isHostOnline(_ hostID: UUID) -> Bool {
        for r in rules where r.serverID == hostID {
            switch coordinator.status(r.id) {
            case .active, .starting: return true
            default: continue
            }
        }
        return false
    }

    private func reconnectAll() {
        model.runSequence(items: launchItems, coordinator: coordinator,
                          relay: relay, container: modelContext.container)
    }

    // MARK: - 编辑配置

    @ViewBuilder
    private var editorOverlay: some View {
        if let editing {
            ForwardEditorSheet(
                server: editing.server,
                existing: editing.rule,
                // 端口冲突校验只针对**同一主机**的规则（监听端口冲突是主机本地的事）。
                allRules: rules.filter { $0.serverID == editing.server.id }.map(\.snapshot),
                onCancel: { self.editing = nil },
                onSave: { draft in
                    save(draft, on: editing.server)
                    self.editing = nil
                }
            )
        }
    }

    /// 打开编辑器（编辑既有 / 新建）。已开则忽略（幂等守卫，防双击在一拍内反复横跳，见 TunnelRow）。
    private func beginEdit(_ rule: ForwardingRule, on server: ServerProfile) {
        guard editing == nil else { return }
        editing = GFEditTarget(rule: rule, server: server)
    }

    /// 在指定主机上新建一条转发（来自「新建」菜单选主机）。
    private func beginNew(on server: ServerProfile) {
        guard editing == nil else { return }
        editing = GFEditTarget(rule: nil, server: server)
    }

    /// 保存草稿。编辑既有：就地写字段 + 持久化；若「保持连接」则用新配置**重启**隧道立即生效，
    /// 否则只断开旧隧道（避免旧端口残留）。新建：插入新规则并分配 sortOrder（与单主机页一致，
    /// 默认不自动起 —— 用户在行上点「保持连接」再建立）。
    private func save(_ draft: ForwardEditorDraft, on server: ServerProfile) {
        if let id = draft.editingID, let rule = rules.first(where: { $0.id == id }) {
            rule.name = draft.name
            rule.typeRaw = draft.kind.rawValue
            rule.listenHost = draft.listenHost
            rule.listenPort = draft.listenPort
            rule.destHost = draft.destHost
            rule.destPort = draft.destPort
            rule.autostart = draft.autostart
            try? modelContext.save()
            coordinator.stop(rule.id)
            if rule.launchAtAppStart {
                coordinator.start(rule.snapshot, on: server,
                                  relay: relay, modelContainer: modelContext.container)
            }
        } else {
            let store = ForwardingRuleStore(context: modelContext)
            let rule = ForwardingRule(
                serverID: server.id,
                name: draft.name,
                kind: draft.kind,
                listenHost: draft.listenHost,
                listenPort: draft.listenPort,
                destHost: draft.destHost,
                destPort: draft.destPort,
                destLabel: nil,
                autostart: draft.autostart,
                sortOrder: store.nextSortOrder(forServer: server.id))
            store.add(rule)
        }
    }
}

// MARK: - 标题栏

/// 自绘标题栏（替代系统 toolbar，镜像 `PortForwardTitleBar`）：左让位红绿灯，居中
/// 「全局端口转发」+ `· N 台主机`(mono)。38pt 扁平 `WindowDragHandle` 实色底 + 底部 1px 描边。
struct GlobalForwardingTitleBar: View {
    let hostCount: Int

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Text("全局端口转发")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                Text("· \(hostCount) 台主机")
                    .font(UD.mono(12)).foregroundStyle(UD.text3)
            }
            HStack(spacing: 0) { Color.clear.frame(width: 68); Spacer() }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }
}

// MARK: - 启动自动化横幅

/// 顶部强调色淡底卡：闪电徽章 + 「uTerm 启动时自动建立隧道」+ 随状态变化的副文案 +
/// 右侧主开关（`autoStartEnabled`）。运行中显小转圈「运行中」；完成且有失败时显「重新连接」。
struct StartupAutomationBanner: View {
    @Bindable var model: GlobalForwardingModel
    let launchCount: Int
    let upCount: Int
    let failCount: Int
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(UD.accentSoft)
                RoundedRectangle(cornerRadius: 9).strokeBorder(UD.accent.opacity(0.35), lineWidth: 1)
                Image(systemName: "bolt.fill").font(.system(size: 15)).foregroundStyle(UD.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("uTerm 启动时自动建立隧道")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                subtitle.font(.system(size: 11.5))
            }

            Spacer()

            if model.phase == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(UD.accent)
                    Text("运行中").font(.system(size: 11.5)).foregroundStyle(UD.accent)
                }
            } else if model.phase == .done, failCount > 0, model.autoStartEnabled {
                Button(action: onReconnect) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        Text("重新连接").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(UD.text2)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(UD.panelHover))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UD.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            UDToggle($model.autoStartEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(UD.accentSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch model.phase {
        case .done:
            HStack(spacing: 0) {
                Text("\(upCount) 条已建立").foregroundStyle(UD.success)
                if failCount > 0 {
                    Text(" · \(failCount) 条失败").foregroundStyle(UD.danger)
                }
            }
        case .running:
            Text("正在按顺序建立隧道…").foregroundStyle(UD.text3)
        case .idle:
            if model.autoStartEnabled {
                Text("打开 uTerm 时，\(launchCount) 条「保持连接」的隧道会自动建立").foregroundStyle(UD.text3)
            } else {
                Text("自动建立已关闭，隧道需手动开启").foregroundStyle(UD.text3)
            }
        }
    }
}
