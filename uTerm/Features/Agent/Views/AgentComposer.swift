#if os(macOS)
import AgentKit
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
/// 这里只管 uTerm 自己的工具栏内容 —— 附加上下文、模型、思考深度、审批档位。
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

    var body: some View {
        UDAgentComposer(
            text: $model.input,
            placeholder: model.composerPlaceholder(placeholder),
            minLines: minLines,
            status: model.composerStatus,
            // 忙碌时照样能发 —— 进待发队列，Agent 空闲后依次处理。
            canSend: model.hasDraft,
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
            effortSelector(compact: compactSafety)
            safetySelector(compact: compactSafety)
        }
    }

    // MARK: - 模型

    /// 全部 provider 的全部模型按 provider 分组列在一个可搜索的下拉里，在这里直接切换；
    /// 列表来自各 provider 的 `/v1/models`（`AgentModelDirectory`），打开下拉时刷新过期的。
    private func modelSelector(compact: Bool) -> some View {
        UDComposerModelMenu(
            label: modelLabel,
            help: modelHelp,
            maxLabelWidth: compact ? AgentComposerLayout.modelLabelCompactWidth
                                   : AgentComposerLayout.modelLabelMaxWidth,
            groups: AgentComposerModelMenu.groups(providers: model.providers, catalog: catalog),
            selection: AgentComposerModelMenu.itemID(model.activeProvider),
            isRefreshing: catalog.isRefreshing,
            onOpen: { AgentModelDirectory.refresh(model.providers) },
            onRefresh: { AgentModelDirectory.refresh(model.providers, force: true) },
            actions: [UDModelPickerAction(title: "管理模型服务…", systemImage: "slider.horizontal.3",
                                          action: onOpenSettings)],
            onSelect: select)
    }

    private var catalog: AgentModelCatalog { AgentModelDirectory.catalog }

    private func select(_ item: UDModelPickerItem) {
        guard let providerID = UUID(uuidString: item.groupID),
              let id = model.selectModel(AgentModelItem(providerID: providerID, model: item.title, detail: nil))
        else { return }
        activeProviderIDString = id.uuidString
    }

    private var modelLabel: String { AgentModelMenu.label(model.activeProvider) }

    private var modelHelp: String { AgentModelMenu.help(model.activeProvider) }

    // MARK: - 思考深度

    /// 当前模型支持思考深度时才出现（按 provider 协议与模型家族判定，见 `AgentEffortChoice`）。
    @ViewBuilder
    private func effortSelector(compact: Bool) -> some View {
        if let choice = model.effortChoice {
            UDComposerEffortMenu(
                options: choice.options.map { UDEffortOption(value: $0.value, label: $0.label) },
                selection: choice.selection,
                compact: compact,
                onSelect: choice.select)
        }
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

// MARK: - 模型下拉的数据

/// 共享的 `AgentModelMenu` 换成 DesignKit 下拉的类型（单测守它）。
enum AgentComposerModelMenu {
    /// 下拉项 id：`provider id|模型 id`。
    static func itemID(_ provider: AIProvider?) -> String? {
        AgentModelMenu.itemID(provider)
    }

    @MainActor
    static func groups(providers: [AIProvider], catalog: AgentModelCatalog) -> [UDModelPickerGroup] {
        AgentModelMenu.groups(providers: providers, catalog: catalog).map { group in
            let status: UDModelPickerGroup.Status
            switch group.status {
            case .loading: status = .loading
            case .failed(let message): status = .failed(message)
            case .ready: status = .ready
            }
            return UDModelPickerGroup(
                id: group.id, title: group.title,
                items: group.items.map {
                    UDModelPickerItem(id: $0.id, groupID: group.id, title: $0.model, detail: $0.detail)
                },
                status: status)
        }
    }

    /// 「默认」+ 该模型支持的档位。
    static func effortOptions(_ support: AgentReasoningSupport) -> [UDEffortOption] {
        AgentModelMenu.effortOptions(support).map { UDEffortOption(value: $0.value, label: $0.label) }
    }
}

// MARK: - 审批档位的图标与颜色

extension AgentSafety {
    /// 最保守的一档不抢眼；放权越多颜色越醒目。图标与排列顺序在共享的 `AgentComposerSupport`。
    @MainActor var tint: Color {
        switch self {
        case .confirm:  return UD.text3
        case .readAuto: return UD.accent
        case .auto:     return UD.warning
        }
    }
}
#endif
