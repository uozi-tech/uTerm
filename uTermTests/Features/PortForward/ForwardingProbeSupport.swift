import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import uTerm

// 端口转发两个窗口（全局面板 / 单主机面板）性能探针的共用夹具。
// 方法论抄 `uTermTests/Support/ProbeSmokeTests.swift`（它只自证链路，不评判视图）：
// 真窗口 `.transparentOnScreen` + 建窗后断言 `blindsRealMouse`，四把尺（挂载 / 心跳拍数 /
// 单帧 p50·p95·超预算 / hitTest）+ NSView 结构判据，绝对毫秒只打印。

/// 一档的读数。绝对毫秒只打印，断言只用结构判据与同轮相对比。
struct ForwardingProbeReading {
    var label: String = ""
    var rows: Int = 0
    var mountMS: Double = 0
    /// 3 秒静止窗口（不滚动）里 8ms 心跳实际收到的拍数。理想 375。
    var idleBeats: Int = 0
    /// 静止窗口里每一拍「把 SwiftUI 挂起的更新交付掉」的耗时（ms）分位数。
    ///
    /// **必须显式交付**：窗口 `alphaValue = 0` 时 CA 不会每帧替我们跑 SwiftUI 的更新，
    /// 只量相邻拍的墙钟间隔会得到一条平的线（实测 p50 9.08 / max 10.5ms，1000 行与
    /// 50 行完全一样）—— 那不是「没有开销」，是开销还没发生。
    /// `NSHostingView.layoutSubtreeIfNeeded()` 会同步把挂起的 `@State` / `@Observable`
    /// 变更交付掉，所以每一拍逼一次，每秒那一拍的 body 重求就落在 p99 / max 上。
    var idleStepP50: Double = 0
    var idleStepP99: Double = 0
    var idleStepMax: Double = 0
    /// 静止窗口里超过 `max(1ms, 8 × 中位数)` 的拍数 —— 每秒一次的轮询应该正好留下 ~3 个。
    /// 它是这条尺的**自证**：读到 0 说明轮询根本没跑，读数不算数。
    var idleSpikes: Int = 0
    var frameP50: Double = 0
    var frameP95: Double = 0
    var overBudget: Double = 0
    var hitP50: Double = 0
    var views: Int = 0
    var buttons: Int = 0
    var scrollableHeight: CGFloat = 0
    var histogram: String = ""

    var oneLine: String {
        String(format: """
            rows=%d mount=%.2fms idle-beats=%d/375 idle-step p50=%.3f p99=%.3f max=%.3fms \
            spikes=%d frame-p50=%.3fms frame-p95=%.3fms over-8.33=%.1f%% hit-p50=%.1fus \
            views=%d buttons=%d scrollable=%.0f
            """,
            rows, mountMS, idleBeats, idleStepP50, idleStepP99, idleStepMax, idleSpikes,
            frameP50, frameP95, overBudget, hitP50, views, buttons, scrollableHeight)
    }
}

/// 转发规则探针的造数据 + 建窗 + 量尺。
@MainActor
enum ForwardingProbeFixture {

    // MARK: - 造数据

    /// 内存容器 + N 台主机 × M 条规则。规则的 `sortOrder` 按主机各自计数（与真实一致）。
    ///
    /// 状态按固定配比种进协调器（不起任何真实会话）：60% active / 25% inactive / 15% error。
    /// 刻意**不**用 `.starting` —— 它画 `ProgressView`，会一直转、把静止窗口的心跳读数
    /// 变成「转圈的开销」而不是「每秒轮询的开销」。真实界面里 `.starting` 也只是过渡态。
    static func seed(hosts: Int, rulesPerHost: Int)
        throws -> (container: ModelContainer,
                   coordinator: ForwardingCoordinator,
                   profiles: [ServerProfile],
                   rules: [ForwardingRule],
                   traffic: [UUID: TunnelBytes]) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: ServerProfile.self, ForwardingRule.self, ServerGroup.self, KnownHost.self,
            configurations: config)
        // 用 `container.mainContext` 而不是新建 `ModelContext`：`.modelContainer(_:)`
        // 把 `@Query` 接到的正是 mainContext，另起一个上下文会让探针手里的对象与视图
        // 看到的是两套实例，改一个另一个不动（契约测试会假红）。
        let context = container.mainContext
        let coordinator = ForwardingCoordinator()

        var profiles: [ServerProfile] = []
        var rules: [ForwardingRule] = []
        var traffic: [UUID: TunnelBytes] = [:]
        for h in 0..<hosts {
            let profile = ServerProfile()
            profile.name = String(format: "host-%02d.prod.internal", h)
            profile.host = "10.\(h / 256).\(h % 256).8"
            profile.port = 22
            profile.username = "deploy"
            profile.group = ["生产", "预发", "开发"][h % 3]
            profile.sortOrder = h
            context.insert(profile)
            profiles.append(profile)

            for r in 0..<rulesPerHost {
                let kind: ForwardKind = [.local, .remote, .dynamic][(h &+ r) % 3]
                let rule = ForwardingRule(
                    serverID: profile.id,
                    name: String(format: "tunnel-%02d-%02d", h, r),
                    kind: kind,
                    listenHost: "127.0.0.1",
                    listenPort: 20000 + h * 100 + r,
                    destHost: kind == .dynamic ? nil : "db-\(r).svc.cluster.local",
                    destPort: kind == .dynamic ? 0 : 5432,
                    destLabel: r % 2 == 0 ? "PostgreSQL 主库 \(r)" : nil,
                    autostart: r % 3 == 0,
                    sortOrder: r,
                    launchAtAppStart: r % 2 == 0)
                context.insert(rule)
                rules.append(rule)

                switch (h &+ r) % 20 {
                case 0..<12:
                    coordinator.setStatusForTesting(.active, for: rule.id)
                    traffic[rule.id] = TunnelBytes(up: UInt64(1_000_000 + r * 7919),
                                                  down: UInt64(4_000_000 + h * 104_729))
                case 12..<17:
                    coordinator.setStatusForTesting(.inactive, for: rule.id)
                default:
                    coordinator.setStatusForTesting(
                        .error(ForwardingError(kind: .conflict,
                                               message: "本机 \(20000 + h * 100 + r) 端口已被占用")),
                        for: rule.id)
                }
            }
        }
        try context.save()
        coordinator.injectTrafficForTesting(traffic)
        return (container, coordinator, profiles, rules, traffic)
    }

    // MARK: - 建窗

    struct Mounted {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
    }

    static func mount(_ view: AnyView, size: NSSize,
                      windows: inout [NSWindow]) throws -> Mounted {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width,
                                                              height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "夹具里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView, "NSScrollView 必须有 documentView")
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(unconstrained),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")
        return Mounted(window: unconstrained, host: host, scroll: scroll,
                       document: document, mountMS: mountMS)
    }

    // MARK: - 量

    static func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ view: NSView) { n += 1; for sub in view.subviews { walk(sub) } }
        walk(root)
        return n
    }

    /// 子树里真正的 AppKit 控件数（SwiftUI 的 `Button` 在平台上落成 `NSControl` 子类）。
    static func controlCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ view: NSView) {
            if view is NSControl { n += 1 }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return n
    }

    static func classHistogram(in root: NSView) -> String {
        var counts: [String: Int] = [:]
        func walk(_ view: NSView) {
            counts[String(describing: type(of: view)), default: 0] += 1
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }

    /// 一档全套：挂载 → 扫一遍实例化懒行 → 3s **静止**心跳 → 200 步往返 → hitTest。
    ///
    /// 静止窗口是这一处的重点：全局面板每秒替换一次 `traffic`，不滚动时主线程的开销
    /// 全来自那一拍；`idleGapP99` / `idleGapMax` 就是那一拍撑起来的尾巴。
    /// - Parameter mutateSource: 静止窗口里每 8 拍调一次，让被观察的数据源**真的变**
    ///   （在计时区间之外调用，不进读数）。没有它的话读到的是「数据没变 ⇒ SwiftUI 什么
    ///   都不做」：`@State` 的写入是带相等性比较的，注入一份恒定的流量快照时
    ///   `traffic = stats` 根本不会让 body 重求，量到的 idle 开销恒为 0 —— 那是夹具
    ///   的假象，不是产线的真相（真隧道每秒都在涨字节）。
    static func measure(label: String, rows: Int, mounted: Mounted,
                        mutateSource: (() -> Void)? = nil) async -> ForwardingProbeReading {
        var reading = ForwardingProbeReading(label: label, rows: rows, mountMS: mounted.mountMS)
        let scroll = mounted.scroll
        let document = mounted.document
        let host = mounted.host

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)
        reading.scrollableHeight = maxOffset

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        // 先以小于一屏的间距扫过要往返的那一段，把懒建的行与 tracking area 全部计入。
        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited)
            layout()
            try? await Task.sleep(for: .milliseconds(8))
            visited += max(1, viewport * 0.8)
        }
        scrollTo(0)
        layout()
        try? await Task.sleep(for: .milliseconds(200))

        // ① 3 秒静止：一步都不滚，只让 runloop 转，每拍逼一次交付。
        //    每秒轮询替换 `traffic` 的那一拍就落在 p99 / max / spikes 上。
        var steps: [Double] = []
        let idleStart = Date()
        var beats = 0
        while Date().timeIntervalSince(idleStart) < 3 {
            try? await Task.sleep(for: .milliseconds(8))
            // 数据源的变更在计时区间之外做，不进读数。
            if beats % 8 == 0 { mutateSource?() }
            let t0 = CFAbsoluteTimeGetCurrent()
            layout()
            steps.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            beats += 1
        }
        reading.idleBeats = beats
        let median = ProbeMetrics.percentile(steps, 0.5)
        reading.idleStepP50 = median
        reading.idleStepP99 = ProbeMetrics.percentile(steps, 0.99)
        reading.idleStepMax = steps.max() ?? 0
        let spikeThreshold = max(1.0, median * 8)
        reading.idleSpikes = steps.filter { $0 > spikeThreshold }.count

        // ② 200 步往返，每步逼一次布局 + 绘制。
        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try? await Task.sleep(for: .milliseconds(8))
        }
        reading.frameP50 = ProbeMetrics.percentile(frames, 0.5)
        reading.frameP95 = ProbeMetrics.percentile(frames, 0.95)
        reading.overBudget = Double(frames.filter { $0 > 8.33 }.count) / Double(frames.count) * 100

        // ③ hitTest：首中尾三处各 100 次。它不随规模涨才说明命中路径没被行数拖累。
        var hits: [Double] = []
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction)
            layout()
            try? await Task.sleep(for: .milliseconds(120))
            for i in 0..<100 {
                let point = NSPoint(x: CGFloat(60 + (i % 11) * 60), y: CGFloat(80 + (i % 9) * 50))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }
        reading.hitP50 = ProbeMetrics.percentile(hits, 0.5)
        reading.views = viewCount(in: host)
        reading.buttons = controlCount(in: host)
        reading.histogram = classHistogram(in: host)
        return reading
    }
}
