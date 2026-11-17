import UDesignKit
import SwiftUI

/// 快捷命令新建 / 编辑表单（复刻原型 `QcForm`，右栏内联）。
/// 字段：名称 / 关联服务器（多选 + 分组三态）/ 执行命令 / AI 介入。
struct QuickCommandForm: View {
    let hostRefs: [QuickCommandHostRef]
    let initial: QuickCommand?
    let onCancel: () -> Void
    let onSave: (FormData) -> Void

    struct FormData {
        var name: String
        var serverIDs: [UUID]
        var command: String
        var intent: String
        var aiAssisted: Bool
    }

    @State private var name: String
    @State private var selected: Set<UUID>
    @State private var command: String
    @State private var intent: String
    @State private var aiAssisted: Bool
    @State private var serverPopoverOpen = false

    init(hostRefs: [QuickCommandHostRef],
         initial: QuickCommand?,
         onCancel: @escaping () -> Void,
         onSave: @escaping (FormData) -> Void) {
        self.hostRefs = hostRefs
        self.initial = initial
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _command = State(initialValue: initial?.command ?? "")
        _intent = State(initialValue: initial?.intent ?? "")
        _aiAssisted = State(initialValue: initial?.aiAssisted ?? false)
        // 创建时默认选中第一台（对齐原型）；编辑时沿用既有绑定。
        // 仅保留仍可选的主机 id（剔除已删除 / 现为 sftpOnly 的悬空绑定）——
        // 否则 allSelected/「N/总数」与三态会与可见复选框对不上。保存时 orderedSelection
        // 同样按 hostRefs 过滤，故净保存结果不变。
        let validIDs = Set(hostRefs.map(\.id))
        let seedIDs = (initial?.serverIDs ?? hostRefs.first.map { [$0.id] } ?? [])
            .filter { validIDs.contains($0) }
        _selected = State(initialValue: Set(seedIDs))
    }

    private var orderedSelection: [UUID] {
        hostRefs.filter { selected.contains($0.id) }.map(\.id)
    }

    private var valid: Bool {
        QuickCommandLogic.isSaveable(name: name, hasServers: !selected.isEmpty,
                                     command: command, intent: intent, ai: aiAssisted)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(initial == nil ? "新建快捷命令" : "编辑快捷命令")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    QCField(label: "名称") {
                        UDTextField(placeholder: "例如：重启 Nginx 并健康检查", text: $name)
                    }
                    QCField(label: "关联主机", hint: "可多选 · 并行执行") {
                        serverMultiSelect
                    }
                    // AI 介入开启时先出现「AI 指令（自然语言）」——AI 命令以说人话为主。
                    if aiAssisted {
                        QCField(label: "AI 指令", hint: "自然语言 · 描述你想让 AI 做什么") {
                            intentEditor
                        }
                    }
                    // AI 时命令字段降级为「等效命令 · AI 实际执行 · 可留空让 AI 自行决定」；非 AI 时为必填的执行命令。
                    QCField(label: aiAssisted ? "等效命令" : "执行命令",
                            hint: aiAssisted ? "AI 实际执行 · 可留空让 AI 自行决定" : "支持 && 串联多条") {
                        commandEditor
                    }
                    QCField(label: "AI 介入", hint: "可选") {
                        aiToggleRow
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 18, bottom: 8, trailing: 18))
            }

            HStack(spacing: 10) {
                Spacer()
                UDButton(title: "取消", style: .secondary, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                UDButton(title: "保存", style: .primary) {
                    guard valid else { return }
                    onSave(FormData(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    serverIDs: orderedSelection,
                                    command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                                    intent: intent.trimmingCharacters(in: .whitespacesAndNewlines),
                                    aiAssisted: aiAssisted))
                }
                .disabled(!valid)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        // 分区方案 v3.3：与左侧列表同为卡面色，靠 1pt 竖线分开（分隔线两侧同底色）。
        // 曾做成 panelHi 抬升块 + 6pt 间隙，「白卡里套灰卡」，用户要求返工。
        .overlay(alignment: .leading) { Rectangle().fill(UD.border).frame(width: 1) }
    }

    // MARK: 关联服务器多选

    private var serverMultiSelect: some View {
        Button { serverPopoverOpen.toggle() } label: {
            HStack(spacing: 9) {
                if let summary = QuickCommandLogic.selectionSummary(hostRefs, selected: selected) {
                    Circle().fill(UD.success).frame(width: 6, height: 6)
                    Text(summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                    if selected.count > 1 {
                        HStack(spacing: 4) {
                            QCParallelIcon(size: 10, color: UD.success)
                            Text("并行").font(.system(size: 10.5)).foregroundStyle(UD.success)
                        }
                    }
                } else {
                    Text("选择主机…（可多选）")
                        .font(.system(size: 13))
                        .foregroundStyle(UD.text4)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .rotationEffect(.degrees(serverPopoverOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous).fill(UD.inputBg))
            .overlay(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                .strokeBorder(serverPopoverOpen ? UD.accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .popover(isPresented: $serverPopoverOpen, arrowEdge: .bottom) {
            serverPopoverContent
        }
    }

    private var serverPopoverContent: some View {
        VStack(spacing: 0) {
            if hostRefs.isEmpty {
                Text("没有可用的主机")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text4)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(QuickCommandLogic.grouped(hostRefs), id: \.group) { group in
                            groupSection(name: group.group, hosts: group.hosts)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 240)

                HStack(spacing: 8) {
                    Text("\(selected.count) / \(hostRefs.count) 台 · 并行执行")
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text4)
                    Spacer()
                    Button(allSelected ? "清空" : "全选") {
                        selected = allSelected ? [] : Set(hostRefs.map(\.id))
                    }
                    .buttonStyle(.udPlain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text2)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UD.fillFaint))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
            }
        }
        .frame(width: 300)
        .background(UD.overlay)
    }

    private var allSelected: Bool {
        !hostRefs.isEmpty && selected.count == hostRefs.count
    }

    @ViewBuilder
    private func groupSection(name: String, hosts: [QuickCommandHostRef]) -> some View {
        let state = QuickCommandLogic.groupState(hosts, selected: selected)
        let picked = hosts.filter { selected.contains($0.id) }.count

        VStack(alignment: .leading, spacing: 0) {
            Button {
                let ids = hosts.map(\.id)
                if state.all { selected.subtract(ids) } else { selected.formUnion(ids) }
            } label: {
                HStack(spacing: 9) {
                    QCGroupCheck(on: state.all, partial: state.some && !state.all)
                    Text(name.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(UD.text3)
                    Text("\(picked)/\(hosts.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(UD.text4)
                    Spacer()
                    Text(state.all ? "取消整组" : "选择整组")
                        .font(.system(size: 10.5))
                        .foregroundStyle(state.some ? UD.accent : UD.text4)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)

            ForEach(hosts) { host in
                hostRow(host)
            }
        }
    }

    @ViewBuilder
    private func hostRow(_ host: QuickCommandHostRef) -> some View {
        let on = selected.contains(host.id)
        Button {
            if on { selected.remove(host.id) } else { selected.insert(host.id) }
        } label: {
            HStack(spacing: 10) {
                QCCheckbox(checked: on)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                    Text(host.endpoint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(UD.text4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(on ? UD.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
    }

    // MARK: AI 指令（自然语言）

    /// 紫色淡底多行编辑器，存 `intent`。正文走默认字体（说人话，非等宽），区别于下方等宽命令字段。
    private var intentEditor: some View {
        ZStack(alignment: .topLeading) {
            // 占位用 .opacity 切显隐而非 `if` 增删：TextEditor 在 ZStack 里被 `if` 移除兄弟节点时，
            // SwiftUI 的位置身份 diff 偶发不真正移除占位视图，导致占位与正文重叠（残影）。
            // 恒驻树 + 透明度切换可彻底避免该类身份错乱。
            Text("例如：重启 Nginx 后做健康检查，异常就自动诊断修复")
                .font(.system(size: 13))
                .foregroundStyle(UD.text4)
                .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 12))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(intent.isEmpty ? 1 : 0)
            TextEditor(text: $intent)
                .font(.system(size: 13))
                .foregroundStyle(UD.text)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 8))
                .frame(minHeight: 64)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.aiAccent.opacity(0.08)))
    }

    // MARK: 执行命令

    private var commandEditor: some View {
        ZStack(alignment: .topLeading) {
            // 占位用 .opacity 切显隐而非 `if` 增删，避免 ZStack 内 TextEditor 占位残影（详见 intentEditor 注释）。
            Text("sudo systemctl restart nginx && curl -fsS localhost/healthz")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(UD.text4)
                .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 12))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(command.isEmpty ? 1 : 0)
            TextEditor(text: $command)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(UD.text)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 8))
                .frame(minHeight: 80)
        }
        // 可编辑输入用 inputBg（可见灰底、无描边）——区别于只读命令展示块的 panelHi。
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.inputBg))
    }

    // MARK: AI 介入

    /// 「续接下一步」用正文色强调，其余继承 text2。AttributedString 避免 Text `+`（macOS 26 弃用）。
    private var aiBlurb: AttributedString {
        let head = AttributedString("运行时让 AI 读取输出、自动诊断并")
        var emphasis = AttributedString("续接下一步")
        emphasis.foregroundColor = UD.text
        return head + emphasis
    }

    private var aiToggleRow: some View {
        QCAiToggleRow(isOn: $aiAssisted) {
            Text(aiBlurb)
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 表单字段壳

/// 表单字段壳：标签 + 可选提示 + 内容。
private struct QCField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(UD.text2)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text4)
                }
            }
            content
        }
    }
}

// MARK: - 勾选件

/// 单台复选框（16×16）。选中 = accent 填充 + 白勾。
private struct QCCheckbox: View {
    let checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(checked ? UD.accent : UD.fillMed)
            .overlay {
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
    }
}

/// 分组三态勾选（全选 = 勾 / 半选 = 横线 / 未选 = 空）。
private struct QCGroupCheck: View {
    let on: Bool
    let partial: Bool
    private var active: Bool { on || partial }

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(active ? UD.accent : UD.fillMed)
            .overlay {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                } else if partial {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
    }
}
