import SwiftUI
import SwiftData

/// AI provider 配置面板。左列：列表 + 增删。右列：选中项编辑表单（下一 task 实现）。
struct ProvidersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIProvider.sortOrder) private var providers: [AIProvider]
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(providers) { p in
                    row(p).tag(p.id)
                }
            }
            .listStyle(.sidebar)
            .toolbar {
                ToolbarItemGroup {
                    Button { addProvider() } label: { Image(systemName: "plus") }
                    Button { deleteSelected() } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if let provider = providers.first(where: { $0.id == selectedID }) {
                ProviderEditView(provider: provider)
            } else {
                Text("从左侧选择一个 provider，或点 + 新增")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = providers.first?.id }
        }
    }

    private func row(_ p: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.name).font(.body)
            HStack(spacing: 6) {
                Text(p.kind.displayName)
                Text("·")
                Text(p.model.isEmpty ? "未设置模型" : p.model)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func addProvider() {
        let nextSort = (providers.map(\.sortOrder).max() ?? -1) + 1
        let p = AIProvider(
            name: "新 Provider",
            kind: .anthropic,
            baseURL: ProviderPreset.anthropicBaseURL,
            model: ProviderPreset.anthropicModels.first ?? "",
            sortOrder: nextSort)
        modelContext.insert(p)
        try? modelContext.save()
        selectedID = p.id
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let p = providers.first(where: { $0.id == id }) else { return }
        // 同步删 keychain 条目。
        try? AgentKeychain().delete(for: p.id)
        modelContext.delete(p)
        try? modelContext.save()
        selectedID = providers.first?.id
    }
}
