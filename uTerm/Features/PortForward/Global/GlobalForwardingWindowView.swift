import UDesignKit
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

    /// 编辑器目标（nil = 关闭）：编辑既有规则，或在某主机上新建。
    @State private var editing: GFEditTarget?
    /// 「新建」主机选择器（分组弹窗）是否展开。
    @State private var newPickerOpen = false

    /// 编辑器目标：携带规则与其所属主机（编辑器需 `ServerProfile` 做端口冲突校验 / 重启）。
    /// `rule == nil` = 在该主机上**新建**一条转发。
    struct GFEditTarget {
        let rule: ForwardingRule?
        let server: ServerProfile
    }

    // MARK: - 派生数据

    /// 一次 body 求值只算一遍（见 `GlobalForwardingDerived`）。改前这里是四个独立的
    /// 计算属性，`groups` 一次 body 里被算 2~3 遍、`isHostOnline` 逐组扫全表。
    private var derived: GlobalForwardingDerived {
        GlobalForwardingDerived(profiles: profiles, rules: rules, coordinator: coordinator)
    }

    var body: some View {
        // 算一次、往下传。
        let derived = self.derived
        return VStack(spacing: 0) {
            GlobalForwardingTitleBar(hostCount: derived.sections.count)
            StartupAutomationBanner(
                model: model,
                launchCount: derived.summary.launchTotal,
                upCount: derived.summary.upCount,
                failCount: derived.summary.failCount,
                onReconnect: { reconnectAll(derived.launchItems) })
            summaryStrip(derived.summary)
            // 流量轮询与列表一起下沉到 `GlobalForwardingList`：每秒那一拍只让**列表**
            // 重求，标题栏 / 横幅 / 汇总条 / 派生数据都不再跟着重算。
            GlobalForwardingList(sections: derived.sections,
                                 counts: derived.counts,
                                 relay: relay,
                                 coordinator: coordinator,
                                 onEdit: { rule, host in beginEdit(rule, on: host) })
        }
        .frame(minWidth: 680, minHeight: 560)
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "全局端口转发"))
        .hostKeySheet(relay)
        .overlay { editorOverlay }
    }

    // MARK: - 汇总条

    private func summaryStrip(_ summary: GFSummary) -> some View {
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

    /// 「新建」按钮 + 分组主机选择弹窗：选一台 = 在该主机上新建转发（开既有 ForwardEditorSheet，
    /// 含 -L/-R/-D 三种）。全局面板跨主机，故新建须先选主机；该主机的跳板机 / 连接细节仍在其
    /// 「服务器」表单里配（jumpHost 是连接级共享设置，不在单条转发里改）。
    private var newForwardMenu: some View {
        Button { newPickerOpen.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("新建").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(UD.accentInk)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(UD.accentSoft))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $newPickerOpen, arrowEdge: .bottom) { newHostPicker }
    }

    /// 新建时的主机选择弹窗：按**分组**分区列出全部主机（复用 `QuickCommandLogic.grouped` 的分组
    /// 逻辑 + `QuickCommandHostRef`，行样式对齐 `JumpHostSelectorView` 的名称 + 端点）。单选：点一台
    /// = 在其上新建转发。
    private var newHostPicker: some View {
        let refs = profiles.map {
            QuickCommandHostRef(id: $0.id, name: QuickCommandTargets.displayName($0),
                                group: $0.group, username: $0.username, host: $0.host, port: $0.port)
        }
        return VStack(spacing: 0) {
            Text("选择主机 · 新建转发")
                .font(.system(size: 10.5)).tracking(0.5).foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
            Rectangle().fill(UD.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(QuickCommandLogic.grouped(refs), id: \.group) { group in
                        Text(group.group.uppercased())
                            .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(UD.text3)
                            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        ForEach(group.hosts) { ref in newHostRow(ref) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
        .background(UD.overlay)
    }

    private func newHostRow(_ ref: QuickCommandHostRef) -> some View {
        Button {
            newPickerOpen = false
            if let p = profiles.first(where: { $0.id == ref.id }) { beginNew(on: p) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(UD.accent).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UD.text).lineLimit(1)
                    Text(ref.endpoint).font(UD.mono(11)).foregroundStyle(UD.text4).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill").font(.system(size: 12.5)).foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 空态（无任何规则时列表区显示）。列表组件复用它。
    static var emptyState: some View {
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

    private func reconnectAll(_ items: [GlobalForwardingModel.LaunchItem]) {
        model.runSequence(items: items, coordinator: coordinator,
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

// MARK: - 分组列表

/// 按主机分组的规则列表 + 每秒一次的流量轮询。
///
/// **为什么单独成一个视图**：`traffic` 每秒被整体替换一次，谁持有它谁就每秒重求一次
/// body。放在窗口根视图上时，那一拍连标题栏、启动横幅、汇总条和全部派生数据一起重算；
/// 下沉到这里之后，每秒那一拍只碰列表。
///
/// **为什么 `LazyVStack` 只包到分组这一层**：真正会长的是主机数（`@Query` 无上限），
/// 单台主机的规则数天然有限。分组一层走 lazy，屏外的主机连行都不建；组内仍是普通
/// `VStack`，圆角卡片容器 / 组内分隔线 / `isLast` 判定这些视觉契约一点没动。
/// （playbook 的反例表：小规模档换懒栈可能更慢 —— 所以只在会长的那一维上懒。）
struct GlobalForwardingList: View {
    let sections: [GFGroup<ServerProfile, ForwardingRule>]
    let counts: GFDerivedCounts
    let relay: HostKeyChallengeRelay
    let coordinator: ForwardingCoordinator
    let onEdit: (ForwardingRule, ServerProfile) -> Void

    /// 每条规则的展示流量（累计 + 速率），由下方 1s 轮询刷新。
    @State private var traffic: [UUID: GFTrafficStat] = [:]
    /// 上一次拉到的累计字节，用来算每秒速率。
    @State private var lastBytes: [UUID: TunnelBytes] = [:]

    /// 分组这一层什么时候才值得走 `LazyVStack`（按**总规则数**分档）。
    ///
    /// 「换懒栈一定更快」是错的（playbook 反例表）。本屏同轮实测：
    /// - 10 组 / 50 行：非 lazy 单帧 p95 **2.00ms**、超预算 0%；换 lazy 后 p95 **15.41ms**、超预算 9.5%。
    /// - 50 组 / 1000 行：非 lazy p95 **17.90ms**、超预算 99.5%；换 lazy 后 p95 **7.23ms**、超预算 4.0%。
    ///
    /// 所以小规模留非 lazy、大规模才懒。120 取在「四五屏」的量级（行高 52pt，
    /// 一屏约 13 行）；两档之间的确切拐点没量过，见 `docs/scroll-perf-findings.md`。
    static let lazyRowThreshold = 120

    private var totalRules: Int { sections.reduce(0) { $0 + $1.rules.count } }

    var body: some View {
        ScrollView {
            if sections.isEmpty {
                GlobalForwardingWindowView.emptyState
            } else if totalRules > Self.lazyRowThreshold {
                LazyVStack(spacing: 12) {
                    ForEach(sections, id: \.host.id) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)
            } else {
                VStack(spacing: 12) {
                    ForEach(sections, id: \.host.id) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
        }
        .task { await pollTraffic() }
    }

    private func section(_ group: GFGroup<ServerProfile, ForwardingRule>) -> some View {
        let host = group.host
        // 在线 / 活跃数直接查表（改前是逐组扫一遍全部规则，O(主机 × 规则)）。
        let online = counts.onlineHosts.contains(host.id)
        let activeN = counts.activeByHost[host.id] ?? 0
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
                        .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillFaint))
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
                                     onEdit: { onEdit(rule, host) })
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
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
            stats.reserveCapacity(now.count)
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
            // 一字未变就别写回 —— 全部隧道都闲着时（速率归零后每拍的快照完全一样），
            // 这一步省掉的是整张列表每秒一次的重求。
            if stats != traffic { traffic = stats }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - 一次 body 求值要的全部派生数据

/// 全局面板一次 body 求值要的全部派生数据，**一遍算完**。
///
/// 原来这些是四个各自独立的计算属性（`groups` / `summary` / `launchItems` / `isHostOnline`），
/// 一次 body 求值里 `groups` 被算 2~3 遍、`isHostOnline` 逐组扫全部规则
/// （O(主机数 × 规则数)）、`summary` 又把每条规则的状态查一遍。而 `pollTraffic`
/// **每秒**替换一次 `@State traffic`，整窗 body 至少每秒重求一遍 —— 这些账每秒都要还一次。
///
/// 现在：分组一遍、计数一遍（每条规则查一次状态），组头要的在线 / 活跃数直接查表。
@MainActor
struct GlobalForwardingDerived {
    let sections: [GFGroup<ServerProfile, ForwardingRule>]
    let counts: GFDerivedCounts
    let launchItems: [GlobalForwardingModel.LaunchItem]

    var summary: GFSummary { counts.summary }

    init(profiles: [ServerProfile], rules: [ForwardingRule],
         coordinator: ForwardingCoordinator) {
        sections = gfGroupByHost(hosts: profiles, rules: rules,
                                 hostID: { $0.id }, ruleServerID: { $0.serverID })
        counts = gfDerivedCounts(rules: rules,
                                 ruleServerID: { $0.serverID },
                                 status: { coordinator.status($0.id) },
                                 launchFlag: { $0.launchAtAppStart })
        // 按 `sections` 顺序展开 —— 序列推进顺序与列表自上而下一致（规则的全局
        // sortOrder 是按主机各自计数的，直接 filter 会跨主机交错）。
        launchItems = sections.flatMap { group in
            group.rules.filter(\.launchAtAppStart).map {
                GlobalForwardingModel.LaunchItem(rule: $0.snapshot, server: group.host)
            }
        }
    }

    func isOnline(_ hostID: UUID) -> Bool { counts.onlineHosts.contains(hostID) }
    func activeCount(_ hostID: UUID) -> Int { counts.activeByHost[hostID] ?? 0 }
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
