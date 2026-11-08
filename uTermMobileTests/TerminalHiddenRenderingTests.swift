import ObjectiveC
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 看不见的终端不画、不跑动画、不按 60Hz 喂；回到可见时补画。字节照常解析，SSH 不受影响。
/// - App 退到后台：前台标签也算看不见（并行执行续命、退后台后的那几十秒里 SSH 还在收输出）；
/// - 后台标签里闪烁光标的重复动画停掉（SwiftTerm 补丁 #19）；
/// - iOS 终端视图不再被一个永不触发的 CADisplayLink 持有到进程结束（SwiftTerm 补丁 #18）。
@MainActor
final class TerminalHiddenRenderingTests: XCTestCase {
    private nonisolated(unsafe) static var draws = 0
    private var restoreDraw: (() -> Void)?
    private var window: UIWindow?

    override func setUp() async throws {
        let method = class_getInstanceMethod(SwiftTerm.TerminalView.self, #selector(UIView.draw(_:)))!
        typealias Draw = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let original = method_getImplementation(method)
        let call = unsafeBitCast(original, to: Draw.self)
        let counting: @convention(block) (AnyObject, CGRect) -> Void = { view, rect in
            Self.draws += 1
            call(view, #selector(UIView.draw(_:)), rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
        restoreDraw = { method_setImplementation(method, original) }
    }

    override func tearDown() async throws {
        restoreDraw?()
        window?.isHidden = true
        window = nil
    }

    private func hostedTerminal() async throws -> (MTerminalView, MTerminalContainerView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        window.windowLevel = .alert
        window.isHidden = false
        self.window = window
        let view = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        let container = MTerminalContainerView(terminalView: view, fontSize: 11)
        container.frame = window.bounds
        window.addSubview(container)
        container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        return (view, container)
    }

    private func drawsWhileFeeding(_ view: MTerminalView, ticks: Int) async throws -> Int {
        Self.draws = 0
        for tick in 0..<ticks {
            view.feed(text: "tick \(tick)\r\n")
            try await Task.sleep(for: .milliseconds(40))
        }
        return Self.draws
    }

    // MARK: App 在后台

    func testAppInBackgroundStopsDrawingAndRepaintsOnReturn() async throws {
        let (view, _) = try await hostedTerminal()
        let controller = MobileTerminalController()
        controller.attach(view)
        let visibleDraws = try await drawsWhileFeeding(view, ticks: 3)
        XCTAssertGreaterThan(visibleDraws, 0, "自证：在前台时照常画")

        controller.appVisibilityChanged(inBackground: true)
        XCTAssertTrue(view.suppressesDrawing)
        let hiddenDraws = try await drawsWhileFeeding(view, ticks: 5)
        XCTAssertEqual(hiddenDraws, 0)
        XCTAssertTrue(view.getTerminal().getLine(row: view.getTerminal().buffer.y - 1)?
            .translateToString(trimRight: true).hasPrefix("tick 4") == true, "后台期间字节照常解析")

        Self.draws = 0
        controller.appVisibilityChanged(inBackground: false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(view.suppressesDrawing)
        XCTAssertGreaterThan(Self.draws, 0, "回到前台补画")
    }

    /// 后台标签回到前台 App 时仍是后台标签：两种「看不见」各管各的，谁都不会误把对方放开。
    func testOffScreenAndAppBackgroundCombine() async throws {
        let (view, container) = try await hostedTerminal()
        container.isOnScreen = false
        view.isAppInBackground = true
        view.isAppInBackground = false
        XCTAssertTrue(view.suppressesDrawing, "仍是后台标签")

        view.isAppInBackground = true
        container.isOnScreen = true
        XCTAssertTrue(view.suppressesDrawing, "App 仍在后台")

        view.isAppInBackground = false
        XCTAssertFalse(view.suppressesDrawing)
    }

    /// 视图晚于进后台才挂上（外壳切换时重建）：挂上时就按后台处理。
    func testViewAttachedWhileInBackgroundStartsSuppressed() async throws {
        let controller = MobileTerminalController()
        controller.appVisibilityChanged(inBackground: true)
        let view = MTerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300),
                                 font: .monospacedSystemFont(ofSize: 11, weight: .regular))

        controller.attach(view)

        XCTAssertTrue(view.suppressesDrawing)
    }

    func testPacingFollowsTabAndAppVisibility() {
        XCTAssertEqual(MobileTerminalController.pacing(isForeground: true, isAppInBackground: false), .foreground)
        XCTAssertEqual(MobileTerminalController.pacing(isForeground: false, isAppInBackground: false), .background)
        XCTAssertEqual(MobileTerminalController.pacing(isForeground: true, isAppInBackground: true), .background)
        XCTAssertEqual(MobileTerminalController.pacing(isForeground: false, isAppInBackground: true), .background)
    }

    /// 外壳切换时新容器接走旧视图：以新容器为准，不沿用旧容器留下的「不在屏上」。
    func testNewContainerResetsOffScreenLeftByOldOne() async throws {
        let (view, container) = try await hostedTerminal()
        container.isOnScreen = false
        XCTAssertTrue(view.suppressesDrawing)

        _ = MTerminalContainerView(terminalView: view, fontSize: 11)

        XCTAssertFalse(view.suppressesDrawing)
    }

    /// 反过来：新容器接走之后，旧容器才被告知「不在屏上」（外壳切换时旧片最后一次刷新）。
    /// 旧容器已经不摆放这个视图了，不能替新容器决定它画不画——否则画面停在那一刻、再也不刷新。
    func testStaleContainerCannotStopTheAdoptedViewFromDrawing() async throws {
        let (view, stale) = try await hostedTerminal()
        let live = MTerminalContainerView(terminalView: view, fontSize: 11)
        XCTAssertTrue(view.superview === live)

        stale.isOnScreen = false

        XCTAssertFalse(view.suppressesDrawing, "旧容器改不了新容器里的视图")
        live.isOnScreen = false
        XCTAssertTrue(view.suppressesDrawing, "持有视图的容器照常能停画")
        stale.isOnScreen = true
        XCTAssertTrue(view.suppressesDrawing, "旧容器也放不开")
    }

    // MARK: 闪烁光标

    private func animatedSubviews(of view: UIView) -> [UIView] {
        view.subviews.filter { !($0.layer.animationKeys() ?? []).isEmpty }
    }

    func testBlinkingCaretAnimationPausesWhileHidden() async throws {
        let (view, container) = try await hostedTerminal()
        view.caretViewTracksFocus = false
        view.feed(text: "\u{1B}[1 q$ ")   // DECSCUSR 1：闪烁方块
        view.flushPendingDisplay()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(animatedSubviews(of: view).isEmpty, "自证：可见时光标在闪")

        container.isOnScreen = false
        XCTAssertTrue(view.suspendsCaretAnimation)
        XCTAssertTrue(animatedSubviews(of: view).isEmpty, "隐藏后不再跑重复动画")

        container.isOnScreen = true
        XCTAssertFalse(animatedSubviews(of: view).isEmpty, "露出来接着闪")
    }

    // MARK: 不再泄漏

    /// 上游的 CADisplayLink 把视图当 target 强持有，只有 `updateUiClosed()` 才放开（uTerm 从不调），
    /// 关掉的标签连同整份回滚缓冲一直留在内存里。
    func testTerminalViewIsReleasedWhenNoLongerReferenced() async throws {
        weak var released: SwiftTerm.TerminalView?
        do {
            let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300),
                                              font: .monospacedSystemFont(ofSize: 11, weight: .regular))
            view.feed(text: "hello\r\n")
            released = view
        }
        // 节流后的那次绘制排在主队列上，会短暂持有视图。
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(released)
    }
}
