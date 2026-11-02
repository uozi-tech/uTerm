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
        guard let provider = model.providers.first(where: { $0.id.uuidString == item.groupID }) else { return }
        provider.model = item.title
        activeProviderIDString = provider.id.uuidString
    }

    private var modelLabel: String {
        guard let provider = model.activeProvider else { return "选择模型" }
        return provider.model.isEmpty ? "选择模型" : provider.model
    }

    private var modelHelp: String {
        guard let provider = model.activeProvider else { return "还没有配置模型服务" }
        return provider.model.isEmpty ? "\(provider.name)：还没有选择模型" : "\(provider.name) · \(provider.model)"
    }

    // MARK: - 思考深度

    /// 当前模型支持思考深度时才出现（按 provider 协议与模型家族判定，见 `AgentReasoningSupport`）。
    @ViewBuilder
    private func effortSelector(compact: Bool) -> some View {
        if let provider = model.activeProvider, !provider.model.isEmpty,
           let support = AgentReasoningSupport.resolve(protocol: provider.kind.wireProtocol,
                                                       modelID: provider.model) {
            let preferences = AgentReasoningPreferences.shared
            let current = preferences.effort(providerID: provider.id, model: provider.model)
            UDComposerEffortMenu(
                options: AgentComposerModelMenu.effortOptions(support),
                // 存着的档位这个模型不支持（换过模型族）就当默认显示，请求里也不会带。
                selection: current.flatMap { support.levels.contains($0) ? $0.rawValue : nil },
                compact: compact,
                onSelect: { value in
                    preferences.setEffort(value.flatMap(AgentReasoningEffort.init(rawValue:)),
                                          providerID: provider.id, model: provider.model)
                })
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

/// 输入区模型下拉的分组与选项（纯函数，单测守它）。
enum AgentComposerModelMenu {
    /// 下拉项 id：`provider id|模型 id`。
    static func itemID(_ provider: AIProvider?) -> String? {
        guard let provider, !provider.model.isEmpty else { return nil }
        return "\(provider.id.uuidString)|\(provider.model)"
    }

    /// 每个 provider 一组，按 provider 的排序；组内是拉到的模型，当前选中但不在列表里的
    /// 那个排在最前并标注。
    @MainActor
    static func groups(providers: [AIProvider], catalog: AgentModelCatalog) -> [UDModelPickerGroup] {
        providers.sorted { $0.sortOrder < $1.sortOrder }.map { provider in
            let entry = catalog.entry(for: provider.id)
            let fetched = Set(entry?.models ?? [])
            let groupID = provider.id.uuidString
            let items = catalog.models(for: provider.id, including: provider.model).map { id in
                UDModelPickerItem(id: "\(groupID)|\(id)", groupID: groupID, title: id,
                                  detail: entry?.fetchedAt != nil && !fetched.contains(id) ? "不在列表中" : nil)
            }
            let status: UDModelPickerGroup.Status
            if entry?.isLoading == true {
                status = .loading
            } else if let error = entry?.error {
                status = .failed(error)
            } else if entry == nil {
                status = .loading
            } else {
                status = .ready
            }
            return UDModelPickerGroup(id: groupID, title: provider.name.isEmpty ? provider.kind.displayName
                                                                                : provider.name,
                                      items: items, status: status)
        }
    }

    /// 「默认」+ 该模型支持的档位。
    static func effortOptions(_ support: AgentReasoningSupport) -> [UDEffortOption] {
        [UDEffortOption(value: nil, label: "默认")]
            + support.levels.map { UDEffortOption(value: $0.rawValue, label: $0.label) }
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
