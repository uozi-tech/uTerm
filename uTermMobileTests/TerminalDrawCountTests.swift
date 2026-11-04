import ObjectiveC
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 终端在什么时候画、画几次。挂在真实 scene 的窗口上：没有 scene 的窗口一次都不画，读数全是 0。
@MainActor
final class TerminalDrawCountTests: XCTestCase {
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

    /// 喂若干拍，每拍之间留够绘制时间，返回期间画了几次。
    private func drawsWhileFeeding(_ view: MTerminalView, ticks: Int) async throws -> Int {
        Self.draws = 0
        for tick in 0..<ticks {
            view.feed(text: String(repeating: "line \(tick)\r\n", count: 80))
            try await Task.sleep(for: .milliseconds(40))
        }
        return Self.draws
    }

    /// 滚动的输出每拍只画一次。上游会多画一次（滚动位置变化又触发一次）。
    func testScrollingOutputDrawsOncePerTick() async throws {
        let (view, _) = try await hostedTerminal()

        let draws = try await drawsWhileFeeding(view, ticks: 10)

        XCTAssertGreaterThan(draws, 0)
        XCTAssertLessThanOrEqual(draws, 12)
    }

    /// 还有积压时不画中间帧，喂完立刻画最后一帧。
    func testBacklogSkipsFramesAndPaintsWhenDrained() async throws {
        let (view, _) = try await hostedTerminal()
        let chunk = ArraySlice(Array(String(repeating: "backlog\r\n", count: 200).utf8))

        Self.draws = 0
        for _ in 0..<10 {
            view.feedPaced(chunk, backlogged: true)
            try await Task.sleep(for: .milliseconds(5))
        }
        let duringBacklog = Self.draws
        view.feedPaced(chunk, backlogged: false)
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertLessThanOrEqual(duringBacklog, 2)
        XCTAssertGreaterThan(Self.draws, duringBacklog, "喂完必须把最后一帧画出来")
        XCTAssertEqual(view.displayThrottleNanoseconds, SwiftTerm.TerminalView.defaultDisplayThrottleNanoseconds)
    }

    func testOffScreenTerminalDoesNotDraw() async throws {
        let (view, container) = try await hostedTerminal()
        container.isOnScreen = false

        let draws = try await drawsWhileFeeding(view, ticks: 5)

        XCTAssertEqual(draws, 0)
    }

    /// 隐藏期间的输出在露出来时补上。
    func testShowingTerminalPaintsWhatItMissed() async throws {
        let (view, container) = try await hostedTerminal()
        container.isOnScreen = false
        _ = try await drawsWhileFeeding(view, ticks: 2)

        Self.draws = 0
        container.isOnScreen = true
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertGreaterThan(Self.draws, 0)
    }

    /// 滚回历史时不能因为这条优化留下旧画面：手动滚动要照常重绘。
    func testUserScrollRedraws() async throws {
        let (view, _) = try await hostedTerminal()
        _ = try await drawsWhileFeeding(view, ticks: 3)
        try await Task.sleep(for: .milliseconds(60))

        Self.draws = 0
        view.contentOffset.y = max(0, view.contentOffset.y - 200)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertGreaterThan(Self.draws, 0)
    }
}
