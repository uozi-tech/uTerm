import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 快捷命令执行日志的**行为闸门**：展开头从 `Button` 换成
/// `onTapGesture + 手工 AX` 之后，展开 / 收起、无障碍语义、内容一条都不能少。
///
/// 走 AX 默认动作（`accessibilityPerformPress`）而不是合成 `NSEvent` ——
/// 理由与 `WelcomeServerListContractTests` 相同（SwiftUI 手势只认真实光标）。
@MainActor
final class QuickCommandRunLogContractTests: XCTestCase {
    override func setUp() async throws {
        AccessibilityTreeForTests.enable(for: self)
    }


    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func mount(_ runs: [QuickCommandRun]) throws -> NSHostingView<AnyView> {
        let size = NSSize(width: 640, height: 520)
        let host = NSHostingView(rootView: AnyView(
            ScrollView { QuickCommandRunLog(runs: runs).padding(14) }
                .frame(width: size.width, height: size.height)))
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

    /// 见 `WelcomeServerListContractTests.axElement`：必须走 `AnyObject`
    /// 动态派发（懒栈的行挂在 `AccessibilityLazyLayoutNode` 下）。
    private func axElement(matching predicate: (String) -> Bool,
                           in root: NSView) throws -> AnyObject {
        var out: AnyObject?
        var visited = 0
        func find(_ node: Any) {
            guard out == nil, visited < 20_000 else { return }
            visited += 1
            let element = node as AnyObject
            if let label = element.accessibilityLabel?(), predicate(label) { out = element; return }
            for child in (element.accessibilityChildren?() ?? []) { find(child) }
            if out == nil, let view = node as? NSView {
                for child in view.subviews { find(child) }
            }
        }
        find(root)
        return try XCTUnwrap(out, "真实 AX 树里找不到目标元素")
    }

    /// 收 label **+ title + value** 三样。
    ///
    /// 坑：只收 `accessibilityLabel` 的话，纯 `Text` 一个都读不到 ——
    /// SwiftUI 的静态文本把内容放在 `accessibilityValue` / `accessibilityTitle` 上，
    /// 只有显式 `.accessibilityLabel(...)` 过的元素才有 label。
    /// 「找不到元素」不等于「元素不存在」。
    private func axStrings(_ root: Any) -> [String] {
        var out: [String] = []
        var seen = 0
        func walk(_ node: Any) {
            seen += 1
            guard seen < 20_000 else { return }
            let element = node as AnyObject
            if let object = node as? NSObject {
                for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    let sel = NSSelectorFromString(name)
                    if object.responds(to: sel),
                       let s = object.perform(sel)?.takeUnretainedValue() as? String {
                        out.append(s)
                    }
                }
            }
            for child in (element.accessibilityChildren?() ?? []) { walk(child) }
            if let view = node as? NSView { for child in view.subviews { walk(child) } }
        }
        walk(root)
        return out
    }

    /// `accessibilityValue()` 在 `AnyObject` 上有多个重载（`Any?` / `String?`…），
    /// 直接调是 ambiguous —— 走 selector 取值。
    private func axValue(_ element: AnyObject) -> String? {
        guard let object = element as? NSObject else { return nil }
        let sel = NSSelectorFromString("accessibilityValue")
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel)?.takeUnretainedValue() as? String
    }

    private func settle(_ host: NSView) {
        for _ in 0..<20 { _ = RunLoop.current.run(mode: .default, before: .distantPast) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    // MARK: - ① 展开 / 收起走 AX 默认动作

    /// 换掉 `Button` 之后，展开头必须仍然是「可按下的、能念出展开态的」元素，
    /// 而且真的按得动 —— 否则 VoiceOver / 全键盘控制的用户展不开任何一条日志。
    func testLogEntryTogglesThroughAccessibilityPress() throws {
        defer { closeAllWindows() }
        let runs = QuickCommandRunLogCostTests.makeRuns(8)
        let host = try mount(runs)

        let header = try axElement(matching: { $0.contains("6 台") }, in: host)
        XCTAssertEqual(header.accessibilityRole?(), .button,
                       "展开头必须仍是 AXButton")
        XCTAssertEqual(axValue(header), "已折叠",
                       "折叠态必须念得出来（视觉上的箭头方向对 VoiceOver 不存在）")

        let pressed = header.accessibilityPerformPress?() ?? false
        settle(host)
        XCTAssertTrue(pressed, "AX 默认动作必须被实现")

        let reopened = try axElement(matching: { $0.contains("6 台") }, in: host)
        XCTAssertEqual(axValue(reopened), "已展开",
                       "按下之后展开态必须进 AX")

        // 展开之后逐台结果必须真的出现在 AX 树里。
        let labels = axStrings(host)
        XCTAssertTrue(labels.contains { $0.contains("host-0-0") },
                      "展开后逐台结果行必须出现在 AX 树里：\(labels.prefix(20))")

        // 再按一次收回去。
        _ = reopened.accessibilityPerformPress?()
        settle(host)
        let collapsed = try axElement(matching: { $0.contains("6 台") }, in: host)
        XCTAssertEqual(axValue(collapsed), "已折叠")
    }

    /// 概览文案（N 台 / 成功 / 失败 / 耗时）不能因为改成「一次取值」而算错。
    func testOverviewTextMatchesTheDecodedResults() throws {
        defer { closeAllWindows() }
        let runs = QuickCommandRunLogCostTests.makeRuns(8)
        let host = try mount(runs)
        let labels = axStrings(host)

        for run in runs.prefix(4) {
            let fails = run.results.filter { !$0.ok }.count
            let ok = run.results.count - fails
            var expected = ["\(run.results.count) 台", "成功 \(ok)"]
            if fails > 0 { expected.append("失败 \(fails)") }
            expected.append(UFormat.duration(milliseconds: Double(run.durationMs)))
            let overview = expected.joined(separator: " · ")
            XCTAssertTrue(labels.contains { $0.contains(overview) },
                          "AX 树里必须念得出概览「\(overview)」")
        }
    }

    // MARK: - ② 源码形态闸门

    func testRunLogKeepsLazyStackAndTapGesture() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/QuickCommandRunLog.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("LazyVStack(spacing: 7)"),
                      "日志列表必须是懒栈 —— 30 天窗口没有条数上限")
        XCTAssertFalse(source.contains(".buttonStyle(.plain)"),
                       "展开头不能包回 Button：每行会多出一个 _FocusRingView + KeyViewProxy")
        XCTAssertTrue(source.contains(".onTapGesture { toggle() }"))
        XCTAssertTrue(source.contains(".accessibilityAction { toggle() }"),
                      "不是 Button 就必须手工补默认动作")
        XCTAssertTrue(source.contains(".accessibilityValue(open ? \"已展开\" : \"已折叠\")"))

        // 一次 body 只取一次值：行体里不该再出现 `run.results` / `run.aiRecord` 的
        // 多次取值（它们背后是 JSONDecoder）。
        XCTAssertEqual(source.components(separatedBy: "run.results").count - 1, 1,
                       "`run.results` 一次 body 只能取一次值")
        XCTAssertEqual(source.components(separatedBy: "run.aiRecord").count - 1, 1,
                       "`run.aiRecord` 一次 body 只能取一次值")
        XCTAssertFalse(source.contains("run.failureCount"))
        XCTAssertFalse(source.contains("run.allSucceeded"))
    }

    /// 模型侧的解码缓存不能被悄悄拆掉（它是 `@Transient`，不入库、不影响 CloudKit）。
    func testRunModelKeepsTheTransientDecodeCache() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Core/Models/QuickCommand.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@Transient private var decodedResults"))
        XCTAssertTrue(source.contains("@Transient private var decodedAIRecord"))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
