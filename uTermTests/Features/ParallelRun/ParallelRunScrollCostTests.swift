import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 并行执行窗口（Shell 网格 / AI 泳道 / 广播条）的渲染成本探针。
///
/// 形状抄 `uTermTests/Support/ProbeSmokeTests.swift`：真窗口 `.transparentOnScreen`、
/// 建窗后断言 `blindsRealMouse`、每条用例开头 `defer { closeAllWindows() }`
/// （`uTermTests` 默认隔离是 `nonisolated`，覆写 `tearDown()` 拆窗过不了 Swift 6）。
///
/// ## 规模来源
///
/// - **真实档 6 台 × 600 行**：一条快捷命令绑定的服务器数（`QuickCommand.serverIDs`，
///   欢迎页 Tweaks 钳 50 台但一条命令实际广播的是「一个分组」量级）；行数来自
///   `SSHCommandExecutor(maxLines: 200, maxBytes: 16000)` × 自愈几步。
/// - **极端档 24 台 × 1200 行**：`ParallelRunModel.maxAgentSteps = 6`，每步一条命令
///   最多回 200 行 → 6 × 200 = 1200 行封顶；24 台是「把一个中型分组整批广播」。
/// - **追加速率 50 行/秒/台 × 10 秒**：模型里 `states[i].lines.append(contentsOf:)`
///   是每条命令跑完一次性灌进去的（`ParallelRunModel.swift:232/337`），
///   真实峰值就是一大坨一起进；这里用连续追加把「追加期间主线程还剩多少」量出来
///   （比一次性灌更能分辨每格 `onChange` + 合并 `scrollTo` 的账）。
@MainActor
final class ParallelRunScrollCostTests: XCTestCase {

    // MARK: - 夹具

    /// 驱动 `states` 增量追加的持有者。`ParallelServerState` 是 `@MainActor` 结构体，
    /// 所以持有者也必须是 `@MainActor`。
    @MainActor
    @Observable
    final class Feed {
        var states: [ParallelServerState] = []

        static func make(hosts: Int, seedLines: Int) -> Feed {
            let feed = Feed()
            feed.states = (0..<hosts).map { i in
                var s = ParallelServerState(id: UUID(),
                                            name: "web-\(String(format: "%02d", i + 1))",
                                            endpoint: "ops@10.0.\(i / 254).\(i % 254 + 1):22",
                                            endpointDisplay: "ops@10.0.\(i / 254).\(i % 254 + 1)")
                s.status = .running
                s.tone = .running
                s.lines = [ParallelTermLine(kind: .cmd, text: "systemctl status nginx")]
                s.lines.append(contentsOf: Self.outputLines(count: max(0, seedLines - 1), from: 0))
                s.summary = "正在检查 nginx 服务状态并汇总。"
                s.steps = ["连接主机", "执行 systemctl status nginx"]
                return s
            }
            return feed
        }

        static func outputLines(count: Int, from offset: Int) -> [ParallelTermLine] {
            (0..<count).map { j in
                let n = offset + j
                let kind: ParallelTermLine.Kind = n % 37 == 36 ? .err : (n % 23 == 22 ? .ok : .out)
                return ParallelTermLine(
                    kind: kind,
                    text: "Sep 07 12:\(String(format: "%02d", n % 60)):\(String(format: "%02d", (n * 7) % 60)) "
                        + "web nginx[\(1000 + n % 900)]: worker process \(n) handled request /api/v1/items?page=\(n)")
            }
        }

        /// 给每台（或指定一台）追加 `count` 行（模拟命令输出增量到达）。
        func append(count: Int, tick: Int, only: Int? = nil) {
            guard count > 0 else { return }
            let targets = only.map { [$0] } ?? Array(states.indices)
            for i in targets where states.indices.contains(i) {
                states[i].lines.append(contentsOf: Self.outputLines(count: count,
                                                                    from: tick * count + i * 10_000))
            }
        }
    }

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// 并行执行窗口 `minWidth: 760, minHeight: 540`；取一个偏大的常见尺寸。
    private static let size = NSSize(width: 1120, height: 720)

    private func mount<V: View>(_ view: V,
                                size: NSSize = ParallelRunScrollCostTests.size)
        throws -> (window: ProbeWindow.Unconstrained, host: NSHostingView<AnyView>, mountMS: Double) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .darkAqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(unconstrained),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")
        return (unconstrained, host, mountMS)
    }

    private func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ v: NSView) { n += 1; for s in v.subviews { walk(s) } }
        walk(root)
        return n
    }

    private func classHistogram(in root: NSView) -> String {
        var counts: [String: Int] = [:]
        func walk(_ v: NSView) {
            counts[String(describing: type(of: v)), default: 0] += 1
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }

    private func allScrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return found
    }

    // MARK: - 读数

    struct Reading {
        var hosts = 0
        var lines = 0
        var mountMS = 0.0
        /// 10s 追加期间 8ms 心跳实收拍数（理想 1250）。
        var streamBeats = 0
        /// 每次追加 + 布局 + 绘制的主线程耗时。
        var streamP50 = 0.0
        var streamP95 = 0.0
        var streamMax = 0.0
        var streamOverBudget = 0.0
        /// 单格 200 步往返。
        var paneP50 = 0.0
        var paneP95 = 0.0
        var paneOverBudget = 0.0
        var hitP50 = 0.0
        var views = 0
        var scrollViews = 0
        /// 追加期结束时「各格离底还差多少」的中位数。0 附近 = 跟随真的在生效；
        /// 上万 pt = 根本没跟随（那样这一轮读数不能拿来评判跟随的账）。
        var tailGap = 0.0
        var histogram = ""
    }

    private func log(_ tag: String, _ r: Reading) {
        print(String(format: """
            [%@] hosts=%d lines=%d mount=%.1fms stream-beats=%d/1250 stream-p50=%.2fms \
            stream-p95=%.2fms stream-max=%.1fms stream-over8.33=%.1f%% pane-p50=%.2fms \
            pane-p95=%.2fms pane-over8.33=%.1f%% tail-gap-p50=%.0fpt hit-p50=%.1fus views=%d \
            scrollviews=%d cpu=%.2fs rss=%.0fMB
            """,
            tag, r.hosts, r.lines, r.mountMS, r.streamBeats, r.streamP50, r.streamP95,
            r.streamMax, r.streamOverBudget, r.paneP50, r.paneP95, r.paneOverBudget,
            r.tailGap, r.hitP50, r.views, r.scrollViews,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[\(tag)-views] \(r.histogram)")
    }

    // MARK: - Shell 网格

    /// 一档：建 feed → 挂载 → 10s 按 50 行/秒/台追加（量心跳与单次追加的主线程账）
    /// → 单格 200 步往返 → hitTest。
    private func measureShellGrid(hosts: Int,
                                  totalLines: Int,
                                  seconds: Double = 10,
                                  roundRobin: Bool = false,
                                  measureScroll: Bool = true) async throws -> Reading {
        // **不预置历史**：窗格 `onAppear` 那一发贴底要在首次布局之后才落地，
        // 预置几百行的话它落空，紧接着 `onScrollPhaseChange` 的 `.idle` 用
        // 「内容一万多 pt、可见区在最顶上」算出 `isNearBottom == false`，
        // `followsTail` 就此永久为假——整轮追加**根本没在跟随**（tail-gap 上万 pt），
        // 量到的不是要评判的那条路。真实场景里命令刚开跑时 `lines` 是空的，
        // 所以这里也从空开始，10 秒内把目标行数全流进来。
        let streamed = totalLines
        let seed = 1
        let rate = Double(totalLines) / seconds
        let feed = Feed.make(hosts: hosts, seedLines: seed)

        struct GridProbe: View {
            let feed: Feed
            var body: some View { ParallelShellGrid(states: feed.states) }
        }

        let fixture = try mount(GridProbe(feed: feed))
        let host = fixture.host
        var r = Reading(hosts: hosts, lines: totalLines, mountMS: fixture.mountMS)

        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        /// 把每格先摁到底 —— 生产的 `followsTail` 只在「已经贴底」时才继续跟随
        /// （`AgentScrollPolicy.isNearBottom`），而窗格 `onAppear` 里那一发
        /// `scrollTo` 在探针里赶在首次布局之前、落空。不摁这一下，整轮追加期
        /// **根本没在跟随**，量到的就不是跟随的账（tail-gap 会是上万 pt）。
        func pinToBottom() {
            for s in allScrollViews(in: host) {
                guard let doc = s.documentView else { continue }
                let maxOffset = max(0, doc.frame.height - s.contentSize.height)
                s.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
                s.reflectScrolledClipView(s.contentView)
            }
        }
        for _ in 0..<3 {
            layout()
            pinToBottom()
            layout()
            try await Task.sleep(for: .milliseconds(150))
        }

        // ── 追加期：8ms 心跳，按经过时间补足 50 行/秒/台，10 秒。
        var frames: [Double] = []
        let t0 = Date()
        var appended = 0
        var beats = 0
        while Date().timeIntervalSince(t0) < seconds {
            try await Task.sleep(for: .milliseconds(8))
            beats += 1
            let elapsed = Date().timeIntervalSince(t0)
            let want = min(streamed, Int(elapsed * rate))
            let delta = want - appended
            let start = CFAbsoluteTimeGetCurrent()
            if roundRobin {
                // 更贴近真实：`execBounded` 每台各自跑完才一次性灌输出，
                // 同一帧里通常只有一台在变。
                feed.append(count: delta * hosts, tick: beats, only: beats % max(1, hosts))
            } else {
                feed.append(count: delta, tick: beats)
            }
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            appended = want
        }
        r.streamBeats = beats
        r.streamP50 = ProbeMetrics.percentile(frames, 0.5)
        r.streamP95 = ProbeMetrics.percentile(frames, 0.95)
        r.streamMax = frames.max() ?? 0
        r.streamOverBudget = Double(frames.filter { $0 > 8.33 }.count) / Double(max(1, frames.count)) * 100

        // 跟随是否真的成立：各格「离底还差多少」的中位数（0 附近 = 在跟随）。
        try await Task.sleep(for: .milliseconds(400))
        layout()
        r.tailGap = ProbeMetrics.percentile(allScrollViews(in: host).compactMap { s in
            guard let doc = s.documentView else { return nil }
            return Double(max(0, doc.frame.height - s.contentSize.height) - s.contentView.bounds.origin.y)
        }, 0.5)

        // 收尾：全部落定（完成态），再量滚动 —— 用户真正会去翻输出的时刻。
        for i in feed.states.indices {
            feed.states[i].status = i % 5 == 4 ? .failed : .succeeded
            feed.states[i].exitCode = i % 5 == 4 ? 1 : 0
            feed.states[i].durationMs = 1200 + i * 37
            feed.states[i].tone = i % 5 == 4 ? .failed : .ok
        }
        layout()
        try await Task.sleep(for: .milliseconds(200))

        let scrolls = allScrollViews(in: host)
        r.scrollViews = scrolls.count
        // 取「第一个真的有滚动余量的」格子；24 台时每格只有 ~50pt 高，余量仍在。
        let pane = scrolls.first { s in
            (s.documentView?.frame.height ?? 0) - s.contentSize.height > 1
        } ?? scrolls.first
        if measureScroll, let scroll = pane, let document = scroll.documentView {
            let viewport = scroll.contentSize.height
            let maxOffset = max(0, document.frame.height - viewport)
            let amplitude = min(maxOffset, max(viewport, 1) * 3)
            func scrollTo(_ y: CGFloat) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            // 先扫一遍让懒行实例化。
            var visited: CGFloat = 0
            while visited < amplitude {
                scrollTo(visited); layout()
                try await Task.sleep(for: .milliseconds(8))
                visited += max(1, viewport * 0.8)
            }
            scrollTo(0); layout()
            try await Task.sleep(for: .milliseconds(120))

            var paneFrames: [Double] = []
            for step in 0..<200 {
                let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
                let start = CFAbsoluteTimeGetCurrent()
                scrollTo(amplitude * wave)
                layout()
                paneFrames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                try await Task.sleep(for: .milliseconds(8))
            }
            r.paneP50 = ProbeMetrics.percentile(paneFrames, 0.5)
            r.paneP95 = ProbeMetrics.percentile(paneFrames, 0.95)
            r.paneOverBudget = Double(paneFrames.filter { $0 > 8.33 }.count)
                / Double(paneFrames.count) * 100
        }

        var hits: [Double] = []
        for i in 0..<100 {
            let point = NSPoint(x: CGFloat(60 + (i % 13) * 70), y: CGFloat(60 + (i % 9) * 70))
            let start = CFAbsoluteTimeGetCurrent()
            _ = host.hitTest(point)
            hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
        }
        r.hitP50 = ProbeMetrics.percentile(hits, 0.5)
        r.views = viewCount(in: host)
        r.histogram = classHistogram(in: host)
        await closeWindows()
        return r
    }

    /// 主用例：真实档 + 极端档各量一次。判据只用结构量与同轮相对比。
    func testShellGridStreamingAndPaneScroll() async throws {
        defer { closeAllWindows() }
        let real = try await measureShellGrid(hosts: 6, totalLines: 600)
        log("par-shell", real)
        let extreme = try await measureShellGrid(hosts: 24, totalLines: 1200)
        log("par-shell", extreme)

        // 结构判据①：**这一轮真的在跟随**。不成立的话下面所有读数讲的都不是跟随的账
        // （老版探针预置了几百行历史，`followsTail` 一上来就被判成假，整轮 gap 上万 pt）。
        XCTAssertLessThan(real.tailGap, 200, "真实档必须一直贴着底，否则量的不是跟随")
        XCTAssertLessThan(extreme.tailGap, 200, "极端档必须一直贴着底，否则量的不是跟随")
        // 结构判据②：每格一个 ScrollView —— 台数决定 NSScrollView 数（这是形态本身）。
        XCTAssertGreaterThanOrEqual(extreme.scrollViews, real.scrollViews,
                                    "24 台的 NSScrollView 数不该少于 6 台")
        // 结构判据③：主线程没被追加占死。
        XCTAssertGreaterThan(real.streamBeats, 100, "10 秒 8ms 心跳掉到 100 拍以下 = 主线程被追加占死")
        XCTAssertGreaterThan(extreme.streamBeats, 60, "极端档 10 秒心跳掉到 60 拍以下 = 主线程被追加占死")
    }

    /// 归因：追加期的主线程账到底跟着「台数」涨还是跟着「行数」涨？
    /// 四格 4 秒短跑，只看 `stream-p50` 的相对关系（绝对值只打印）。
    func testShellGridStreamCostAttribution() async throws {
        defer { closeAllWindows() }
        var out: [String] = []
        for (hosts, lines, rr) in [(24, 1200, false), (24, 400, false),
                                   (6, 1200, false), (24, 1200, true)] {
            let r = try await measureShellGrid(hosts: hosts, totalLines: lines,
                                               seconds: 4, roundRobin: rr, measureScroll: false)
            out.append(String(format: "hosts=%d lines=%d rr=%@ beats=%d/500 p50=%.2fms p95=%.2fms over=%.0f%% views=%d",
                              hosts, lines, rr ? "y" : "n", r.streamBeats,
                              r.streamP50, r.streamP95, r.streamOverBudget, r.views))
        }
        for line in out { print("[par-attrib] \(line)") }
        XCTAssertEqual(out.count, 4)
    }

    // MARK: - 变体归因（探针内的对照件，只用来定位成本在哪一层）

    /// 「贴底跟随」怎么做。
    enum FollowMode: String, CaseIterable {
        /// 完全不跟随（地板值）。
        case none
        /// 生产写法：`ScrollViewReader` + `proxy.scrollTo("shell-bottom", anchor: .bottom)`，
        /// 每次 `lines.count` 变就发（未合并）。
        case anchorImmediate
        /// 生产写法 + 100ms `DispatchWorkItem` 合并（= `ParallelShellGrid` 现状）。
        case anchorCoalesced
        /// `ScrollPosition.scrollTo(edge: .bottom)`——不解析 id，只往内容底走。
        case edgeImmediate
        /// 边缘式 + 100ms 合并。
        case edgeCoalesced
        /// 完全不发 scrollTo，靠 `.defaultScrollAnchor(.bottom)` 让 ScrollView 自己贴底。
        case defaultAnchor
        /// 同上，但只在**内容尺寸变化**时贴底（初始位置不强制）。
        case defaultAnchorSizeChanges
        /// 锚点换成**最后一行自己的 id**（仍在 LazyVStack 内），100ms 合并。
        case lastLineCoalesced
        /// 最后一行 id + 尾沿去抖（新输出到就重排 100ms），并封顶 500ms 强制发一次。
        case lastLineDebounced
    }

    /// 行列表本身怎么摆。
    enum RowsMode: Equatable {
        /// 生产写法：`LazyVStack { ForEach(lines) }`，长行自动换行（行高不定）。
        case flat
        /// 长行不换行（`lineLimit(1)` + 截断）→ 行高恒定，看「行高不定」值多少。
        case noWrap
        /// 分块：`LazyVStack { ForEach(块) { VStack { 块内 50 行 } } }`，懒栈的孩子从 1200 降到 24。
        case chunked
        /// 只渲染末尾 N 行（跟随期间的「尾窗」；离开跟随后要换回全量）。
        case tail(Int)
    }

    /// 每行文字的可选中做法。
    enum SelectionMode: String, CaseIterable {
        /// 生产写法：每行一个 `.textSelection(.enabled)`。
        case perLine
        /// 提到整格一次。
        case whole
        /// 完全不给选（地板值，**不是候选修法**，只用来看这一层值多少）。
        case off
    }

    /// 生产窗格的「拆件版」：把跟随方式 / 可选中方式 / 行戳门控三层拆开各量一次。
    /// **它不是修法本身**——定位到之后修法要落回 `ParallelShellGrid.swift`，
    /// 再用上面的生产探针做前→后。
    private struct VariantGrid: View {
        let feed: Feed
        var follow: FollowMode = .anchorCoalesced
        var selection: SelectionMode = .perLine
        var rowsMode: RowsMode = .flat
        /// 把 `Color.clear.id("shell-bottom")` 挪进 LazyVStack 里（生产现状是它在
        /// LazyVStack 的**外面**，解析它必须先知道整栈真实高度）。
        var bottomInsideLazy = false
        /// 每格用 `.equatable()` 按行戳门控（自身没变就不重算 body）。
        var stampGate = false

        private var columns: Int { feed.states.count <= 3 ? max(1, feed.states.count) : 2 }

        var body: some View {
            GeometryReader { geo in
                let cols = columns
                let rows = Int(ceil(Double(feed.states.count) / Double(cols)))
                let cellW = geo.size.width / CGFloat(cols)
                let cellH = rows > 0 ? geo.size.height / CGFloat(rows) : geo.size.height
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: cols),
                          spacing: 0) {
                    ForEach(Array(feed.states.enumerated()), id: \.element.id) { _, state in
                        Group {
                            if stampGate {
                                VariantPane(state: state, follow: follow, selection: selection,
                                            rows: rowsMode, bottomInsideLazy: bottomInsideLazy)
                                    .equatable()
                            } else {
                                VariantPane(state: state, follow: follow, selection: selection,
                                            rows: rowsMode, bottomInsideLazy: bottomInsideLazy)
                            }
                        }
                        .frame(width: cellW, height: cellH)
                    }
                }
            }
        }
    }

    private struct VariantPane: View, Equatable {
        let state: ParallelServerState
        let follow: FollowMode
        let selection: SelectionMode
        var rows: RowsMode = .flat
        var bottomInsideLazy = false

        @State private var pending: DispatchWorkItem?
        @State private var firstPendingAt: Double = 0
        @State private var position = ScrollPosition(idType: String.self)

        /// 行戳：id + 状态 + 行数 + 首尾行 id。行只追加不改写，所以这组值一变
        /// 就等价于「这一格的内容变了」。
        nonisolated static func == (a: VariantPane, b: VariantPane) -> Bool {
            MainActor.assumeIsolated {
                a.state.id == b.state.id
                    && a.state.status == b.state.status
                    && a.state.exitCode == b.state.exitCode
                    && a.state.durationMs == b.state.durationMs
                    && a.state.lines.count == b.state.lines.count
                    && a.state.lines.first?.id == b.state.lines.first?.id
                    && a.state.lines.last?.id == b.state.lines.last?.id
            }
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(state.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(state.status == .running ? "运行中" : "退出码 \(state.exitCode ?? 0)")
                        .font(.system(size: 10.5, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                lineBody
            }
        }

        @ViewBuilder
        private func row(_ line: ParallelTermLine) -> some View {
            HStack(alignment: .top, spacing: 7) {
                ParTermLinesView.prefix(line.kind)
                Group {
                    if selection == .perLine {
                        Text(line.text).textSelection(.enabled)
                    } else {
                        Text(line.text)
                    }
                }
                .modifier(NoWrap(enabled: rows == .noWrap))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        private var lines: some View {
            Group {
                switch rows {
                case .flat, .noWrap:
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(state.lines) { row($0) }
                        if bottomInsideLazy {
                            RunningCaret().padding(.top, 1)
                            Color.clear.frame(height: 1).id("shell-bottom")
                        }
                    }
                case .tail(let n):
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(state.lines.suffix(n)) { row($0) }
                    }
                case .chunked:
                    let blocks = stride(from: 0, to: state.lines.count, by: 50).map {
                        Array(state.lines[$0..<min($0 + 50, state.lines.count)])
                    }
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(blocks, id: \.first!.id) { block in
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(block) { row($0) }
                            }
                        }
                    }
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
        }

        @ViewBuilder
        private var scrollBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    lines
                    if !bottomInsideLazy { Color.clear.frame(height: 1).id("shell-bottom") }
                }
                .padding(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(SelectionWhole(enabled: selection == .whole))
        }

        @ViewBuilder
        private var lineBody: some View {
            switch follow {
            case .none:
                scrollBody
            case .defaultAnchor:
                scrollBody.defaultScrollAnchor(.bottom)
            case .defaultAnchorSizeChanges:
                scrollBody.defaultScrollAnchor(.bottom, for: .sizeChanges)
            case .anchorImmediate, .anchorCoalesced:
                ScrollViewReader { proxy in
                    scrollBody
                        .onChange(of: state.lines.count) { _, _ in
                            if follow == .anchorImmediate {
                                proxy.scrollTo("shell-bottom", anchor: .bottom)
                            } else {
                                coalesce { proxy.scrollTo("shell-bottom", anchor: .bottom) }
                            }
                        }
                }
            case .lastLineCoalesced, .lastLineDebounced:
                ScrollViewReader { proxy in
                    scrollBody
                        .onChange(of: state.lines.count) { _, _ in
                            // 注意：`scrollTo` 收的是非可选 Hashable。传 `UUID?` 会让
                            // ID 类型变成 `Optional<UUID>`，与 ForEach 注册的 `UUID`
                            // 永不相等 —— 静默不滚（第一版就这么假绿了一轮）。
                            guard let last = state.lines.last?.id else { return }
                            if follow == .lastLineCoalesced {
                                coalesce { proxy.scrollTo(last, anchor: .bottom) }
                            } else {
                                debounce { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                }
            case .edgeImmediate, .edgeCoalesced:
                scrollBody
                    .scrollPosition($position)
                    .onChange(of: state.lines.count) { _, _ in
                        if follow == .edgeImmediate {
                            position.scrollTo(edge: .bottom)
                        } else {
                            coalesce { position.scrollTo(edge: .bottom) }
                        }
                    }
            }
        }

        /// 尾沿去抖 + 500ms 封顶：连续追加期间把 10Hz 的贴底降到 2Hz，
        /// 输出一停立刻贴底（100ms 内）。
        private func debounce(_ action: @escaping @MainActor () -> Void) {
            let now = CFAbsoluteTimeGetCurrent()
            if firstPendingAt == 0 { firstPendingAt = now }
            if now - firstPendingAt >= 0.5 {
                pending?.cancel(); pending = nil; firstPendingAt = 0
                action()
                return
            }
            pending?.cancel()
            let work = DispatchWorkItem {
                MainActor.assumeIsolated { pending = nil; firstPendingAt = 0; action() }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        /// 与生产同款：100ms `DispatchWorkItem` 合并，已有待发就不再排。
        private func coalesce(_ action: @escaping @MainActor () -> Void) {
            guard pending == nil else { return }
            let work = DispatchWorkItem { MainActor.assumeIsolated { pending = nil; action() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentScrollPolicy.coalescingDelay,
                                          execute: work)
        }
    }

    private struct NoWrap: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.lineLimit(1).truncationMode(.tail) } else { content }
        }
    }

    private struct SelectionWhole: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.textSelection(.enabled) } else { content }
        }
    }

    /// 变体归因：同一份数据、同一段 4 秒追加，只翻一个开关。
    func testShellGridVariantAttribution() async throws {
        defer { closeAllWindows() }
        var out: [String] = []
        let cases: [(String, FollowMode, SelectionMode, RowsMode, Bool, Bool)] = [
            ("A prod (spacer OUTSIDE lazy)",           .anchorCoalesced,    .perLine, .flat, false, false),
            ("B last-line-id anchor",                  .lastLineCoalesced,  .perLine, .flat, false, false),
            ("E spacer INSIDE lazy",                   .anchorCoalesced,    .perLine, .flat, false, true),
            ("E + no-sel",                             .anchorCoalesced,    .off,     .flat, false, true),
            ("D no-follow (floor)",                    .none,               .perLine, .flat, false, false),
            ("A prod (spacer OUTSIDE lazy)",           .anchorCoalesced,    .perLine, .flat, false, false),
            ("B last-line-id anchor",                  .lastLineCoalesced,  .perLine, .flat, false, false),
            ("E spacer INSIDE lazy",                   .anchorCoalesced,    .perLine, .flat, false, true),
            ("E + no-sel",                             .anchorCoalesced,    .off,     .flat, false, true),
            ("D no-follow (floor)",                    .none,               .perLine, .flat, false, false),
        ]
        for (name, follow, selection, rowsMode, gate, insideLazy) in cases {
            let feed = Feed.make(hosts: 24, seedLines: 1000)
            let fixture = try mount(VariantGrid(feed: feed, follow: follow,
                                                selection: selection, rowsMode: rowsMode,
                                                bottomInsideLazy: insideLazy, stampGate: gate))
            let host = fixture.host
            var frames: [Double] = []
            var beats = 0
            var appended = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 4 {
                try await Task.sleep(for: .milliseconds(8))
                beats += 1
                let want = min(200, Int(Date().timeIntervalSince(t0) * 50))
                let delta = want - appended
                let start = CFAbsoluteTimeGetCurrent()
                feed.append(count: delta, tick: beats)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                appended = want
            }
            // 跟随是否真的成立：量所有格里「离底还有多远」的中位数（0 = 贴底）。
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let gaps: [Double] = allScrollViews(in: host).compactMap { s in
                guard let doc = s.documentView else { return nil }
                let maxOffset = max(0, doc.frame.height - s.contentSize.height)
                return Double(maxOffset - s.contentView.bounds.origin.y)
            }
            out.append(String(format: "%-38@ beats=%d/500 p50=%.2fms p95=%.2fms over=%.0f%% views=%d tail-gap-p50=%.0fpt",
                              name as NSString, beats,
                              ProbeMetrics.percentile(frames, 0.5),
                              ProbeMetrics.percentile(frames, 0.95),
                              Double(frames.filter { $0 > 8.33 }.count) / Double(frames.count) * 100,
                              viewCount(in: host),
                              ProbeMetrics.percentile(gaps, 0.5)))
            await closeWindows()
        }
        for line in out { print("[par-variant] \(line)") }
        XCTAssertEqual(out.count, cases.count)
    }

    // MARK: - AI 泳道

    private func measureAgentView(hosts: Int) async throws -> Reading {
        let feed = Feed.make(hosts: hosts, seedLines: 40)
        for i in feed.states.indices {
            feed.states[i].tone = i % 5 == 4 ? .failed : .ok
            feed.states[i].summary = "已检查 nginx 与磁盘用量，均在阈值内；本次未做变更。"
            feed.states[i].steps = ["连接主机", "systemctl status nginx", "df -h", "汇总"]
        }

        struct AgentProbe: View {
            let feed: Feed
            var body: some View {
                ParallelAgentView(commandName: "检查 nginx",
                                  aiAssisted: true,
                                  states: feed.states,
                                  synthesis: "24 台里 5 台 nginx 未运行，已重启并复验通过。",
                                  allDone: true,
                                  onTrustAndRetry: { _ in })
            }
        }

        let fixture = try mount(AgentProbe(feed: feed))
        let host = fixture.host
        var r = Reading(hosts: hosts, lines: 0, mountMS: fixture.mountMS)
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        let scrolls = allScrollViews(in: host)
        r.scrollViews = scrolls.count
        if let scroll = scrolls.max(by: { $0.frame.height < $1.frame.height }),
           let document = scroll.documentView {
            let viewport = scroll.contentSize.height
            let maxOffset = max(0, document.frame.height - viewport)
            let amplitude = min(maxOffset, viewport * 3)
            func scrollTo(_ y: CGFloat) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            var visited: CGFloat = 0
            while visited < amplitude {
                scrollTo(visited); layout()
                try await Task.sleep(for: .milliseconds(8))
                visited += max(1, viewport * 0.8)
            }
            scrollTo(0); layout()
            try await Task.sleep(for: .milliseconds(120))
            var frames: [Double] = []
            for step in 0..<200 {
                let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
                let start = CFAbsoluteTimeGetCurrent()
                scrollTo(amplitude * wave); layout()
                frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                try await Task.sleep(for: .milliseconds(8))
            }
            r.paneP50 = ProbeMetrics.percentile(frames, 0.5)
            r.paneP95 = ProbeMetrics.percentile(frames, 0.95)
            r.paneOverBudget = Double(frames.filter { $0 > 8.33 }.count) / Double(frames.count) * 100
        }
        r.views = viewCount(in: host)
        r.histogram = classHistogram(in: host)
        await closeWindows()
        return r
    }

    func testAgentLaneScroll() async throws {
        defer { closeAllWindows() }
        let real = try await measureAgentView(hosts: 6)
        log("par-agent", real)
        let extreme = try await measureAgentView(hosts: 24)
        log("par-agent", extreme)
        XCTAssertGreaterThan(extreme.views, 0)
    }

    // MARK: - scrollKey 拼接成本

    /// `ParallelAgentView.scrollKey` 每次 body 都 `states.map{}.joined()`。
    /// 这里只量「拼一次要多久」——它每帧至少一次，且随台数线性涨。
    func testScrollKeyStringJoinCost() {
        let states: [ParallelServerState] = (0..<24).map { i in
            var s = ParallelServerState(id: UUID(), name: "web-\(i)",
                                        endpoint: "ops@h\(i):22", endpointDisplay: "ops@h\(i)")
            s.summary = String(repeating: "已检查 nginx 与磁盘用量，均在阈值内。", count: 4)
            s.steps = Array(repeating: "systemctl status nginx", count: 6)
            return s
        }
        func joined() -> String {
            states.map { "\($0.tone == .running ? 0 : 1):\($0.summary.count):\($0.steps.count)" }
                .joined(separator: "|") + "#\(120)#\(1)"
        }
        func stamped() -> Int {
            var h = Hasher()
            for s in states {
                h.combine(s.tone == .running)
                h.combine(s.summary.count)
                h.combine(s.steps.count)
            }
            h.combine(120)
            h.combine(true)
            return h.finalize()
        }
        var joinNS: [Double] = []
        var stampNS: [Double] = []
        for _ in 0..<2000 {
            var t = CFAbsoluteTimeGetCurrent()
            _ = joined()
            joinNS.append((CFAbsoluteTimeGetCurrent() - t) * 1_000_000)
            t = CFAbsoluteTimeGetCurrent()
            _ = stamped()
            stampNS.append((CFAbsoluteTimeGetCurrent() - t) * 1_000_000)
        }
        print(String(format: "[par-scrollkey] states=24 join-p50=%.2fus join-p95=%.2fus "
                     + "hash-p50=%.2fus hash-p95=%.2fus",
                     ProbeMetrics.percentile(joinNS, 0.5), ProbeMetrics.percentile(joinNS, 0.95),
                     ProbeMetrics.percentile(stampNS, 0.5), ProbeMetrics.percentile(stampNS, 0.95)))
        XCTAssertGreaterThan(joinNS.count, 0)
    }

    // MARK: - 广播条 10Hz TimelineView

    /// 静止（全部跑完）时 `TimelineView(.periodic(by: 0.1))` 还在 10Hz 唤醒。
    /// 量法：只挂广播条，3 秒 8ms 心跳（理想 375 拍），运行中 vs 已完成两轮对照。
    private func measureBroadcastBar(finished: Bool) async throws -> (beats: Int, cpu: Double) {
        struct BarProbe: View {
            let finished: Bool
            let started = Date()
            var body: some View {
                ParallelBroadcastBar(text: "systemctl status nginx",
                                     isIntent: false,
                                     mode: .shell,
                                     total: 24,
                                     doneCount: finished ? 24 : 9,
                                     okCount: finished ? 20 : 8,
                                     failedCount: finished ? 4 : 1,
                                     startedAt: started,
                                     finishedAt: finished ? started.addingTimeInterval(12) : nil)
            }
        }
        let fixture = try mount(BarProbe(finished: finished),
                                size: NSSize(width: 1120, height: 96))
        let host = fixture.host
        let cpu0 = ProbeMetrics.threadCPUSeconds()
        let t0 = Date()
        var beats = 0
        while Date().timeIntervalSince(t0) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            beats += 1
        }
        let cpu = ProbeMetrics.threadCPUSeconds() - cpu0
        await closeWindows()
        return (beats, cpu)
    }

    func testBroadcastBarTimelineIdleCost() async throws {
        defer { closeAllWindows() }
        let running = try await measureBroadcastBar(finished: false)
        let done = try await measureBroadcastBar(finished: true)
        print(String(format: "[par-timeline] running beats=%d/375 cpu=%.3fs   finished beats=%d/375 cpu=%.3fs",
                     running.beats, running.cpu, done.beats, done.cpu))
        XCTAssertGreaterThan(running.beats, 100)
        XCTAssertGreaterThan(done.beats, 100)
    }
}
