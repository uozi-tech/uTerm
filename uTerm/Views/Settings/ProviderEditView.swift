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
        Form {
            Section("基本") {
                TextField("名称", text: $provider.name)

                Picker("类型", selection: kindBinding) {
                    ForEach(ProviderKind.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }

                TextField("Base URL", text: $provider.baseURL, prompt: Text("如 https://api.openai.com"))
                    .textFieldStyle(.roundedBorder)
                    .help(baseURLHelpText)
            }

            Section("模型") {
                modelPicker
            }

            Section("API Key") {
                SecureField("sk-…", text: $keyDraft, prompt: Text("粘贴新 key 后按下方保存"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存 Key") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if keySaved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let err = keySaveError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    if keychain.load(for: provider.id) != nil {
                        Text("已有 Key").foregroundStyle(.secondary).font(.caption)
                    } else {
                        Text("尚未设置 Key").foregroundStyle(.orange).font(.caption)
                    }
                }
            }

            Section("诊断") {
                HStack {
                    Button("测试连接") { Task { await testConnection() } }
                        .disabled(testInFlight)
                    if testInFlight { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.message,
                              systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
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
        Picker("预置", selection: $provider.model) {
            ForEach(presets, id: \.self) { Text($0).tag($0) }
            if !presets.contains(provider.model) {
                Text(provider.model.isEmpty ? "（自定义）" : provider.model)
                    .tag(provider.model)
            }
        }
        TextField("Model ID（可手打）", text: $provider.model)
            .textFieldStyle(.roundedBorder)
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
