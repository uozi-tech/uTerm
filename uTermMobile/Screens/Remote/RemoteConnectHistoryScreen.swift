import SwiftUI

/// 最近的连接：每次连接 Mac、打开屏幕的每一步（局域网、连中继、信令、直连、中继接通、验证身份……）
/// 什么时候开始、用了多久、成没成。弱网下连不上时不用插线抓日志，在这里看停在哪一步、拷贝给排查用。
struct RemoteConnectHistoryScreen: View {
    var log = RemoteConnectTraceLog.standard

    @State private var records: [RemoteConnectTraceRecord] = []
    @State private var copied = false
    @State private var confirmsClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if records.isEmpty {
                    Text("还没有连接记录。连接一次 Mac 或打开它的屏幕后，这里会列出每一步的耗时。")
                        .font(M.sans(13)).foregroundStyle(M.text3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.vertical, 40)
                }
                ForEach(records) { record in
                    MInsetGroup(header: header(record), footer: footer(record)) {
                        MInsetRow(icon: record.ok ? "check" : "x", iconColor: record.ok ? M.success : M.danger,
                                  label: record.outcome.isEmpty ? (record.ok ? "成功" : "失败") : record.outcome,
                                  value: "\(record.totalMillis) ms", last: record.steps.isEmpty)
                        ForEach(Array(record.steps.enumerated()), id: \.offset) { index, step in
                            MInsetRow(icon: icon(step), iconColor: color(step), label: step.stage.label,
                                      sub: step.detail, value: timing(step),
                                      last: index == record.steps.count - 1)
                        }
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: M.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(M.canvas)
        .navigationTitle("最近的连接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MMenu {
                    Button(copied ? "已拷贝" : "拷贝全部", systemImage: "doc.on.doc", action: copyAll)
                    Button("清空", systemImage: "trash", role: .destructive) { confirmsClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                // 挂在触发它的按钮上：宽屏下是 popover，挂在整页上会弹在屏幕正中。
                .confirmationDialog("清空全部连接记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
                    Button("清空", role: .destructive) {
                        log.clear()
                        records = []
                    }
                }
            }
        }
        .onAppear { records = log.load() }
    }

    private func header(_ record: RemoteConnectTraceRecord) -> String {
        let kind = record.kind == .desktop ? String(localized: "打开屏幕") : String(localized: "连接")
        return "\(kind) \(record.macName) · \(record.startedAt.formatted(date: .omitted, time: .standard))"
    }

    /// 网络放脚注：区段标题会转大写，「Wi-Fi」会变成「WI-FI」。
    private func footer(_ record: RemoteConnectTraceRecord) -> String? {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .omitted)]
        if let network = record.network { parts.append(network) }
        if record.attempt > 1 { parts.append(String(localized: "第 \(record.attempt) 次尝试")) }
        parts += record.events
        return parts.joined(separator: " · ")
    }

    private func timing(_ step: RemoteConnectTraceRecord.Step) -> String {
        let duration = step.durationMillis.map { "\($0) ms" } ?? String(localized: "未结束")
        return "+\(step.startMillis) · \(duration)"
    }

    private func icon(_ step: RemoteConnectTraceRecord.Step) -> String {
        switch step.ok {
        case true?: return "check"
        case false?: return "x"
        case nil: return "clock"
        }
    }

    private func color(_ step: RemoteConnectTraceRecord.Step) -> Color {
        switch step.ok {
        case true?: return M.success
        case false?: return M.danger
        case nil: return M.text3
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = RemoteConnectTraceLog.exportText(records)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
