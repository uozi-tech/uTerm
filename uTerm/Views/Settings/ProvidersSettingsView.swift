import SwiftUI
import SwiftData

/// AI provider 配置面板。左列：List + 底栏 +/− 按钮。右列：选中项编辑表单。
///
/// 用纯 HStack 而非 NavigationSplitView —— macOS Settings 场景里
/// NavigationSplitView 的 sidebar toolbar 没地方挂、selection 行为
/// 也异常（issue：左列空白 + 按钮 squeeze 到左上角不可点）。
struct ProvidersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIProvider.sortOrder) private var providers: [AIProvider]
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedID == nil { selectedID = providers.first?.id }
        }
    }

    // MARK: - 左列

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(providers) { p in
                    row(p).tag(p.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 4) {
                Button { addProvider() } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .help("新增 provider")

                Button { deleteSelected() } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                .help("删除选中 provider")

                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 220)
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
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - 右列

    @ViewBuilder
    private var detail: some View {
        if let provider = providers.first(where: { $0.id == selectedID }) {
            ProviderEditView(provider: provider)
        } else {
            VStack {
                Spacer()
                Text(providers.isEmpty
                     ? "点左下角 + 新增第一个 provider"
                     : "从左侧选择一个 provider")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 动作

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
        try? AgentKeychain().delete(for: p.id)
        modelContext.delete(p)
        try? modelContext.save()
        selectedID = providers.first?.id
    }
}
