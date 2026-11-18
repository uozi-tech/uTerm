import XCTest
@testable import uTermMobile

/// 画布换第一响应者（弹 / 收软键盘）不能发生在调用的当场：调用方是 SwiftUI 的 `updateUIView`，在更新途中换第一响应者
/// 会让 AttributeGraph 判成环、主线程空转（2026-11-18 Duo：点键盘按钮后触摸全无反应）。
@MainActor
final class RemoteDesktopCanvasResponderTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func mountedCanvas() throws -> RemoteDesktopCanvasView {
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let session = RemoteDesktopSession(client: client, maxWidth: 1280, maxHeight: 800)
        let canvas = RemoteDesktopCanvasView(session: session, keys: RemoteDesktopKeyState())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.isHidden = false
        window.makeKey()
        self.window = window
        canvas.frame = window.bounds
        window.addSubview(canvas)
        return canvas
    }

    private func turnRunLoop() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func keyInput(of canvas: RemoteDesktopCanvasView) throws -> RemoteKeyInputView {
        try XCTUnwrap(canvas.subviews.compactMap { $0 as? RemoteKeyInputView }.first)
    }

    func testMountingDoesNotTakeFirstResponderOnTheSpot() async throws {
        let canvas = try mountedCanvas()
        XCTAssertFalse(canvas.isFirstResponder, "挂上窗口的当场不换第一响应者")
        await turnRunLoop()
        XCTAssertTrue(canvas.isFirstResponder, "这一轮跑完画布才当第一响应者（外接键盘要用）")
        canvas.teardown()
    }

    func testShowingAndHidingKeyboardChangesResponderOnlyAfterTheCurrentTurn() async throws {
        let canvas = try mountedCanvas()
        let input = try keyInput(of: canvas)
        await turnRunLoop()

        canvas.setKeyboardVisible(true)
        XCTAssertFalse(input.isFirstResponder, "调用的当场不换")
        await turnRunLoop()
        XCTAssertTrue(input.isFirstResponder)

        canvas.setKeyboardVisible(false)
        XCTAssertTrue(input.isFirstResponder, "收起也一样")
        await turnRunLoop()
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertTrue(canvas.isFirstResponder, "收起软键盘后画布接着当第一响应者")
        canvas.teardown()
    }

    func testLastRequestWinsWhenToggledWithinOneTurn() async throws {
        let canvas = try mountedCanvas()
        let input = try keyInput(of: canvas)
        await turnRunLoop()
        canvas.setKeyboardVisible(true)
        canvas.setKeyboardVisible(false)
        await turnRunLoop()
        XCTAssertFalse(input.isFirstResponder, "同一轮里先要后不要：最后不弹")
        canvas.teardown()
    }

    // MARK: - 系统键盘自带的「粘贴」

    func testSystemPasteIsForwardedInsteadOfIgnored() {
        let input = RemoteKeyInputView()
        let paste = #selector(UIResponderStandardEditActions.paste(_:))
        XCTAssertFalse(input.canPerformAction(paste, withSender: nil), "没人接的时候不声称能粘贴")
        var pasted = 0
        input.onPaste = { pasted += 1 }
        XCTAssertTrue(input.canPerformAction(paste, withSender: nil), "系统据此决定给不给「粘贴」")
        input.paste(nil)
        XCTAssertEqual(pasted, 1, "点了系统键盘上的粘贴：交给外面按「粘贴到 Mac」处理")
    }

    func testCanvasPassesSystemPasteOn() async throws {
        let canvas = try mountedCanvas()
        var pasted = 0
        canvas.onSystemPaste = { pasted += 1 }
        try keyInput(of: canvas).paste(nil)
        XCTAssertEqual(pasted, 1)
        canvas.teardown()
    }

    // MARK: - 触摸屏模式的落点

    func testTouchPointMapsIntoThePicture() {
        let picture = CGRect(x: 20, y: 40, width: 400, height: 200)
        XCTAssertEqual(RemoteDesktopCanvasView.pointer(at: CGPoint(x: 220, y: 140), picture: picture),
                       CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(RemoteDesktopCanvasView.pointer(at: CGPoint(x: 20, y: 40), picture: picture), .zero)
        XCTAssertEqual(RemoteDesktopCanvasView.pointer(at: CGPoint(x: 5, y: 500), picture: picture),
                       CGPoint(x: 0, y: 1), "落在画面外的收到画面边上")
    }
}
