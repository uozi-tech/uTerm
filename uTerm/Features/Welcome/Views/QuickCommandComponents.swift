import SwiftUI

/// 快捷命令的共享小件与纯逻辑助手（复刻原型 `pages/quick-commands.jsx`）。
/// 纯展示组件只读 `UD` token；逻辑助手是可单测的纯函数。

// MARK: - 主机引用（解耦 @Model，便于纯函数分组 / 单测）

/// 多选用的轻量主机值快照。从 `ServerProfile` 映射而来，`Sendable`、可在纯函数里分组。
nonisolated struct QuickCommandHostRef: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let group: String?
    let username: String
    let host: String
    let port: Int

    var endpoint: String { "\(username)@\(host):\(port)" }
}

// MARK: - 目标服务器解析（统一显示名 / 端点 / 已删除占位）

/// 把命令的 `serverIDs` 解析为展示信息。集中「名为空回退主机名」与「已删除服务器」占位，
/// 避免列表行 / 详情 / 执行器各写一份且行为不一致。`@MainActor`（读 @Model 属性）。
enum QuickCommandTargets {
    static let deletedLabel = "已删除服务器"

    static func displayName(_ profile: ServerProfile) -> String {
        profile.name.isEmpty ? profile.host : profile.name
    }

    static func endpoint(_ profile: ServerProfile) -> String {
        "\(profile.username)@\(profile.host):\(profile.port)"
    }

    /// 一条解析结果（已删除的服务器 `endpoint == nil`、`exists == false`）。
    struct Resolved: Identifiable, Equatable {
        let id: UUID
        let name: String
        let endpoint: String?
        let exists: Bool
    }

    /// 按 `serverIDs` 顺序解析，未找到的服务器用占位名占位。
    static func resolve(_ serverIDs: [UUID], in hosts: [ServerProfile]) -> [Resolved] {
        serverIDs.map { id in
            if let host = hosts.first(where: { $0.id == id }) {
                return Resolved(id: id, name: displayName(host), endpoint: endpoint(host), exists: true)
            }
            return Resolved(id: id, name: deletedLabel, endpoint: nil, exists: false)
        }
    }
}

// MARK: - AI 介入开关行（详情 / 表单共用 chrome）

/// 「AI 介入」开关行：sparkles + 调用方内容 + 紫色 `UDToggle`，开启时紫色高亮底/边。
/// 详情与表单共用此 chrome，仅内容文案不同（消除两处近乎一致的重复）。
struct QCAiToggleRow<Content: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(isOn ? UD.aiAccent : UD.text3)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            UDToggle($isOn, tint: UD.aiAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isOn ? UD.aiAccent.opacity(0.07) : Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(isOn ? UD.aiAccent.opacity(0.20) : UD.border, lineWidth: 1))
    }
}

// MARK: - 纯逻辑（可单测）

nonisolated enum QuickCommandLogic {
    static let ungroupedLabel = "未分组"

    /// 按 `group` 分组（空 → 「未分组」），保持出现顺序。纯函数。
    static func grouped(_ refs: [QuickCommandHostRef]) -> [(group: String, hosts: [QuickCommandHostRef])] {
        var order: [String] = []
        var map: [String: [QuickCommandHostRef]] = [:]
        for ref in refs {
            let g = (ref.group?.isEmpty ?? true) ? ungroupedLabel : ref.group!
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(ref)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    /// 某组的三态：`all`（整组都已选）/ `some`（部分已选，含全选）。
    static func groupState(_ groupHosts: [QuickCommandHostRef], selected: Set<UUID>) -> (all: Bool, some: Bool) {
        guard !groupHosts.isEmpty else { return (false, false) }
        let picked = groupHosts.filter { selected.contains($0.id) }.count
        return (picked == groupHosts.count, picked > 0)
    }

    /// 触发器摘要：0 台 → nil；1 台名称；2 台「A、B」；更多「A 等 N 台」。
    /// 按 `refs` 顺序取已选项。
    static func selectionSummary(_ refs: [QuickCommandHostRef], selected: Set<UUID>) -> String? {
        let chosen = refs.filter { selected.contains($0.id) }
        switch chosen.count {
        case 0: return nil
        case 1: return chosen[0].name
        case 2: return "\(chosen[0].name)、\(chosen[1].name)"
        default: return "\(chosen[0].name) 等 \(chosen.count) 台"
        }
    }

    /// 运行按钮文案（复刻原型 `QcDetail.runLabel`）：多台优先显示并行，单台按 AI 区分。
    static func runLabel(serverCount: Int, ai: Bool) -> String {
        if serverCount > 1 { return "并行运行 · \(serverCount) 台" }
        return ai ? "运行 · AI 介入" : "运行命令"
    }

    /// AI 命令的「说人话」文案（复刻原型 `qcAiIntent`）：优先 `intent`（去空白），
    /// 缺失时由名称兜底成一句。列表行副标题 / 详情指令块共用，保证两处一致。
    static func aiIntentText(name: String, intent: String) -> String {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "执行「\(name)」：运行后让 AI 读取输出、自动诊断并续接下一步。"
    }

    /// AI 命令运行时交给 Agent 的预填文案：自然语言意图优先，其次等效命令，
    /// 两者皆空再兜底成一句——保证 Agent 输入框总有可读内容。
    static func agentPrefill(name: String, intent: String, command: String) -> String {
        let i = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !i.isEmpty { return i }
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        return aiIntentText(name: name, intent: "")
    }

    /// 保存校验（复刻原型 `QcForm.valid`）：名称非空 + 至少一台服务器 +
    /// （AI 时 `intent` 或 `command` 至少有一；非 AI 时 `command` 必填）。纯函数、可单测。
    static func isSaveable(name: String, hasServers: Bool,
                           command: String, intent: String, ai: Bool) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasServers else { return false }
        let hasCommand = !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasIntent = !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ai ? (hasIntent || hasCommand) : hasCommand
    }
}

// MARK: - 图标 Shapes（复刻原型自绘 SVG）

/// `>_` 终端提示符字形（chevron + 下划线），14 单位坐标系，描边绘制。
struct PromptChevronShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let s = rect.width / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 4)); path.addLine(to: p(5.6, 6.6)); path.addLine(to: p(3, 9.2))
        path.move(to: p(7.4, 9.6)); path.addLine(to: p(11, 9.6))
        return path
    }
}

/// 并行图标：两路右向箭头（14 单位坐标系）。
struct ParallelArrowsShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let s = rect.width / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // 上行
        path.move(to: p(2, 4.3)); path.addLine(to: p(9.2, 4.3))
        path.move(to: p(7.3, 2.2)); path.addLine(to: p(9.6, 4.3)); path.addLine(to: p(7.3, 6.4))
        // 下行
        path.move(to: p(2, 9.7)); path.addLine(to: p(9.2, 9.7))
        path.move(to: p(7.3, 7.6)); path.addLine(to: p(9.6, 9.7)); path.addLine(to: p(7.3, 11.8))
        return path
    }
}

/// 并行图标视图（描边）。
struct QCParallelIcon: View {
    var size: CGFloat = 11
    var color: Color = UD.success
    var body: some View {
        ParallelArrowsShape()
            .stroke(color, style: StrokeStyle(lineWidth: size * 1.2 / 14, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

// MARK: - 提示符字形图标 PromptGlyph

/// `>_` 字形图标块。AI 介入时染固定紫 `UD.aiAccent`，否则用连接强调色 `UD.accent`。
/// 圆角方块（tint 11% 底 + tint 23% 描边 + tint 字形），用于列表行 / 详情头 / 空态。
struct QCPromptGlyph: View {
    var size: CGFloat = 30
    var ai: Bool = false

    private var tint: Color { ai ? UD.aiAccent : UD.accent }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 8 / 30, style: .continuous)
            .fill(tint.opacity(0.11))
            .overlay(
                RoundedRectangle(cornerRadius: size * 8 / 30, style: .continuous)
                    .strokeBorder(tint.opacity(0.23), lineWidth: 1)
            )
            .overlay(
                PromptChevronShape()
                    .stroke(tint, style: StrokeStyle(lineWidth: size * 1.5 / 30,
                                                     lineCap: .round, lineJoin: .round))
                    .frame(width: size * 14 / 30, height: size * 14 / 30)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - AI 介入徽标

/// 「AI 介入」徽标（固定紫描边胶囊 + sparkles）。`compact` 为列表行用的更小尺寸。
struct QCAiBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 9 : 10))
            Text("AI 介入")
                .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                .tracking(0.2)
        }
        .foregroundStyle(UD.aiAccent)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(UD.aiAccent.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(UD.aiAccent.opacity(0.23), lineWidth: 1)
        )
        .fixedSize()
    }
}

// MARK: - 服务器徽标

/// 服务器徽标：单台 = 名称芯片（绿点 + 名）；多台 = 绿色「⇄ N 台并行」。
struct QCServersBadge: View {
    let count: Int
    let firstName: String?

    var body: some View {
        if count <= 1, let firstName {
            HStack(spacing: 6) {
                Circle().fill(UD.success).frame(width: 5, height: 5)
                Text(firstName)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(UD.border, lineWidth: 1)
            )
            .fixedSize()
        } else if count > 1 {
            HStack(spacing: 6) {
                QCParallelIcon(size: 11, color: UD.success)
                Text("\(count) 台并行")
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text2)
            }
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(UD.success.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(UD.success.opacity(0.32), lineWidth: 1)
            )
            .fixedSize()
        }
    }
}

/// 「并行执行」小标记（详情目标服务器区，多台时显示）。
struct QCParallelTag: View {
    var body: some View {
        HStack(spacing: 4) {
            QCParallelIcon(size: 10, color: UD.success)
            Text("并行执行")
                .font(.system(size: 10.5))
                .foregroundStyle(UD.success)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Capsule().fill(UD.success.opacity(0.12)))
        .overlay(Capsule().strokeBorder(UD.success.opacity(0.35), lineWidth: 1))
    }
}
