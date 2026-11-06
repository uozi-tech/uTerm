import UDesignKit
import SwiftUI

/// Provider 编辑表单。
/// - name / kind / baseURL 字段绑到 SwiftData @Model（自动持久）。
/// - 模型不在这里选：Agent 输入区的模型下拉把所有 provider 的 `/v1/models` 列表合在一起，
///   在那里直接切换（`AgentModelDirectory`）。这里的「测试连接」就是拉一次模型列表。
/// - kind 切换若 baseURL 当前等于另一 kind 的预置，自动替为本 kind 的预置；
///   用户已自定义的 baseURL 不动。
/// - apiKey 不在 SwiftData：草稿、保存与测试连接的状态在共享的 `ProviderDraftModel`
///   （iOS 编辑页同一份），「保存 Key」写钥匙串。
struct ProviderEditView: View {
    @Bindable var provider: AIProvider
    @State private var draft: ProviderDraftModel

    init(provider: AIProvider) {
        self.provider = provider
        _draft = State(initialValue: ProviderDraftModel(provider: provider))
    }

    /// 显式 String 而非字面量 —— `help(_:)` 有 LocalizedStringKey / StringProtocol
    /// 两个 overload，字面量 prefer LocalizedStringKey，会把 `https://...` 当
    /// markdown URL 解析成 attributed string 触发 runtime warning：
    /// "Only unstyled text can be used with help(_:)"
    /// 已知 String 类型走 StringProtocol overload 跳过 markdown 解析。
    private let baseURLHelpText: String =
        "不含路径段。OpenAI-兼容端点按同样规则填，如 https://api.deepseek.com、http://localhost:11434。"

    /// Base URL 必填；远程端点须 HTTPS，loopback 开发服务可用 HTTP。
    private var baseURLError: String? {
        ProviderManagement.baseURLError(provider.baseURL, kind: provider.kind)
    }

    /// 名称必填；空时返回错误文案。
    private var nameError: String? {
        ProviderManagement.nameError(provider.name)
    }

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: provider.name.isEmpty ? String(localized: "未命名") : provider.name,
                               subtitle: ProviderManagement.summary(provider))

            SettingsGroup(title: "基本", footer: baseURLHelpText) {
                SettingsRow(label: "名称") {
                    UDTextField(placeholder: "名称",
                                text: $provider.name,
                                errorMessage: nameError)
                        .frame(minWidth: 140, maxWidth: 240)
                        .accessibilityLabel("名称")
                        .accessibilityValue(nameError ?? provider.name)
                }
                SettingsRow(label: "类型") {
                    UDSegmented(
                        selection: kindBinding,
                        options: ProviderKind.allCases.map { (value: $0, label: $0.displayName) }
                    )
                }
                SettingsRow(label: "Base URL") {
                    UDTextField(placeholder: "如 https://api.openai.com",
                                text: $provider.baseURL,
                                errorMessage: baseURLError)
                        .frame(minWidth: 160, maxWidth: 360)
                        .help(baseURLHelpText)
                        .accessibilityLabel("Base URL")
                        .accessibilityValue(baseURLError ?? provider.baseURL)
                }
            }

            SettingsGroup(title: "API Key", footer: keyFootnote) {
                SettingsRow(label: "密钥") {
                    HStack(spacing: 8) {
                        UDTextField(
                            placeholder: "粘贴新 Key",
                            text: $draft.keyDraft,
                            isSecure: true,
                            revealable: true
                        )
                        .frame(minWidth: 140, maxWidth: 280)
                        .accessibilityLabel("API Key")
                        .accessibilityValue(draft.canSaveKey ? "已输入新 key" : "未输入")
                        UDButton(title: "保存", style: .primary) { draft.saveKey() }
                            .disabled(!draft.canSaveKey)
                    }
                }
                if draft.keySaved {
                    SettingsInlineNote(tone: .success, text: String(localized: "已保存到钥匙串"))
                }
                if let err = draft.keySaveError {
                    SettingsInlineNote(tone: .danger, text: err)
                }
            }

            SettingsGroup(title: "诊断",
                          footer: String(localized: "在 Agent 输入区的模型菜单里切换模型 —— 那里列出所有服务的全部可用模型（取自各自的 /v1/models）。")) {
                SettingsRow(label: "测试连接", hint: String(localized: "用当前地址与 Key 拉一次模型列表")) {
                    HStack(spacing: 10) {
                        if draft.testInFlight {
                            UDIndeterminateBar()
                                .frame(width: 72)
                        } else if let r = draft.testResult {
                            SettingsStatusLabel(symbol: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                                tone: r.ok ? .success : .danger, text: r.message)
                                .frame(maxWidth: 220, alignment: .trailing)
                        }
                        UDButton(title: "测试连接", style: .secondary) {
                            Task { await draft.testConnection() }
                        }
                        .disabled(draft.testInFlight || baseURLError != nil)
                    }
                }
            }
        }
        .id(provider.id)              // 切换选中行时重建本视图，清空 keyDraft 等本地状态。
        .onChange(of: provider.id) { _, _ in
            draft.reset(to: provider)
        }
    }

    private var keyFootnote: String {
        draft.hasKey
            ? String(localized: "钥匙串里已有 Key。粘贴新 Key 并保存会替换它。")
            : String(localized: "尚未设置 Key。粘贴后点「保存」写入钥匙串。")
    }

    /// kind 改时若 baseURL 是另一 kind 的预置，自动同步过来；用户已自定义的 baseURL 不动。
    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { provider.kind },
            set: { ProviderManagement.setKind($0, on: provider) })
    }
}
