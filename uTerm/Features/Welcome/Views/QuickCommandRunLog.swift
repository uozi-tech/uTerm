import UDesignKit
import SwiftUI

/// 执行日志区（复刻原型 `QcRunLog` / `QcLogEntry`）：保留近 30 天，每条可展开看
/// 逐台退出码/耗时；若该次启用过 AI 介入，附紫色「AI 介入记录」块（诊断摘要 + 处置步骤）。
///
/// **渲染成本形态（见 `docs/scroll-perf-findings.md`「快捷命令执行日志」）**：
/// 行数 = 近 30 天的执行记录数，**没有上限**（`QuickCommandStore.runs(for:)`
/// 只按时间过滤、不 `fetchLimit`；每 10 分钟一次的巡检命令 30 天就是 4320 条）。
/// 改动时请守住三条：
///
/// 1. **列表保持 `LazyVStack`**（外层 `QuickCommandDetail` 已经是 `ScrollView`）。
/// 2. **行不要包回 `Button`**：展开走 `onTapGesture` + 手工 AX（`.isButton` +
///    展开态进 AX value + 默认动作）。
/// 3. **一次 body 只取一次 `results` / `aiRecord`**。它们背后是
///    `JSONDecoder`（模型侧已加 `@Transient` 解码缓存，但别再退回「随手多取几次」）。
struct QuickCommandRunLog: View {
    let runs: [QuickCommandRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("执行日志")
                    .font(.system(size: 10.5))
                    .tracking(0.5)
                    .foregroundStyle(UD.text4)
                Text("保留近 30 天")
                    .font(.system(size: 10))
                    .foregroundStyle(UD.text3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(UD.fillFaint))
                Spacer()
                Text("\(runs.count) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UD.text4)
            }

            if runs.isEmpty {
                VStack(spacing: 2) {
                    Text("暂无执行记录")
                    Text("运行后将在此保留近 30 天")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text4)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(UD.border))
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(runs) { run in
                        QuickCommandLogEntry(run: run)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("超过 30 天的执行记录与 AI 对话会自动清理")
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(UD.text4)
                .padding(.top, 2)
            }
        }
    }
}

/// 单条执行日志（可展开）。
///
/// 行体里 `results` / `aiRecord` **各只取一次值**（它们背后是 `JSONDecoder`），
/// 取出来的值往下传；别改回「行体里逐处再取一次」。
struct QuickCommandLogEntry: View {
    let run: QuickCommandRun
    @State private var open = false

    var body: some View {
        // 一次 body 只解一次 —— 下面所有派生量都从这两个局部量算。
        let results = run.results
        let aiRecord = run.aiRecord
        let failCount = results.reduce(0) { $0 + ($1.ok ? 0 : 1) }
        let allOK = !results.isEmpty && failCount == 0
        let statusColor = allOK ? UD.success : UD.danger
        let summary = overview(results: results, failCount: failCount)

        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(UTermFormat.logTimestamp(run.startedAt))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UD.text)
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(UD.text4)
                }
                Spacer(minLength: 4)
                if aiRecord != nil { aiRecordTag }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // 展开头不再是 `Button`（每行一个 plain Button 会常驻一个
            // `_FocusRingView` + 一个 `KeyViewProxy`），AX 语义手工补回。
            .onTapGesture { toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(UTermFormat.logTimestamp(run.startedAt))，\(summary)")
            .accessibilityValue(open ? "已展开" : "已折叠")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { result in
                        serverResultRow(result)
                    }
                    if let aiRecord { aiRecordBlock(aiRecord) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UD.fillFaint))
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
    }

    private func overview(results: [QuickCommandServerResult], failCount: Int) -> String {
        let ok = results.count - failCount
        var parts = ["\(results.count) 台", "成功 \(ok)"]
        if failCount > 0 { parts.append("失败 \(failCount)") }
        parts.append(UFormat.duration(milliseconds: Double(run.durationMs)))
        return parts.joined(separator: " · ")
    }

    private var aiRecordTag: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text("AI 记录").font(.system(size: 10))
        }
        .foregroundStyle(UD.aiAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(UD.aiAccent.opacity(0.12)))
    }

    private func serverResultRow(_ result: QuickCommandServerResult) -> some View {
        HStack(spacing: 8) {
            Circle().fill(result.ok ? UD.success : UD.danger).frame(width: 5, height: 5)
            Text(result.serverName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(resultDetail(result))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(result.ok ? UD.text4 : UD.danger)
                .lineLimit(1)
        }
    }

    private func resultDetail(_ result: QuickCommandServerResult) -> String {
        let duration = UFormat.duration(milliseconds: Double(result.durationMs))
        guard let code = result.exitCode else { return "连接失败或超时 · \(duration)" }
        return "退出码 \(code) · \(duration)"
    }

    private func aiRecordBlock(_ ai: QuickCommandAIRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text("AI 介入记录").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(UD.aiAccent)

            Text(ai.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text2)
                .fixedSize(horizontal: false, vertical: true)

            if !ai.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(ai.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(idx + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(UD.aiAccent)
                            Text(step)
                                .font(.system(size: 11))
                                .foregroundStyle(UD.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.aiAccent.opacity(0.10)))
    }
}
