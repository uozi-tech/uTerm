import Network
import SwiftUI
import UIKit

/// 网络诊断：对一台 Mac 把局域网、IPv6 直连、IPv4 直连、中继各测一遍，给出「实际会走哪条路、多快」。
///
/// 每条路都强制只走自己，不看「只走公网」（那是正式连接的开发者选项，在 设置 › 远程控制）。
/// 入口：设置 › 远程控制 › 网络诊断；主机页「我的 Mac」那一行的长按菜单（带上那台 Mac）。
struct RemoteNetworkDiagnosticsScreen: View {
    /// 从某台 Mac 的长按菜单进来时预选它。
    var preferredMacID: String?
    var log = RemotePathMatrixLog(defaults: .standard)

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.mAccent) private var accent
    @AppStorage(DefaultsKey.remoteIceProbeNote) private var note = ""
    @AppStorage(DefaultsKey.remotePathMatrixRounds) private var rounds = 3
    /// 跳过的路（逗号分隔）。存跳过的而不是要测的：以后加了新路，默认就会测。
    @AppStorage(DefaultsKey.remotePathMatrixSkippedModes) private var skippedRaw = ""
    @State private var selectedMacID: String?
    @State private var network = "…"
    @State private var relayName: String?
    @State private var running: Task<Void, Never>?
    @State private var current: [RemotePathProbeResult] = []
    @State private var currentTotal = 0
    @State private var lastRun: [RemotePathProbeResult] = []
    @State private var historyCount = 0
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                targetGroup
                environmentGroup
                runControls
                if !shown.isEmpty { resultsGroup }
                settingsGroup
                historyGroup
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
            reloadHistory()
            if selectedMacID == nil { selectedMacID = preferredMacID ?? candidates.first(where: isReachable)?.id }
            network = await RemoteNetworkLabel.current()
        }
        .onDisappear { running?.cancel() }
    }

    // MARK: - 测哪台 Mac

    /// 能诊断的 Mac：知道身份的（配对过的）。
    private var candidates: [RemoteMacDirectory.Mac] {
        directory.macs.filter { $0.expectedPeer != nil }
    }

    private func isReachable(_ mac: RemoteMacDirectory.Mac) -> Bool {
        mac.isOnRelay || directory.isOnLocalNetwork(mac)
    }

    @ViewBuilder private var targetGroup: some View {
        let macs = candidates
        MInsetGroup(header: "检测哪台 Mac",
                    footer: macs.isEmpty ? "还没有配对过的 Mac。先在同一个局域网里连一次。" : nil) {
            if macs.isEmpty {
                MInsetRow(icon: "mac", label: "没有可检测的 Mac", last: true)
            } else {
                ForEach(macs) { mac in
                    MInsetRow(icon: "mac", label: mac.name, value: reachability(mac), last: mac.id == macs.last?.id,
                              trailing: AnyView(selectionMark(mac.id == selectedMacID)),
                              onTap: running == nil ? { selectedMacID = mac.id } : nil)
                }
            }
        }
    }

    private func reachability(_ mac: RemoteMacDirectory.Mac) -> String {
        let parts = [directory.isOnLocalNetwork(mac) ? "局域网" : nil, mac.isOnRelay ? "中继" : nil].compactMap { $0 }
        return parts.isEmpty ? "不在线" : parts.joined(separator: " · ")
    }

    @ViewBuilder private func selectionMark(_ selected: Bool) -> some View {
        if selected { MIcon(name: "check", size: 15, color: accent, weight: .semibold) }
    }

    // MARK: - 环境

    private var environmentGroup: some View {
        MInsetGroup(header: "这台手机") {
            MInsetRow(icon: "globe", label: "网络", value: network)
            MInsetRow(icon: "link", label: "中继服务器", value: relayName ?? "未配置", last: !directory.internetOnly)
            if directory.internetOnly {
                MInsetRow(icon: "forward", label: "只走公网", value: "已打开", last: true)
            }
        }
    }

    // MARK: - 运行

    private var modes: [RemotePathProbeMode] {
        let skipped = Set(skippedRaw.split(separator: ",").map(String.init))
        return RemotePathProbeMode.allCases.filter { !skipped.contains($0.rawValue) }
    }

    private var selectedMac: RemoteMacDirectory.Mac? {
        candidates.first { $0.id == selectedMacID }
    }

    @ViewBuilder private var runControls: some View {
        VStack(spacing: 10) {
            if running != nil {
                ProgressView(value: Double(current.count), total: Double(max(1, currentTotal)))
                    .tint(accent)
                Text(progressText).font(M.sans(13)).foregroundStyle(M.text3)
                MBtn(title: "停止", kind: .secondary, full: true, height: 46) { running?.cancel() }
            } else {
                MBtn(title: "开始检测", icon: "run", full: true, height: 46,
                     disabled: selectedMac == nil || modes.isEmpty, action: run)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 22)
    }

    private var progressText: String {
        guard current.count < currentTotal, !modes.isEmpty else { return "收尾中…" }
        let index = current.count
        let round = rounds > 1 ? "第 \(index / modes.count + 1) 轮 · " : ""
        return "\(round)正在测\(modes[index % modes.count].label)（\(index + 1)/\(currentTotal)）"
    }

    private func run() {
        guard let mac = selectedMac, let probe = directory.pathMatrixRunner(for: mac) else { return }
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
            reloadHistory()
            running = nil
        }
    }

    private func reloadHistory() {
        historyCount = log.load().count
        lastRun = log.lastRun()
    }

    // MARK: - 结果

    /// 正在测或刚测完的这一次；否则上一次。
    private var shown: [RemotePathProbeResult] {
        current.isEmpty ? lastRun : current
    }

    private var resultsGroup: some View {
        let results = shown
        let summaries = RemotePathProbeSummary.summarize(results)
        let header = running != nil ? "正在检测" : current.isEmpty
            ? "上次结果 · \(results.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")" : "检测结果"
        let context = results.first.map { [$0.network, $0.note].filter { !$0.isEmpty }.joined(separator: " · ") }
        return MInsetGroup(header: header, footer: context) {
            if running == nil {
                RemotePathVerdictRow(chosen: RemotePathVerdict.chosen(summaries, skipsLocalNetwork: directory.internetOnly),
                                     untested: RemotePathProbeMode.allCases.filter { mode in
                                         !summaries.contains { $0.mode == mode }
                                     },
                                     skipsLocalNetwork: directory.internetOnly)
            }
            ForEach(summaries, id: \.mode) { summary in
                RemotePathSummaryRow(summary: summary, results: results, last: summary.mode == summaries.last?.mode)
            }
        }
    }

    // MARK: - 检测设置

    private func modeBinding(_ mode: RemotePathProbeMode) -> Binding<Bool> {
        Binding(get: { modes.contains(mode) }, set: { on in
            var set = Set(modes)
            if on { set.insert(mode) } else { set.remove(mode) }
            skippedRaw = RemotePathProbeMode.allCases.filter { !set.contains($0) }.map(\.rawValue)
                .joined(separator: ",")
        })
    }

    private var settingsGroup: some View {
        MInsetGroup(header: "检测设置", footer: showsSettings
                    ? "局域网走 Bonjour 找到的地址；IPv6 / IPv4 直连只用公网地址打洞；中继经服务器转发。每条路都只走自己，"
                        + "插着数据线、连着同一个 Wi-Fi 都不影响结果。"
                    : nil) {
            MInsetRow(label: "测试项与轮数", value: settingsSummary, last: !showsSettings,
                      trailing: AnyView(MIcon(name: showsSettings ? "chev-down" : "chev", size: 14, color: M.text4,
                                              weight: .semibold)),
                      onTap: { withAnimation(.easeOut(duration: 0.15)) { showsSettings.toggle() } })
            if showsSettings {
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
    }

    private var settingsSummary: String {
        let count = modes.count == RemotePathProbeMode.allCases.count ? "全部" : "\(modes.count) 条路"
        return "\(count) · \(rounds) 轮"
    }

    // MARK: - 历史

    private var historyGroup: some View {
        MInsetGroup {
            NavigationLink {
                RemotePathHistoryScreen(log: log, onCleared: reloadHistory)
            } label: {
                MInsetRow(icon: "clock", label: "历史记录", value: historyCount == 0 ? "无" : "\(historyCount) 条",
                          chevron: true, last: true)
            }
            .buttonStyle(MRowStyle())
            .disabled(historyCount == 0)
        }
    }
}

/// 结论：实际连接会走哪条路。
private struct RemotePathVerdictRow: View {
    let chosen: RemotePathProbeSummary?
    /// 这次没测的路：结论只对测过的路负责。
    let untested: [RemotePathProbeMode]
    let skipsLocalNetwork: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(M.sans(17, weight: .semibold)).foregroundStyle(chosen == nil ? M.danger : M.text)
                Text(detail).font(M.sans(13)).foregroundStyle(M.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .overlay(alignment: .bottom) { MRowDivider() }
    }

    private var title: String {
        guard let chosen else { return untested.isEmpty ? "这台 Mac 现在连不上" : "测过的路都不通" }
        return "实际会走\(chosen.mode.label)"
    }

    private var detail: String {
        let notTested = untested.isEmpty ? "" : "这次没测\(untested.map(\.label).joined(separator: "、"))（在「检测设置」里打开）。"
        guard let chosen else { return "看下面每条路的原因。\(notTested)" }
        let latency = chosen.medianRoundTripMillis.map { String(format: "往返约 %.0f ms", $0) } ?? "往返未测出"
        let skip = skipsLocalNetwork ? "「只走公网」已打开，正式连接会跳过局域网。" : ""
        return "连接按局域网 → 直连 → 中继的顺序挑第一条通的，\(latency)。\(skip)\(notTested)"
    }
}

/// 一条路的汇总：通过率着色，下面一排四个读数；没通过的写原因。
struct RemotePathSummaryRow: View {
    let summary: RemotePathProbeSummary
    let results: [RemotePathProbeResult]
    let last: Bool

    private var tone: Color {
        if summary.successes == summary.attempts { return M.success }
        return summary.successes == 0 ? M.danger : M.warning
    }

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
                    metric("往返", Self.millis(summary.medianRoundTripMillis))
                    metric("p95", Self.millis(summary.medianP95Millis))
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

    static func millis(_ value: Double?) -> String? {
        value.map { $0 < 10 ? String(format: "%.1fms", $0) : String(format: "%.0fms", $0) }
    }
}

/// 历史记录：按每次检测分组，最新在上。复制全部给排查用。
struct RemotePathHistoryScreen: View {
    let log: RemotePathMatrixLog
    var onCleared: () -> Void = {}

    @State private var runs: [[RemotePathProbeResult]] = []
    @State private var copied = false
    @State private var confirmsClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(runs, id: \.first?.id) { run in
                    let summaries = RemotePathProbeSummary.summarize(run)
                    MInsetGroup(header: run.first?.date.formatted(date: .abbreviated, time: .shortened),
                                footer: context(run)) {
                        ForEach(summaries, id: \.mode) { summary in
                            RemotePathSummaryRow(summary: summary, results: run,
                                                 last: summary.mode == summaries.last?.mode)
                        }
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: M.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(M.canvas)
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MMenu {
                    Button(copied ? "已复制" : "复制全部", systemImage: "doc.on.doc", action: copyAll)
                    Button("清空", systemImage: "trash", role: .destructive) { confirmsClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("清空全部诊断记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                log.clear()
                runs = []
                onCleared()
            }
        }
        .onAppear { runs = Self.group(log.load()) }
    }

    /// 网络与备注放脚注：区段标题会转大写，「Wi-Fi」会变成「WI-FI」。
    private func context(_ run: [RemotePathProbeResult]) -> String? {
        let parts = [run.first?.network ?? "", run.first?.note ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func copyAll() {
        let all = runs.flatMap { $0 }
        let summaries = RemotePathProbeSummary.summarize(all).map(\.line)
        UIPasteboard.general.string = (summaries + [""] + all.map(\.summaryLine)).joined(separator: "\n")
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// 记录是最新在前的平铺列表；按 `runID` 切成一次次检测（旧记录没有 `runID` 的各自成组）。
    static func group(_ results: [RemotePathProbeResult]) -> [[RemotePathProbeResult]] {
        var runs: [[RemotePathProbeResult]] = []
        for result in results {
            if let runID = result.runID, let index = runs.lastIndex(where: { $0.first?.runID == runID }) {
                runs[index].append(result)
            } else {
                runs.append([result])
            }
        }
        return runs.map { $0.reversed() }
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
