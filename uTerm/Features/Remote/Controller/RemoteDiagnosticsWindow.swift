import AppKit
import SwiftUI
import UDesignKit

/// 网络诊断窗口：一台 Mac 一个。从「我的 Mac」里那台 Mac 的菜单打开。
nonisolated struct RemoteDiagnosticsWindowID: Hashable, Codable, Sendable {
    let macID: String
}

/// 对一台配对过的 Mac 把局域网、IPv6 直连、IPv4 直连、中继各测一遍，看实际会走哪条路、有多快。
/// 每条路都只走自己，不影响正在用的连接。状态在共享的 `RemotePathDiagnosticsModel`，和手机上的诊断页同一套。
struct RemoteDiagnosticsWindowView: View {
    let windowID: RemoteDiagnosticsWindowID?

    @Environment(RemoteMacDirectory.self) private var directory
    @State private var model = RemotePathDiagnosticsModel(log: RemotePathMatrixLog(defaults: RemoteLocalState.defaults))

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(UD.mono(13))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
                .allowsHitTesting(false)
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .background(WindowDragHandle(fill: WS.canvasNSColor))
            RemoteDiagnosticsContent(model: model, macID: windowID?.macID)
                .udCard()
                .padding(.horizontal, UD.Layout.cardInset)
                .padding(.bottom, UD.Layout.cardInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        .background(WorkspaceWindowChrome(serverName: "", background: WS.canvasNSColor))
        .background(WindowTitleBinding(title: title))
        .frame(minWidth: 520, minHeight: 480)
        .onAppear {
            if directory.isActivated { directory.startBrowsing() } else { directory.activate() }
        }
        .onDisappear { model.stop() }
    }

    private var title: String {
        let name = windowID.flatMap { id in directory.macs.first { $0.id == id.macID }?.name }
        return name.map { String(localized: "网络诊断 · \($0)") } ?? String(localized: "网络诊断")
    }
}

/// 窗口正文。单独一层方便截图验收。
struct RemoteDiagnosticsContent: View {
    let model: RemotePathDiagnosticsModel
    let macID: String?

    @Environment(RemoteMacDirectory.self) private var directory
    @AppStorage(DefaultsKey.remoteIceProbeNote) private var note = ""
    @AppStorage(DefaultsKey.remotePathMatrixRounds) private var rounds = 3
    /// 跳过的路（逗号分隔）。存跳过的而不是要测的：以后加了新路，默认就会测。
    @AppStorage(DefaultsKey.remotePathMatrixSkippedModes) private var skippedRaw = ""
    @State private var relayName: String?
    @State private var showsHistory = false
    @State private var history: [[RemotePathProbeResult]] = []
    @State private var copied = false
    @State private var confirmsClear = false

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: String(localized: "网络诊断"),
                               subtitle: String(localized: "把局域网、IPv6 直连、IPv4 直连和中继各测一遍，看连这台 Mac 实际会走哪条路、有多快。每条路都只走自己，不影响正在用的连接。"))
            targetGroup
            runGroup
            if !model.shown.isEmpty { resultsGroup }
            settingsGroup
            historyGroup
        }
        // 页面开着时持续刷新这台 Mac 在不在中继上。
        .task { await directory.keepLiveStatusFresh() }
        .task {
            relayName = directory.relayServerName()
            model.reloadHistory()
            await model.refreshNetwork()
        }
        .alert("清空全部诊断记录？", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) {
                model.clearHistory()
                history = []
                showsHistory = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删这台 Mac 上的记录。")
        }
    }

    private var mac: RemoteMacDirectory.Mac? {
        directory.macs.first { $0.id == macID && $0.expectedPeer != nil }
    }

    private var modes: [RemotePathProbeMode] { RemotePathProbeMode.enabled(skipping: skippedRaw) }

    // MARK: - 对象与环境

    private var targetGroup: some View {
        SettingsGroup(title: String(localized: "检测对象")) {
            if let mac {
                SettingsListRow(icon: "desktopcomputer", tint: mac.isOnline ? UD.success : UD.text4,
                                title: mac.name, subtitle: Self.reachability(mac, onLAN: directory.isOnLocalNetwork(mac))) {
                    EmptyView()
                }
            } else {
                SettingsEmptyRow(symbol: "desktopcomputer",
                                 text: String(localized: "这台 Mac 还没配对，或已被忘记。先在「我的 Mac」里配对。"))
            }
            SettingsRow(label: String(localized: "这台 Mac 的网络"), icon: "network") {
                Text(model.network).font(.system(size: 12.5)).foregroundStyle(UD.text2)
            }
            SettingsRow(label: String(localized: "中继"), icon: "point.3.connected.trianglepath.dotted") {
                Text(relayName ?? String(localized: "未配置")).font(.system(size: 12.5)).foregroundStyle(UD.text2)
            }
            if directory.internetOnly {
                SettingsRow(label: String(localized: "只走公网"),
                            hint: String(localized: "正式连接会跳过局域网；诊断照样测局域网。"), icon: "globe") {
                    Text("已打开").font(.system(size: 12.5)).foregroundStyle(UD.text2)
                }
            }
        }
    }

    nonisolated static func reachability(_ mac: RemoteMacDirectory.Mac, onLAN: Bool) -> String {
        mac.reachabilityLabel(.routes, onLocalNetwork: onLAN)
    }

    // MARK: - 运行

    private var runGroup: some View {
        SettingsGroup(title: nil) {
            if model.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.progressText).font(.system(size: 12.5)).foregroundStyle(UD.text2)
                        Spacer()
                        UDButton(title: String(localized: "停止", comment: "停止检测"), style: .secondary) { model.stop() }
                    }
                    ProgressView(value: Double(model.current.count), total: Double(max(1, model.currentTotal)))
                        .progressViewStyle(.linear)
                        .tint(UD.accent)
                }
                .settingsRowPadding()
            } else {
                SettingsRow(label: String(localized: "开始检测"),
                            hint: String(localized: "\(modes.count) 条路，每条 \(rounds) 轮，约需 \(Self.estimate(modes: modes.count, rounds: rounds))。")) {
                    UDButton(title: String(localized: "开始", comment: "开始检测")) { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(mac == nil || modes.isEmpty)
                }
            }
        }
    }

    /// 粗估耗时：一条路通了约 3 秒（建连加 40 次往返），不通时等到超时约 8 秒，取中间值。
    nonisolated static func estimate(modes: Int, rounds: Int) -> String {
        let seconds = modes * max(1, rounds) * 5
        return seconds < 60 ? String(localized: "\(seconds) 秒") : String(localized: "\((seconds + 30) / 60) 分钟")
    }

    private func run() {
        guard let mac, let probe = directory.pathMatrixRunner(for: mac) else { return }
        model.run(runner: probe.runner, peer: probe.peer, rounds: rounds, modes: modes, note: note)
    }

    // MARK: - 结果

    private var resultsGroup: some View {
        let results = model.shown
        let summaries = model.summaries
        return SettingsGroup(title: model.resultsTitle, footer: Self.context(results)) {
            if !model.isRunning {
                RemoteDiagnosticsVerdictRow(
                    chosen: RemotePathVerdict.chosen(summaries, skipsLocalNetwork: directory.internetOnly),
                    untested: model.untested, skipsLocalNetwork: directory.internetOnly)
            }
            ForEach(summaries, id: \.mode) { summary in
                RemoteDiagnosticsSummaryRow(summary: summary, results: results)
            }
        }
    }

    nonisolated static func context(_ run: [RemotePathProbeResult]) -> String? {
        RemotePathMatrixLog.context(run)
    }

    // MARK: - 设置

    private func modeBinding(_ mode: RemotePathProbeMode) -> Binding<Bool> {
        Binding(get: { modes.contains(mode) }, set: { on in
            skippedRaw = RemotePathProbeMode.skippedRaw(skippedRaw, setting: mode, enabled: on)
        })
    }

    private var settingsGroup: some View {
        SettingsGroup(title: String(localized: "检测设置"),
                      footer: String(localized: "局域网走 Bonjour 找到的地址；IPv6 / IPv4 直连只用公网地址打洞；中继这条路由中继转发。两台 Mac 在同一个局域网里也不影响直连和中继的结果。")) {
            ForEach(RemotePathProbeMode.allCases, id: \.self) { mode in
                SettingsRow(label: mode.label) {
                    UDToggle(modeBinding(mode))
                }
                .disabled(model.isRunning)
            }
            SettingsRow(label: String(localized: "每条路跑几轮")) {
                SettingsNumberField(value: $rounds, width: 56, minValue: 1, maxValue: 10, suffix: String(localized: "轮"))
            }
            .disabled(model.isRunning)
            SettingsRow(label: String(localized: "备注"), hint: String(localized: "记进每条结果，如「公司 Wi-Fi ↔ 家里电信」。")) {
                UDTextField(placeholder: String(localized: "可不填"), text: $note)
                    .frame(width: 200)
            }
        }
    }

    // MARK: - 历史

    private var historyGroup: some View {
        SettingsGroup(title: String(localized: "历史记录"),
                      footer: String(localized: "只存在这台 Mac 上，留最近 300 条结果。")) {
            SettingsRow(label: model.historyCount == 0 ? String(localized: "还没有记录")
                        : String(localized: "共 \(model.historyCount) 条结果")) {
                HStack(spacing: 6) {
                    UDButton(title: showsHistory ? String(localized: "收起", comment: "收起历史记录") : String(localized: "查看", comment: "查看历史记录"), style: .secondary) { toggleHistory() }
                    SettingsMoreMenu(items: [
                        UDMenuItem(label: copied ? String(localized: "已拷贝") : String(localized: "拷贝全部"),
                                   systemImage: "doc.on.doc") { copyAll() },
                        UDMenuItem(label: String(localized: "清空…"), systemImage: "trash", danger: true) {
                            confirmsClear = true
                        },
                    ])
                }
                .disabled(model.historyCount == 0)
            }
            if showsHistory {
                ForEach(history, id: \.first?.id) { run in
                    RemoteDiagnosticsHistoryRun(run: run)
                }
            }
        }
    }

    private func toggleHistory() {
        if !showsHistory { history = RemotePathMatrixLog.runs(model.log.load()) }
        withAnimation(.easeOut(duration: 0.15)) { showsHistory.toggle() }
    }

    private func copyAll() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(model.log.exportAllText(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// 结论：实际连接会走哪条路。
private struct RemoteDiagnosticsVerdictRow: View {
    let chosen: RemotePathProbeSummary?
    let untested: [RemotePathProbeMode]
    let skipsLocalNetwork: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: chosen == nil ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .font(.system(size: 18))
                .foregroundStyle(chosen == nil ? UD.danger : UD.success)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(UD.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(UD.text3)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 12)
    }

    private var title: String { RemotePathVerdict.title(chosen: chosen, untested: untested) }

    private var detail: String {
        RemotePathVerdict.detail(chosen: chosen, untested: untested, skipsLocalNetwork: skipsLocalNetwork)
    }
}

/// 一条路的汇总：通过率着色，右边四个读数；没通过的写原因。
private struct RemoteDiagnosticsSummaryRow: View {
    let summary: RemotePathProbeSummary
    let results: [RemotePathProbeResult]

    private var tone: Color {
        switch summary.tone {
        case .passed: UD.success
        case .partial: UD.caution
        case .failed: UD.danger
        }
    }

    var body: some View {
        let failures = RemotePathProbeSummary.failures(of: summary.mode, in: results)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(tone).frame(width: 7, height: 7)
                Text(summary.mode.label).font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                    .frame(width: 72, alignment: .leading)
                Text("\(summary.successes)/\(summary.attempts)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(tone)
                    .frame(width: 36, alignment: .leading)
                Spacer(minLength: 8)
                if summary.successes > 0 {
                    metric("建立", summary.medianSetupMillis.map { "\($0) ms" })
                    metric("往返", RemotePathProbeSummary.millis(summary.medianRoundTripMillis))
                    metric("p95", RemotePathProbeSummary.millis(summary.medianP95Millis))
                    metric("丢包", summary.meanLossPercent.map { "\($0)%" })
                }
            }
            if !failures.isEmpty {
                Text(failures).font(.system(size: 11.5)).foregroundStyle(UD.text3)
                    .padding(.leading, 17)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 10)
        .settingsDivider(inset: SettingsMetrics.rowInset)
    }

    private func metric(_ title: LocalizedStringKey, _ value: String?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(UD.text3)
            Text(value ?? "–").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value == nil ? UD.text4 : UD.text)
        }
        .frame(width: 58, alignment: .trailing)
    }
}

/// 历史里的一次检测：时间、网络与备注，下面各条路。
private struct RemoteDiagnosticsHistoryRun: View {
    let run: [RemotePathProbeResult]

    var body: some View {
        let summaries = RemotePathProbeSummary.summarize(run)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(run.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(UD.text2)
                if let context = RemoteDiagnosticsContent.context(run) {
                    Text(context).font(.system(size: 11.5)).foregroundStyle(UD.text3).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.top, 10)
            ForEach(summaries, id: \.mode) { summary in
                RemoteDiagnosticsSummaryRow(summary: summary, results: run)
            }
        }
    }
}
