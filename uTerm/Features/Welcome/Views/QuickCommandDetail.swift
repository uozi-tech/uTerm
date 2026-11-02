import UDesignKit
import SwiftUI
import SwiftData
import AppKit

/// 快捷命令详情面板（复刻原型 `QcDetail`）：可滚动主体 + 底部固定操作栏。
/// 标题区 · 目标服务器列表 · 命令块 · 元信息 · AI 介入开关 · 执行日志（30 天）· 运行/编辑/删除。
struct QuickCommandDetail: View {
    let command: QuickCommand
    let hosts: [ServerProfile]
    var runner: QuickCommandRunner
    let onEdit: () -> Void
    let onToggleAI: (Bool) -> Void
    let onRun: () -> Void
    let onDelete: () -> Void

    @Query private var runs: [QuickCommandRun]
    @State private var copied = false
    /// AI 指令块里「查看等效命令」折叠态（默认收起，只呈现说人话的意图）。
    @State private var showEquivalent = false

    init(command: QuickCommand,
         hosts: [ServerProfile],
         runner: QuickCommandRunner,
         onEdit: @escaping () -> Void,
         onToggleAI: @escaping (Bool) -> Void,
         onRun: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.command = command
        self.hosts = hosts
        self.runner = runner
        self.onEdit = onEdit
        self.onToggleAI = onToggleAI
        self.onRun = onRun
        self.onDelete = onDelete

        let id = command.id
        let cutoff = QuickCommandStore.expiryCutoff()
        _runs = Query(filter: #Predicate { $0.commandID == id && $0.startedAt >= cutoff },
                      sort: \.startedAt, order: .reverse)
    }

    private var serverCount: Int { command.serverIDs.count }
    private var runTint: Color { command.aiAssisted ? UD.aiAccent : UD.accent }
    private var isRunning: Bool { runner.isRunning(command.id) }

    /// 目标服务器（已删除的服务器仍占位展示）。
    private var targets: [QuickCommandTargets.Resolved] {
        QuickCommandTargets.resolve(command.serverIDs, in: hosts)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    targetSection.padding(.top, 16)
                    commandRegion.padding(.top, 16)
                    metaGrid.padding(.top, 18)
                    aiToggleRow.padding(.top, 18)
                    QuickCommandRunLog(runs: runs).padding(.top, 18)
                }
                .padding(EdgeInsets(top: 22, leading: 22, bottom: 12, trailing: 22))
            }
            actionBar
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        // 分区方案 v3 第 7 条：卡内抬升块（`UD.panelHi`、圆角 8、四周距卡边 6pt），
        // 靠底色差与左侧列表分开，替代原来的左分隔线。
        .background(RoundedRectangle(cornerRadius: UD.Layout.wellRadius, style: .continuous)
            .fill(UD.panelHi))
        .padding(UD.Layout.wellGap)
    }

    // MARK: 标题区

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            QCPromptGlyph(size: 30, ai: command.aiAssisted)
            VStack(alignment: .leading, spacing: 4) {
                Text(command.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(UD.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    QCServersBadge(count: serverCount, firstName: targets.first?.name)
                    if command.aiAssisted { QCAiBadge(compact: true) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 目标服务器

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("目标服务器")
                if serverCount > 1 { QCParallelTag() }
                Spacer()
                Text("\(serverCount) 台")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UD.text4)
            }
            VStack(spacing: 6) {
                ForEach(targets, id: \.id) { target in
                    targetRow(target)
                }
            }
        }
    }

    @ViewBuilder
    private func targetRow(_ target: QuickCommandTargets.Resolved) -> some View {
        let phase = runner.phases(for: command.id)[target.id]
        HStack(spacing: 9) {
            statusDot(for: phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                if let endpoint = target.endpoint {
                    Text(endpoint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(UD.text4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let phase { phaseLabel(phase) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.fillFaint))
    }

    @ViewBuilder
    private func statusDot(for phase: QuickCommandRunner.ServerPhase?) -> some View {
        switch phase {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 6, height: 6)
        case .done(let ok, _, _):
            Circle().fill(ok ? UD.success : UD.danger).frame(width: 6, height: 6)
        case nil:
            Circle().fill(UD.success).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func phaseLabel(_ phase: QuickCommandRunner.ServerPhase) -> some View {
        switch phase {
        case .running:
            Text("运行中…").font(.system(size: 10.5)).foregroundStyle(UD.text4)
        case .done(let ok, let code, let ms):
            let duration = UFormat.duration(milliseconds: Double(ms))
            Text(ok ? "退出码 \(code ?? 0) · \(duration)" : (code == nil ? "连接失败" : "退出码 \(code!) · \(duration)"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(ok ? UD.text4 : UD.danger)
        }
    }

    // MARK: 命令区（AI 介入 → 自然语言指令块；非 AI → shell 代码块）

    /// AI 命令以自然语言意图为主；等效 shell 收进折叠，默认不堆在用户面前。
    @ViewBuilder
    private var commandRegion: some View {
        if command.aiAssisted {
            intentBlock
        } else {
            commandBlock
        }
    }

    // MARK: AI 指令块（自然语言 + 等效命令折叠）

    private var intentBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.aiAccent)
                Text("AI 指令 · 自然语言")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(UD.aiAccent)
            }
            Text(QuickCommandLogic.aiIntentText(name: command.name, intent: command.intent))
                .font(.system(size: 13))
                .foregroundStyle(UD.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)

            // 等效命令留空（让 AI 自行决定）时无可展开内容，整块折叠入口隐藏。
            if !command.command.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { showEquivalent.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(UD.text3)
                            .rotationEffect(.degrees(showEquivalent ? 90 : 0))
                        Text(showEquivalent ? "隐藏等效命令" : "查看等效命令")
                            .font(.system(size: 11))
                            .foregroundStyle(UD.text3)
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UD.fillFaint))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)

                if showEquivalent {
                    commandBlock.padding(.top, 9)
                }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UD.aiAccent.opacity(0.08)))
    }

    // MARK: 命令块

    private var commandBlock: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 0) {
                Text("$ ").foregroundStyle(runTint)
                Text(command.command).foregroundStyle(UD.text)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5, design: .monospaced))
            .textSelection(.enabled)
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            // 命令块底 = 终端底（设计稿 --u-term-bg）：外层详情已是 panelHi 抬升块。
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UD.termBg))

            Button(action: copy) {
                Text(copied ? "已复制" : "复制")
                    .font(.system(size: 10.5))
                    .foregroundStyle(copied ? UD.success : UD.text3)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UD.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UD.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    // MARK: 元信息

    private var metaGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 14) {
            metaCell("执行方式", serverCount > 1 ? "并行 · \(serverCount) 台" : "单台")
            metaCell("上次运行", UTermFormat.relative(command.lastRunAt))
            metaCell("运行次数", "\(command.runCount)", mono: true)
            metaCell("AI 介入", command.aiAssisted ? "已开启" : "关闭",
                     valueColor: command.aiAssisted ? UD.aiAccent : UD.text)
        }
    }

    private func metaCell(_ label: String, _ value: String, mono: Bool = false, valueColor: Color = UD.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel(label)
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }

    // MARK: AI 介入开关

    private var aiToggleRow: some View {
        QCAiToggleRow(isOn: Binding(get: { command.aiAssisted }, set: { onToggleAI($0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 介入")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(UD.text)
                Text("运行后把命令与输出交给 AI 助手诊断、续接下一步")
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 底部操作栏

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button(action: onRun) {
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Text("运行中…").font(.system(size: 13.5, weight: .medium))
                    } else {
                        if command.aiAssisted {
                            Image(systemName: "sparkles").font(.system(size: 12))
                        }
                        Text(QuickCommandLogic.runLabel(serverCount: serverCount, ai: command.aiAssisted))
                            .font(.system(size: 13.5, weight: .medium))
                        KbdReturn()
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(runTint))
                .opacity(isRunning ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .keyboardShortcut(.return, modifiers: [])

            squareButton(systemImage: "pencil", help: "编辑", action: onEdit)
            squareButton(systemImage: "trash", help: "删除", danger: true, action: onDelete)
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 16, trailing: 18))
    }

    private func squareButton(systemImage: String, help: String, danger: Bool = false,
                              action: @escaping () -> Void) -> some View {
        SquareActionButton(systemImage: systemImage, help: help, danger: danger, action: action)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .tracking(0.5)
            .foregroundStyle(UD.text4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.command, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .milliseconds(1400)); copied = false }
    }
}

/// 内嵌 ↵ 键帽（运行按钮里）。
private struct KbdReturn: View {
    var body: some View {
        Text("⏎")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.18)))
    }
}

/// 40×40 方钮（编辑 / 删除）。删除态 hover 红 tint 底 + 红描边。
private struct SquareActionButton: View {
    let systemImage: String
    let help: String
    var danger: Bool = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(foreground)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    private var foreground: Color {
        if danger { return hover ? UD.danger : UD.text3 }
        return UD.text2
    }
    private var fill: Color {
        if danger { return hover ? UD.danger.opacity(0.14) : UD.fillFaint }
        return hover ? UD.fillSoft : UD.fillFaint
    }
    private var border: Color {
        // 危险钮 hover 保留红描边（对齐 UDButton .danger）
        if danger, hover { return UD.danger.opacity(0.40) }
        return .clear
    }
}
