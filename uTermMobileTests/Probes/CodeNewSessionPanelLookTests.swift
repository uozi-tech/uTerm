import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// Code 标签页「＋」的新会话面板长什么样、键盘挡不挡：同 App 一样经 `mBottomPanel` 弹出 `CodeNewSessionPanel`
/// （数据是假的主机：Claude Code + Codex 两种工具，三个项目），几种状态各拍一张（挂成 XCTest 附件；设了
/// `UTERM_STYLE_SHOTS_DIR` 再写成 PNG），并量：
/// - 卡片整个在屏内，「开始」按钮在屏内；
/// - 输入路径时输入框拿到焦点、系统键盘弹出来后，输入框和「选择」都在键盘上面。
///
/// 模拟器接着硬件键盘时不弹软键盘：键盘那一条量不到就跳过（不算过），到真机（Duo）上跑。
@MainActor
final class CodeNewSessionPanelLookTests: XCTestCase {
    /// 键盘通知在主队列上来，只在主线程读写。
    private final class KeyboardBox: @unchecked Sendable { var frame: CGRect = .zero }
    private let keyboard = KeyboardBox()
    private var keyboardFrame: CGRect { keyboard.frame }
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        try await super.setUp()
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                                          object: nil, queue: .main) { [keyboard] note in
            keyboard.frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        }
    }

    override func tearDown() async throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        MobileProbeWindow.closeAll()
        try await super.tearDown()
    }

    private struct Harness: View {
        let tab: ClaudeHistoryTab

        var body: some View {
            M.surface
                .ignoresSafeArea()
                .mBottomPanel(item: Binding(get: { tab.newSessionDraft }, set: { tab.newSessionDraft = $0 })) { draft in
                    if let history = tab.connection.history {
                        CodeNewSessionPanel(draft: draft, history: history, connection: tab.connection,
                                            hostName: tab.hostName) { _, _ in }
                    }
                }
        }
    }

    private func makeTab(directory: String? = MobileAgentHistoryFixture.shop,
                         tools: [AgentHistoryTool] = [.claude, .codex]) async throws -> ClaudeHistoryTab {
        let host = ServerProfile()
        host.name = "prod-web-01"
        let tab = MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source(tools: tools),
                                                directory: directory)
        tab.start()
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        _ = await MobileFakeTerminal.waitUntil { tab.connection.homeDirectory != nil }
        return tab
    }

    /// 弹出面板，等卡片滑入。返回承载面板的那个控制器（透明的 fullScreenCover）。
    private func present(_ tab: ClaudeHistoryTab) async throws -> (UIWindow, UIViewController) {
        let (window, _) = MobileProbeWindow.make(placement: .visibleOnScreen, isolateHost: true, rootView: Harness(tab: tab))
        try await Task.sleep(for: .milliseconds(300))
        tab.presentNewSession()
        let controller = try XCTUnwrap(window.rootViewController)
        var presented: UIViewController?
        for _ in 0..<50 where presented == nil {
            try await Task.sleep(for: .milliseconds(100))
            presented = controller.presentedViewController
        }
        let cover = try XCTUnwrap(presented, "面板没有弹出来")
        try await Task.sleep(for: .milliseconds(900))
        return (window, cover)
    }

    // MARK: 状态

    func testDefaultPanelFitsOnScreen() async throws {
        let tab = try await makeTab()
        let (window, _) = try await present(tab)
        let draft = try XCTUnwrap(tab.newSessionDraft)
        XCTAssertEqual(draft.choices.count, 4, "三个项目 + 主目录：\(draft.choices)")
        let image = try shot("default", window)
        let start = try XCTUnwrap(accentSpan(in: image, atX: startColumn(window)), "画面里找不到「开始」")
        print("PANEL-DEFAULT start=\(start) screen=\(window.screen.bounds) safe=\(window.safeAreaInsets)")
        assertOnScreen(start, window, "开始")
        tab.close()
    }

    func testPanelWithoutADirectoryExplainsTheGreyButton() async throws {
        let tab = try await makeTab(directory: nil, tools: [.claude])
        let (window, _) = try await present(tab)
        XCTAssertNil(tab.newSessionDraft?.directory)
        let history = try XCTUnwrap(tab.connection.history)
        XCTAssertEqual(history.newSessionTools(directory: nil), [], "没选目录：按钮灰着（截图看说明那一行）")
        try shot("no-directory", window)
        tab.close()
    }

    func testManyCandidatesScrollInsideTheList() async throws {
        let tab = try await makeTab()
        let (window, _) = try await present(tab)
        let draft = try XCTUnwrap(tab.newSessionDraft)
        draft.choices = (1...10).map { "/home/user/projects/service-\($0)-with-a-rather-long-directory-name" }
        try await Task.sleep(for: .milliseconds(400))
        let image = try shot("ten-candidates", window)
        let start = try XCTUnwrap(accentSpan(in: image, atX: startColumn(window)), "画面里找不到「开始」")
        assertOnScreen(start, window, "十个候选时「开始」")
        tab.close()
    }

    func testTypedPathSitsAboveTheKeyboard() async throws {
        let tab = try await makeTab()
        let (window, cover) = try await present(tab)
        let draft = try XCTUnwrap(tab.newSessionDraft)
        // 同点「输入路径…」那一行：先截一张键盘还没起来时的（按钮位置作对照），再看输入框自己拿到焦点。
        draft.typing = AgentHistoryPathEntry(text: draft.display(MobileAgentHistoryFixture.shop))
        var field: UITextField?
        for _ in 0..<20 where field == nil {
            try await Task.sleep(for: .milliseconds(10))
            field = textField(in: cover.view)
        }
        let before = try shot("typing", window)
        let input = try XCTUnwrap(field, "找不到输入框")
        let fieldView = input
        // 「取消」「选择」并排、和输入框一样宽：取输入框右沿往里一点那一列（「选择」右侧没有字；宽屏上卡片限宽居中）。
        let chooseX = fieldView.convert(fieldView.bounds, to: nil).maxX - 4
        let chooseBefore = try XCTUnwrap(accentSpan(in: before, atX: chooseX), "画面里找不到「选择」")

        // 不再手动 becomeFirstResponder：换成输入框后它自己拿焦点、弹键盘，不用再点一下。
        for _ in 0..<30 where keyboardFrame.height == 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(fieldView.isFirstResponder, "换成输入框后自己拿到焦点")
        try await Task.sleep(for: .milliseconds(900))
        let screen = window.screen.bounds
        let keyboard = keyboardFrame.intersection(screen)
        let focused = try shot("typing-focused", window)
        guard keyboard.height > 0 else {
            throw XCTSkip("没弹软键盘（模拟器接着硬件键盘）：键盘遮挡要在真机上量")
        }
        let choose = try XCTUnwrap(accentSpan(in: focused, atX: chooseX), "画面里找不到「选择」")
        let fieldFrame = fieldView.convert(fieldView.bounds, to: nil)
        print("PANEL-KEYBOARD screen=\(screen) keyboard=\(keyboard) field=\(fieldFrame) choose=\(choose) "
              + "chooseBefore=\(chooseBefore) gap=\(keyboard.minY - choose.upperBound) moved=\(chooseBefore.lowerBound - choose.lowerBound)")
        XCTAssertLessThanOrEqual(fieldFrame.maxY, keyboard.minY, "输入框被键盘挡住")
        XCTAssertLessThanOrEqual(choose.upperBound, keyboard.minY, "「选择」被键盘挡住")
        XCTAssertGreaterThanOrEqual(fieldFrame.minY, window.safeAreaInsets.top, "输入框被顶出屏幕上沿")
        XCTAssertLessThan(keyboard.minY - choose.upperBound, 80,
                          "「选择」离键盘太远（卡片被键盘的高度抬了两次）：差 \(keyboard.minY - choose.upperBound)pt")

        // 核对失败：说明换成红字，面板不关，还在键盘上面。
        draft.typing?.text = "~/nope"
        _ = await draft.typing?.submit(using: tab.connection)
        try await Task.sleep(for: .milliseconds(500))
        let error = try shot("typing-error", window)
        let after = try XCTUnwrap(accentSpan(in: error, atX: chooseX), "画面里找不到「选择」")
        XCTAssertLessThanOrEqual(after.upperBound, keyboardFrame.intersection(screen).minY,
                                 "报错多了一行字之后「选择」被键盘挡住")
        tab.close()
    }

    // MARK: 工具

    private func assertOnScreen(_ span: ClosedRange<CGFloat>, _ window: UIWindow, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let bounds = window.screen.bounds
        XCTAssertGreaterThanOrEqual(span.lowerBound, bounds.minY + window.safeAreaInsets.top,
                                    "\(what) 顶出屏幕上沿：\(span)", file: file, line: line)
        XCTAssertLessThanOrEqual(span.upperBound, bounds.maxY - window.safeAreaInsets.bottom + 1,
                                 "\(what) 压到 Home 条：\(span) / \(bounds)", file: file, line: line)
    }

    /// 截整个窗口（含弹出的面板）。系统键盘在另一个窗口里，按层级一起画上（画不出来时就是空的）。
    @discardableResult
    private func shot(_ name: String, _ window: UIWindow) throws -> UIImage {
        let windows = (window.windowScene?.windows ?? [window]).filter { !$0.isHidden }.sorted { $0.windowLevel < $1.windowLevel }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.screen.bounds, format: format).image { _ in
            for each in windows where each === window || each.windowLevel > window.windowLevel {
                _ = each.drawHierarchy(in: each.frame, afterScreenUpdates: true)
            }
        }
        let data = try XCTUnwrap(image.pngData())
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "code-new-session-\(name)-\(device)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(attachment.name ?? name).png"))
        }
        return image
    }

    /// 「开始」左半边没有图标和字的一列：卡片在安全区里居中（宽屏限宽），按钮和卡片内容一样宽、图标和字在中间。
    private func startColumn(_ window: UIWindow) -> CGFloat {
        let insets = window.safeAreaInsets
        return insets.left + (window.bounds.width - insets.left - insets.right) / 2 - 150
    }

    /// 主按钮（强调色实心）在 `x` 这一列上的上下沿（点）。SwiftUI 的按钮没有自己的 UIView，测试里也拿不到
    /// 无障碍树，只能看画出来的像素。
    private func accentSpan(in image: UIImage, atX x: CGFloat) -> ClosedRange<CGFloat>? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let column = min(width - 1, Int(x * image.scale))
        var rows: [Int] = []
        for row in 0..<height {
            let i = (row * width + column) * 4
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            if b > 200, b - r > 120, g > 100, g < 200 { rows.append(row) }
        }
        // 连续的段里取最后一段、至少 20pt 高（输入框聚焦时的强调色描边只有一两个像素，不算）。
        var runs: [ClosedRange<Int>] = []
        for row in rows {
            if let last = runs.last, last.upperBound == row - 1 { runs[runs.count - 1] = last.lowerBound...row }
            else { runs.append(row...row) }
        }
        guard let run = runs.last(where: { CGFloat($0.count) >= 20 * image.scale }) else { return nil }
        return CGFloat(run.lowerBound) / image.scale...CGFloat(run.upperBound + 1) / image.scale
    }

    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for child in view.subviews { if let found = textField(in: child) { return found } }
        return nil
    }
}
