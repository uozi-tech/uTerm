import UDesignKit
import AppKit
import SwiftUI
import XCTest
@testable import uTerm

// 形状抄自 `uTermTests/Support/ProbeSmokeTests.swift`（链路自证），量法照
// `<workspace>/uTable/docs/swiftui-scroll-perf-playbook.md` §一 四把尺。
//
// 被测对象是**两个共用 `FileBrowserModel` 数据的列表**：
// - `SFTPFileTable`（独立 SFTP 窗口的文件表，经真 `SFTPBrowserView` 挂载）
// - `FileBrowserContent`（工作区左侧栏文件树，常驻）
//
// 判据全部走结构读数（NSView / NSTextField / tracking area / toolTip 数、文档高度），
// 绝对毫秒只打印 —— 换台机器绝对值就变，同一轮内的相对比才作数（playbook §二·4）。

// MARK: - 共用夹具

/// 探针共用的规模与造数。
///
/// 规模来源：`FileBrowserModel.swift:374` 的 `entries = try await provider.list(path:)`
/// 是**全量发布、无截断**，所以列表长度就是远端目录的真实条目数。
/// - 真实档 500：一个普通项目目录（源码 + 资源 + 锁文件）。
/// - 极端档 20000：`node_modules` / `/usr/bin` 量级。
@MainActor
enum FileBrowserProbeFixture {

    static let realistic = 500
    static let extreme = 20_000

    static let directoryPath = "/home/deploy/project"

    /// 造一个目录列表。名字里带零填充序号，供筛选探针按数字挑子集。
    ///
    /// `uid` / `gid` 一律 nil、`ownerName` / `groupName` 直接给好 —— 让
    /// `FileBrowserModel.resolveOwnerNames` 早退，探针不去量 exec 补全那条路
    /// （那是网络往返，不是渲染成本）。
    static func entries(_ count: Int) -> [RemoteEntry] {
        let extensions = ["swift", "ts", "tsx", "js", "json", "md", "png",
                          "yml", "lock", "txt", "go", "py", "css", "html", "sh"]
        return (0..<count).map { index in
            let isDirectory = index % 7 == 0
            let name = isDirectory
                ? String(format: "package-%05d", index)
                : String(format: "module-%05d.%@", index, extensions[index % extensions.count])
            return RemoteEntry(
                name: name,
                posixPermissions: isDirectory ? 0o040755 : 0o100644,
                size: isDirectory ? nil : UInt64(1024 + index * 37),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 613),
                uid: nil, gid: nil,
                ownerName: index % 3 == 0 ? "root" : "deploy",
                groupName: index % 3 == 0 ? "wheel" : "staff")
        }
    }

    /// 建一个已经处于 `.browsing`、列表已就位的 model。
    static func model(_ count: Int) async -> FileBrowserModel {
        let provider = MockSFTP(tree: [directoryPath: entries(count)])
        let model = FileBrowserModel(testProvider: provider, startPath: directoryPath)
        await model.refresh()
        return model
    }
}

/// 一档的读数。绝对毫秒只打印，硬断言只用后面那几个结构量。
struct FileBrowserProbeReading {
    let label: String
    let rows: Int
    let mountMS: Double
    let beats: Int
    let frameP50: Double
    let frameP95: Double
    let frameMax: Double
    let overBudget: Double
    let hitP50: Double
    let views: Int
    let textFields: Int
    /// 整棵子树里的 `NSTrackingArea` 总数 —— `.onHover` / `hoverBackground` 每行
    /// 是不是各留一个平台追踪区，看这个。
    let trackingAreas: Int
    /// `toolTip != nil` 的视图数 —— 行内 `.help` 是不是每行常驻一个 tooltip 区，看这个。
    let toolTips: Int
    let documentHeight: CGFloat
    let scrollableHeight: CGFloat
    let histogram: String
}

/// 建窗 + 挂载 + 扫掠 + 心跳 + 单帧 + hitTest 的共用实现。两个被测视图只是
/// 传进来的 `content` 不同。
@MainActor
final class FileBrowserProbeRig {

    struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
    }

    private(set) var windows: [NSWindow] = []

    func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    func closeWindowsAndSettle() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// 挂载一棵 SwiftUI 树到透明屏内窗口（计时判据必须在屏上，见 `ProbeWindow` 顶部 A/B）。
    func mount(_ view: some View, size: NSSize) throws -> Fixture {
        let root = AnyView(view.frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "夹具里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView, "NSScrollView 必须有 documentView")
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(unconstrained),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")
        return Fixture(window: unconstrained, host: host, scroll: scroll,
                       document: document, mountMS: mountMS)
    }

    /// 扫掠 → 心跳 → 200 步往返 → hitTest。往返幅度钳 ≈3 视口。
    func measure(_ fixture: Fixture, label: String, rows: Int) async throws
        -> FileBrowserProbeReading {
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += max(1, viewport * 0.8)
        }
        scrollTo(0)
        layout()
        try await Task.sleep(for: .milliseconds(120))

        let heartbeatStart = Date()
        var beats = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(beats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            beats += 1
        }

        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }

        var hits: [Double] = []
        let scrollFrame = scroll.convert(scroll.bounds, to: host)
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction)
            layout()
            try await Task.sleep(for: .milliseconds(120))
            for i in 0..<100 {
                let point = NSPoint(
                    x: scrollFrame.minX + CGFloat(20 + (i % 9) * 30),
                    y: scrollFrame.minY + CGFloat(20 + (i % 11) * 30))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = FileBrowserProbeReading(
            label: label,
            rows: rows,
            mountMS: fixture.mountMS,
            beats: beats,
            frameP50: ProbeMetrics.percentile(frames, 0.5),
            frameP95: ProbeMetrics.percentile(frames, 0.95),
            frameMax: frames.max() ?? 0,
            overBudget: Double(frames.filter { $0 > 8.33 }.count) / Double(frames.count) * 100,
            hitP50: ProbeMetrics.percentile(hits, 0.5),
            views: Self.viewCount(in: host),
            textFields: Self.count(in: host) { $0 is NSTextField },
            trackingAreas: Self.trackingAreaCount(in: host),
            toolTips: Self.count(in: host) { $0.toolTip != nil },
            documentHeight: document.frame.height,
            scrollableHeight: maxOffset,
            histogram: Self.classHistogram(in: host))
        Self.log(reading)
        return reading
    }

    static func log(_ r: FileBrowserProbeReading) {
        print(String(format: """
            [%@] rows=%d mount=%.2fms beats=%d/375 frame-p50=%.3fms frame-p95=%.3fms \
            max=%.3fms over-8.33=%.1f%% hit-p50=%.1fus views=%d textfields=%d \
            tracking=%d tooltips=%d doc-h=%.0f scrollable=%.0f cpu=%.2fs rss=%.1fMB
            """,
            r.label, r.rows, r.mountMS, r.beats, r.frameP50, r.frameP95, r.frameMax,
            r.overBudget, r.hitP50, r.views, r.textFields, r.trackingAreas, r.toolTips,
            r.documentHeight, r.scrollableHeight,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[\(r.label)-views] rows=\(r.rows) \(r.histogram)")
    }

    // MARK: 结构读数

    static func viewCount(in root: NSView) -> Int {
        count(in: root) { _ in true }
    }

    static func count(in root: NSView, where predicate: (NSView) -> Bool) -> Int {
        var n = 0
        func walk(_ view: NSView) {
            if predicate(view) { n += 1 }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return n
    }

    static func trackingAreaCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ view: NSView) {
            n += view.trackingAreas.count
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

    // MARK: 交互端到端

    /// 一次真单击的读数。
    ///
    /// **为什么要分两个数**：两个列表的行**改前**都是 `onTapGesture(count: 2)` 链
    /// `onTapGesture`（单 / 双击互斥消歧），单击必须先等双击超时才落地 —— 那段
    /// 等待是系统的双击间隔常数、不是渲染成本，把它算进「一次单击多贵」就量错了
    /// 对象。改后两处都换成容器级 `NSEvent.clickCount` 分派
    /// （`ClickSelectActivate.swift`），那段等待归零，`latencyMS` 从此就是真成本。
    /// - `latencyMS`：事件进去到那一行像素变掉的墙钟。
    /// - `repaintMS`：其间**最贵的那一步** `layoutSubtreeIfNeeded + displayIfNeeded`
    ///   —— 选中态落地时真正要付的那一帧。
    struct ClickReading {
        let latencyMS: Double
        let repaintMS: Double
        let meanChannelDelta: Double
    }

    /// 往窗口里真打一次左键单击（down + up），然后一小步一小步转 runloop 等选中态落地。
    ///
    /// **必须走 `NSApp.sendEvent`**：行的点击层是挂在 `NSApplication` 上的本地事件
    /// 监视器（`RowClickLayerView`），`window.sendEvent` 绕过 `NSApp` 就收不到。
    func click(_ fixture: Fixture, rowHeight: CGFloat) async -> ClickReading {
        let host = fixture.host
        let scrollInHost = fixture.scroll.convert(fixture.scroll.bounds, to: host)
        // 取滚动区正中的一条横带 —— 一定落在列表行上，且不受翻转坐标系影响。
        let centerY = scrollInHost.midY
        let rowRect = NSRect(x: scrollInHost.minX, y: centerY - rowHeight / 2,
                             width: scrollInHost.width, height: rowHeight)
        let before = Self.snapshot(host, rect: rowRect)
        let pointInHost = NSPoint(x: scrollInHost.minX + 120, y: centerY)
        let pointInWindow = host.convert(pointInHost, to: nil)

        let start = CFAbsoluteTimeGetCurrent()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: pointInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            NSApp.sendEvent(event)
        }

        var repaintMS = 0.0
        var delta = 0.0
        var latencyMS = 0.0
        // 改后按下即落地；上限留足 2s，好在回退时也能把「等了多久」量出来。
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(20))
            let stepStart = CFAbsoluteTimeGetCurrent()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            repaintMS = max(repaintMS, (CFAbsoluteTimeGetCurrent() - stepStart) * 1000)
            delta = Self.meanChannelDelta(before, Self.snapshot(host, rect: rowRect))
            if delta > 0.001 {
                latencyMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
                break
            }
        }
        if latencyMS == 0 { latencyMS = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
        return ClickReading(latencyMS: latencyMS, repaintMS: repaintMS, meanChannelDelta: delta)
    }

    /// 找到（唯一的）可编辑 `NSTextField` —— SFTP 路径栏的筛选框。
    func editableTextField(in root: NSView) -> NSTextField? {
        var found: NSTextField?
        func walk(_ view: NSView) {
            if found == nil, let field = view as? NSTextField, field.isEditable {
                found = field
            }
            for sub in view.subviews where found == nil { walk(sub) }
        }
        walk(root)
        return found
    }

    /// 往筛选框真打一个字符（走 field editor 的文本输入路径，与用户敲键同一条链），
    /// 量到「布局 + 绘制完成」为止。
    func typeIntoFilter(_ fixture: Fixture, _ character: String) throws -> Double {
        let field = try XCTUnwrap(editableTextField(in: fixture.host), "路径栏必须有筛选输入框")
        if fixture.window.firstResponder !== field.currentEditor() {
            XCTAssertTrue(fixture.window.makeFirstResponder(field), "筛选框必须能拿到焦点")
        }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "聚焦后必须有 field editor")
        let start = CFAbsoluteTimeGetCurrent()
        editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: 像素

    static func snapshot(_ view: NSView, rect: NSRect) -> NSBitmapImageRep? {
        let clipped = rect.intersection(view.bounds)
        guard !clipped.isEmpty,
              let rep = view.bitmapImageRepForCachingDisplay(in: clipped) else { return nil }
        view.cacheDisplay(in: clipped, to: rep)
        return rep
    }

    /// 两张同尺寸位图的平均通道差（0…1）。用来证明「点下去之后这一行真的重画了」。
    static func meanChannelDelta(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Double {
        guard let a, let b,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let pa = a.bitmapData, let pb = b.bitmapData,
              a.bytesPerRow == b.bytesPerRow else { return -1 }
        let bytes = a.bytesPerRow * a.pixelsHigh
        var sum = 0.0
        for i in 0..<bytes { sum += Double(abs(Int(pa[i]) - Int(pb[i]))) }
        return sum / Double(bytes) / 255.0
    }
}

// MARK: - SFTP 独立窗口文件表

/// `SFTPFileTable`（`uTerm/Features/SFTP/Views/SFTPFileTable.swift:108/161`）经真
/// `SFTPBrowserView` 挂载后的读数。
///
/// 每行的交互元件：`onDrag` + `contextMenu` + `hoverBackground` 的 `onHover` +
/// `permChip` 的 `.help`。单 / 双击与目录行 `onDrop` 都已收到整表一个的容器级层
/// （`ClickSelectActivate.swift` / `RemoteRowDropTargeting.swift`）。
@MainActor
final class SFTPFileTableScrollCostTests: XCTestCase {

    private let rig = FileBrowserProbeRig()
    private static let windowSize = NSSize(width: 1200, height: 780)

    /// SFTP 窗口外壳（自绘标题栏 + 标签栏）不在被测范围内，这里只挂浏览器本体。
    private func browser(_ model: FileBrowserModel) -> some View {
        SFTPBrowserView(model: model, server: ServerProfile(), openWorkspace: {})
    }

    private func reading(rows: Int, label: String) async throws -> FileBrowserProbeReading {
        let model = await FileBrowserProbeFixture.model(rows)
        let fixture = try rig.mount(browser(model), size: Self.windowSize)
        let reading = try await rig.measure(fixture, label: label, rows: rows)
        await rig.closeWindowsAndSettle()
        return reading
    }

    /// 真实档 500 与极端档 20000 各一窗。
    func testFileTableScaleReadings() async throws {
        defer { rig.closeAllWindows() }
        let small = try await reading(rows: FileBrowserProbeFixture.realistic,
                                      label: "sftp-table")
        let large = try await reading(rows: FileBrowserProbeFixture.extreme,
                                      label: "sftp-table")

        // 懒栈真的在回收：平台视图数不该随目录条目数线性涨。
        XCTAssertGreaterThan(large.scrollableHeight, small.scrollableHeight,
                             "20000 条的可滚动高度必须大于 500 条")
        XCTAssertGreaterThan(large.documentHeight, small.documentHeight)
        XCTAssertGreaterThan(large.beats, 30, "3 秒 8ms 心跳一拍都收不到 = 主线程被占死")
        XCTAssertLessThan(Double(large.views), Double(small.views) * 2 + 40,
                          "行数翻 40 倍，平台视图数不该跟着涨："
                          + "500 行 \(small.views) vs 20000 行 \(large.views)")
    }

    /// 一次单击选中、一次筛选击键的端到端（极端档）。
    func testFileTableInteractionCost() async throws {
        defer { rig.closeAllWindows() }
        let rows = FileBrowserProbeFixture.extreme
        let model = await FileBrowserProbeFixture.model(rows)
        let fixture = try rig.mount(browser(model), size: Self.windowSize)
        try await Task.sleep(for: .milliseconds(200))

        let click = await rig.click(fixture, rowHeight: 52)
        print(String(format: "[sftp-table-click] rows=%d latency=%.2fms repaint=%.2fms pixel-delta=%.4f",
                     rows, click.latencyMS, click.repaintMS, click.meanChannelDelta))
        XCTAssertGreaterThan(click.meanChannelDelta, 0.001,
                             "单击必须真的把那一行画成选中态（像素得变）")

        // 纯扫表成本（一次 `localizedCaseInsensitiveContains` 过全表）单独量一次，
        // 好把「筛选击键」那笔账拆成「扫表」与「SwiftUI 重建 ForEach」两半。
        let source = model.sortedEntries
        let scanStart = CFAbsoluteTimeGetCurrent()
        let scanned = RemoteEntryFilter().apply(source, query: "7")
        let scanMS = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000

        let heightBefore = fixture.document.frame.height
        let keystroke = try rig.typeIntoFilter(fixture, "7")
        try await Task.sleep(for: .milliseconds(120))
        fixture.host.layoutSubtreeIfNeeded()
        let heightAfter = fixture.document.frame.height
        // 第二击：源数组还是 20000（扫表成本相同），但结果集从 6878 缩到几百 ——
        // 与第一击的差就是「SwiftUI 重建多少行」那一半。
        let keystroke2 = try rig.typeIntoFilter(fixture, "7")
        try await Task.sleep(for: .milliseconds(120))
        fixture.host.layoutSubtreeIfNeeded()
        print(String(format: """
            [sftp-table-filter] rows=%d scan-only=%.2fms(->%d) keystroke1=%.2fms \
            keystroke2=%.2fms doc-h %.0f -> %.0f -> %.0f
            """,
                     rows, scanMS, scanned.count, keystroke, keystroke2,
                     heightBefore, heightAfter, fixture.document.frame.height))
        XCTAssertLessThan(heightAfter, heightBefore,
                          "敲一个「7」必须真的把列表筛短（否则量的不是筛选）")

        await rig.closeWindowsAndSettle()
    }

    /// 5 个标签同时挂载（`SFTPWindowView.swift:76` 的 `ZStack + ForEach` + opacity 显隐）
    /// 对照 1 个标签。这里复刻那段挂载形状，而不是去起真窗口场景。
    func testMultipleTabsMountedAtOnce() async throws {
        defer { rig.closeAllWindows() }
        let rows = FileBrowserProbeFixture.realistic

        let one = try await tabStackReading(tabCount: 1, rows: rows)
        let five = try await tabStackReading(tabCount: 5, rows: rows)

        print(String(format: "[sftp-tabs] 1 tab views=%d mount=%.2fms  |  5 tabs views=%d mount=%.2fms",
                     one.views, one.mountMS, five.views, five.mountMS))
        XCTAssertGreaterThan(five.beats, 30)
        // 结构判据：非活动标签也在挂载，所以平台视图数按标签数涨。这条断言钉住
        // 「五个标签的确都挂了」——它是判定的证据，不是闸门。
        XCTAssertGreaterThanOrEqual(five.views, one.views)
    }

    private func tabStackReading(tabCount: Int, rows: Int) async throws
        -> FileBrowserProbeReading {
        var models: [FileBrowserModel] = []
        for _ in 0..<tabCount { models.append(await FileBrowserProbeFixture.model(rows)) }
        let stack = ProbeSFTPTabStack(models: models)
        let fixture = try rig.mount(stack, size: Self.windowSize)
        let reading = try await rig.measure(fixture, label: "sftp-tabs-\(tabCount)", rows: rows)
        await rig.closeWindowsAndSettle()
        return reading
    }
}

/// `SFTPWindowView.sftpBody` 里那段「全部标签同时挂载、按激活态显隐」的复刻
/// （`SFTPWindowView.swift:76-83`）。逐字对齐 opacity / allowsHitTesting / zIndex 三个修饰器；
/// 起真窗口场景要 `openWindow` / `dismiss` 环境值，探针里拿不到。
private struct ProbeSFTPTabStack: View {
    let models: [FileBrowserModel]

    var body: some View {
        ZStack {
            ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                SFTPBrowserView(model: model, server: ServerProfile(), openWorkspace: {})
                    .opacity(index == 0 ? 1 : 0)
                    .allowsHitTesting(index == 0)
                    .zIndex(index == 0 ? 1 : 0)
            }
        }
    }
}

// MARK: - 工作区左侧栏文件树

/// `FileBrowserContent`（`uTerm/Features/Files/Views/FileBrowserView.swift:268`）的读数。
/// 与 SFTP 文件表同形态、同数据源，但常驻工作区侧栏，行高 30、无筛选框。
@MainActor
final class FileBrowserSidebarScrollCostTests: XCTestCase {

    private let rig = FileBrowserProbeRig()
    private static let windowSize = NSSize(width: 320, height: 760)

    private func reading(rows: Int) async throws -> FileBrowserProbeReading {
        let model = await FileBrowserProbeFixture.model(rows)
        let fixture = try rig.mount(FileBrowserContent(model: model), size: Self.windowSize)
        let reading = try await rig.measure(fixture, label: "files-sidebar", rows: rows)
        await rig.closeWindowsAndSettle()
        return reading
    }

    func testSidebarScaleReadings() async throws {
        defer { rig.closeAllWindows() }
        let small = try await reading(rows: FileBrowserProbeFixture.realistic)
        let large = try await reading(rows: FileBrowserProbeFixture.extreme)

        XCTAssertGreaterThan(large.scrollableHeight, small.scrollableHeight)
        XCTAssertGreaterThan(large.beats, 30, "3 秒 8ms 心跳一拍都收不到 = 主线程被占死")
        XCTAssertLessThan(Double(large.views), Double(small.views) * 2 + 40,
                          "行数翻 40 倍，平台视图数不该跟着涨："
                          + "500 行 \(small.views) vs 20000 行 \(large.views)")
    }

    func testSidebarClickCost() async throws {
        defer { rig.closeAllWindows() }
        let rows = FileBrowserProbeFixture.extreme
        let model = await FileBrowserProbeFixture.model(rows)
        let fixture = try rig.mount(FileBrowserContent(model: model), size: Self.windowSize)
        try await Task.sleep(for: .milliseconds(200))

        let click = await rig.click(fixture, rowHeight: 30)
        print(String(format: "[files-sidebar-click] rows=%d latency=%.2fms repaint=%.2fms pixel-delta=%.4f",
                     rows, click.latencyMS, click.repaintMS, click.meanChannelDelta))
        XCTAssertGreaterThan(click.meanChannelDelta, 0.001,
                             "单击必须真的把那一行画成选中态（像素得变）")
        await rig.closeWindowsAndSettle()
    }
}

// MARK: - 行内修饰器归因矩阵

/// 「行里贵的到底是哪个修饰器」的归因探针。
///
/// 不动生产代码：用一份与 `SFTPFileTable.row` 同形状的合成行，逐个把行内修饰器
/// 加回去，量每一档的**平台视图数**与滚动读数。这样「per-row `.help` / `onHover` /
/// `contextMenu` / `onDrag` / `onDrop` 各自值多少钱」是量出来的，不是猜的
/// （uTable playbook §五·八③：去掉 Button 反而更慢，所以必须逐项对照）。
struct ProbeRowFeatures: OptionSet {
    let rawValue: Int
    static let tapGestures = ProbeRowFeatures(rawValue: 1 << 0)
    static let hoverBackground = ProbeRowFeatures(rawValue: 1 << 1)
    static let contextMenu = ProbeRowFeatures(rawValue: 1 << 2)
    static let help = ProbeRowFeatures(rawValue: 1 << 3)
    static let drag = ProbeRowFeatures(rawValue: 1 << 4)
    static let drop = ProbeRowFeatures(rawValue: 1 << 5)
    static let accessibility = ProbeRowFeatures(rawValue: 1 << 6)
    static let all: ProbeRowFeatures = [.tapGestures, .hoverBackground, .contextMenu,
                                        .help, .drag, .drop, .accessibility]
}

/// 与 `SFTPFileTable` 同形状的合成列表（同样 `ScrollView + LazyVStack + ForEach`、
/// 同样的行高与列结构），行内修饰器按 `features` 开关。
private struct ProbeAttributionList: View {
    let entries: [RemoteEntry]
    let features: ProbeRowFeatures
    /// true = 复刻工作区侧栏那一版（窄栏、行高 30、只有图标 + 名字 + 大小）。
    var compact: Bool = false
    @State private var selectedID: RemoteEntry.ID?

    private var actions: SFTPRowActions {
        SFTPRowActions(currentPath: "/home/deploy/project",
                       onActivate: { _ in }, onRename: { _ in },
                       onPermissions: { _ in }, onDelete: { _ in })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    row(entry).id(entry.id)
                }
            }
        }
        .background(UD.bg)
    }

    @ViewBuilder
    private func row(_ entry: RemoteEntry) -> some View {
        let kind = BrowserFileKind.from(name: entry.name,
                                        isDirectory: entry.isDirectory,
                                        isSymlink: entry.isSymlink)
        let selected = entry.id == selectedID
        let base = compact ? AnyView(compactBody(entry, kind: kind, selected: selected))
                           : AnyView(wideBody(entry, kind: kind, selected: selected))
        applyDrop(applyDrag(applyMenu(applyAccessibility(applyTap(applyHover(base),
                                                                 entry: entry),
                                                         entry: entry, kind: kind),
                                      entry: entry),
                            entry: entry),
                  entry: entry)
    }

    private func compactBody(_ entry: RemoteEntry, kind: BrowserFileKind,
                             selected: Bool) -> some View {
        HStack(spacing: 9) {
            SFTPFileIcon(kind: kind, size: 16).frame(width: 22)
            Text(entry.name).font(.system(size: 13))
                .foregroundStyle(UD.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = entry.size, !entry.isDirectory {
                Text(UFormat.bytes(Int64(clamping: size)))
                    .font(UD.mono(11)).foregroundStyle(UD.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Rectangle().fill(selected ? UD.rowSelected : Color.clear))
        .contentShape(Rectangle())
    }

    private func wideBody(_ entry: RemoteEntry, kind: BrowserFileKind,
                          selected: Bool) -> some View {
        HStack(spacing: 12) {
            SFTPFileIcon(kind: kind).frame(width: 30)
            Text(entry.name).font(.system(size: 13.5))
                .foregroundStyle(UD.text).lineLimit(1).truncationMode(.middle)
                .frame(width: 420, alignment: .leading)
            Text(entry.ownerDisplayText).font(UD.mono(12)).foregroundStyle(UD.text2)
                .lineLimit(1).frame(width: 112, alignment: .leading)
            permissionChip(entry).frame(width: 72, alignment: .leading)
            Text(entry.modifiedAt.map { UFormat.dateTime($0) } ?? UFormat.placeholder)
                .font(UD.mono(12)).foregroundStyle(UD.text3)
                .lineLimit(1).frame(width: 156, alignment: .leading)
            Text(entry.isDirectory || entry.size == nil
                 ? UFormat.placeholder : UFormat.bytes(Int64(clamping: entry.size!)))
                .font(UD.mono(12)).foregroundStyle(UD.text2)
                .lineLimit(1).frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(Rectangle().fill(selected ? UD.rowSelected : Color.clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func permissionChip(_ entry: RemoteEntry) -> some View {
        let chip = Text(posixOctalString(entry.permissions))
            .font(UD.mono(11)).foregroundStyle(UD.text2)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillSoft))
        if features.contains(.help) {
            chip.help(posixPermissionString(entry.permissions))
        } else {
            chip
        }
    }

    @ViewBuilder
    private func applyHover(_ content: some View) -> some View {
        if features.contains(.hoverBackground) {
            content.hoverBackground(UD.rowHover)
        } else {
            content
        }
    }

    @ViewBuilder
    private func applyTap(_ content: some View, entry: RemoteEntry) -> some View {
        if features.contains(.tapGestures) {
            content
                .onTapGesture(count: 2) { selectedID = entry.id }
                .onTapGesture { selectedID = entry.id }
        } else {
            content
        }
    }

    @ViewBuilder
    private func applyAccessibility(_ content: some View,
                                    entry: RemoteEntry, kind: BrowserFileKind) -> some View {
        if features.contains(.accessibility) {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(entry.name)
                .accessibilityValue(kind.label)
                .accessibilityAction { }
        } else {
            content
        }
    }

    @ViewBuilder
    private func applyMenu(_ content: some View, entry: RemoteEntry) -> some View {
        if features.contains(.contextMenu) {
            content.contextMenu { SFTPRowMenu(entry: entry, actions: actions) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func applyDrag(_ content: some View, entry: RemoteEntry) -> some View {
        if features.contains(.drag) {
            content.onDrag { NSItemProvider(object: entry.name as NSString) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func applyDrop(_ content: some View, entry: RemoteEntry) -> some View {
        if features.contains(.drop), entry.isDirectory {
            content.onDrop(of: [.utermRemoteFile], isTargeted: nil) { _ in false }
        } else {
            content
        }
    }
}

/// 逐项归因：每加一个行内修饰器，平台视图数与滚动读数各涨多少。
@MainActor
final class FileBrowserRowAttributionTests: XCTestCase {

    private let rig = FileBrowserProbeRig()
    private static let windowSize = NSSize(width: 1200, height: 780)

    func testRowModifierAttribution() async throws {
        defer { rig.closeAllWindows() }
        let entries = FileBrowserProbeFixture.entries(FileBrowserProbeFixture.extreme)
        let cases: [(String, ProbeRowFeatures)] = [
            ("base", []),
            ("+tap", [.tapGestures]),
            ("+hover", [.tapGestures, .hoverBackground]),
            ("+ax", [.tapGestures, .hoverBackground, .accessibility]),
            ("+menu", [.tapGestures, .hoverBackground, .accessibility, .contextMenu]),
            ("+help", [.tapGestures, .hoverBackground, .accessibility, .contextMenu, .help]),
            ("+drag", [.tapGestures, .hoverBackground, .accessibility, .contextMenu,
                       .help, .drag]),
            ("+drop(all)", .all)
        ]
        var readings: [FileBrowserProbeReading] = []
        for (name, features) in cases {
            let fixture = try rig.mount(
                ProbeAttributionList(entries: entries, features: features),
                size: Self.windowSize)
            readings.append(try await rig.measure(fixture, label: "attr-\(name)",
                                                  rows: entries.count))
            await rig.closeWindowsAndSettle()
        }
        print("[attr-summary] 档 | views | tracking | frame-p50 | frame-p95 | over8.33 | hit-p50")
        for r in readings {
            print(String(format: "[attr-summary] %@ | %d | %d | %.3f | %.3f | %.1f%% | %.1fus",
                         r.label, r.views, r.trackingAreas, r.frameP50, r.frameP95,
                         r.overBudget, r.hitP50))
        }
        XCTAssertGreaterThan(readings.count, 1)
    }
}

// MARK: - 两个列表交替对照

/// **为什么要交替**：同一个测试进程里，先跑的那一档系统性偏慢（首轮
/// `attr-base` p50 5.37ms → 末轮 `attr-+drop` 3.41ms，而结构读数证明后者只多不少）。
/// 所以「侧栏比文件表差」这种跨视图结论，必须把两臂**交错**排（A/B/B/A），
/// 只信同一轮里的相对差（`ProbeWindow` 顶部 A/B 方法论）。
@MainActor
final class FileBrowserInterleavedComparisonTests: XCTestCase {

    private let rig = FileBrowserProbeRig()

    func testSidebarVersusFileTableInterleaved() async throws {
        defer { rig.closeAllWindows() }
        let rows = FileBrowserProbeFixture.extreme
        var readings: [FileBrowserProbeReading] = []
        for arm in ["sidebar", "table", "table", "sidebar"] {
            let model = await FileBrowserProbeFixture.model(rows)
            let fixture: FileBrowserProbeRig.Fixture
            if arm == "sidebar" {
                fixture = try rig.mount(FileBrowserContent(model: model),
                                        size: NSSize(width: 320, height: 760))
            } else {
                fixture = try rig.mount(
                    SFTPBrowserView(model: model, server: ServerProfile(), openWorkspace: {}),
                    size: NSSize(width: 1200, height: 780))
            }
            readings.append(try await rig.measure(fixture, label: "ilv-\(arm)", rows: rows))
            await rig.closeWindowsAndSettle()
        }
        print("[ilv-summary] 轮次 | views | frame-p50 | frame-p95 | over8.33 | hit-p50 | beats")
        for r in readings {
            print(String(format: "[ilv-summary] %@ | %d | %.3f | %.3f | %.1f%% | %.1fus | %d",
                         r.label, r.views, r.frameP50, r.frameP95, r.overBudget,
                         r.hitP50, r.beats))
        }
        XCTAssertEqual(readings.count, 4)
    }
}

// MARK: - 侧栏几何下的 onDrop 归因

/// 交替对照「侧栏行形状 + 行内 `onDrop`」与「同形状但没有行内 `onDrop`」。
///
/// 侧栏是两个列表里唯一越线的那个（超 8.33ms 的帧 3.5~8.0%），而它与文件表的
/// 结构差别只有一处：**平台视图数 258 vs 177，多出来的全是
/// `_PlatformDraggingDestinationView` + 它的宿主**（122 对 vs 65 对）。
/// 这一条用同一轮 A/B/B/A 判定「那些平台节点是不是越线的原因」。
@MainActor
final class FileBrowserDropTargetAttributionTests: XCTestCase {

    private let rig = FileBrowserProbeRig()

    func testRowDropTargetsAtSidebarGeometry() async throws {
        defer { rig.closeAllWindows() }
        let entries = FileBrowserProbeFixture.entries(FileBrowserProbeFixture.extreme)
        let withDrop: ProbeRowFeatures = .all
        let withoutDrop: ProbeRowFeatures = ProbeRowFeatures.all.subtracting(.drop)
        var readings: [FileBrowserProbeReading] = []
        for (name, features) in [("no-drop", withoutDrop), ("drop", withDrop),
                                 ("drop", withDrop), ("no-drop", withoutDrop)] {
            let fixture = try rig.mount(
                ProbeAttributionList(entries: entries, features: features, compact: true),
                size: NSSize(width: 320, height: 760))
            readings.append(try await rig.measure(fixture, label: "drop-\(name)",
                                                  rows: entries.count))
            await rig.closeWindowsAndSettle()
        }
        print("[drop-summary] 轮次 | views | frame-p50 | frame-p95 | over8.33 | hit-p50")
        for r in readings {
            print(String(format: "[drop-summary] %@ | %d | %.3f | %.3f | %.1f%% | %.1fus",
                         r.label, r.views, r.frameP50, r.frameP95, r.overBudget, r.hitP50))
        }
        XCTAssertEqual(readings.count, 4)
    }

    /// 行内 `.help`（权限 chip 的 tooltip）的同轮 A/B。
    ///
    /// 结构上它不生成任何平台视图（归因矩阵：加 `.help` 前后 NSView 都是 29），
    /// 但 uTable playbook §四 第 3 层记着 `NSToolTipManager` 每个滚动 tick 全量重算
    /// 窗内 tooltip 区 —— 那笔账在 NSView 计数里看不见，只能靠交替对照量。
    func testRowHelpAtTableGeometry() async throws {
        defer { rig.closeAllWindows() }
        let entries = FileBrowserProbeFixture.entries(FileBrowserProbeFixture.extreme)
        let withHelp: ProbeRowFeatures = .all
        let withoutHelp: ProbeRowFeatures = ProbeRowFeatures.all.subtracting(.help)
        var readings: [FileBrowserProbeReading] = []
        for (name, features) in [("no-help", withoutHelp), ("help", withHelp),
                                 ("help", withHelp), ("no-help", withoutHelp)] {
            let fixture = try rig.mount(
                ProbeAttributionList(entries: entries, features: features),
                size: NSSize(width: 1200, height: 780))
            readings.append(try await rig.measure(fixture, label: "help-\(name)",
                                                  rows: entries.count))
            await rig.closeWindowsAndSettle()
        }
        print("[help-summary] 轮次 | views | tracking | frame-p50 | frame-p95 | over8.33 | hit-p50")
        for r in readings {
            print(String(format: "[help-summary] %@ | %d | %d | %.3f | %.3f | %.1f%% | %.1fus",
                         r.label, r.views, r.trackingAreas, r.frameP50, r.frameP95,
                         r.overBudget, r.hitP50))
        }
        XCTAssertEqual(readings.count, 4)
    }
}
