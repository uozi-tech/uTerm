import SwiftUI
import SwiftData
import Combine

/// 并行执行请求（命令广播到多台主机）。由命令详情发起，根视图以全屏覆盖呈现。
struct ParallelRunRequest: Identifiable {
    let id = UUID()
    let commandID: UUID
    let name: String
    let command: String
    let intent: String
    let aiAssisted: Bool
    let serverIDs: [UUID]
}

/// 造并行控制器所需的、只有视图取得到的东西（`@Query` 出的主机与 provider、SwiftData 上下文）。
/// 见 `ParallelRunView.makeController`。
@MainActor
struct ParallelRunSetup {
    let request: ParallelRunRequest
    /// 按 `request.serverIDs` 选中的主机（顺序与 serverIDs 一致）。
    let targets: [ServerProfile]
    let providers: [AIProvider]
    let context: ModelContext
}

/// 并行执行全屏视图（设计稿 `ParallelRun`）：Shell 网格 + AI 泳道两视图共用一次真实执行。
struct ParallelRunView: View {
    let request: ParallelRunRequest
    /// 控制器工厂。默认造真控制器（真实 SSH 执行器），**生产调用点不变**；
    /// 探针注入一个带假执行器的控制器，整屏就能在没有真机器的情况下挂起来量。
    let makeController: @MainActor (ParallelRunSetup) -> ParallelRunController
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var allHosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]

    @State private var controller: ParallelRunController?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// - Parameters:
    ///   - makeController: 控制器工厂，默认造真控制器。
    ///   - controller: 直接给一个现成的控制器（**探针用**）。给了就跳过 `onAppear` 现造那一步，
    ///     首帧即内容（否则要先渲一帧 `ProgressView`，探针在那一帧里拿不到 `UIScrollView`）；
    ///     此时 `start()` 由调用方自己发。生产不传，走工厂。
    init(request: ParallelRunRequest,
         makeController: @escaping @MainActor (ParallelRunSetup) -> ParallelRunController
            = ParallelRunView.defaultController,
         controller: ParallelRunController? = nil,
         onClose: @escaping () -> Void) {
        self.request = request
        self.makeController = makeController
        self.onClose = onClose
        _controller = State(initialValue: controller)
    }

    var body: some View {
        Group {
            if let c = controller {
                content(c)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(M.bg)
            }
        }
        .onAppear { if controller == nil { setup() } }
        .onReceive(ticker) { t in if controller?.allDone == false { now = t } }
    }

    private func setup() {
        let targets = request.serverIDs.compactMap { id in allHosts.first { $0.id == id } }
        let c = makeController(ParallelRunSetup(request: request, targets: targets,
                                                providers: providers, context: context))
        controller = c
        c.start()
    }

    /// 默认工厂：真 AI doctor + 真 SSH 执行器 + 真 `QuickCommandStore`（与加注入口之前逐行一致）。
    @MainActor
    static func defaultController(_ setup: ParallelRunSetup) -> ParallelRunController {
        ParallelRunController(
            commandID: setup.request.commandID, commandName: setup.request.name,
            command: setup.request.command, intent: setup.request.intent,
            aiAssisted: setup.request.aiAssisted,
            targets: setup.targets, doctor: ParallelDoctor.make(provider: setup.providers.first),
            store: QuickCommandStore(context: setup.context), container: setup.context.container)
    }

    // MARK: 组合
    private func content(_ c: ParallelRunController) -> some View {
        @Bindable var c = c
        return VStack(spacing: 0) {
            nav(c)
            modeToggle(c)
            broadcastBar(c)
            if c.mode == .ai {
                aiBody(c)
            } else {
                shellBody(c)
            }
            statusBar(c)
        }
        .background(M.bg)
    }

    private func nav(_ c: ParallelRunController) -> some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                MIcon(name: "x", size: 17, color: M.text2).frame(width: 36, height: 36)
                    .background(M.fillFaint).clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if c.aiAssisted { MIcon(name: "spark", size: 13, color: M.aiAccent) }
                    Text(c.commandName).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
                }
                parBadge(ai: c.mode == .ai, n: c.total)
            }
            Spacer()
            Button { c.rerun() } label: {
                MIcon(name: "rerun", size: 17, color: c.allDone ? M.text2 : M.text4)
                    .frame(width: 36, height: 36).background(M.fillFaint)
                    .clipShape(Circle())
            }.disabled(!c.allDone)
        }
        .padding(.horizontal, 14).padding(.top, M.topBreath).padding(.bottom, 11)
        .background(M.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private func modeToggle(_ c: ParallelRunController) -> some View {
        HStack(spacing: 3) {
            ForEach(PMode.allCases, id: \.self) { m in
                let on = c.mode == m
                let c2: Color = m == .ai ? M.aiAccent : accent
                Button { c.mode = m } label: {
                    HStack(spacing: 6) {
                        if m == .ai { MIcon(name: "spark", size: 13, color: on ? .white : M.text2) }
                        Text(m == .ai ? "AI 介入" : "Shell")
                            .font(M.sans(13.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? .white : M.text2)
                    }
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(on ? c2 : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())   // 整段可点（含透明区），不必点到文字
                }.buttonStyle(MPressStyle())
            }
        }
        .padding(3).background(M.fillFaint)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 16).padding(.top, 10)
        .background(M.panel)
    }

    private func broadcastBar(_ c: ParallelRunController) -> some View {
        let tintC: Color = c.mode == .ai ? M.aiAccent : accent
        let elapsed = (c.finishedAt ?? now).timeIntervalSince(c.startedAt)
        return VStack(spacing: 10) {
            HStack(spacing: 9) {
                MIcon(name: "parallel", size: 13, color: tintC)
                if !c.broadcastIsIntent { Text("$").font(M.mono(13)).foregroundStyle(tintC) }
                Text(c.broadcastText).font(M.mono(13)).foregroundStyle(M.text2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(M.cmdSurface)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(M.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(M.fillFaint)
                        Capsule().fill(c.failedCount > 0 ? M.caution : tintC)
                            .frame(width: geo.size.width * (c.total == 0 ? 0 : Double(c.doneCount) / Double(c.total)))
                            .animation(.easeOut(duration: 0.35), value: c.doneCount)
                    }
                }.frame(height: 6)
                HStack(spacing: 11) {
                    Text("完成 \(c.doneCount)/\(c.total)").font(M.mono(12)).foregroundStyle(M.text2)
                    if c.failedCount > 0 {
                        Text("\(c.failedCount) 失败").font(M.mono(12)).foregroundStyle(M.danger)
                    }
                    Text(String(format: "%.1fs", elapsed)).font(M.mono(12)).foregroundStyle(M.text4)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(M.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private func shellBody(_ c: ParallelRunController) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(c.states) { s in
                    ParShellPane(state: s, accent: accent) { c.trustAndRetry(serverID: s.id) }
                    Rectangle().fill(M.divider).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.cmdSurface)
    }

    private func aiBody(_ c: ParallelRunController) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    agentAvatar
                    Text("正在 \(c.total) 台服务器上并行执行「\(c.commandName)」。完成后逐台汇报，遇异常自动诊断并尝试修复。")
                        .font(M.sans(14)).foregroundStyle(M.text).lineSpacing(2)
                }
                ForEach(c.states) { s in ParAILane(state: s) { c.trustAndRetry(serverID: s.id) } }
                if c.allDone && !c.synthesis.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        agentAvatar
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                MIcon(name: "spark", size: 13, color: M.aiAccent)
                                Text("并行结果汇总").font(M.sans(12.5, weight: .semibold)).foregroundStyle(M.aiAccent)
                            }
                            Text(c.synthesis).font(M.sans(14)).foregroundStyle(M.text).lineSpacing(2)
                        }
                        .padding(13)
                        .background(M.aiAccent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                }
                if !c.allDone {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在并行执行并汇总…").font(M.mono(12.5)).foregroundStyle(M.text3)
                    }
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.bg)
    }

    private func statusBar(_ c: ParallelRunController) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                MIcon(name: "parallel", size: 11, color: c.mode == .ai ? M.aiAccent : accent)
                Text(c.mode == .ai ? "AI 介入" : "并行广播").foregroundStyle(c.mode == .ai ? M.aiAccent : accent)
            }
            Text("\(c.total) 台").foregroundStyle(M.text3)
            Spacer()
            Text(c.allDone ? "已完成" : "执行中").foregroundStyle(M.text3)
        }
        .font(M.mono(11)).frame(height: 30).padding(.horizontal, 14)
        .background(M.panel)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var agentAvatar: some View {
        MIcon(name: "spark", size: 15, color: M.aiAccent)
            .frame(width: 30, height: 30)
            .background(M.aiAccent.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func parBadge(ai: Bool, n: Int) -> some View {
        let c: Color = ai ? M.aiAccent : M.success
        return HStack(spacing: 5) {
            MIcon(name: "parallel", size: 11, color: c)
            Text(ai ? "AI · \(n) 台" : "并行 · \(n) 台").font(M.sans(11.5, weight: .medium)).foregroundStyle(c)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(c.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Shell 窗格（逐台真实输出）

/// `internal` 而非 `private`：探针要单独挂一格来给「行数 / 台数各自涨多少」归因
/// （整屏读数分不出这两笔账）。可见性之外没有任何改动。
struct ParShellPane: View {
    let state: PServerState
    let accent: Color
    var onTrust: () -> Void

    private var tint: Color {
        switch state.status {
        case .running: return accent
        case .succeeded: return M.success
        case .failed: return M.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MDot(color: tint, pulse: state.status == .running, size: 7)
                Text(state.name).font(M.sans(13, weight: .semibold)).foregroundStyle(M.text)
                Text(state.endpointDisplay).font(M.mono(11)).foregroundStyle(M.text4).lineLimit(1)
                Spacer(minLength: 6)
                if state.status == .running {
                    Text("运行中").font(M.mono(11)).foregroundStyle(M.text3)
                } else if let code = state.exitCode {
                    Text("退出码 \(code)").font(M.mono(11)).foregroundStyle(state.status == .failed ? M.danger : M.text4)
                } else if state.status == .failed {
                    Text("失败").font(M.mono(11)).foregroundStyle(M.danger)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(M.panel)
            .overlay(alignment: .top) { Rectangle().fill(tint).frame(height: 2) }
            .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }

            // `LazyVStack` 而不是 `VStack`：一格就是一台的全部输出（自愈 6 步 × 200 行
            // 封顶 1200 行，极端档一格两万多 pt）。外层懒栈只保证「没进视野的**格**不建」，
            // 一旦某格进了视野，非懒的内层会把这一格的一千两百行**整批**建出来 ——
            // 实测（`ParallelRunProbeTests`，24 台 × 1200 行）翻到下一台那一跳
            // p50 316ms / max 367ms，是 16.67ms 预算的 19~22 倍；6 台 × 600 行也要 161ms。
            // 换成懒栈后只建视野内那几十行。
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(state.lines) { line in
                    HStack(alignment: .top, spacing: 7) {
                        switch line.kind {
                        case .cmd: Text("$").foregroundStyle(accent)
                        case .err: Text("✕").foregroundStyle(M.danger)
                        case .ok: Text("✓").foregroundStyle(M.success)
                        case .out: Text(" ").foregroundStyle(.clear)
                        }
                        Text(line.text).foregroundStyle(lineColor(line.kind))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(M.mono(12.5))
                }
                if state.hostKeyUntrusted {
                    MBtn(title: "信任并重试", icon: "shield", kind: .tinted, height: 36, action: onTrust)
                        .fixedSize().padding(.top, 8)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        }
    }

    private func lineColor(_ kind: PLine.Kind) -> Color {
        switch kind {
        case .cmd: return M.text
        case .err: return M.danger
        default: return M.text3
        }
    }
}

// MARK: - AI 泳道

/// `internal` 而非 `private`：探针要量「展开处理过程」这一下的成本，而 `open` 是
/// `@State`，外部点不到（SwiftUI 的 Button 在视图树里不是 `UIControl`，hitTest 也点不着）。
struct ParAILane: View {
    let state: PServerState
    /// 初始就展开「处理过程」。**默认 false = 现状**；只有探针会传 true，用来做展开前→后同轮对照。
    var initiallyOpen = false
    var onTrust: () -> Void
    @State private var open: Bool

    init(state: PServerState, initiallyOpen: Bool = false, onTrust: @escaping () -> Void) {
        self.state = state
        self.initiallyOpen = initiallyOpen
        self.onTrust = onTrust
        _open = State(initialValue: initiallyOpen)
    }

    private var resolved: Bool { state.tone != .running }
    private var tint: Color {
        switch state.tone {
        case .running: return M.aiAccent
        case .ok: return M.success
        case .failed: return M.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                MDot(color: tint, pulse: !resolved, size: 7)
                Text(state.name).font(M.sans(14, weight: .medium)).foregroundStyle(M.text)
                Text(state.endpointDisplay).font(M.mono(11)).foregroundStyle(M.text4).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if !resolved { ProgressView().controlSize(.mini) }
                    Text(state.laneStatusText).font(M.sans(11, weight: .medium)).foregroundStyle(tint)
                        .padding(.horizontal, resolved ? 8 : 0).padding(.vertical, resolved ? 2 : 0)
                        .background(resolved ? tint.opacity(0.12) : .clear)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .overlay(alignment: .bottom) { if resolved { Rectangle().fill(M.divider).frame(height: 1) } }

            if resolved {
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.summary).font(M.sans(13.5)).foregroundStyle(M.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.hostKeyUntrusted {
                        MBtn(title: "信任并重试", icon: "shield", kind: .tinted, height: 36, action: onTrust)
                            .fixedSize().padding(.top, 9)
                    }
                    if !state.steps.isEmpty {
                        Button { withAnimation { open.toggle() } } label: {
                            HStack(spacing: 6) {
                                MIcon(name: "chev", size: 11, color: M.text3, weight: .semibold)
                                    .rotationEffect(.degrees(open ? 90 : 0))
                                Text(open ? "收起处理过程" : "查看处理过程 · \(state.steps.count) 步")
                                    .font(M.sans(12)).foregroundStyle(M.text3)
                            }
                            .padding(.horizontal, 9).frame(height: 28)
                            .background(M.fillMed)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(MPressStyle()).padding(.top, 9)
                        if open {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(state.steps.enumerated()), id: \.offset) { i, step in
                                    HStack(alignment: .top, spacing: 9) {
                                        Text("\(i + 1)").font(M.mono(10.5)).foregroundStyle(M.aiAccent)
                                            .frame(width: 18, height: 18).background(M.aiAccent.opacity(0.12)).clipShape(Circle())
                                        Text(step).font(M.sans(13)).foregroundStyle(M.text3).lineSpacing(1)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }.padding(.top, 9)
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
            }
        }
        .background(state.tone == .failed ? M.danger.opacity(0.05) : M.fillFaint)
        // 失败态保留红描边（状态边）；常态卡片按 v2 只靠灰填充成形
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(state.tone == .failed ? M.danger.opacity(0.25) : .clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}
