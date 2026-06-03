import SwiftUI

/// 工作区底部状态栏的远程遥测。周期性在 SFTP 连接上跑一条合并命令
/// （`TelemetryParser.command`），解析 `/proc` 等并格式化成展示串 + CPU/内存
/// 滚动历史（供 sparkline）。复用 SFTP 的 SSH 连接、不碰交互 PTY。
///
/// Linux 优先；非 Linux（无 `/proc`）只显示能取到的（平台等），不伪造缺失指标。
@MainActor
@Observable
final class TelemetryModel {

    /// 展示用快照：格式化好的字符串 + 百分比（百分比另供 sparkline / 进度判断）。
    struct Display: Equatable {
        var platform: String?      // "Ubuntu 22.04 LTS"
        var uptime: String?        // "47d 16h"
        var load: String?          // "0.42"
        var cpuPercent: Double?    // 64.0（首拍 nil = 还在建基线）
        var cores: Int?            // 8
        var memUsedText: String?   // "1.2 GB"
        var memPercent: Double?    // 30.0
        var diskUsedText: String?  // "42.1 GB"
        var diskPercent: Double?   // 21.0
        var timestamp: String?     // "2026-05-25 14:22:08"
        /// 本拍是否成功取到远端数据（用于「未连接 → 不显示遥测」）。
        var reachable: Bool = false
    }

    private(set) var display = Display()
    private(set) var cpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []

    /// 滚动历史窗口（~2 分钟 @ 3s）。
    private let historyLimit = 40
    private let interval: Duration = .seconds(3)

    /// 延迟取 SFTP provider（连上后才非 nil）——与 `FilePreviewModel` 同款解耦。
    private let providerProvider: () -> (any SFTPProviding)?
    private var pollTask: Task<Void, Never>?
    private var prevCPUIdle: UInt64?
    private var prevCPUTotal: UInt64?

    init(provider: @escaping () -> (any SFTPProviding)?) {
        self.providerProvider = provider
    }

    /// 启动轮询（幂等）。SFTP 尚未连上时每拍 no-op，连上后自动出数；与视图
    /// 生命周期解耦（独立 Task），仅 `stop()` 能终止。
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 轮询主循环（MainActor 隔离）。每拍 tick 后睡 `interval`；`await` 期间释放
    /// MainActor，不阻塞 UI。`stop()` 取消任务即跳出。
    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: interval)
        }
    }

    private func tick() async {
        guard let provider = providerProvider() else {
            if display.reachable { display.reachable = false }
            return
        }
        guard let output = try? await provider.exec(TelemetryParser.command) else {
            if display.reachable { display.reachable = false }
            return
        }
        apply(TelemetryParser.parse(output))
    }

    private func apply(_ raw: TelemetryParser.RawSample) {
        var d = Display()
        d.reachable = true
        d.platform = raw.prettyName ?? raw.osName
        d.cores = raw.cores
        if let up = raw.uptimeSeconds { d.uptime = Self.formatUptime(up) }
        if let l = raw.load1 { d.load = String(format: "%.2f", l) }

        // CPU%：相邻两次 /proc/stat 差分；首拍只建基线。
        let cpu = TelemetryParser.cpuPercent(
            prevIdle: prevCPUIdle, prevTotal: prevCPUTotal,
            idle: raw.cpuIdle, total: raw.cpuTotal)
        prevCPUIdle = raw.cpuIdle
        prevCPUTotal = raw.cpuTotal
        d.cpuPercent = cpu
        if let cpu { pushHistory(&cpuHistory, cpu) }

        // 内存：used = total − available。
        if let total = raw.memTotalKB, let avail = raw.memAvailableKB, total > 0 {
            let used = total > avail ? total - avail : 0
            d.memUsedText = Self.formatKB(used)
            let pct = Double(used) / Double(total) * 100
            d.memPercent = pct
            pushHistory(&memHistory, pct)
        }

        // 磁盘。
        if let used = raw.diskUsedKB { d.diskUsedText = Self.formatKB(used) }
        d.diskPercent = raw.diskPercent.map(Double.init)

        if let epoch = raw.epoch { d.timestamp = Self.formatTime(epoch) }

        display = d
    }

    private func pushHistory(_ arr: inout [Double], _ value: Double) {
        arr.append(value)
        if arr.count > historyLimit { arr.removeFirst(arr.count - historyLimit) }
    }

    // MARK: - 格式化

    static func formatUptime(_ seconds: Double) -> String {
        let s = Int(seconds)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func formatKB(_ kb: UInt64) -> String {
        Self.byteFormatter.string(fromByteCount: Int64(clamping: kb) &* 1024)
    }

    static func formatTime(_ epoch: Int) -> String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useGB, .useMB]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
