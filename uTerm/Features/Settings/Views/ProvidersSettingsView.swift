import UDesignKit
import SwiftUI
import SwiftData

/// AI provider 配置面板。左列：已配置列表 + 底部「添加服务」/ 删除。右列：选中项编辑表单。
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
            HStack(spacing: 6) {
                Text("已配置")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .accessibilityAddTraits(.isHeader)
                UDCountBadge(providers.count)
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // 自绘扁平列表（取代 .listStyle(.sidebar) 的半透明侧边栏材质底）。坐在 UD.card 上，
            // 行 = 首字母方块 + 名称 + 类型 · 地址，选中 accentSoft，hover rowHover。
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(providers) { p in
                        ProviderRow(provider: p, selected: p.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = p.id }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(p.name)
                            .accessibilityValue(ProviderManagement.summary(p))
                            .accessibilityAddTraits(p.id == selectedID ? [.isButton, .isSelected] : .isButton)
                            // `onTapGesture` 不带 AX 默认动作，只标 `.isButton`
                            // 的话读屏 / 全键盘控制按下去是空转。显式补上。
                            .accessibilityAction { selectedID = p.id }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }

            HStack(spacing: 6) {
                UDAddButton(title: String(localized: "添加服务")) { addProvider() }
                    .help("添加模型服务")
                UDIconButton(systemImage: "trash", size: 32, style: .danger) { deleteSelected() }
                    .disabled(selectedID == nil)
                    .help("删除选中的模型服务")
                    .accessibilityLabel("删除选中的模型服务")
            }
            .padding(12)
        }
        .frame(width: 240)
        .background(UD.bg)
    }

    // MARK: - 右列

    @ViewBuilder
    private var detail: some View {
        if let provider = providers.first(where: { $0.id == selectedID }) {
            ProviderEditView(provider: provider)
        } else {
            VStack {
                SettingsEmptyRow(symbol: "sparkles",
                                 text: providers.isEmpty
                                    ? String(localized: "还没有模型服务。点左下角「添加服务」新增第一个。")
                                    : String(localized: "从左侧选择一个模型服务"))
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UD.bg)
        }
    }

    // MARK: - 动作

    private func addProvider() {
        selectedID = ProviderManagement.add(in: modelContext).id
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let p = providers.first(where: { $0.id == id }) else { return }
        ProviderManagement.delete(p, in: modelContext)
        selectedID = providers.first?.id
    }
}

/// 列表行：28pt 首字母方块（accent 14% 底）+ 名称（13pt）+ 类型 · 地址（11.5pt、UD.text3、省略号；
/// 不显示模型，见 `ProviderManagement.summary`）。选中 = accentSoft 底，hover = UD.rowHover。
private struct ProviderRow: View {
    let provider: AIProvider
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            SettingsListIcon.monogram(String(provider.name.prefix(1)).uppercased(), UD.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name.isEmpty ? String(localized: "未命名") : provider.name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? UD.accentInk : UD.text)
                    .lineLimit(1)
                Text(ProviderManagement.summary(provider))
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? UD.accentSoft : (hovering ? UD.rowHover : Color.clear))
        )
        .onHover { hovering = $0 }
    }
}
