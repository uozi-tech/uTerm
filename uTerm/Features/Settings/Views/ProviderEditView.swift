import UDesignKit
import SwiftUI

/// Provider 编辑表单。
/// - name / kind / baseURL 字段绑到 SwiftData @Model（自动持久）。
/// - 模型不在这里选：Agent 输入区的模型下拉把所有 provider 的 `/v1/models` 列表合在一起，
///   在那里直接切换（`AgentModelDirectory`）。这里的「测试连接」就是拉一次模型列表。
/// - kind 切换若 baseURL 当前等于另一 kind 的预置，自动替为本 kind 的预置；
///   用户已自定义的 baseURL 不动。
/// - apiKey 不在 SwiftData，由本视图持有 @State keyDraft，「保存 Key」
///   按钮直接调 AgentKeychain.save(_:for:)。
struct ProviderEditView: View {
    @Bindable var provider: AIProvider
    @State private var keyDraft = ""
    @State private var keySaveError: String?
    @State private var keySaved = false
    @State private var testInFlight = false
    @State private var testResult: (ok: Bool, message: String)?

    private let keychain = AgentKeychain()

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

    /// 待保存的 API Key 草稿（去空白）。
    private var keyDraftTrimmed: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "基本") {
                ProviderFormField(label: "名称") {
                    UDTextField(placeholder: "名称",
                                text: $provider.name,
                                errorMessage: nameError)
                        .frame(width: 320)
                        .accessibilityLabel("名称")
                        .accessibilityValue(nameError ?? provider.name)
                }

                ProviderFormField(label: "类型") {
                    UDSegmented(
                        selection: kindBinding,
                        options: ProviderKind.allCases.map { (value: $0, label: $0.displayName) }
                    )
                }

                ProviderFormField(label: "Base URL", hint: baseURLHelpText) {
                    UDTextField(placeholder: "如 https://api.openai.com",
                                text: $provider.baseURL,
                                errorMessage: baseURLError)
                        .frame(width: 360)
                        .help(baseURLHelpText)
                        .accessibilityLabel("Base URL")
                        .accessibilityValue(baseURLError ?? provider.baseURL)
                }
            }

            SettingsGroup(title: "API Key") {
                ProviderFormField(label: "密钥") {
                    VStack(alignment: .leading, spacing: 8) {
                        UDTextField(
                            placeholder: "粘贴新 key 后按下方保存",
                            text: $keyDraft,
                            isSecure: true,
                            revealable: true
                        )
                        .frame(width: 360)
                        .accessibilityLabel("API Key")
                        .accessibilityValue(keyDraftTrimmed.isEmpty ? "未输入" : "已输入新 key")

                        HStack(spacing: 10) {
                            UDButton(title: "保存 Key", style: .secondary) { saveKey() }
                                .disabled(keyDraftTrimmed.isEmpty)
                            keyStatus
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            SettingsGroup(title: "诊断") {
                Text("在 Agent 输入区的模型菜单里切换模型 —— 那里列出所有服务的全部可用模型（取自各自的 /v1/models）。")
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    UDButton(title: "测试连接", style: .secondary) {
                        Task { await testConnection() }
                    }
                    .disabled(testInFlight || baseURLError != nil)

                    if testInFlight {
                        UDIndeterminateBar()
                            .frame(width: 72)
                    }
                    if let r = testResult {
                        statusLabel(r.message, ok: r.ok)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .id(provider.id)              // 切换选中行时重建本视图，清空 keyDraft 等本地状态。
        .onChange(of: provider.id) { _, _ in
            keyDraft = ""
            keySaved = false
            keySaveError = nil
            testInFlight = false
            testResult = nil
        }
    }

    @ViewBuilder
    private var keyStatus: some View {
        if keySaved {
            statusLabel("已保存", ok: true)
        }
        if let err = keySaveError {
            statusLabel(err, ok: false)
        }
        if ProviderManagement.hasKey(provider, keychain: keychain) {
            Text("已有 Key")
                .font(UD.caption)
                .foregroundStyle(UD.text3)
        } else {
            Text("尚未设置 Key")
                .font(UD.caption)
                .foregroundStyle(UD.warning)
        }
    }

    private func statusLabel(_ message: String, ok: Bool) -> some View {
        Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(UD.caption)
            .foregroundStyle(ok ? UD.success : UD.danger)
            .lineLimit(1)
    }

    /// kind 改时若 baseURL 是另一 kind 的预置，自动同步过来；用户已自定义的 baseURL 不动。
    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { provider.kind },
            set: { ProviderManagement.setKind($0, on: provider) })
    }

    /// 测试连接 = 拉一次 `/v1/models`（`ProviderManagement.testConnection`）；
    /// 用未保存的 keyDraft（若有）覆盖钥匙串中的 key——便于先试再保存。
    private func testConnection() async {
        testInFlight = true
        defer { testInFlight = false }
        let result = await ProviderManagement.testConnection(provider, keyDraft: keyDraft, keychain: keychain)
        testResult = (result.ok, result.message)
    }

    private func saveKey() {
        guard !keyDraftTrimmed.isEmpty else { return }
        do {
            try ProviderManagement.saveKey(keyDraftTrimmed, for: provider, keychain: keychain)
            keyDraft = ""
            keySaveError = nil
            keySaved = true
        } catch {
            keySaveError = "保存到钥匙串失败：\(error)"
            keySaved = false
        }
    }
}

private struct ProviderFormField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UD.text2)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}
