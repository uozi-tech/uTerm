import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 侧栏拖动置顶的样子（用户录屏里的三处）：真窗口里挂会话列表，拍「正拖着、悬在列表上」与「没在拖」两个样子比。
///
/// - 「拖到这里置顶」那一条出现时不推动列表：下面各组标题的位置一点不动（以前它插进列表，整列往下跳一行、松手又弹回）；
/// - 跟着光标的那张卡片是不透明的（以前透明，字直接叠在别的行上，两行重影）。
///
/// 系统的拖动会话（`NSDraggingSession`）在进程里驱动不了，拖动中的状态用画廊的那个口子（`catalogPreset`）摆出来。
@MainActor
final class AgentHistoryPinDragLayoutTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "pin-drag-layout-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AccessibilityTreeForTests.enable(for: self)
    }

    override func tearDown() async throws {
        AgentHistoryPinDragModel.catalogPreset = nil
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func history() async -> AgentHistoryModel {
        let now = Date()
        var sessions: [Session] = []
        for (index, project) in ["shop", "infra", "blog"].enumerated() {
            for n in 0..<3 {
                sessions.append(Session(id: "\(project)-\(n)", projectID: ClaudeProjectPath.encode("/srv/\(project)"),
                                        resumeDirectory: "/srv/\(project)", title: "\(project) 的第 \(n) 个会话",
                                        modifiedAt: now.addingTimeInterval(-TimeInterval(index * 1000 + n * 60))))
            }
        }
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    /// 拍下列表：`dragging` 时摆成「正拖着一个会话、悬在列表上、落点是置顶」。被拖的那个不在列表里（不让它那一行变淡）。
    /// 无障碍树在 `LazyVStack` 里是懒的、读不到行，所以直接比像素。
    private func snapshot(dragging: Bool) async throws -> NSBitmapImageRep {
        let history = await history()
        AgentHistoryPinDragModel.catalogPreset = dragging
            ? (AgentHistoryPinKey(tool: .claude, sessionID: "elsewhere"), .pin(index: 0)) : nil
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                                      key: true, placement: .transparentOnScreen)
        let host = NSHostingView(rootView: AgentHistorySessionList(history: history)
            .frame(width: 300, height: 600)
            .background(UD.card))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView = host
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张图从 `top` 往下（视图坐标，向下为正）有多少行像素不一样。
    private func differingRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, from top: CGFloat) -> Int {
        let scale = CGFloat(a.pixelsHigh) / a.size.height
        var differing = 0
        for y in Int(top * scale)..<min(a.pixelsHigh, b.pixelsHigh) {
            var same = true
            var x = 0
            while x < min(a.pixelsWide, b.pixelsWide) {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                    same = false
                    break
                }
                x += 3
            }
            if !same { differing += 1 }
        }
        return differing
    }

    func testDropStripDoesNotPushTheList() async throws {
        let still = try await snapshot(dragging: false)
        let dragging = try await snapshot(dragging: true)
        XCTAssertGreaterThan(differingRows(still, dragging, from: 0), 0, "拖动中出那条落点")
        // 落点盖在搜索框下面那一截上（30pt 高）；再往下的列表一像素不动（以前整列往下推一行）。
        let below = AgentHistorySessionList.headerHeight + 2 + 6 + 34
        XCTAssertEqual(differingRows(still, dragging, from: below), 0, "落点出现时下面的列表不动")
    }

    /// 顶上跑着的会话（还没对上记录的新会话）那一行悬停时右端的 ×（结束会话）：盖在行上，不挤这一行的字、不推动下面的列表——
    /// 和没悬停时比，变了的像素只在右端那一小块里。悬停拍不到，用画廊的口子（`catalogHovered`）摆出来。
    func testRunRowEndButtonDoesNotShiftTheRow() async throws {
        let plain = try await runRowSnapshot(hovered: false)
        let hovered = try await runRowSnapshot(hovered: true)
        let changed = changedBox(plain, hovered)
        let box = try XCTUnwrap(changed, "悬停时出 ×")
        let scale = CGFloat(plain.pixelsWide) / plain.size.width
        XCTAssertGreaterThan(box.minX, (300 - 40) * scale, "变的只在右端：行里的字没挪")
        XCTAssertLessThan(box.height, 26 * scale, "只有那个 × 的高度：下面的行没被推动")
    }

    /// × 在这一行里上下居中（用户报的：以前贴着右上角）。行的范围取选中底色那一块（选中与没选中两张图的差），
    /// × 取悬停与没悬停的差，比两块的竖直中心。
    func testRunRowEndButtonIsVerticallyCentered() async throws {
        let plain = try await runRowSnapshot(hovered: false)
        let selected = try await runRowSnapshot(hovered: false, selected: true)
        let hovered = try await runRowSnapshot(hovered: true)
        let rowBox = try XCTUnwrap(changedBox(plain, selected), "选中时这一行有底色")
        let buttonBox = try XCTUnwrap(changedBox(plain, hovered), "悬停时出 ×")
        let scale = CGFloat(plain.pixelsWide) / plain.size.width
        XCTAssertGreaterThan(rowBox.height, 30 * scale, "行高两行字")
        XCTAssertEqual(buttonBox.midY, rowBox.midY, accuracy: 1.5 * scale, "× 上下居中")
    }

    /// 标题很长时 × 盖住两行字的行尾，上下不露半截字：悬停时变了的像素从行顶到行底是一整条。
    func testRunRowEndButtonCoversBothLineEnds() async throws {
        let title = String(repeating: "很长的标题", count: 20)
        let plain = try await runRowSnapshot(hovered: false, title: title)
        let selected = try await runRowSnapshot(hovered: false, selected: true, title: title)
        let hovered = try await runRowSnapshot(hovered: true, title: title)
        let rowBox = try XCTUnwrap(changedBox(plain, selected))
        let buttonBox = try XCTUnwrap(changedBox(plain, hovered), "悬停时出 ×")
        let scale = CGFloat(plain.pixelsWide) / plain.size.width
        XCTAssertGreaterThan(buttonBox.minX, (300 - 40) * scale, "变的只在右端")
        XCTAssertEqual(buttonBox.midY, rowBox.midY, accuracy: 1.5 * scale, "盖住的那一块也上下居中")
        XCTAssertLessThanOrEqual(buttonBox.height, rowBox.height, "不出这一行")
    }

    /// 跑着的会话有记录、在它那一组里自己那一行上（不在顶上单独一块）：悬停同样出 ×，只在右端、不挪字。
    func testListedRunRowEndButtonDoesNotShiftTheRow() async throws {
        let plain = try await runRowSnapshot(hovered: false, record: "infra-1")
        let hovered = try await runRowSnapshot(hovered: true, record: "infra-1")
        let box = try XCTUnwrap(changedBox(plain, hovered), "悬停时出 ×")
        let scale = CGFloat(plain.pixelsWide) / plain.size.width
        XCTAssertGreaterThan(box.minX, (300 - 40) * scale, "变的只在右端：行里的字没挪")
        XCTAssertLessThan(box.height, 60 * scale, "只有那一行：上下的行没被推动")
    }

    /// 拖起来的那一行（跑着的会话，鼠标还悬在它上面）不出 ×：这一行淡下去了，× 和它后面那条不透明的垫底不淡，
    /// 看着是一块方底（用户录屏里的）。悬停与没悬停两张图一样。
    func testLiftedRunRowHidesEndButton() async throws {
        let plain = try await runRowSnapshot(hovered: false, record: "infra-1", lifted: true)
        let hovered = try await runRowSnapshot(hovered: true, record: "infra-1", lifted: true)
        XCTAssertNil(changedBox(plain, hovered), "拖起来的行悬停时不出 ×")
    }

    /// `record`：跑着的会话对上的记录（会话 ID），在列表里它那一行上；nil = 还没对上记录的新会话，在最顶上。
    /// `lifted`：摆成那一行正被拖着、悬在列表上。
    private func runRowSnapshot(hovered: Bool, selected: Bool = false, title: String = AgentHistoryText.newSession,
                                record: String? = nil, lifted: Bool = false) async throws -> NSBitmapImageRep {
        let history = await history()
        AgentHistoryRunRowActions.catalogHovered = hovered
        defer { AgentHistoryRunRowActions.catalogHovered = false }
        let path = record.flatMap { id in history.files.first { $0.sessionID == id }?.path }
        if lifted, let file = history.files.first(where: { $0.path == path }) {
            AgentHistoryPinDragModel.catalogPreset = (AgentHistoryPinKey(file), .pin(index: 0))
        }
        defer { AgentHistoryPinDragModel.catalogPreset = nil }
        let row = AgentHistoryRunRow(id: UUID(), title: title, tool: .claude, directory: "/srv/shop",
                                     isSelected: selected, path: path, status: AgentHistoryRunStatus {
                                         .program(ProgramStatusRecord(state: .working, app: "claude-code"))
                                     })
        let actions = AgentHistoryRunActions(end: { _ in }, showRecord: { _ in }, showTerminal: { _ in }, moveToTab: nil)
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                                      key: true, placement: .transparentOnScreen)
        let host = NSHostingView(rootView: AgentHistorySessionList(
            history: history, running: AgentHistoryRunning(rows: { [row] }, onSelect: { _ in }, actions: actions))
            .frame(width: 300, height: 600)
            .background(UD.card))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView = host
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张图不一样的像素围成的框（像素坐标）。一样时为 nil。
    private func changedBox(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 跟手的卡片：拍成图，看中间偏右（字的右边、没有字的地方）是不是不透明的底。
    func testDragPreviewIsAnOpaqueCard() async throws {
        let history = await history()
        let file = try XCTUnwrap(history.files.first)
        let card = AgentHistorySessionRowPreview(history: history, file: file)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // 卡片四周留了 10 的阴影边，取卡片里靠右的一个点。
        let x = Int(Double(bitmap.pixelsWide) * 0.85), y = bitmap.pixelsHigh / 2
        let alpha = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
        XCTAssertEqual(alpha, 1, accuracy: 0.01, "卡片的底不透明：拖着走时不和别的行的字叠在一起")
    }
}
