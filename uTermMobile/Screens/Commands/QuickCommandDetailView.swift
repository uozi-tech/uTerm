import UDesignKit
import SwiftUI
import SwiftData

/// 快捷命令详情（设计稿 `QcDetail`）：命令 / 意图、目标服务器、元信息、AI 介入开关、近 30 天执行日志。
/// 「运行」按钮把命令广播到目标主机（并行执行视图）。
struct QuickCommandDetailView: View {
    let cmd: QuickCommand
    @Environment(MobileStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent

    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @Query private var runs: [QuickCommandRun]

    @State private var editing = false
    @State private var pendingDelete = false

    init(cmd: QuickCommand) {
        self.cmd = cmd
        let id = cmd.id
        let cutoff = QuickCommandStore.expiryCutoff()
        _runs = Query(filter: #Predicate<QuickCommandRun> { $0.commandID == id && $0.startedAt >= cutoff },
                      sort: [SortDescriptor(\.startedAt, order: .reverse)])
    }

    private var targets: [ServerProfile] { cmd.serverIDs.compactMap { id in hosts.first { $0.id == id } } }
    private var n: Int { cmd.serverIDs.count }
    private var tint: Color { cmd.aiAssisted ? M.aiAccent : accent }
    private var runLabel: String { QuickCommandLogic.runLabel(serverCount: n, ai: cmd.aiAssisted) }
    private var commandStore: QuickCommandStore { QuickCommandStore(context: context) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    commandCard
                    targetsSection
                    metaGrid
                    aiToggle
                    runLogs
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
                .mReadableColumn()
            }
            actionBar
        }
        .background(M.canvas)
        .navigationTitle(cmd.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { CommandFormSheet(cmd: cmd).mSheetContentMargins() }
        .alert("删除命令「\(cmd.name)」？", isPresented: $pendingDelete) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作无法撤销。") }
    }

    // MARK: 头部
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 13) {
            qcGlyph(size: 46)
            VStack(alignment: .leading, spacing: 7) {
                Text(cmd.name).font(M.sans(19, weight: .bold)).tracking(-0.3).foregroundStyle(M.text)
                HStack(spacing: 7) {
                    serversBadge
                    if cmd.aiAssisted { aiBadge }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var commandCard: some View {
        Group {
            if cmd.aiAssisted {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        MIcon(name: "spark", size: 13, color: M.aiAccent)
                        Text("AI 指令 · 自然语言").font(M.sans(11.5, weight: .semibold)).foregroundStyle(M.aiAccent)
                    }
                    Text(QuickCommandLogic.aiIntentText(name: cmd.name, intent: cmd.intent))
                        .font(M.sans(14.5)).foregroundStyle(M.text).lineSpacing(3)
                    if !cmd.command.isEmpty {
                        Text("$ \(cmd.command)").font(M.mono(13)).foregroundStyle(M.text2)
                            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(M.cmdSurface)
                            // 卡片底部的嵌套块，与卡片同心（距边 13pt）
                            .clipShape(RoundedRectangle(cornerRadius: MRadius.inner(of: MRadius.list, inset: 13)))
                    }
                }
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(M.aiAccent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
            } else {
                Text("$ \(cmd.command)").font(M.mono(13.5)).foregroundStyle(M.text)
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(M.cmdSurface)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
            }
        }
        .padding(.top, 18)
    }

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MSectionCap(text: "目标主机 · \(n) 台")
                if n > 1 { Text("并行执行").font(M.sans(11)).foregroundStyle(M.success) }
            }
            VStack(spacing: 7) {
                ForEach(targets) { h in
                    HStack(spacing: 10) {
                        MDot(color: M.success, size: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(QuickCommandTargets.displayName(h)).font(M.sans(14, weight: .medium)).foregroundStyle(M.text)
                            Text(QuickCommandTargets.endpoint(h)).font(M.mono(12)).foregroundStyle(M.text4).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(M.card)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
                }
                if targets.isEmpty {
                    Text("尚未绑定主机").font(M.sans(13)).foregroundStyle(M.text4)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
        }
        .padding(.top, 20)
    }

    private var metaGrid: some View {
        let items: [(String, String, Bool)] = [
            ("执行方式", n > 1 ? "并行 · \(n) 台" : "单台", false),
            ("上次运行", lastRunText, false),
            ("运行次数", "\(cmd.runCount)", true),
            ("AI 介入", cmd.aiAssisted ? "已开启" : "已关闭", false),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                         spacing: 16) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0.uppercased()).font(M.sans(11)).tracking(0.4).foregroundStyle(M.text4)
                    Text(item.1).font(item.2 ? M.mono(14.5) : M.sans(14.5))
                        .foregroundStyle(item.0 == "AI 介入" && cmd.aiAssisted ? M.aiAccent : M.text)
                }
            }
        }
        .padding(.top, 20)
    }

    private var aiToggle: some View {
        HStack(spacing: 11) {
            MIcon(name: "spark", size: 16, color: cmd.aiAssisted ? M.aiAccent : M.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 介入").font(M.sans(14, weight: .medium)).foregroundStyle(M.text)
                Text("运行时让 AI 读取输出、自动诊断并续接下一步").font(M.sans(12)).foregroundStyle(M.text3)
            }
            Spacer(minLength: 6)
            MSwitch(on: Binding(get: { cmd.aiAssisted }, set: { commandStore.setAIAssisted(cmd, $0) }))
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(cmd.aiAssisted ? M.aiAccent.opacity(0.10) : M.card)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
        .padding(.top, 18)
    }

    private var runLogs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MSectionCap(text: "执行日志")
                Text("保留近 30 天").font(M.sans(10.5)).foregroundStyle(M.text3)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(M.fillFaint)
                    .clipShape(Capsule())
                Spacer()
                Text("\(runs.count) 条").font(M.mono(12)).foregroundStyle(M.text4)
            }
            if runs.isEmpty {
                Text("暂无执行记录\n运行后将在此保留近 30 天")
                    .font(M.sans(12.5)).foregroundStyle(M.text4).multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .overlay(RoundedRectangle(cornerRadius: MRadius.list).stroke(M.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
            } else {
                // 30 天内的记录可能上千条，每条首次渲染还要解一次 JSON：按需构建。
                LazyVStack(spacing: 8) { ForEach(runs) { run in RunLogRow(run: run) } }
            }
        }
        .padding(.top, 22)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            MBtn(title: runLabel, icon: cmd.aiAssisted ? "spark" : "run", kind: .primary, full: true, height: 48, tint: tint) {
                store.runCommand(cmd, hosts: hosts)
            }
            Button { editing = true } label: {
                MIcon(name: "edit", size: 18, color: M.text2).frame(width: 48, height: 48)
                    .background(M.button)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text("编辑命令"))
            Button { pendingDelete = true } label: {
                MIcon(name: "trash", size: 18, color: M.danger).frame(width: 48, height: 48)
                    .background(M.button)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text("删除命令"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        // 宽屏与上方内容同列宽，主按钮不横跨整屏。
        .mReadableColumn()
        // 底栏与画布靠底色差分区，不再叠 hairline（「线或底色差，二选一」）。
        .background(M.panel)
    }

    // MARK: 元件
    private func qcGlyph(size: CGFloat) -> some View {
        MIcon(name: cmd.aiAssisted ? "spark" : "bolt", size: size * 0.5, color: tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
    }
    private var serversBadge: some View {
        Group {
            if n <= 1 {
                Text(targets.first.map(QuickCommandTargets.displayName) ?? "\(n) 台").font(M.sans(12)).foregroundStyle(M.text3)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(M.fillFaint)
                    .clipShape(Capsule())
            } else {
                HStack(spacing: 5) {
                    MIcon(name: "parallel", size: 11, color: M.success)
                    Text("\(n) 台并行").font(M.sans(12, weight: .medium)).foregroundStyle(M.success)
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(M.success.opacity(0.14))
                .clipShape(Capsule())
            }
        }
    }
    private var aiBadge: some View {
        HStack(spacing: 4) {
            MIcon(name: "spark", size: 11, color: M.aiAccent)
            Text("AI 介入").font(M.sans(12, weight: .medium)).foregroundStyle(M.aiAccent)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(M.aiAccent.opacity(0.15))
        .clipShape(Capsule())
    }
    private var lastRunText: String { UTermFormat.relative(cmd.lastRunAt) }
    /// 连带删掉这条命令的全部执行日志（与 macOS 同一个入口）。
    private func delete() {
        commandStore.delete(cmd)
        dismiss()
    }
}

/// 单条执行日志（可展开逐台结果 + AI 记录）。
private struct RunLogRow: View {
    let run: QuickCommandRun
    @State private var open = false

    private var fail: Int { run.failureCount }
    private var tint: Color { fail > 0 ? M.danger : M.success }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation { open.toggle() } } label: {
                HStack(spacing: 10) {
                    MDot(color: tint, size: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(timeText).font(M.sans(13.5, weight: .medium)).foregroundStyle(M.text)
                        Text("\(run.results.count) 台 · 成功 \(run.results.count - fail)\(fail > 0 ? " · 失败 \(fail)" : "") · \(secText)")
                            .font(M.sans(11.5)).foregroundStyle(M.text4)
                    }
                    Spacer(minLength: 6)
                    if run.aiRecord != nil {
                        HStack(spacing: 3) {
                            MIcon(name: "spark", size: 9, color: M.aiAccent)
                            Text("AI").font(M.sans(10.5)).foregroundStyle(M.aiAccent)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(M.aiAccent.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    MIcon(name: "chev", size: 13, color: M.text4, weight: .semibold).rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(MRowStyle())

            if open {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(run.results) { r in
                        HStack(spacing: 8) {
                            MDot(color: r.ok ? M.success : M.danger, size: 6)
                            Text(r.serverName).font(M.sans(12.5, weight: .medium)).foregroundStyle(M.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("退出码 \(r.exitCode.map(String.init) ?? UFormat.placeholder) · \(UFormat.duration(milliseconds: Double(r.durationMs)))")
                                .font(M.mono(11.5)).foregroundStyle(r.ok ? M.text4 : M.danger)
                        }
                    }
                    if let ai = run.aiRecord {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                MIcon(name: "spark", size: 12, color: M.aiAccent)
                                Text("AI 介入记录").font(M.sans(11.5, weight: .semibold)).foregroundStyle(M.aiAccent)
                            }
                            Text(ai.summary).font(M.sans(12.5)).foregroundStyle(M.text2).lineSpacing(2)
                            ForEach(Array(ai.steps.enumerated()), id: \.offset) { i, step in
                                HStack(alignment: .top, spacing: 7) {
                                    Text("\(i + 1).").font(M.mono(11)).foregroundStyle(M.aiAccent)
                                    Text(step).font(M.sans(12)).foregroundStyle(M.text3)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(M.aiAccent.opacity(0.08))
                        // 展开区底部的嵌套块，与记录卡片同心（距底边 10pt）
                        .clipShape(RoundedRectangle(cornerRadius: MRadius.inner(of: MRadius.list, inset: 10)))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
            }
        }
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
    }

    private var timeText: String { UTermFormat.logTimestamp(run.startedAt) }
    private var secText: String { UFormat.duration(milliseconds: Double(run.durationMs)) }
}
