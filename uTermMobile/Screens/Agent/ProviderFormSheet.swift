import SwiftUI
import SwiftData

/// 新建 AI Provider（写 `AIProvider` + 钥匙串 API Key）。
struct ProviderFormSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: ProviderKind = .anthropic
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MInsetGroup(header: "类型") {
                        Picker("类型", selection: $kind) {
                            ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented).padding(12)
                    }

                    MInsetGroup(header: "基本") {
                        formRow("名称", "如 Claude / DeepSeek", $name, autocap: .sentences, last: false)
                        formRow("Base URL", ProviderPreset.defaultBaseURL(for: kind), $baseURL, last: false)
                        formRow("模型", ProviderPreset.models(for: kind).first ?? "", $model, last: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MSectionCap(text: "API Key").padding(.horizontal, 20)
                        MInput(text: $apiKey, placeholder: "sk-…", mono: true, secure: true)
                            .padding(.horizontal, 16)
                        Text("仅存于本机钥匙串，不会上传。")
                            .font(M.sans(12)).foregroundStyle(M.text4).padding(.horizontal, 20)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MSectionCap(text: "可选模型").padding(.horizontal, 20)
                        FlowChips(items: ProviderPreset.models(for: kind)) { model = $0 }
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(M.canvas)
            .navigationTitle("添加 Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid).fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func formRow(_ label: String, _ placeholder: String, _ binding: Binding<String>,
                         autocap: TextInputAutocapitalization = .never, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(M.sans(15)).foregroundStyle(M.text).frame(width: 92, alignment: .leading)
                TextField(placeholder, text: binding)
                    .font(M.sans(15)).foregroundStyle(M.text)
                    .textInputAutocapitalization(autocap).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if !last { Divider().overlay(M.divider).padding(.leading, 14) }
        }
    }

    private func save() {
        let next = ((try? context.fetch(FetchDescriptor<AIProvider>()))?.map(\.sortOrder).max() ?? -1) + 1
        let provider = AIProvider(name: name.trimmingCharacters(in: .whitespaces),
                                  kind: kind,
                                  baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                                  model: model.trimmingCharacters(in: .whitespaces),
                                  sortOrder: next)
        context.insert(provider)
        try? context.save()
        try? AgentKeychain().save(apiKey.trimmingCharacters(in: .whitespaces), for: provider.id)
        dismiss()
    }
}

/// 简单自动换行的可点选模型 chip 组。
struct FlowChips: View {
    let items: [String]
    var onTap: (String) -> Void
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 90), spacing: 8)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item).font(M.mono(12)).foregroundStyle(M.text2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(M.fillFaint)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(MPressStyle())
            }
        }
    }
}
