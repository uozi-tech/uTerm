import SwiftUI
import SwiftData

/// 底部状态栏：设计稿 Telemetry 风格的密集语义色指标行。
/// 左：连接状态点 · 平台 · endpoint；右：uptime · load · CPU* · 内存* · 磁盘 · 时间
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
                Circle()
                    .fill(WS.color(for: ConnectionStatusDisplay(state: session.connectionState).tint))
                    .frame(width: 6, height: 6)
            }
            // 左：平台 + endpoint
            if let platform = t.platform {
                metric(icon: "shippingbox", color: WS.mPlatform, text: platform)
            }
            if let endpoint = endpointText {
                metric(icon: "server.rack", color: WS.mEndpoint, text: endpoint)
            }

            Spacer(minLength: 8)

            // 右：实时指标（仅在取到时显示）
            if t.reachable {
                if let up = t.uptime {
                    metric(icon: "clock", color: WS.mUptime, text: up)
                }
                if let load = t.load {
                    metric(icon: "waveform.path.ecg", color: WS.mLoad, text: load)
                }
                if let cpu = t.cpuPercent {
                    cpuItem(cpu, cores: t.cores)
                }
                if let mem = t.memUsedText, let pct = t.memPercent {
                    memItem(mem, pct: pct)
                }
                if let disk = t.diskUsedText {
                    metric(icon: "internaldrive", color: WS.mDisk, text: diskLabel(disk, pct: t.diskPercent))
                }
                if let ts = t.timestamp {
                    metric(icon: "calendar", color: WS.mEndpoint, text: ts)
                }
            } else if let tab = workspace.activeTab {
                // 未连接 / 无遥测：回退到窗格 · 标签计数。
                Text("\(tab.root.leafCount) 窗格 · \(workspace.tabs.count) 标签")
                    .foregroundStyle(WS.text3)
            }
        }
        .font(WS.mono(10.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(WS.panel)
    }

    // MARK: - 指标单元

    private func metric(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
        .foregroundStyle(color)
    }

    private func cpuItem(_ pct: Double, cores: Int?) -> some View {
        Button { cpuPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 9))
                Text(String(format: "%.0f%%", pct))
            }
            .foregroundStyle(WS.mCPU)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $cpuPopover, arrowEdge: .bottom) {
            SparklinePopover(
                title: "CPU 与负载",
                summary: cores.map { "\($0) 核 · \(String(format: "%.0f%%", pct))" }
                    ?? String(format: "%.0f%%", pct),
                color: WS.mCPU,
                history: workspace.telemetryModel.cpuHistory)
        }
    }

    private func memItem(_ text: String, pct: Double) -> some View {
        Button { memPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip").font(.system(size: 9))
                Text("\(text) · \(String(format: "%.0f%%", pct))")
            }
            .foregroundStyle(WS.mMem)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $memPopover, arrowEdge: .bottom) {
            SparklinePopover(
                title: "内存负载",
                summary: "\(text) · \(String(format: "%.0f%%", pct))",
                color: WS.mMem,
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
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text)
                Spacer()
                Text(summary).font(WS.mono(11)).foregroundStyle(color)
            }
            sparkline.frame(width: 280, height: 80)
            HStack {
                Text("-2 min"); Spacer(); Text("现在")
            }
            .font(WS.mono(9)).foregroundStyle(WS.text4)
        }
        .padding(12)
        .frame(width: 304)
        .background(WS.panelHi)
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
                    .stroke(WS.border, lineWidth: 1)
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
                        .font(WS.mono(10)).foregroundStyle(WS.text4)
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
