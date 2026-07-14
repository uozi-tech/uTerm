import UDesignKit
import SwiftUI
import SwiftData

/// 底部状态栏：设计稿 Telemetry 风格的密集语义色指标行。
/// 左：连接状态点 · 平台 · endpoint；右：uptime · load+CPU* · 内存* · 磁盘 · 时间
/// （`*` 可点，弹出滚动 sparkline）。遥测取不到时回退到「窗格 · 标签」计数。
struct StatusBarView: View {
    let workspace: WorkspaceModel

    @Query private var profiles: [ServerProfile]
    @State private var cpuPopover = false
    @State private var memPopover = false

    var body: some View {
        let t = workspace.telemetryModel.display
        HStack(spacing: 10) {
            // 连接状态点（聚焦窗格）
            if let session = workspace.activeTab?.focusedPane?.session {
                let display = ConnectionStatusDisplay(state: session.connectionState)
                Circle()
                    .fill(display.tint.color)
                    .frame(width: 6, height: 6)
                    // 纯色状态点：给 VoiceOver 念读「已连接 / 连接中…」等文案。
                    .accessibilityLabel(Text(display.label))
                    .help(display.label)
            }
            // 左：平台 + endpoint
            if let platform = t.platform {
                metric(icon: "shippingbox", color: UD.mPlatform, text: platform)
            }
            if let endpoint = endpointText {
                metric(icon: "server.rack", color: UD.mEndpoint, text: endpoint)
            }

            // 文件传输 —— 复用独立 SFTP 窗口的传输 Dock。
            // 喂同一个 workspace.fileBrowserModel —— 与左侧 SFTPSidebar 的上传共享
            // 队列、进度与取消/重试，单文件内联进度、多文件点击展开上传列表。
            SFTPTransfersDock(
                transfers: workspace.fileBrowserModel.transfers,
                onCancel: { workspace.fileBrowserModel.cancelTransfer($0) },
                onCancelAll: { workspace.fileBrowserModel.cancelAllActiveTransfers() },
                onClearFinished: { workspace.fileBrowserModel.clearFinishedTransfers() },
                onRetry: { workspace.fileBrowserModel.retryTransfer($0) })

            Spacer(minLength: 8)

            // 右：实时指标（仅在取到时显示）
            if t.reachable {
                if let up = t.uptime {
                    metric(icon: "clock", color: UD.mUptime, text: up)
                }
                if let cpu = t.cpuPercent {
                    cpuLoadItem(load: t.load, cpu: cpu, cores: t.cores)
                } else if let load = t.load {
                    metric(icon: "waveform.path.ecg", color: UD.mLoad, text: load)
                }
                if let mem = t.memUsedText, let pct = t.memPercent {
                    memItem(mem, pct: pct)
                }
                if let disk = t.diskUsedText {
                    metric(icon: "internaldrive", color: UD.mDisk, text: diskLabel(disk, pct: t.diskPercent))
                }
                if let ts = t.timestamp {
                    metric(icon: "calendar", color: UD.mEndpoint, text: ts)
                }
            } else if let tab = workspace.activeTab {
                // 未连接 / 无遥测：回退到窗格 · 标签计数。
                Text("\(tab.root.leafCount) 窗格 · \(workspace.tabs.count) 标签")
                    .foregroundStyle(UD.text3)
            }
        }
        .font(UD.mono(10.5))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(UD.panel)
    }

    // MARK: - 指标单元

    private func metric(icon: String, color: Color, text: String) -> some View {
        UDFooterItem(systemImage: icon, color: color, label: text, iconSize: 11)
    }

    static func cpuLoadSummary(load: String?, cpuPercent: Double, cores: Int?) -> String {
        var parts: [String] = []
        if let load {
            parts.append("负载 \(load)")
        }
        if let cores {
            parts.append("\(cores) 核")
        }
        parts.append("CPU \(String(format: "%.0f%%", cpuPercent))")
        return parts.joined(separator: " · ")
    }

    private func cpuLoadItem(load: String?, cpu: Double, cores: Int?) -> some View {
        Button { cpuPopover.toggle() } label: {
            HStack(spacing: 8) {
                if let load {
                    UDFooterItem(systemImage: "waveform.path.ecg", color: UD.mLoad,
                                 label: load, iconSize: 11)
                }
                UDFooterItem(systemImage: "cpu", color: UD.mCPU,
                             label: String(format: "%.0f%%", cpu), iconSize: 11)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.cpuLoadSummary(load: load, cpuPercent: cpu, cores: cores)))
        .help("查看 CPU 与负载历史")
        .popover(isPresented: $cpuPopover, arrowEdge: .bottom) {
            SparklinePopover(
                title: "CPU 与负载",
                summary: Self.cpuLoadSummary(load: load, cpuPercent: cpu, cores: cores),
                color: UD.mCPU,
                history: workspace.telemetryModel.cpuHistory)
        }
    }

    private func memItem(_ text: String, pct: Double) -> some View {
        Button { memPopover.toggle() } label: {
            UDFooterItem(systemImage: "memorychip", color: UD.mMem,
                         label: "\(text) · \(String(format: "%.0f%%", pct))", iconSize: 11)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("内存 \(text) · \(String(format: "%.0f%%", pct))"))
        .help("查看内存负载历史")
        .popover(isPresented: $memPopover, arrowEdge: .bottom) {
            SparklinePopover(
                title: "内存负载",
                summary: "\(text) · \(String(format: "%.0f%%", pct))",
                color: UD.mMem,
                history: workspace.telemetryModel.memHistory)
        }
    }

    private func diskLabel(_ text: String, pct: Double?) -> String {
        guard let pct else { return text }
        return "\(text) · \(String(format: "%.0f%%", pct))"
    }

    private var endpointText: String? {
        guard let pane = workspace.activeTab?.focusedPane,
              let profile = profiles.first(where: { $0.id == pane.serverProfileID })
        else { return nil }
        return profile.displayEndpoint
    }
}

/// CPU / 内存指标点击弹出的 sparkline 卡片（最近 ~2 分钟）。
private struct SparklinePopover: View {
    let title: String
    let summary: String
    let color: Color
    let history: [Double]   // 0...100

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(UD.text)
                Spacer()
                Text(summary).font(UD.mono(11)).foregroundStyle(color)
            }
            sparkline.frame(width: 280, height: 80)
            HStack {
                Text("-2 min"); Spacer(); Text("现在")
            }
            .font(UD.mono(9)).foregroundStyle(UD.text4)
        }
        .padding(12)
        .frame(width: 304)
        .background(UD.panelHi)
    }

    private var sparkline: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                ForEach([25.0, 50.0, 75.0], id: \.self) { pct in
                    let y = geo.size.height * (1 - pct / 100)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(UD.border, lineWidth: 1)
                }
                if pts.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, lineWidth: 1.4)
                } else {
                    Text("采集中…")
                        .font(UD.mono(10)).foregroundStyle(UD.text4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard history.count >= 2 else { return [] }
        let stepX = size.width / CGFloat(history.count - 1)
        return history.enumerated().map { i, v in
            let clamped = min(100, max(0, v))
            return CGPoint(x: CGFloat(i) * stepX,
                           y: size.height * CGFloat(1 - clamped / 100))
        }
    }
}
