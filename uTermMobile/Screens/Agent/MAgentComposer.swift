import AgentKit
import SwiftUI

/// 终端 Agent 的输入区（iOS）。行为全在共享的 `AgentComposerSupport` 里（与 macOS
/// `AgentComposer` 同一份：模型菜单、思考深度、忙碌排队、停止、上下文附加），这里只管画：
///
/// - 一张卡片：上面是纵向增长的输入框（1…6 行），下面一行控件——附加上下文、模型、
///   思考深度（当前模型支持时才出现）、审批档位，右端主操作位。
/// - **一个主操作位**：空闲时是发送；Agent 在跑时同一位置是停止；忙碌且有草稿时停止 +
///   发送并排（草稿进待发队列）。与 macOS `UDAgentComposer` 一致。
/// - iOS 26 起卡片是液态玻璃（`glassEffect`），坐在 `safeAreaBar` 里，消息从它下面滚过时
///   由系统的滚动边缘效果虚化；更早的系统退回 `.bar` 材质。卡片里的控件不再叠玻璃
///   （HIG：不要玻璃叠玻璃），主操作是实心强调色圆钮。
/// - 硬件键盘（iPad / 外接）：↩ 发送、⇧↩ 或 ⌥↩ 换行、esc 停止。软键盘的回车照常换行。
struct MAgentComposer: View {
    @Bindable var model: AssistantModel
    @Binding var safety: AgentSafety
    @Binding var activeProviderIDString: String
    let placeholder: String
    let onSend: () -> Void
    let onAttach: () -> Void
    let onManageProviders: () -> Void

    @FocusState private var focused: Bool
    @State private var pickingModel = false
    @Environment(\.mAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = model.composerStatus {
                Label(status, systemImage: "stop.circle")
                    .font(M.sans(12)).foregroundStyle(M.text3)
                    .padding(.leading, 10)
                    .transition(.opacity)
            }
            card
        }
        .animation(.smooth(duration: 0.2), value: model.composerStatus)
        .sheet(isPresented: $pickingModel) {
            MModelPickerSheet(model: model, activeProviderIDString: $activeProviderIDString,
                              onManageProviders: onManageProviders)
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            TextField(model.composerPlaceholder(placeholder), text: $model.input, axis: .vertical)
                .font(M.sans(16)).foregroundStyle(M.text)
                .lineLimit(1...6)
                .focused($focused)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 4)
                .onKeyPress(.return, phases: .down, action: hardwareReturn)
                .onKeyPress(.escape) {
                    guard model.canStop else { return .ignored }
                    model.stop()
                    return .handled
                }
                .accessibilityLabel("给 Agent 的消息")

            HStack(spacing: 2) {
                attachButton
                // 逐级收缩（与 macOS `AgentComposer` 同一顺序）：完整 → 思考深度 / 审批档位只留
                // 图标 → 模型名也收窄。手机竖屏通常落在第二档，模型名保持完整。
                ViewThatFits(in: .horizontal) {
                    selectors(compactModel: false, compactOthers: false)
                    selectors(compactModel: false, compactOthers: true)
                    selectors(compactModel: true, compactOthers: true)
                }
                Spacer(minLength: 4)
                primaryActions
            }
            .padding(.leading, 6).padding(.trailing, 8).padding(.bottom, 8)
        }
        .mComposerSurface(shape)
        .contentShape(shape)
        .onTapGesture { focused = true }
    }

    // MARK: - 控件

    private var attachButton: some View {
        Button(action: onAttach) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(M.text2)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel("附加主机上下文")
    }

    private func selectors(compactModel: Bool, compactOthers: Bool) -> some View {
        HStack(spacing: 2) {
            modelChip(compact: compactModel)
            effortMenu(compact: compactOthers)
            safetyMenu(compact: compactOthers)
        }
    }

    /// 模型：打开可搜索的分组列表（全部服务的全部模型，取自各自的 `/v1/models`）。
    private func modelChip(compact: Bool) -> some View {
        Button {
            AgentModelDirectory.refresh(model.providers)
            pickingModel = true
        } label: {
            MComposerChip(showsChevron: true) {
                Text(AgentModelMenu.label(model.activeProvider))
                    .font(M.mono(12.5))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: compact ? 92 : 170, alignment: .leading)
                    .fixedSize(horizontal: !compact, vertical: false)
            }
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel("模型")
        .accessibilityValue(AgentModelMenu.help(model.activeProvider))
    }

    /// 思考深度：当前模型支持时才出现。
    @ViewBuilder
    private func effortMenu(compact: Bool) -> some View {
        if let choice = model.effortChoice {
            Menu {
                Picker("思考深度", selection: Binding(get: { choice.selection }, set: choice.select)) {
                    ForEach(choice.options, id: \.self) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            } label: {
                MComposerChip(showsChevron: !compact) {
                    Image(systemName: "brain").font(.system(size: 12.5))
                    if !compact { Text(choice.selectedLabel).font(M.sans(12.5)) }
                }
            }
            .menuOrder(.fixed)
            .accessibilityLabel("思考深度")
            .accessibilityValue(choice.selectedLabel)
        }
    }

    /// 审批档位：每一项带一行说明——三档的差别靠名字猜不出来。
    private func safetyMenu(compact: Bool) -> some View {
        Menu {
            Picker("审批档位", selection: $safety) {
                ForEach(AgentSafety.byAutonomy) { mode in
                    Label {
                        Text(mode.label)
                        Text(mode.detail)
                    } icon: {
                        Image(systemName: mode.symbolName)
                    }
                    .tag(mode)
                }
            }
        } label: {
            MComposerChip(showsChevron: !compact) {
                Image(systemName: safety.symbolName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(safety.mTint)
                if !compact { Text(safety.label).font(M.sans(12.5)) }
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("审批档位")
        .accessibilityValue(safety.label)
    }

    // MARK: - 主操作位

    @ViewBuilder
    private var primaryActions: some View {
        HStack(spacing: 6) {
            if model.canStop {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(M.text)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(M.fillMed))
                }
                .buttonStyle(MPressStyle())
                .accessibilityLabel("停止")
                .accessibilityHint("停止生成和审批，取消待执行命令；已下发命令继续回收结果")
                .transition(.scale.combined(with: .opacity))
            }
            if !model.canStop || model.hasDraft {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(model.hasDraft ? accent : M.text4.opacity(0.5)))
                }
                .buttonStyle(MPressStyle())
                .disabled(!model.hasDraft)
                .accessibilityLabel(model.isBusy ? "排队发送" : "发送")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
        .animation(.snappy(duration: 0.2), value: model.canStop)
        .animation(.snappy(duration: 0.2), value: model.hasDraft)
    }

    /// 硬件键盘 ↩ 发送；带 ⇧ / ⌥ 时放行给输入框换行。
    private func hardwareReturn(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
        onSend()
        return .handled
    }
}

// MARK: - 控件外观

/// 卡片工具栏里的幽灵控件：静态无底色，按下才出底（与 macOS `UDComposerGhostLabel` 同一语言），
/// 命中区补到 36pt 高。
private struct MComposerChip<Content: View>: View {
    var showsChevron = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(M.text4)
            }
        }
        .foregroundStyle(M.text2)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .contentShape(Rectangle())
    }
}

private extension View {
    /// 输入卡片的表面：iOS 26 液态玻璃，更早退回 `.bar` 材质 + hairline。
    @ViewBuilder
    func mComposerSurface(_ shape: RoundedRectangle) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.bar, in: shape)
                .overlay(shape.strokeBorder(M.border, lineWidth: 1))
        }
    }
}

extension AgentSafety {
    /// 最保守的一档不抢眼；放权越多颜色越醒目（与 macOS `AgentSafety.tint` 同一取色）。
    var mTint: Color {
        switch self {
        case .confirm:  return M.text3
        case .readAuto: return M.accent
        case .auto:     return M.warning
        }
    }
}

// MARK: - 模型选择

/// 全部服务的全部模型，按服务分组、可搜索（对齐 macOS 输入区的 `UDComposerModelMenu`）。
/// 分组、「不在列表中」标注、选中写回都走共享的 `AgentModelMenu` / `AssistantModel.selectModel`。
struct MModelPickerSheet: View {
    let model: AssistantModel
    @Binding var activeProviderIDString: String
    let onManageProviders: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var catalog: AgentModelCatalog { AgentModelDirectory.catalog }

    var body: some View {
        let groups = AgentModelMenu.groups(providers: model.providers, catalog: catalog)
        let selected = AgentModelMenu.itemID(model.activeProvider)
        NavigationStack {
            List {
                ForEach(groups) { group in
                    section(group, selected: selected)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型")
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { AgentModelDirectory.refresh(model.providers, force: true) } label: {
                        if catalog.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(catalog.isRefreshing)
                    .accessibilityLabel("刷新模型列表")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        dismiss()
                        onManageProviders()
                    } label: {
                        Label("管理模型服务", systemImage: "slider.horizontal.3")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func section(_ group: AgentModelGroup, selected: String?) -> some View {
        let items = filtered(group.items)
        // 搜索时整组都没命中就不显示这一组。
        if query.isEmpty || !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button { select(item) } label: { row(item, selected: item.id == selected) }
                }
                switch group.status {
                case .loading where items.isEmpty:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在获取模型列表…").foregroundStyle(M.text3)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(M.sans(13)).foregroundStyle(M.warning)
                case .ready where items.isEmpty && query.isEmpty:
                    Text("服务器没有返回任何模型").foregroundStyle(M.text3)
                default:
                    EmptyView()
                }
            } header: {
                Text(group.title)
            }
        }
    }

    private func row(_ item: AgentModelItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.model).font(M.mono(14)).foregroundStyle(M.text)
                if let detail = item.detail {
                    Text(detail).font(M.sans(12)).foregroundStyle(M.text4)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(M.accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func filtered(_ items: [AgentModelItem]) -> [AgentModelItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.model.localizedCaseInsensitiveContains(needle) }
    }

    private func select(_ item: AgentModelItem) {
        if let id = model.selectModel(item) { activeProviderIDString = id.uuidString }
        dismiss()
    }
}
