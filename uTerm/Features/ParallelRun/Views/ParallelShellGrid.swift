import UDesignKit
import SwiftUI

/// Shell 视图：每台一个迷你终端窗格的网格。N≤3 → N 列；N≥4 → 2 列。
/// 同一条命令在各台并行下发，窗格各自独立展示输出 + 退出码。
struct ParallelShellGrid: View {
    let states: [ParallelServerState]
    /// 某台「主机指纹未信任」时，用户点窗格内「信任并重试」的回调（serverID）。
    var onTrustAndRetry: (UUID) -> Void = { _ in }

    private var columns: Int { states.count <= 3 ? max(1, states.count) : 2 }

    var body: some View {
        GeometryReader { geo in
            let cols = columns
            let rows = Int(ceil(Double(states.count) / Double(cols)))
            let cellW = geo.size.width / CGFloat(cols)
            let cellH = rows > 0 ? geo.size.height / CGFloat(rows) : geo.size.height
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: cols), spacing: 0) {
                ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                    ParallelShellPane(state: state,
                                      edgeRight: index % cols != cols - 1,
                                      edgeBottom: index < states.count - cols,
                                      onTrustAndRetry: onTrustAndRetry)
                        .frame(width: cellW, height: cellH)
                }
            }
        }
        .background(ParTermSurface.bg)
    }
}

/// 单台迷你终端窗格：顶部 2px 状态色条 + header（状态点 / 名 / endpoint / 退出码或运行中）
/// + 等宽逐行输出。
struct ParallelShellPane: View {
    let state: ParallelServerState
    let edgeRight: Bool
    let edgeBottom: Bool
    var onTrustAndRetry: (UUID) -> Void = { _ in }

    @State private var followsTail = true
    @State private var pendingTailScroll: DispatchWorkItem?

    private var running: Bool { state.status == .running }
    private var failed: Bool { state.status == .failed }
    private var stateTint: Color {
        running ? UD.accent : (failed ? UD.danger : UD.success)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
        }
        // 运行中顶条用淡化强调色，完成后才满饱和（对齐原型「运行=淡条 / 完成=实条」层次）。
        .overlay(alignment: .top) { Rectangle().fill(running ? stateTint.opacity(0.6) : stateTint).frame(height: 2) }
        .overlay(alignment: .trailing) { if edgeRight { Rectangle().fill(UD.border).frame(width: 1) } }
        .overlay(alignment: .bottom) { if edgeBottom { Rectangle().fill(UD.border).frame(height: 1) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(stateTint).frame(width: 7, height: 7)
            Text(state.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
            Text(state.endpointDisplay)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(UD.text4)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if running {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    Text("运行中").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(UD.text3)
                }
            } else {
                // 有单条退出码（非 AI / AI 带初始命令）就显退出码；intent-only AI 无单一退出码 → 显成功/失败。
                Text(state.exitCode.map { "退出码 \($0) · \(durationText)" } ?? "\(failed ? "失败" : "成功") · \(durationText)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(failed ? UD.danger : UD.text4)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(UD.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private var body_: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ParTermLinesView(lines: state.lines)
                    // 主机指纹未信任：窗格内联展示指纹 +「信任并重试」。
                    if case .hostKeyUntrusted(let challenge) = state.failure {
                        HostKeyRetryCard(challenge: challenge) { onTrustAndRetry(state.id) }
                            .padding(.top, 8)
                    }
                    if running {
                        RunningCaret().padding(.top, 1)
                    }
                    Color.clear.frame(height: 1).id("shell-bottom")
                }
                .padding(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .tracking || phase == .interacting {
                    followsTail = false
                    cancelPendingTailScroll()
                }
                if phase == .idle {
                    followsTail = AgentScrollPolicy.isNearBottom(
                        visibleMaxY: context.geometry.visibleRect.maxY,
                        contentHeight: context.geometry.contentSize.height)
                }
            }
            // 终端跟随：输出增量追加时滚到底（自愈多步会持续追加命令输出）。
            // 大块输出常一次性追加（execBounded 整条命令跑完才回 → 多行同时进 lines）：同步
            // scrollTo 会滚到「旧底部」（新行还没布局），结果停在最新输出上方。用
            // 合并到下一批布局之后再滚，避免大输出时反复重入 LazyVStack 布局。
            .onChange(of: state.lines.count) { _, _ in
                scheduleTailScroll(proxy)
            }
            // 切换屏幕（Shell↔AI 切回、窗格重建）后贴底：切走时累积的输出，切回应看最新。
            .onAppear {
                Task { @MainActor in
                    proxy.scrollTo("shell-bottom", anchor: .bottom)
                }
            }
            .onDisappear { cancelPendingTailScroll() }
        }
    }

    private func scheduleTailScroll(_ proxy: ScrollViewProxy) {
        guard followsTail, pendingTailScroll == nil else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                pendingTailScroll = nil
                proxy.scrollTo("shell-bottom", anchor: .bottom)
            }
        }
        pendingTailScroll = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AgentScrollPolicy.coalescingDelay,
            execute: work)
    }

    private func cancelPendingTailScroll() {
        pendingTailScroll?.cancel()
        pendingTailScroll = nil
    }

    private var durationText: String {
        guard let ms = state.durationMs else { return "—" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }
}

/// 终端逐行输出渲染（Shell 窗格 / AI 泳道「原始命令与输出」共用）。终端面随主题翻
/// （深底亮字 / 白底深字），故文字直接用 UD 主题色；ok/err 用语义绿红，两档均可读。
struct ParTermLinesView: View {
    let lines: [ParallelTermLine]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 7) {
                    Self.prefix(line.kind)
                    Text(line.text)
                        .foregroundStyle(Self.color(line.kind))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    @ViewBuilder
    static func prefix(_ kind: ParallelTermLine.Kind) -> some View {
        switch kind {
        case .cmd: Text("$").foregroundStyle(UD.accent)
        case .ok:  Text("✓").foregroundStyle(UD.success)
        case .err: Text("✕").foregroundStyle(UD.danger)
        case .out: Text(" ").foregroundStyle(.clear)
        }
    }

    static func color(_ kind: ParallelTermLine.Kind) -> Color {
        switch kind {
        case .cmd: return UD.text
        case .ok:  return UD.success
        case .err: return UD.danger
        case .out: return UD.text3
        }
    }
}

/// 运行中末行的**稳定**光标块（不闪烁，对齐项目稳定光标的设计语言）。运行态由窗格头部
/// 「运行中」spinner 表达，此光标只作终端视觉收尾。
struct RunningCaret: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(UD.accent)
            .frame(width: 7, height: 13)
    }
}
