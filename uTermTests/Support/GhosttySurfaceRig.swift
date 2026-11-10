import AppKit
import GhosttyTerminal
import XCTest
@testable import uTerm

/// 带真 surface 的终端：一条会话（假后端）+ 窗格容器，挂在一个透明、在屏上的窗口里（引擎要有显示节拍才解析、出帧），
/// 终端视图是第一响应者。给要读「画面那一侧」的用例用：选区、按键编码、画出来的像素。
///
/// 只读影子终端就够的用例不要用它（慢，而且测试窗口被完全遮挡时显示节拍会停）。
@MainActor
final class GhosttySurfaceRig {
    let session = TerminalSession()
    let backend = MockBackend()
    let container: GhosttyContainerView
    let window: NSWindow

    var view: GhosttySurfaceView { session.ghostty.view }
    var bridge: GhosttyTerminalBridge { session.ghostty }

    /// 建好并等到 surface 在吃实时字节、网格停稳、后端已连上。
    init(size: NSSize = NSSize(width: 800, height: 500), file: StaticString = #filePath, line: UInt = #line) async {
        session.attentionSink = { _ in }
        let rect = NSRect(origin: .zero, size: size)
        container = GhosttyContainerView(surface: session.ghostty.view)
        container.isActive = true
        window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen)
        container.frame = window.contentView?.bounds ?? rect
        container.layoutSubtreeIfNeeded()
        // 真的主菜单会把 ⌘Q、⌘W 执行掉：测试里一律不问它。
        view.performMenuKeyEquivalent = { _ in false }
        let live = await waitUntil(10) { self.bridge.isLive && self.bridge.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪", file: file, line: line)
        var last = bridge.grid.map { "\($0)" } ?? ""
        var stableSince = Date()
        while Date().timeIntervalSince(stableSince) < 0.3 {
            try? await Task.sleep(for: .milliseconds(20))
            let now = bridge.grid.map { "\($0)" } ?? ""
            if now != last { last = now; stableSince = Date() }
        }
        await session.connect(using: backend)
        window.makeFirstResponder(view)
    }

    func close() {
        session.dispose()
        window.orderOut(nil)
    }

    func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: 输出

    private var syncReplies = 0
    private static let syncQuery = "\u{1b}[5n"
    private static let syncReply = Array("\u{1b}[0n".utf8)

    /// 当作后端输出喂一段文字，并等 surface 也解析到这里。影子终端是同步解析的，surface 是异步的：在后面跟一个
    /// 状态查询（DSR 5），surface 解析到它才会应答（`ESC [ 0 n`）——应答到了，前面的字节一定都解析过了。
    /// 这个应答不算进 `sent` / `press` 的结果。
    func feed(_ text: String, file: StaticString = #filePath, line: UInt = #line) async {
        let expected = syncReplies + 1
        bridge.onWriteForTesting = { [weak self] data in
            if Array(data) == Self.syncReply { self?.syncReplies += 1 }
        }
        session.feedOutput(text: text + Self.syncQuery)
        let parsed = await waitUntil(5) { self.syncReplies >= expected }
        XCTAssertTrue(parsed, "surface 没解析到这段输出（测试窗口被遮挡时引擎不出节拍）", file: file, line: line)
    }

    /// surface 自己读到的视口文字（和影子终端的 `viewportText()` 同一种读法）。
    var surfaceText: String { bridge.viewportText() ?? "" }

    // MARK: 输入

    /// 后端收到的全部字节（键盘输入与终端应答）。输入经有序通道异步到达：等够 `count` 字节或超时。
    func sent(expecting count: Int, timeout: TimeInterval = 2) async -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let bytes = await writtenBytes()
            if bytes.count >= count || Date() > deadline { return bytes }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 后端收到的字节，去掉 `feed` 用来对齐的那个查询的应答。
    private func writtenBytes() async -> [UInt8] {
        await backend.writtenData.filter { Array($0) != Self.syncReply }.flatMap { [UInt8]($0) }
    }

    /// 按一下键（down + up），直接交给终端视图。返回这次按键之后后端新收到的字节。
    func press(characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = []) async -> [UInt8] {
        let before = await writtenBytes().count
        view.keyDown(with: RealEvents.key(.keyDown, window: window, characters: characters, keyCode: keyCode, modifiers: modifiers))
        view.keyUp(with: RealEvents.key(.keyUp, window: window, characters: characters, keyCode: keyCode, modifiers: modifiers))
        let all = await sent(expecting: before + 1, timeout: 1)
        return Array(all.dropFirst(before))
    }

    // MARK: 几何、鼠标、像素

    /// 一格的大小（点）。
    var cellPoints: CGSize? {
        guard let cell = view.uTermCellPixels else { return nil }
        let scale = window.backingScaleFactor
        return CGSize(width: cell.width / scale, height: cell.height / scale)
    }

    /// 视口里第 `row` 行第 `col` 列那一格的中心，窗口坐标。
    func windowPoint(col: Int, row: Int) -> NSPoint? {
        guard let cell = cellPoints else { return nil }
        let inView = NSPoint(x: (CGFloat(col) + 0.5) * cell.width,
                             y: view.bounds.height - (CGFloat(row) + 0.5) * cell.height)
        return view.convert(inView, to: nil)
    }

    /// 在某一格上连点 `count` 下（Ghostty 自己按时间和位置数连击：2 = 选词，3 = 选整行）。
    func click(col: Int, row: Int, count: Int = 1) {
        guard let point = windowPoint(col: col, row: row) else { return XCTFail("量不到格子尺寸") }
        for index in 1...count {
            view.mouseDown(with: RealEvents.mouse(.leftMouseDown, window: window, at: point, clickCount: index))
            view.mouseUp(with: RealEvents.mouse(.leftMouseUp, window: window, at: point, clickCount: index))
        }
    }

    /// 从一格拖到另一格（选中这一段）。
    func drag(fromCol: Int, row: Int, toCol: Int, toRow: Int? = nil) {
        guard let start = windowPoint(col: fromCol, row: row), let end = windowPoint(col: toCol, row: toRow ?? row) else {
            return XCTFail("量不到格子尺寸")
        }
        view.mouseDown(with: RealEvents.mouse(.leftMouseDown, window: window, at: start))
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        view.mouseDragged(with: RealEvents.mouse(.leftMouseDragged, window: window, at: mid))
        view.mouseDragged(with: RealEvents.mouse(.leftMouseDragged, window: window, at: end))
        view.mouseUp(with: RealEvents.mouse(.leftMouseUp, window: window, at: end))
    }

    /// 选区落在视口里的位置；没有选区（或全不在视口里）是 nil。
    var selection: TerminalSelectionRegion? { view.selectionRegion }

    /// 选区盖住的文字，按视口的行列从影子终端读（两边吃的是同一份字节）。只支持单行选区。
    var selectedText: String? {
        guard let region = selection, region.topLeft.row == region.bottomRight.row else { return nil }
        let lines = session.shadow.viewportText().components(separatedBy: "\n")
        guard region.topLeft.row < lines.count else { return nil }
        let line = Array(lines[region.topLeft.row])
        let from = min(region.topLeft.column, line.count), to = min(region.bottomRight.column + 1, line.count)
        return String(line[from..<max(from, to)])
    }

    /// 画出来的那一帧里，第 `row` 行第 `col` 列那一格中心的颜色（sRGB 0–255）。还没出过帧是 nil。
    func pixel(col: Int, row: Int) -> (r: Int, g: Int, b: Int)? {
        guard let cell = view.uTermCellPixels, let surface = GhosttyFrameWatch.currentSurface(of: view) else { return nil }
        let x = Int((CGFloat(col) + 0.5) * cell.width), y = Int((CGFloat(row) + 0.5) * cell.height)
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        guard x >= 0, y >= 0, x < w, y < h else { return nil }
        let bpr = IOSurfaceGetBytesPerRow(surface), bpe = max(4, IOSurfaceGetBytesPerElement(surface))
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        // Ghostty 的 IOSurface 是 BGRA。
        let o = y * bpr + x * bpe
        return (Int(base[o + 2]), Int(base[o + 1]), Int(base[o]))
    }

    /// 让 surface 继续出帧。窗口的遮挡状态变化（上一个用例的窗口刚收走、这一个刚摆上来）偶尔会让视图把自己当成
    /// 看不见的而停掉显示节拍；读像素之前把它叫回来。
    func keepRendering() {
        window.orderFrontRegardless()
        view.setSurfaceVisible(true)
    }

    /// 等画面上那一格的颜色满足条件（渲染线程出帧要时间），返回最后读到的颜色。
    func waitForPixel(col: Int, row: Int, timeout: TimeInterval = 5,
                      where matches: ((r: Int, g: Int, b: Int)) -> Bool) async -> (r: Int, g: Int, b: Int)? {
        keepRendering()
        var last: (r: Int, g: Int, b: Int)?
        _ = await waitUntil(timeout) {
            last = self.pixel(col: col, row: row)
            return last.map(matches) ?? false
        }
        return last
    }
}
