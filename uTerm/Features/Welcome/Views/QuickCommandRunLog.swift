import SwiftUI

/// 执行日志区（复刻原型 `QcRunLog` / `QcLogEntry`）：保留近 30 天，每条可展开看
/// 逐台退出码/耗时；若该次启用过 AI 介入，附紫色「AI 介入记录」块（诊断摘要 + 处置步骤）。
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
                VStack(spacing: 7) {
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
struct QuickCommandLogEntry: View {
    let run: QuickCommandRun
    @State private var open = false

    private var results: [QuickCommandServerResult] { run.results }
    private var failCount: Int { run.failureCount }
    private var allOK: Bool { run.allSucceeded }
    private var statusColor: Color { allOK ? UD.success : UD.danger }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 9) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(QuickCommandFormat.logTimestamp(run.startedAt))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(UD.text)
                        Text(overview)
                            .font(.system(size: 10.5))
                            .foregroundStyle(UD.text4)
                    }
                    Spacer(minLength: 4)
                    if run.aiRecord != nil { aiRecordTag }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UD.text4)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { result in
                        serverResultRow(result)
                    }
                    if let ai = run.aiRecord { aiRecordBlock(ai) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UD.fillFaint))
    }

    private var overview: String {
        let ok = results.count - failCount
        var parts = ["\(results.count) 台", "成功 \(ok)"]
        if failCount > 0 { parts.append("失败 \(failCount)") }
        parts.append(QuickCommandFormat.durationSeconds(run.durationMs))
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
        guard let code = result.exitCode else { return "连接失败 · \(result.durationMs)ms" }
        return "退出码 \(code) · \(result.durationMs)ms"
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

/// 执行日志的时间 / 耗时格式化。
nonisolated enum QuickCommandFormat {
    // 缓存格式化器（每条日志行都会调 logTimestamp，逐行新建 DateFormatter 很浪费）。
    // 仅 MainActor 的日志视图调用，故 @MainActor 静态存储，避开 DateFormatter 非 Sendable。
    @MainActor private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "HH:mm"; return f
    }()
    @MainActor private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("Md"); return f
    }()

    /// 友好时间戳：今天 HH:mm / 昨天 HH:mm / M月d日 HH:mm（按当前 locale）。
    @MainActor static func logTimestamp(_ date: Date) -> String {
        let cal = Calendar.current
        let time = timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInYesterday(date) { return "昨天 \(time)" }
        return "\(monthDayFormatter.string(from: date)) \(time)"
    }

    /// 毫秒 → "X.Xs"。
    static func durationSeconds(_ ms: Int) -> String {
        String(format: "%.1fs", Double(ms) / 1000)
    }
}
