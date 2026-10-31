import UDesignKit
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
            // 设计稿 settings.jsx：左列 borderRight 1px。用 UD.border 实色描边，
            // 取代系统 Divider（与 KeyManagerView 一致）。
            Rectangle().fill(UD.border).frame(width: 1)
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
            // 设计稿 settings.jsx：列头「已配置」（10.5pt、UD.text4、大写、字距 0.6）。
            Text("已配置")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)

            // 自绘扁平列表（取代 .listStyle(.sidebar) 的半透明侧边栏材质底——后者
            // 正是「侧边栏背景不对」的来源）。坐在 UD.bg 上，行用头像 tile + 名称 +
            // 模型，选中 / hover 用 UD.rowSelected / UD.rowHover。与 KeyManagerView 同构。
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(providers) { p in
                        ProviderRow(provider: p, selected: p.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = p.id }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(p.name)
                            .accessibilityValue(p.model.isEmpty ? "未设置模型" : p.model)
                            .accessibilityAddTraits(p.id == selectedID ? [.isButton, .isSelected] : .isButton)
                            // `onTapGesture` 不带 AX 默认动作，只标 `.isButton`
                            // 的话读屏 / 全键盘控制按下去是空转。显式补上。
                            .accessibilityAction { selectedID = p.id }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }

            // 列底栏 +/− 按钮：按用户要求去掉分隔条与底色，按钮直接坐在 UD.bg 上
            // （flush，无 borderTop / 无 panel 底）。
            HStack(spacing: 4) {
                UDIconButton(systemImage: "plus") { addProvider() }
                .help("新增 provider")
                .accessibilityLabel("新增 provider")

                UDIconButton(systemImage: "minus") { deleteSelected() }
                .disabled(selectedID == nil)
                .help("删除选中 provider")
                .accessibilityLabel("删除选中 provider")

                Spacer()
            }
            .padding(6)
        }
        .frame(width: 220)
        // 列整体坐在 UD.bg 上（与设计稿一致：列无独立底色，仅靠 borderRight 区隔）。
        .background(UD.bg)
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
            model: "",   // 由编辑页从 provider 实时模型列表里选
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

/// 设计稿 settings.jsx 列表行：22×22 accent 头像 tile（首字母）+ 名称（12.5pt medium）
/// + 模型（11pt mono、UD.text3、省略号）。选中 = UD.rowSelected 底，hover = UD.rowHover。
private struct ProviderRow: View {
    let provider: AIProvider
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(provider.name.prefix(1).uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(UD.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(UD.accentSoft))

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                Text(provider.model.isEmpty ? "未设置模型" : provider.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? UD.rowSelected : (hovering ? UD.rowHover : Color.clear))
        )
        .onHover { hovering = $0 }
    }
}
