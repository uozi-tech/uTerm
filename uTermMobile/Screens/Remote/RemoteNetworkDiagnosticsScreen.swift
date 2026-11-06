import Network
import SwiftUI
import UIKit

/// 网络诊断：手机此刻的网络、中继、「只走公网」开关，以及对一台 Mac 的链路矩阵
/// （IPv6 直连、IPv4 直连、中继各跑几轮，看通断、建立耗时、往返与丢包）。
/// 入口：设置 › 关于 › 网络诊断；远控里 Mac 那一行的长按菜单（带上那台 Mac）。
struct RemoteNetworkDiagnosticsScreen: View {
    /// 从某台 Mac 的长按菜单进来时预选它。
    var preferredMacID: String?
    var log = RemotePathMatrixLog(defaults: .standard)

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.mAccent) private var accent
    @AppStorage(DefaultsKey.remoteIceProbeNote) private var note = ""
    @AppStorage(DefaultsKey.remotePathMatrixRounds) private var rounds = 3
    @AppStorage(DefaultsKey.remotePathMatrixModes) private var modesRaw = RemotePathProbeMode.allCases.map(\.rawValue)
        .joined(separator: ",")
    @State private var selectedMacID: String?
    @State private var network = "…"
    @State private var relayName: String?
    @State private var running: Task<Void, Never>?
    @State private var current: [RemotePathProbeResult] = []
    @State private var currentTotal = 0
    @State private var history: [RemotePathProbeResult] = []
    /// 打开页面时显示的上次结果；开始新一次诊断后换成本次的。
    @State private var lastRun: [RemotePathProbeResult] = []
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                networkGroup
                if !current.isEmpty || !lastRun.isEmpty { currentGroup }
                runControls
                targetGroup
                testsGroup
                if !history.isEmpty { historyGroup }
            }
            .padding(.top, 8)
            .frame(maxWidth: M.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(M.canvas)
        .navigationTitle("网络诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            directory.startBrowsing()
            relayName = directory.relayServerName()
            network = await RemoteNetworkLabel.current()
            history = log.load()
            lastRun = log.lastRun()
            if selectedMacID == nil { selectedMacID = preferredMacID ?? relayMacs.first?.id }
        }
        .onDisappear { running?.cancel() }
    }

    // MARK: - 网络

    private var networkGroup: some View {
        MInsetGroup(header: "网络", footer: "打开「只走公网」后，即使 Mac 就在同一个局域网里，连接也一律经中继或打洞，"
                    + "打洞也不用私有地址，用来复现外出时的情况。诊断量的始终是公网：插着数据线、连着同一个 Wi-Fi 都没关系。") {
            MInsetRow(icon: "globe", label: "手机网络", value: network)
            MInsetRow(icon: "link", label: "中继服务器", value: relayName ?? "未配置")
            MInsetRow(icon: "forward", label: "只走公网", last: true,
                      trailing: AnyView(MSwitch(on: internetOnlyBinding)))
        }
    }

    private var internetOnlyBinding: Binding<Bool> {
        Binding(get: { directory.internetOnly }, set: { directory.internetOnly = $0 })
    }

    // MARK: - 目标

    private var relayMacs: [RemoteMacDirectory.Mac] {
        directory.macs.filter(\.isOnRelay)
    }

    @ViewBuilder private var targetGroup: some View {
        let macs = relayMacs
        MInsetGroup(header: "诊断哪台 Mac", footer: macs.isEmpty ? emptyTargetHint : nil) {
            if macs.isEmpty {
                MInsetRow(icon: "mac", label: relayName == nil ? "还没有配置中继" : "没有在中继上的 Mac", last: true)
            } else {
                ForEach(macs) { mac in
                    MInsetRow(icon: "mac", label: mac.name, value: mac.endpoint == nil ? "中继" : "局域网 · 中继",
                              last: mac.id == macs.last?.id,
                              trailing: AnyView(selectionMark(mac.id == selectedMacID)),
                              onTap: running == nil ? { selectedMacID = mac.id } : nil)
                }
            }
        }
    }

    private var emptyTargetHint: String {
        relayName == nil
            ? "先在 Mac 的「设置 › 远程控制 › 中继服务器」导入中继配置，再让手机在局域网里连一次 Mac，配置会自动带过来。"
            : "Mac 要打开「设置 › 远程控制 › 允许经公网接入」并勾选这台手机。Mac 离线或睡眠时也看不到。"
    }

    @ViewBuilder private func selectionMark(_ selected: Bool) -> some View {
        if selected { MIcon(name: "check", size: 15, color: accent, weight: .semibold) }
    }

    // MARK: - 测试项

    private var modes: [RemotePathProbeMode] {
        let raw = Set(modesRaw.split(separator: ",").map(String.init))
        return RemotePathProbeMode.allCases.filter { raw.contains($0.rawValue) }
    }

    private func modeBinding(_ mode: RemotePathProbeMode) -> Binding<Bool> {
        Binding(get: { modes.contains(mode) }, set: { on in
            var set = Set(modes)
            if on { set.insert(mode) } else { set.remove(mode) }
            modesRaw = RemotePathProbeMode.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
        })
    }

    private var testsGroup: some View {
        MInsetGroup(header: "测试项", footer: "IPv6 直连要两端都有公网 IPv6；IPv4 直连要穿过两边的 NAT，"
                    + "运营商网络下常常不通；中继经服务器转发，是兜底的那条路。") {
            ForEach(RemotePathProbeMode.allCases, id: \.self) { mode in
                MInsetRow(label: mode.label, trailing: AnyView(MSwitch(on: modeBinding(mode))))
            }
            MInsetRow(label: "每条路跑几轮", trailing: AnyView(
                Stepper("\(rounds) 轮", value: $rounds, in: 1...10).fixedSize()
                    .font(M.sans(14)).foregroundStyle(M.text2)))
            HStack(spacing: 12) {
                Text("备注").font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                TextField("如：移动 5G ↔ 家里电信", text: $note)
                    .font(M.sans(14)).multilineTextAlignment(.trailing).foregroundStyle(M.text2)
            }
            .padding(.horizontal, 14).frame(minHeight: 50)
        }
    }

    // MARK: - 运行

    @ViewBuilder private var runControls: some View {
        VStack(spacing: 10) {
            if running != nil {
                ProgressView(value: Double(current.count), total: Double(max(1, currentTotal)))
                    .tint(accent)
                Text(progressText).font(M.sans(13)).foregroundStyle(M.text3)
                MBtn(title: "停止", kind: .secondary, full: true, height: 46) { running?.cancel() }
            } else {
                MBtn(title: "开始诊断", icon: "run", full: true, height: 46,
                     disabled: selectedMacID == nil || modes.isEmpty || relayMacs.isEmpty, action: run)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 22)
    }

    private var progressText: String {
        let next = currentTotal > current.count ? nextStep : nil
        return "已完成 \(current.count)/\(currentTotal)" + (next.map { " · 正在测 \($0)" } ?? "")
    }

    private var nextStep: String? {
        guard !modes.isEmpty else { return nil }
        let index = current.count
        return "第 \(index / modes.count + 1) 轮 \(modes[index % modes.count].label)"
    }

    private func run() {
        guard let mac = relayMacs.first(where: { $0.id == selectedMacID }),
              let probe = directory.pathMatrixRunner(for: mac) else { return }
        let modes = self.modes
        let rounds = self.rounds
        let note = self.note
        current = []
        currentTotal = rounds * modes.count
        running = Task {
            let network = await RemoteNetworkLabel.current()
            self.network = network
            _ = await probe.runner.run(mac: probe.peer, rounds: rounds, modes: modes) { finished in
                var result = finished
                result.note = note
                result.network = network
                await MainActor.run {
                    current.append(result)
                    log.append([result])
                }
            }
            history = log.load()
            lastRun = log.lastRun()
            running = nil
        }
    }

    // MARK: - 结果

    private var currentGroup: some View {
        let shown = current.isEmpty ? lastRun : current
        let header = running != nil ? "正在诊断" : current.isEmpty
            ? "上次结果 · \(shown.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")" : "本次结果"
        return MInsetGroup(header: header, footer: shown.first.map { context($0) }) {
            let summaries = RemotePathProbeSummary.summarize(shown)
            ForEach(summaries, id: \.mode) { summary in
                RemotePathSummaryRow(summary: summary, results: shown, last: summary.mode == summaries.last?.mode)
            }
        }
    }

    private var historyGroup: some View {
        MInsetGroup(header: "历史记录", headerTrailing: AnyView(historyActions),
                    footer: "最近 \(history.count) 条，只保存在这台手机上，不含 IP 地址。") {
            let recent = Array(history.prefix(30))
            ForEach(recent) { result in
                RemotePathHistoryRow(result: result, detail: historySub(result), last: result.id == recent.last?.id)
            }
        }
    }

    private var historyActions: some View {
        HStack(spacing: 14) {
            Button(copied ? "已复制" : "复制全部") {
                let summaries = RemotePathProbeSummary.summarize(history).map(\.line)
                UIPasteboard.general.string = (summaries + [""] + history.map(\.summaryLine)).joined(separator: "\n")
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            Button("清空", role: .destructive) {
                log.clear()
                history = []
                lastRun = []
                current = []
            }
            .disabled(running != nil)
        }
        .font(M.sans(12, weight: .semibold))
    }

    private func context(_ result: RemotePathProbeResult) -> String {
        [result.network, result.note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func historySub(_ result: RemotePathProbeResult) -> String {
        let context = context(result)
        let detail = result.connected
            ? "\(result.setupMillis ?? -1)ms · 往返 \(RemotePathProbeResult.format(result.roundTripMillis))"
                + "/\(RemotePathProbeResult.format(result.roundTripP95Millis)) · 丢包 \(result.lossPercent ?? -1)%"
            : (result.failure ?? "未知")
        return context.isEmpty ? detail : "\(context) · \(detail)"
    }
}

/// 一条路的汇总：通过率着色，下面一排四个读数。
private struct RemotePathSummaryRow: View {
    let summary: RemotePathProbeSummary
    let results: [RemotePathProbeResult]
    let last: Bool

    /// 失败原因按出现次数排：「超时 ×3」。
    private var failures: String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for result in results where result.mode == summary.mode && !result.connected {
            let reason = result.failure ?? "未知"
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: "；")
    }

    private var tone: Color {
        if summary.successes == summary.attempts { return M.success }
        return summary.successes == 0 ? M.danger : M.warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MDot(color: tone)
                Text(summary.mode.label).font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                Spacer()
                Text("通 ").font(M.sans(13)).foregroundStyle(M.text3)
                    + Text("\(summary.successes)/\(summary.attempts)").font(M.mono(14, weight: .semibold))
                    .foregroundStyle(tone)
            }
            if summary.successes > 0 {
                HStack(spacing: 0) {
                    metric("建立", summary.medianSetupMillis.map { "\($0)ms" })
                    metric("往返", RemotePathProbeResult.formatted(summary.medianRoundTripMillis))
                    metric("p95", RemotePathProbeResult.formatted(summary.medianP95Millis))
                    metric("丢包", summary.meanLossPercent.map { "\($0)%" })
                }
            }
            if !failures.isEmpty {
                Text(failures).font(M.sans(12)).foregroundStyle(M.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { if !last { MRowDivider() } }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(M.sans(11)).foregroundStyle(M.text3)
            Text(value ?? "–").font(M.mono(14)).foregroundStyle(value == nil ? M.text4 : M.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 历史里的一条：路名与通断一行，网络、备注、读数或失败原因一行（正文字体，不用等宽：中英混排等宽会拉开间距）。
private struct RemotePathHistoryRow: View {
    let result: RemotePathProbeResult
    let detail: String
    let last: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    MDot(color: result.connected ? M.success : M.danger, size: 7)
                    Text(result.mode.label).font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                }
                Text(detail).font(M.sans(12)).foregroundStyle(M.text3).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(result.date.formatted(date: .omitted, time: .shortened))
                .font(M.sans(13)).foregroundStyle(M.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) { if !last { MRowDivider() } }
    }
}

private extension RemotePathProbeResult {
    static func formatted(_ millis: Double?) -> String? {
        millis.map { String(format: "%.0fms", $0) }
    }
}

/// 手机此刻走的网络：Wi-Fi、蜂窝……
enum RemoteNetworkLabel {
    static func current() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                var parts: [String] = []
                if path.usesInterfaceType(.wifi) {
                    parts.append("Wi-Fi")
                } else if path.usesInterfaceType(.cellular) {
                    parts.append("蜂窝")
                } else if path.usesInterfaceType(.wiredEthernet) {
                    parts.append("有线")
                } else {
                    parts.append("其他")
                }
                parts.append(path.supportsIPv6 ? "有 IPv6" : "无 IPv6")
                continuation.resume(returning: parts.joined(separator: " · "))
            }
            monitor.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.network-label"))
        }
    }
}
