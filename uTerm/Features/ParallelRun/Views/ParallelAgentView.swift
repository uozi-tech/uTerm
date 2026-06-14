import SwiftUI

/// AI 视图：不堆 shell 输出，Agent 用自然语言逐台汇报（正常 / 已自愈 / 需处理），
/// 失败台被自动诊断并修复；末尾一段跨服务器 AI 汇总。居中收窄内容列（≈720）。
struct ParallelAgentView: View {
    let commandName: String
    let aiAssisted: Bool
    let states: [ParallelServerState]
    let synthesis: String
    let allDone: Bool

    private var total: Int { states.count }
    private var resolvedAll: Bool { states.allSatisfy { $0.tone != .running } }
    /// 仍在执行/诊断中，或 AI 命令已落定但跨台汇总尚未回来——都显示「汇总中」指示。
    private var showProgress: Bool {
        !resolvedAll || (aiAssisted && allDone && synthesis.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                opening
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(states) { ParallelAILane(state: $0) }
                }
                .padding(.leading, 32)

                if allDone && !synthesis.isEmpty {
                    synthesisCard
                }
                if showProgress {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                        Text(resolvedAll ? "正在生成跨服务器汇总…" : "正在并行执行并汇总…")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(UD.text3)
                    }
                    .padding(.leading, 32)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        }
        .background(UD.bg)
    }

    /// 「N 台」加粗强调，其余继承正文。用 AttributedString 避免 Text `+`（macOS 26 弃用）。
    private var openingText: AttributedString {
        let head = AttributedString("正在 ")
        var count = AttributedString("\(total) 台")
        count.font = .system(size: 13, weight: .semibold)
        let tail = AttributedString("服务器上并行执行「\(commandName)」。我会在每台上完成操作并验证结果，遇到异常时自动诊断并尝试修复 —— 下面用大白话逐台汇报，不用你去翻 shell 输出。")
        return head + count + tail
    }

    private var opening: some View {
        HStack(alignment: .top, spacing: 10) {
            ParAgentAvatar()
            Text(openingText)
                .font(.system(size: 13))
                .foregroundStyle(UD.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var synthesisCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ParAgentAvatar()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(UD.aiAccent)
                    Text("并行结果汇总").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UD.aiAccent)
                }
                Text(synthesis)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UD.aiAccent.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(UD.aiAccent.opacity(0.18), lineWidth: 1))
        }
        .transition(.opacity)
    }
}

/// 单台自然语言泳道卡。执行/诊断中显 spinner；落定后显结论 + （自愈时）处理步骤。
struct ParallelAILane: View {
    let state: ParallelServerState
    @State private var stepsOpen = false

    private var resolved: Bool { state.tone != .running }
    private var tint: Color {
        switch state.tone {
        case .running: return UD.aiAccent
        case .ok:      return UD.success
        case .healed:  return UD.caution
        case .failed:  return UD.danger
        }
    }
    private var emphasised: Bool { state.tone == .healed || state.tone == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if resolved {
                body_
            }
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(emphasised ? tint.opacity(0.06) : Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(emphasised ? tint.opacity(0.30) : UD.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(state.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UD.text)
            Text(state.endpointDisplay)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(UD.text4)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            statusBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { if resolved { Rectangle().fill(UD.border).frame(height: 1) } }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            if !resolved {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            }
            Text(badgeText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, resolved ? 8 : 0)
                .frame(height: resolved ? 20 : nil)
                .background {
                    if resolved {
                        Capsule().fill(tint.opacity(0.12))
                            .overlay(Capsule().strokeBorder(tint.opacity(0.38), lineWidth: 1))
                    }
                }
        }
    }

    private var badgeText: String {
        switch state.tone {
        case .running: return state.laneStatusText
        case .ok:      return "✓ 正常"
        case .healed:  return "⚠ 已自愈"
        case .failed:  return "✕ 需处理"
        }
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(state.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(UD.text2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !state.steps.isEmpty {
                stepsDisclosure
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
    }

    private var stepsDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { stepsOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UD.text3)
                        .rotationEffect(.degrees(stepsOpen ? 90 : 0))
                    Text(stepsOpen ? "收起处理过程" : "查看处理过程 · \(state.steps.count) 步")
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                }
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UD.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if stepsOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(UD.aiAccent)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(UD.aiAccent.opacity(0.12)))
                            Text(step)
                                .font(.system(size: 12))
                                .foregroundStyle(UD.text3)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}
