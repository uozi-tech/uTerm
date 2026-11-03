import AgentKit
import Foundation

// Agent 输入区背后的编排：模型菜单、思考深度、发送 / 停止 / 排队的状态、上下文附加。
// macOS（`AgentComposer`，画在 DesignKit 的 `UDAgentComposer` 上）与 iOS
// （`MAgentComposer`）共用这一份，平台那侧只负责把它画出来——两端的行为差异只能
// 出在控件形态上，不能出在「选了什么模型、什么时候能发、停止后显示什么」上。

// MARK: - 模型菜单

/// 输入区模型菜单的一组：一个 provider。
struct AgentModelGroup: Identifiable, Equatable {
    enum Status: Equatable {
        case loading
        case failed(String)
        case ready
    }

    let providerID: UUID
    let title: String
    let items: [AgentModelItem]
    let status: Status

    var id: String { providerID.uuidString }
}

/// 输入区模型菜单的一项：某个 provider 的某个模型。
struct AgentModelItem: Identifiable, Hashable {
    let providerID: UUID
    let model: String
    /// 当前选中但 provider 最近一次列表里已经没有它时为「不在列表中」。
    let detail: String?

    /// `provider id|模型 id`。
    var id: String { AgentModelMenu.itemID(providerID: providerID, model: model) }
}

/// 思考深度的一个选项；`value == nil` 是「默认」（请求里不带思考参数）。
struct AgentEffortOption: Hashable {
    let value: String?
    let label: String
}

/// 模型菜单的分组与文案（纯函数，单测守它）。
enum AgentModelMenu {
    nonisolated static func itemID(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString)|\(model)"
    }

    /// 当前选中项的 id；provider 还没选模型时为 nil。
    static func itemID(_ provider: AIProvider?) -> String? {
        guard let provider, !provider.model.isEmpty else { return nil }
        return itemID(providerID: provider.id, model: provider.model)
    }

    /// 每个 provider 一组，按 provider 的排序；组内是拉到的模型，当前选中但不在列表里的
    /// 那个排在最前并标注。
    @MainActor
    static func groups(providers: [AIProvider], catalog: AgentModelCatalog) -> [AgentModelGroup] {
        providers.sorted { $0.sortOrder < $1.sortOrder }.map { provider in
            let entry = catalog.entry(for: provider.id)
            let fetched = Set(entry?.models ?? [])
            let items = catalog.models(for: provider.id, including: provider.model).map { id in
                AgentModelItem(providerID: provider.id, model: id,
                               detail: entry?.fetchedAt != nil && !fetched.contains(id) ? "不在列表中" : nil)
            }
            let status: AgentModelGroup.Status
            if entry?.isLoading == true || entry == nil {
                status = .loading
            } else if let error = entry?.error {
                status = .failed(error)
            } else {
                status = .ready
            }
            return AgentModelGroup(providerID: provider.id,
                                   title: provider.name.isEmpty ? provider.kind.displayName : provider.name,
                                   items: items, status: status)
        }
    }

    /// 替还没选模型的服务挑一个：列表里第一个能对话的模型，都不像就退回第一个。
    /// OpenAI 兼容端点的 `/v1/models` 常把 embedding / 语音 / 图像模型排在前面，
    /// 直接取第一个会选到发不了对话请求的模型。
    nonisolated static func defaultModel(from models: [String]) -> String? {
        models.first { id in
            let lower = id.lowercased()
            return !nonChatMarkers.contains { lower.contains($0) }
        } ?? models.first
    }

    nonisolated private static let nonChatMarkers = [
        "embed", "tts", "whisper", "transcribe", "dall-e", "image", "audio",
        "moderation", "rerank", "realtime", "search",
    ]

    /// 「默认」+ 该模型支持的档位。
    static func effortOptions(_ support: AgentReasoningSupport) -> [AgentEffortOption] {
        [AgentEffortOption(value: nil, label: "默认")]
            + support.levels.map { AgentEffortOption(value: $0.rawValue, label: $0.label) }
    }

    /// 触发器上显示的模型名。
    static func label(_ provider: AIProvider?) -> String {
        guard let provider, !provider.model.isEmpty else { return "选择模型" }
        return provider.model
    }

    /// 触发器的完整说明（macOS tooltip / iOS 读屏值）。
    static func help(_ provider: AIProvider?) -> String {
        guard let provider else { return "还没有配置模型服务" }
        return provider.model.isEmpty ? "\(provider.name)：还没有选择模型" : "\(provider.name) · \(provider.model)"
    }
}

// MARK: - 思考深度

/// 当前模型的思考深度菜单：选项 + 当前选择 + 写回。模型不支持思考深度时没有这个值，
/// 输入区也就不画这个控件。
@MainActor
struct AgentEffortChoice {
    let options: [AgentEffortOption]
    /// 存着的档位这个模型不支持（换过模型族）就当默认，请求里也不会带。
    let selection: String?
    private let providerID: UUID
    private let model: String
    private let preferences: AgentReasoningPreferences

    init?(provider: AIProvider?, preferences: AgentReasoningPreferences = .shared) {
        guard let provider, !provider.model.isEmpty,
              let support = AgentReasoningSupport.resolve(protocol: provider.kind.wireProtocol,
                                                          modelID: provider.model) else { return nil }
        let current = preferences.effort(providerID: provider.id, model: provider.model)
        self.options = AgentModelMenu.effortOptions(support)
        self.selection = current.flatMap { support.levels.contains($0) ? $0.rawValue : nil }
        self.providerID = provider.id
        self.model = provider.model
        self.preferences = preferences
    }

    var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? "默认"
    }

    func select(_ value: String?) {
        preferences.setEffort(value.flatMap(AgentReasoningEffort.init(rawValue:)),
                              providerID: providerID, model: model)
    }
}

// MARK: - 输入区状态与动作

extension AssistantModel {
    /// 输入框里有没有可发的字。忙碌时照样能发——进待发队列，Agent 空闲后依次处理。
    var hasDraft: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 输入区上方的一行状态；只在用户停过本轮时出现。
    var composerStatus: String? {
        guard turnWasStopped else { return nil }
        return state == .running ? "已停止后续步骤，已下发命令仍在运行" : "已停止"
    }

    /// 忙碌时把占位符换成排队说明。
    func composerPlaceholder(_ idle: String) -> String {
        isBusy ? "Agent 正在处理，输入会排队发送…" : idle
    }

    /// 取走输入框里的草稿并**同步**清空（避免回车后「先全选再发」的闪烁）；
    /// 只有空白时返回 nil、输入框不动。
    func takeDraft() -> String? {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        input = ""
        return text
    }

    /// 「附加当前上下文」：把主机描述追加进草稿。
    func appendContext(_ serverContext: String) {
        let snippet = "上下文：\n\(serverContext)"
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = snippet
        } else {
            input += "\n\n\(snippet)"
        }
    }

    /// 最早一张待确认的命令卡（⌘↵ / 「运行全部」的落点）。
    var firstPendingToolCallID: String? {
        for message in messages {
            if let call = message.toolCalls.first(where: { $0.status == .pending }) { return call.id }
        }
        return nil
    }

    /// 在模型菜单里选中一项：记到对应 provider 上并切为活动 provider。
    /// 返回被选中的 provider id，调用方写回自己的持久化选择（`activeProviderID`）。
    @discardableResult
    func selectModel(_ item: AgentModelItem) -> UUID? {
        guard let provider = providers.first(where: { $0.id == item.providerID }) else { return nil }
        provider.model = item.model
        activeProviderID = provider.id
        return provider.id
    }

    /// 当前活动模型的思考深度菜单；模型不支持、或这个状态机不带思考参数
    /// （`reasoningPreferences == nil`，单测构造）时为 nil——菜单与请求同一个口径。
    var effortChoice: AgentEffortChoice? {
        guard let reasoningPreferences else { return nil }
        return AgentEffortChoice(provider: activeProvider, preferences: reasoningPreferences)
    }
}

// MARK: - 空状态的示例

/// 空对话里按「诊断 / 配置 / 部署」分组的示例提示，点一下填进输入框。
enum AgentPromptExamples {
    struct Group: Hashable {
        let tag: String
        let items: [String]
    }

    nonisolated static let groups: [Group] = [
        .init(tag: "诊断", items: ["根分区是什么占满的", "最近的 5xx 集中在什么时间", "CPU 突然飙高是哪个进程"]),
        .init(tag: "配置", items: ["给 upstream 加上 keepalive", "把 SSH 端口改成 2222", "开启 gzip 压缩"]),
        .init(tag: "部署", items: ["拉取最新代码并重启服务", "回滚到上一个版本", "查看 systemd 服务状态"]),
    ]
}

// MARK: - 审批档位的呈现

extension AgentSafety {
    /// 自主程度越高图标越「满」：每步确认是空盾，只读自动半盾，AI 代批带闪电。
    nonisolated var symbolName: String {
        switch self {
        case .confirm:  return "shield"
        case .readAuto: return "shield.lefthalf.filled"
        case .auto:     return "bolt.shield.fill"
        }
    }

    /// 菜单里从保守到放权排列（`allCases` 的声明顺序是历史遗留的 readAuto 在前）。
    nonisolated static let byAutonomy: [AgentSafety] = [.confirm, .readAuto, .auto]
}
