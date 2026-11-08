import SwiftUI
import UIKit

/// 网络诊断：对一台 Mac 把局域网、IPv6 直连、IPv4 直连、中继各测一遍，给出「实际会走哪条路、多快」。
///
/// 每条路都强制只走自己，不看「只走公网」（那是正式连接的开发者选项，在 设置 › 远程控制）。
/// 入口：设置 › 远程控制 › 网络诊断；主机页「我的 Mac」那一行的长按菜单（带上那台 Mac）。
struct RemoteNetworkDiagnosticsScreen: View {
    /// 从某台 Mac 的长按菜单进来时预选它。
    var preferredMacID: String?
    @State private var model: RemotePathDiagnosticsModel

    init(preferredMacID: String? = nil, log: RemotePathMatrixLog = RemotePathMatrixLog(defaults: RemoteLocalState.defaults)) {
        self.preferredMacID = preferredMacID
        _model = State(initialValue: RemotePathDiagnosticsModel(log: log))
    }

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.mAccent) private var accent
    @AppStorage(DefaultsKey.remoteIceProbeNote) private var note = ""
    @AppStorage(DefaultsKey.remotePathMatrixRounds) private var rounds = 3
    /// 跳过的路（逗号分隔）。存跳过的而不是要测的：以后加了新路，默认就会测。
    @AppStorage(DefaultsKey.remotePathMatrixSkippedModes) private var skippedRaw = ""
    @State private var selectedMacID: String?
    @State private var relayName: String?
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                targetGroup
                environmentGroup
                runControls
                if !model.shown.isEmpty { resultsGroup }
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
            model.reloadHistory()
            if selectedMacID == nil { selectedMacID = preferredMacID ?? candidates.first(where: isReachable)?.id }
            await model.refreshNetwork()
        }
        // 页面开着时持续刷新各台 Mac 在不在中继上（「局域网 · 中继」那一栏）。
        .task { await directory.keepLiveStatusFresh() }
        .onDisappear { model.stop() }
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
                    footer: macs.isEmpty ? "还没有配对过的 Mac。同一 Apple ID 的 Mac 会自动出现，其他 Mac 可以扫码配对。" : nil) {
            if macs.isEmpty {
                MInsetRow(icon: "mac", label: "没有可检测的 Mac", last: true)
            } else {
                ForEach(macs) { mac in
                    MInsetRow(icon: "mac", label: mac.name, value: reachability(mac), last: mac.id == macs.last?.id,
                              trailing: AnyView(selectionMark(mac.id == selectedMacID)),
                              onTap: model.isRunning ? nil : { selectedMacID = mac.id })
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
            MInsetRow(icon: "globe", label: "网络", value: model.network)
            MInsetRow(icon: "link", label: "中继", value: relayName ?? "未配置", last: !directory.internetOnly)
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
            if model.isRunning {
                ProgressView(value: Double(model.current.count), total: Double(max(1, model.currentTotal)))
                    .tint(accent)
                Text(model.progressText).font(M.sans(13)).foregroundStyle(M.text3)
                MBtn(title: "停止", kind: .secondary, full: true, height: 46) { model.stop() }
            } else {
                MBtn(title: "开始检测", icon: "run", full: true, height: 46,
                     disabled: selectedMac == nil || modes.isEmpty, action: run)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 22)
    }

    private func run() {
        guard let mac = selectedMac, let probe = directory.pathMatrixRunner(for: mac) else { return }
        model.run(runner: probe.runner, peer: probe.peer, rounds: rounds, modes: modes, note: note)
    }

    // MARK: - 结果

    private var resultsGroup: some View {
        let results = model.shown
        let summaries = model.summaries
        let header = model.isRunning ? "正在检测" : model.current.isEmpty
            ? "上次结果 · \(results.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")" : "检测结果"
        let context = results.first.map { [$0.network, $0.note].filter { !$0.isEmpty }.joined(separator: " · ") }
        return MInsetGroup(header: header, footer: context) {
            if !model.isRunning {
                RemotePathVerdictRow(chosen: RemotePathVerdict.chosen(summaries, skipsLocalNetwork: directory.internetOnly),
                                     untested: model.untested,
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
                    ? "局域网走 Bonjour 找到的地址；IPv6 / IPv4 直连只用公网地址打洞；中继经你自建的中继转发。每条路径单独测试，"
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
                MInsetRow(label: "每条路径的轮数", trailing: AnyView(
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
                RemoteConnectHistoryScreen()
            } label: {
                MInsetRow(icon: "network", label: "最近的连接", sub: "每次连接 Mac 每一步的耗时与结果", chevron: true)
            }
            .buttonStyle(MRowStyle())
            NavigationLink {
                RemotePathHistoryScreen(log: model.log, onCleared: model.reloadHistory)
            } label: {
                MInsetRow(icon: "clock", label: "历史记录",
                          value: model.historyCount == 0 ? "无" : "\(model.historyCount) 条",
                          chevron: true, last: true)
            }
            .buttonStyle(MRowStyle())
            .disabled(model.historyCount == 0)
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
        guard let chosen else { return untested.isEmpty ? "现在无法连接这台 Mac" : "测试过的路径都不通" }
        return "实际会走\(chosen.mode.label)"
    }

    private var detail: String {
        let notTested = untested.isEmpty ? "" : "这次未测试\(untested.map(\.label).joined(separator: "、"))（在「检测设置」中打开）。"
        guard let chosen else { return "各路径的失败原因见下方。\(notTested)" }
        let latency = chosen.medianRoundTripMillis.map { String(format: "往返约 %.0f ms", $0) } ?? "往返未测出"
        let skip = skipsLocalNetwork ? "「只走公网」已打开，正式连接会跳过局域网。" : ""
        return "连接按局域网 → 直连 → 中继的顺序选第一条可用的路径，\(latency)。\(skip)\(notTested)"
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

    private var failures: String {
        RemotePathProbeSummary.failures(of: summary.mode, in: results)
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
                    metric("建立", summary.medianSetupMillis.map { "\($0) ms" })
                    metric("往返", RemotePathProbeSummary.millis(summary.medianRoundTripMillis))
                    metric("p95", RemotePathProbeSummary.millis(summary.medianP95Millis))
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

/// 历史记录：按每次检测分组，最新在上。拷贝全部给排查用。
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
                    Button(copied ? "已拷贝" : "拷贝全部", systemImage: "doc.on.doc", action: copyAll)
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
        .onAppear { runs = RemotePathMatrixLog.runs(log.load()) }
    }

    /// 网络与备注放脚注：区段标题会转大写，「Wi-Fi」会变成「WI-FI」。
    private func context(_ run: [RemotePathProbeResult]) -> String? {
        let parts = [run.first?.network ?? "", run.first?.note ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func copyAll() {
        UIPasteboard.general.string = RemotePathMatrixLog.exportText(runs.flatMap { $0 })
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
