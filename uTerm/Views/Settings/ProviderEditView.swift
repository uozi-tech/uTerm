import SwiftUI

/// Provider 编辑表单。
/// - name / kind / baseURL / model 字段绑到 SwiftData @Model（自动持久）。
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

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "基本") {
                ProviderFormField(label: "名称") {
                    UDTextField(placeholder: "名称", text: $provider.name)
                        .frame(width: 320)
                }

                ProviderFormField(label: "类型") {
                    UDSegmented(
                        selection: kindBinding,
                        options: ProviderKind.allCases.map { (value: $0, label: $0.displayName) }
                    )
                }

                ProviderFormField(label: "Base URL", hint: baseURLHelpText) {
                    UDTextField(placeholder: "如 https://api.openai.com", text: $provider.baseURL)
                        .frame(width: 360)
                        .help(baseURLHelpText)
                }
            }

            SettingsGroup(title: "模型") {
                modelPicker
                ProviderFormField(label: "Model ID") {
                    UDTextField(placeholder: "Model ID", text: $provider.model, monospaced: true)
                        .frame(width: 320)
                }
            }

            SettingsGroup(title: "API Key") {
                ProviderFormField(label: "密钥") {
                    VStack(alignment: .leading, spacing: 8) {
                        UDTextField(
                            placeholder: "粘贴新 key 后按下方保存",
                            text: $keyDraft,
                            isSecure: true
                        )
                        .frame(width: 360)

                        HStack(spacing: 10) {
                            UDButton(title: "保存 Key", style: .secondary) { saveKey() }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            keyStatus
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            SettingsGroup(title: "诊断") {
                HStack(spacing: 10) {
                    UDButton(title: "测试连接", style: .secondary) {
                        Task { await testConnection() }
                    }
                    .disabled(testInFlight)

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
    private var modelPicker: some View {
        let presets = ProviderPreset.models(for: provider.kind)
        let options = presetOptions(presets)
        ProviderFormField(label: "预置") {
            UDSegmented(selection: $provider.model, options: options)
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
        if keychain.load(for: provider.id) != nil {
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

    private func presetOptions(_ presets: [String]) -> [(value: String, label: String)] {
        var options = presets.map { (value: $0, label: $0) }
        if !provider.model.isEmpty, !presets.contains(provider.model) {
            options.append((value: provider.model, label: "自定义"))
        }
        return options
    }

    /// kind 改时若 baseURL 是另一 kind 的预置，自动同步过来；用户已自定义的 baseURL 不动。
    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { provider.kind },
            set: { newKind in
                let oldDefault = ProviderPreset.defaultBaseURL(for: provider.kind)
                if provider.baseURL == oldDefault {
                    provider.baseURL = ProviderPreset.defaultBaseURL(for: newKind)
                }
                provider.kindRaw = newKind.rawValue
            })
    }

    private func testConnection() async {
        testInFlight = true
        defer { testInFlight = false }
        // 用未保存的 keyDraft（若有）覆盖 keychain 中的 key——便于先试再保存。
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (keychain.load(for: provider.id) ?? "")
            : keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            testResult = (false, "请先填或保存 API Key")
            return
        }
        let baseURL = URL(string: provider.baseURL.isEmpty
                           ? ProviderPreset.defaultBaseURL(for: provider.kind)
                           : provider.baseURL)
            ?? URL(string: ProviderPreset.defaultBaseURL(for: provider.kind))!
        let config = LLMRequestConfig(model: provider.model, baseURL: baseURL, apiKey: key)
        let client = LLMClientFactory.make(for: provider)
        do {
            var sawAnything = false
            for try await _ in client.stream(
                messages: [ChatMessage(role: .user, text: "ping")],
                system: "reply with the single word pong",
                config: config) {
                sawAnything = true
            }
            testResult = (sawAnything,
                          sawAnything ? "连接 OK" : "连接通了但模型未返回内容，检查 model id")
        } catch let e as LLMClientError {
            switch e {
            case .httpError(let s, let body):
                testResult = (false, "HTTP \(s)：\(body.prefix(120))")
            case .invalidResponse:
                testResult = (false, "服务器返回了无法解析的响应")
            }
        } catch {
            testResult = (false, "请求失败：\(error.localizedDescription)")
        }
    }

    private func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            try keychain.save(k, for: provider.id)
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
