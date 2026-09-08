import UAppKitBridge
import UDesignKit
import SwiftUI
import SwiftData

/// 端口转发列表主体（设计稿 `pages/port-forwarding.jsx` 的工具栏 + 列表区）。
///
/// 工具栏：`UDSegmented` 类型过滤（全部 / 本地 / 远程 / 动态 + 各类型计数）+
/// 「N 活跃」/「N 异常」汇总点（读 `coordinator`）+「新建」按钮。列表：边框圆角
/// 容器内一列 `TunnelRow`；为空时显 `PFEmptyState`。
///
/// CRUD 走 `modelContext` + `ForwardingRuleStore`（仿 `GroupsManagerView`）；行开关
/// 触发 `coordinator.start/stop`，状态由 `coordinator.status(rule.id)` 驱动行外观。
struct PortForwardListView: View {
    let server: ServerProfile
    let rules: [ForwardingRule]
    /// 单一共享的 host-key relay —— 由 `PortForwardWindowView` 拥有并绑定到
    /// `.hostKeySheet`，下传到此处，使 toggle/retry 触发的连接（若需主机密钥审批）
    /// 也能弹出同一张 sheet。**不要**在本视图里另起一个 relay（否则审批挂起、不可见）。
    let hostKeyRelay: HostKeyChallengeRelay

    @Environment(\.modelContext) private var modelContext
    @Environment(ForwardingCoordinator.self) private var coordinator

    /// 编辑器目标：nil = 关闭；.new = 新建；.rule(r) = 编辑既有规则。
    enum EditTarget: Identifiable {
        case new
        case rule(ForwardingRule)
        var id: String {
            switch self {
            case .new: return "new"
            case .rule(let rule): return rule.id.uuidString
            }
        }
    }

    @State private var filter: ForwardKind?   // nil = 全部
    @State private var editing: EditTarget?
    @State private var confirmDelete: ForwardingRule?
    // host-key relay 由 PortForwardWindowView 通过 init 传入（见上 `let hostKeyRelay`），
    // 不在此处用 @State 新建 —— 必须与绑定到 .hostKeySheet 的那一个是同一实例。

    private var store: ForwardingRuleStore { ForwardingRuleStore(context: modelContext) }

    private var visible: [ForwardingRule] {
        guard let filter else { return rules }
        return rules.filter { $0.kind == filter }
    }

    /// 工具栏要的全部计数，**一遍扫完**。
    ///
    /// 改前是五次独立的 `rules.filter`：活跃数、异常数、以及三个类型各一次；活跃 / 异常
    /// 那两次还各自把每条规则的状态查一遍。合并后每条规则只查一次状态、只走一遍数组。
    private struct ToolbarCounts {
        var active = 0
        var error = 0
        var byKind: [ForwardKind: Int] = [:]
    }

    private var toolbarCounts: ToolbarCounts {
        var counts = ToolbarCounts()
        for rule in rules {
            counts.byKind[rule.kind, default: 0] += 1
            switch coordinator.status(rule.id) {
            case .active: counts.active += 1
            case .error:  counts.error += 1
            case .inactive, .starting: break
            }
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar(toolbarCounts)
            Rectangle().fill(UD.border).frame(height: 1)
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { editorOverlay }
        .overlay { deleteOverlay }
    }

    // MARK: - 工具栏

    private func toolbar(_ counts: ToolbarCounts) -> some View {
        HStack(spacing: 12) {
            UDSegmented(selection: $filter, options: [
                (value: ForwardKind?.none, label: "全部 \(rules.count)"),
                (value: ForwardKind?.some(.local), label: "本地 \(counts.byKind[.local] ?? 0)"),
                (value: ForwardKind?.some(.remote), label: "远程 \(counts.byKind[.remote] ?? 0)"),
                (value: ForwardKind?.some(.dynamic), label: "动态 \(counts.byKind[.dynamic] ?? 0)")
            ])

            Spacer(minLength: 0)

            summaryDot(color: counts.active > 0 ? UD.success : UD.text4,
                       text: "\(counts.active) 活跃",
                       tint: UD.text3)
            if counts.error > 0 {
                summaryDot(color: UD.danger,
                           text: "\(counts.error) 异常",
                           tint: UD.danger)
            }

            UDButton(title: "新建", style: .primary, systemImage: "plus") {
                beginEdit(.new)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summaryDot(color: Color, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tint)
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        let visible = self.visible
        ScrollView {
            if visible.isEmpty {
                PFEmptyState(kind: filter) { beginEdit(.new) }
                    .padding(.top, 8)
            } else if visible.count > PortForwardListLayout.lazyRowThreshold {
                // 规则多到几屏以上才走懒栈（小规模档换懒栈反而更慢，见
                // `PortForwardListLayout.lazyRowThreshold` 的实测数字）。
                LazyVStack(spacing: 0) { rows(visible) }
                    .background(UD.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
                    // 滚动期间关掉行 hover（`TunnelRow` 的编辑 / 删除同样是
                    // 悬停才建的真控件）。见 `UAppKitBridge/ScrollHoverGate.swift`。
                    .scrollHoverGate()
            } else {
                VStack(spacing: 0) { rows(visible) }
                    .background(UD.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
                    .scrollHoverGate()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func rows(_ visible: [ForwardingRule]) -> some View {
        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, rule in
            TunnelRow(
                rule: rule,
                status: coordinator.status(rule.id),
                recentIssue: coordinator.connectionIssue(rule.id)?.reason,
                isLast: idx == visible.count - 1,
                onToggle: { toggle(rule) },
                onRetry: { retry(rule) },
                onChangePort: { beginEdit(.rule(rule)) },
                onEdit: { beginEdit(.rule(rule)) },
                onDelete: { requestDelete(rule) }
            )
        }
    }

    // MARK: - 弹层

    @ViewBuilder
    private var editorOverlay: some View {
        if let editing {
            ForwardEditorSheet(
                server: server,
                existing: { if case .rule(let rule) = editing { return rule } else { return nil } }(),
                allRules: rules.map { $0.snapshot },
                onCancel: { self.editing = nil },
                onSave: { draft in save(draft); self.editing = nil }
            )
        }
    }

    @ViewBuilder
    private var deleteOverlay: some View {
        if let rule = confirmDelete {
            PortForwardDeleteConfirm(
                rule: rule.snapshot,
                onCancel: { confirmDelete = nil },
                onConfirm: {
                    coordinator.stop(rule.id)
                    store.delete(rule)
                    confirmDelete = nil
                }
            )
        }
    }

    // MARK: - 动作

    /// 打开编辑器（新建 / 编辑）。已有任一弹层时忽略——保证连点 / 双击不会让
    /// `editing` 在一拍内反复横跳（见 TunnelRow 双击手势的根因注释）。
    private func beginEdit(_ target: EditTarget) {
        guard editing == nil, confirmDelete == nil else { return }
        editing = target
    }

    /// 请求删除确认。同样的幂等守卫：弹层已开则忽略。
    private func requestDelete(_ rule: ForwardingRule) {
        guard editing == nil, confirmDelete == nil else { return }
        confirmDelete = rule
    }

    private func toggle(_ rule: ForwardingRule) {
        // error 行的开关被红「异常」chip 取代，不会走到这里（防御性再判一次）。
        if case .error = coordinator.status(rule.id) { return }
        if coordinator.status(rule.id) == .active {
            coordinator.stop(rule.id)
        } else {
            coordinator.start(rule.snapshot, on: server,
                              relay: hostKeyRelay, modelContainer: modelContext.container)
        }
    }

    private func retry(_ rule: ForwardingRule) {
        coordinator.retry(rule.snapshot, on: server,
                          relay: hostKeyRelay, modelContainer: modelContext.container)
    }

    /// 保存草稿：编辑既有规则就地改字段；新建则插入并分配 sortOrder。
    private func save(_ draft: ForwardEditorDraft) {
        if let existing = draft.editingID.flatMap({ id in rules.first { $0.id == id } }) {
            existing.name = draft.name
            existing.typeRaw = draft.kind.rawValue
            existing.listenHost = draft.listenHost
            existing.listenPort = draft.listenPort
            existing.destHost = draft.destHost
            existing.destPort = draft.destPort
            existing.autostart = draft.autostart
            try? modelContext.save()
            // 改配置后停掉旧隧道，让用户重新开启（避免旧端口残留）。
            coordinator.stop(existing.id)
        } else {
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
