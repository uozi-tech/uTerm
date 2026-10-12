#if os(macOS)
import SwiftUI
import UDesignKit

/// uTerm 这一侧的版式常量；控件与主操作钮的尺寸在 `UDAgentComposerLayout`。
enum AgentComposerLayout {
    /// 模型名在完整档 / 收缩档的最大宽度；超出走中间省略（型号的区分度在头尾）。
    nonisolated static let modelLabelMaxWidth: CGFloat = 190
    nonisolated static let modelLabelCompactWidth: CGFloat = 84
}

/// 工作区 Agent 面板与终端 Agent 共用的输入区：把 `AssistantModel` 接到 DesignKit 的
/// `UDAgentComposer`（卡片、发送 ⇄ 停止、聚焦环都在共享包里，uTable 用的是同一个），
/// 这里只管 uTerm 自己的工具栏内容 —— 附加上下文、模型、审批档位。
///
/// 工具栏恒为一行：窄面板里按「审批档位只留图标 → 模型名收窄」逐级收缩，而不是折成
/// 两行把输入区撑高。
struct AgentComposer: View {
    @Bindable var model: AssistantModel
    let placeholder: String
    var minLines: Int = 2
    @Binding var safety: AgentSafety
    @Binding var activeProviderIDString: String
    let onSend: () -> Void
    let onAttach: () -> Void
    let onOpenSettings: () -> Void

    private var hasText: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var status: String? {
        guard model.turnWasStopped else { return nil }
        return model.state == .running ? "已停止后续步骤，已下发命令仍在运行" : "已停止"
    }

    var body: some View {
        UDAgentComposer(
            text: $model.input,
            placeholder: model.isBusy ? "Agent 正在处理，输入会排队发送…" : placeholder,
            minLines: minLines,
            status: status,
            // 忙碌时照样能发 —— 进待发队列，Agent 空闲后依次处理。
            canSend: hasText,
            canStop: model.canStop,
            sendHelp: model.isBusy ? "排队发送，Agent 空闲后依次处理（↩）" : "发送（↩）",
            stopHelp: "停止生成和审批，取消待执行命令；已下发命令继续回收结果（esc）",
            onSend: onSend,
            onStop: model.stop,
            toolbar: {
                Button(action: onAttach) { Image(systemName: "plus") }
                    .buttonStyle(UDComposerGhostIconStyle())
                    .help("附加当前上下文")
                    .accessibilityLabel("附加当前上下文")

                // 逐级收缩：完整 → 审批档位只留图标 → 模型名也收窄。
                ViewThatFits(in: .horizontal) {
                    selectors(compactModel: false, compactSafety: false)
                    selectors(compactModel: false, compactSafety: true)
                    selectors(compactModel: true, compactSafety: true)
                }
            })
    }

    private func selectors(compactModel: Bool, compactSafety: Bool) -> some View {
        HStack(spacing: 2) {
            modelSelector(compact: compactModel)
            safetySelector(compact: compactSafety)
        }
    }

    // MARK: - 模型

    private func modelSelector(compact: Bool) -> some View {
        UDDropdown(anchor: .leading) { open in
            UDComposerGhostLabel(open: open) {
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: compact ? AgentComposerLayout.modelLabelCompactWidth
                                             : AgentComposerLayout.modelLabelMaxWidth)
            }
        } content: {
            UDMenu(width: 260, head: "模型", maxHeight: 320, items: modelItems)
        }
        .fixedSize()
        .help(modelHelp)
        .accessibilityLabel("模型")
        .accessibilityValue(modelLabel)
    }

    private var modelLabel: String {
        model.activeProvider.map { $0.model.isEmpty ? $0.name : $0.model } ?? "选择模型"
    }

    private var modelHelp: String {
        guard let provider = model.activeProvider else { return "还没有选择模型" }
        return provider.model.isEmpty ? provider.name : "\(provider.name) · \(provider.model)"
    }

    private var modelItems: [UDMenuItem] {
        var items = model.providers.map { provider in
            UDMenuItem(
                label: provider.model.isEmpty ? provider.name : "\(provider.name) · \(provider.model)",
                active: provider.id == model.activeProvider?.id,
                action: { activeProviderIDString = provider.id.uuidString })
        }
        items.append(.divider())
        items.append(UDMenuItem(label: "管理模型…", systemImage: "slider.horizontal.3",
                                action: onOpenSettings))
        return items
    }

    // MARK: - 审批档位

    private func safetySelector(compact: Bool) -> some View {
        UDDropdown(anchor: .leading) { open in
            // 收缩档连 chevron 也省掉：只剩一枚图标，窄面板里把宽度让给模型名。
            UDComposerGhostLabel(open: open, showsChevron: !compact) {
                Image(systemName: safety.symbolName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(safety.tint)
                if !compact {
                    Text(safety.label).lineLimit(1)
                }
            }
        } content: {
            // 每一项带一行说明 —— 三档的差别靠名字猜不出来，原先只能悬停看 tooltip。
            UDOptionMenu(head: "审批档位", items: AgentSafety.byAutonomy.map { mode in
                UDOptionMenuItem(id: mode.rawValue, systemImage: mode.symbolName, tint: mode.tint,
                                 title: mode.label, detail: mode.detail,
                                 active: mode == safety, action: { safety = mode })
            })
        }
        .fixedSize()
        .help("审批档位：\(safety.label) —— \(safety.detail)")
        .accessibilityLabel("审批档位")
        .accessibilityValue(safety.label)
    }
}

// MARK: - 审批档位的图标与颜色

extension AgentSafety {
    /// 自主程度越高图标越「满」：每步确认是空盾，只读自动半盾，AI 代批带闪电。
    nonisolated var symbolName: String {
        switch self {
        case .confirm:  return "shield"
        case .readAuto: return "shield.lefthalf.filled"
        case .auto:     return "bolt.shield.fill"
        }
    }

    /// 最保守的一档不抢眼；放权越多颜色越醒目。
    @MainActor var tint: Color {
        switch self {
        case .confirm:  return UD.text3
        case .readAuto: return UD.accent
        case .auto:     return UD.warning
        }
    }

    /// 菜单里从保守到放权排列（`allCases` 的声明顺序是历史遗留的 readAuto 在前）。
    nonisolated static let byAutonomy: [AgentSafety] = [.confirm, .readAuto, .auto]
}
#endif
