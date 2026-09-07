import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 「单击即选中、双击即打开」三处列表的**行为闸门**。
///
/// 改前三处行都写成 `.onTapGesture(count: 2) { open }` 链 `.onTapGesture { select }`，
/// SwiftUI 把两者当互斥手势消歧 —— 单击必须先等满系统双击间隔才落地（实测点一行
/// 390~510ms 才高亮，用户报的就是这个）。改后三处统一走
/// `ClickSelectActivate.swift` 的容器级透明层，按 `NSEvent.clickCount` 分派。
///
/// **这次合成事件进得去**：被测的是一个真 `NSView`（`RowClickLayerView`）挂在
/// `NSApplication` 的本地事件监视器上，`NSApp.sendEvent(_:)` 会把事件送给监视器。
/// `WelcomeServerListContractTests` 顶部说的「合成事件驱动不了」讲的是 SwiftUI 的
/// `onTapGesture` —— 那条路确实进不去，这也正是本次改动绕开它的原因之一。
/// 注意必须走 `NSApp.sendEvent`，**不能**走 `window.sendEvent`：本地监视器是
/// `NSApplication` 派发的，绕过 `NSApp` 就收不到（`FileBrowserProbeRig.click`
/// 走的是后者，故那把尺子量不到本层）。
@MainActor
final class ClickSelectActivateTests: XCTestCase {

    private var windows: [NSWindow] = []

    /// 见 `ProbeSmokeTests`：`uTermTests` 默认隔离是 `nonisolated`，
    /// 不能覆写 `tearDown()` 拆窗，每条用例开头 `defer { closeAllWindows() }`。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 落点换算（纯算术）

    func testUniformRowHitMapsYToRowIndex() {
        // 10 行 × 20pt。
        XCTAssertEqual(UniformRowHit.index(atY: 0, containerHeight: 200, rowCount: 10), 0)
        XCTAssertEqual(UniformRowHit.index(atY: 19.9, containerHeight: 200, rowCount: 10), 0)
        XCTAssertEqual(UniformRowHit.index(atY: 20, containerHeight: 200, rowCount: 10), 1)
        XCTAssertEqual(UniformRowHit.index(atY: 199.9, containerHeight: 200, rowCount: 10), 9)
        // 容器外 / 退化输入一律 nil，绝不越界。
        XCTAssertNil(UniformRowHit.index(atY: -1, containerHeight: 200, rowCount: 10))
        XCTAssertNil(UniformRowHit.index(atY: 200, containerHeight: 200, rowCount: 10))
        XCTAssertNil(UniformRowHit.index(atY: 10, containerHeight: 200, rowCount: 0))
        XCTAssertNil(UniformRowHit.index(atY: 10, containerHeight: 0, rowCount: 10))
    }

    // MARK: - 夹具

    /// 建窗并挂载。判据是行为 / 像素，不是时间 —— 走屏外档。
    private func mount(_ view: some View, size: NSSize) throws -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width,
                                                              height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .offScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return host
    }

    /// 整棵树里那一个（且只该有一个）点击层。
    private func clickLayer(in root: NSView) throws -> RowClickLayerView {
        var found: [RowClickLayerView] = []
        func walk(_ view: NSView) {
            if let layer = view as? RowClickLayerView { found.append(layer) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        XCTAssertEqual(found.count, 1, "一份列表只该装一个点击层（逐行装会把 NSView 数拉爆）")
        return try XCTUnwrap(found.first)
    }

    /// 往窗口打一次真 `leftMouseDown`（不发 up —— 选中是按下即落地的，
    /// 发 up 反而会让 AppKit 顺手补出一次点击语义，混淆归因）。
    ///
    /// - Returns: 从 `sendEvent` 返回为止的墙钟毫秒。
    @discardableResult
    private func mouseDown(_ host: NSView, layerY: CGFloat, clickCount: Int) throws -> Double {
        let layer = try clickLayer(in: host)
        let window = try XCTUnwrap(host.window)
        let inWindow = layer.convert(NSPoint(x: 60, y: layerY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1))
        let start = CFAbsoluteTimeGetCurrent()
        NSApp.sendEvent(event)
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - ① 欢迎页服务器列表

    private final class SelectionRecorder {
        var selected: UUID?
        var opened: [String] = []
    }

    private struct ServerListHarness: View {
        let profiles: [ServerProfile]
        let recorder: SelectionRecorder
        @State private var selectedID: UUID?
        @State private var dragging: UUID?

        var body: some View {
            ServerList(profiles: profiles,
                       query: "",
                       selectedID: Binding(get: { selectedID },
                                           set: { selectedID = $0; recorder.selected = $0 }),
                       draggingProfileID: $dragging,
                       onOpen: { _ in },
                       onContextAction: { action, profile in
                           if action == .connect { recorder.opened.append(profile.name) }
                       },
                       existingGroups: [],
                       groupColorHexes: [:])
        }
    }

    /// 按下即选中：`sendEvent` 一返回，`selectedID` **同步**已经是那一行 ——
    /// 没有任何等待（改前要等满系统双击间隔）。
    func testWelcomeRowSelectsSynchronouslyOnMouseDown() throws {
        defer { closeAllWindows() }
        let profiles = WelcomeServerListCostTests.makeProfiles(count: 40, groups: 2)
        let recorder = SelectionRecorder()
        let host = try mount(ServerListHarness(profiles: profiles, recorder: recorder),
                             size: NSSize(width: 900, height: 620))

        let layer = try clickLayer(in: host)
        let rowHeight = layer.bounds.height / CGFloat(profiles.count)
        XCTAssertGreaterThan(rowHeight, 20, "行高反推必须是个像样的数：\(rowHeight)")

        // `ServerList` 首次出现会自动选中第一行，先确认起点不是目标行。
        XCTAssertNotEqual(recorder.selected, profiles[3].id)

        let ms = try mouseDown(host, layerY: rowHeight * 3.5, clickCount: 1)
        print(String(format: "[click-latency] welcome-server-list mousedown->selected %.3fms "
                     + "(row-height=%.1f)", ms, rowHeight))

        XCTAssertEqual(recorder.selected, profiles[3].id,
                       "第一下按下就必须选中第 4 行 —— 一次 runloop 都不用等")
        XCTAssertEqual(recorder.opened, [], "单击不能连接")
    }

    /// 第二下（`clickCount == 2`）才连接，且只连一次。
    func testWelcomeRowDoubleClickConnectsExactlyOnce() throws {
        defer { closeAllWindows() }
        let profiles = WelcomeServerListCostTests.makeProfiles(count: 40, groups: 2)
        let recorder = SelectionRecorder()
        let host = try mount(ServerListHarness(profiles: profiles, recorder: recorder),
                             size: NSSize(width: 900, height: 620))
        let layer = try clickLayer(in: host)
        let rowHeight = layer.bounds.height / CGFloat(profiles.count)

        try mouseDown(host, layerY: rowHeight * 5.5, clickCount: 1)
        try mouseDown(host, layerY: rowHeight * 5.5, clickCount: 2)
        XCTAssertEqual(recorder.selected, profiles[5].id)
        XCTAssertEqual(recorder.opened, [profiles[5].name], "双击必须恰好连接一次")

        // 三连击不再重复触发（对齐 Finder）。
        try mouseDown(host, layerY: rowHeight * 5.5, clickCount: 3)
        XCTAssertEqual(recorder.opened, [profiles[5].name], "三连击不能再连一次")
    }

    // MARK: - ② SFTP 独立窗口文件表

    private struct SFTPTableHarness: View {
        let entries: [RemoteEntry]
        let showParent: Bool
        let recorder: SFTPRecorder
        @State private var selectedID: RemoteEntry.ID?

        var body: some View {
            SFTPFileTable(entries: entries,
                          showParent: showParent,
                          selectedID: Binding(get: { selectedID },
                                              set: { selectedID = $0; recorder.selected = $0 }),
                          sortKey: .name,
                          sortAscending: true,
                          onToggleSort: { _ in },
                          onActivate: { recorder.activated.append($0.name) },
                          onUp: { recorder.wentUp += 1 },
                          onDragProvider: { _ in NSItemProvider() },
                          onDropRemoteItems: { _, _ in false },
                          onDropRemoteItemsToParent: { _ in false },
                          query: "",
                          rowActions: SFTPRowActions(currentPath: "/tmp",
                                                     fileActionLabel: "打开",
                                                     fileActionIcon: "eye",
                                                     onActivate: { _ in },
                                                     onDownload: { _ in },
                                                     onRename: { _ in },
                                                     onPermissions: { _ in },
                                                     onDelete: { _ in }),
                          onNewFolder: {},
                          onNewFile: {})
        }
    }

    private final class SFTPRecorder {
        var selected: RemoteEntry.ID?
        var activated: [String] = []
        var wentUp = 0
    }

    func testSFTPFileTableSelectsSynchronouslyAndActivatesOnSecondClick() throws {
        defer { closeAllWindows() }
        let entries = FileBrowserProbeFixture.entries(60)
        let recorder = SFTPRecorder()
        let host = try mount(SFTPTableHarness(entries: entries, showParent: true,
                                              recorder: recorder),
                             size: NSSize(width: 1200, height: 780))

        // `..` 行 46 + 条目行 52：第 3 个条目的中线。
        let y = SFTPFileTable.parentRowHeight + SFTPFileTable.rowHeight * 2.5
        let ms = try mouseDown(host, layerY: y, clickCount: 1)
        print(String(format: "[click-latency] sftp-file-table mousedown->selected %.3fms", ms))
        XCTAssertEqual(recorder.selected, entries[2].id, "第一下按下就选中第 3 个条目")
        XCTAssertEqual(recorder.activated, [], "单击不能打开")

        try mouseDown(host, layerY: y, clickCount: 2)
        XCTAssertEqual(recorder.activated, [entries[2].name], "双击必须恰好打开一次")

        // `..` 行在这份表里一直是单击就上一级；第二下不能再打开任何东西。
        try mouseDown(host, layerY: SFTPFileTable.parentRowHeight / 2, clickCount: 1)
        try mouseDown(host, layerY: SFTPFileTable.parentRowHeight / 2, clickCount: 2)
        XCTAssertEqual(recorder.wentUp, 1, "`..` 行第一下就返回上级，第二下不再重复")
        XCTAssertEqual(recorder.activated, [entries[2].name], "双击 `..` 不能打开条目")
    }

    /// 「第二下只认第一下刚选中的那一行」。
    ///
    /// 真实场景：在 `/a/b` 双击 `..` 回到根目录 —— 第一下就换了目录，`showParent`
    /// 变 false，第二下落在的已经是新列表，同一个 y 于是落到 entry 0 上。没有这条
    /// 守卫，「双击回上级」会顺手把新目录里的第一个条目打开。
    func testSecondClickDoesNotActivateARowTheFirstClickNeverSelected() throws {
        defer { closeAllWindows() }
        let entries = FileBrowserProbeFixture.entries(60)
        let recorder = SFTPRecorder()
        // 复刻「已经回到根目录」的那一帧：没有 `..` 行、也没有任何选中。
        let host = try mount(SFTPTableHarness(entries: entries, showParent: false,
                                              recorder: recorder),
                             size: NSSize(width: 1200, height: 780))

        try mouseDown(host, layerY: SFTPFileTable.rowHeight * 0.5, clickCount: 2)
        XCTAssertEqual(recorder.activated, [], "没被第一下选中的行，第二下不能打开")
        XCTAssertNil(recorder.selected, "第二下也不该顺手改选中")
    }

    // MARK: - ③ 工作区侧栏文件树

    /// `FileBrowserContent` 的 `selectedID` 是私有 `@State`，读不到 —— 改用它对外
    /// 唯一的可观测副作用：单击文件发 `.openRemoteFile`（`preview: true`），
    /// 双击发同一通知但 `preview: false`。两者都在按下的那一刻同步发出。
    func testFileBrowserSidebarPreviewsSynchronouslyAndOpensOnSecondClick() async throws {
        defer { closeAllWindows() }
        // 只要 20 条：`sortedEntries` 把目录排在前面（造数里每 7 条一个目录），
        // 条目一多，第一个文件行就会被推到首屏之外。
        let model = await FileBrowserProbeFixture.model(20)
        let host = try mount(FileBrowserContent(model: model),
                             size: NSSize(width: 360, height: 620))

        var posted: [(path: String, preview: Bool)] = []
        let token = NotificationCenter.default.addObserver(
            forName: .openRemoteFile, object: nil, queue: nil) { note in
                let path = note.userInfo?["path"] as? String ?? ""
                let preview = note.userInfo?["preview"] as? Bool ?? false
                MainActor.assumeIsolated { posted.append((path, preview)) }
            }
        defer { NotificationCenter.default.removeObserver(token) }

        // 起点是 `/home/deploy/project`（非根），故第一行是 `..`，之后才是条目。
        // `sortedEntries` 把目录排在前面，而目录单击只选中、不发通知 ——
        // 取第一个文件行来点（它才有可观测的副作用）。
        let entries = model.sortedEntries
        let fileIndex = try XCTUnwrap(entries.firstIndex { !$0.isDirectory },
                                      "夹具里必须有文件行")
        XCTAssertLessThan(FileBrowserContent.rowHeight * (CGFloat(fileIndex) + 2), 620,
                          "被点的行必须在首屏内，否则 visibleRect 会把它挡掉")
        let y = FileBrowserContent.rowHeight * (CGFloat(fileIndex) + 1.5)
        let ms = try mouseDown(host, layerY: y, clickCount: 1)
        print(String(format: "[click-latency] file-browser-sidebar mousedown->preview %.3fms", ms))
        XCTAssertEqual(posted.count, 1, "第一下按下就必须同步发出预览通知（零等待）")
        XCTAssertEqual(posted.first?.preview, true, "单击是「预览 tab」")
        XCTAssertTrue(posted.first?.path.hasSuffix(entries[fileIndex].name) ?? false,
                      "预览的必须是被点的那一行：\(posted.first?.path ?? "-") "
                      + "vs \(entries[fileIndex].name)")

        try mouseDown(host, layerY: y, clickCount: 2)
        XCTAssertEqual(posted.count, 2, "第二下必须再发一次（永久打开）")
        XCTAssertEqual(posted.last?.preview, false, "双击是永久打开")

        // 「第二下只认第一下刚选中的那一行」：换一行直接发 clickCount == 2，
        // 不能打开（进目录会整列表换掉，第二下可能落在别的行上）。
        let otherIndex = try XCTUnwrap((fileIndex + 1..<entries.count)
            .first { !entries[$0].isDirectory }, "夹具里必须还有第二个文件行")
        try mouseDown(host,
                      layerY: FileBrowserContent.rowHeight * (CGFloat(otherIndex) + 1.5),
                      clickCount: 2)
        XCTAssertEqual(posted.count, 2, "没被第一下选中的行，第二下不能打开")
    }

    /// 极端档 + 滚到底：点击层的 `bounds` 高达 60 万点（20000 × 30），
    /// 落点换算必须仍然准 —— 这条钉住「巨大 NSView 不会把坐标算歪」。
    func testFileBrowserSidebarHitsCorrectRowWhenScrolledAtExtremeScale() async throws {
        defer { closeAllWindows() }
        let model = await FileBrowserProbeFixture.model(FileBrowserProbeFixture.extreme)
        let host = try mount(FileBrowserContent(model: model),
                             size: NSSize(width: 360, height: 620))
        let scroll = try XCTUnwrap(host.firstScrollView())
        let document = try XCTUnwrap(scroll.documentView)
        let maxOffset = max(0, document.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset * 0.5))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let layer = try clickLayer(in: host)
        print("[click-geometry] layer-bounds=\(layer.bounds.height) doc=\(document.frame.height)")

        var posted: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: .openRemoteFile, object: nil, queue: nil) { note in
                let path = note.userInfo?["path"] as? String ?? ""
                MainActor.assumeIsolated { posted.append(path) }
            }
        defer { NotificationCenter.default.removeObserver(token) }

        // 可见区正中那一行。层坐标 y = visibleRect.midY。
        let y = layer.visibleRect.midY
        let index = Int(((y - FileBrowserContent.rowHeight) / FileBrowserContent.rowHeight)
            .rounded(.down))
        let entries = model.sortedEntries
        // 目录行单击只选中、不发通知；从命中行往下找最近的文件行，好有可观测输出。
        let fileIndex = try XCTUnwrap((index..<entries.count).first { !entries[$0].isDirectory },
                                      "命中行往下必须还有文件行")
        let fileY = FileBrowserContent.rowHeight * (CGFloat(fileIndex) + 1.5)

        try mouseDown(host, layerY: fileY, clickCount: 1)
        XCTAssertEqual(posted.count, 1, "滚到中段后按下仍必须同步命中一行")
        XCTAssertTrue(posted.first?.hasSuffix(entries[fileIndex].name) ?? false,
                      "命中的必须是算出来的那一行：\(posted.first ?? "-") vs \(entries[fileIndex].name)")
    }

    // MARK: - ④ 结构闸门：点击层不按行收费

    /// 逐行挂 `.onPointerDown` / `.onDrop` 那种写法会给每行留一个平台视图；
    /// 容器级点击层**整份列表只有一个**，NSView 数不随行数涨。
    func testClickLayerCountDoesNotGrowWithRows() async throws {
        defer { closeAllWindows() }
        for rows in [50, 5000] {
            let model = await FileBrowserProbeFixture.model(rows)
            let host = try mount(FileBrowserContent(model: model),
                                 size: NSSize(width: 360, height: 620))
            var layers = 0
            func walk(_ view: NSView) {
                if view is RowClickLayerView { layers += 1 }
                for sub in view.subviews { walk(sub) }
            }
            walk(host)
            XCTAssertEqual(layers, 1, "\(rows) 行时点击层必须仍然只有一个（实得 \(layers)）")
            closeAllWindows()
        }
    }
}
