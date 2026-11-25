import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 列表那一行的「多久以前」自己往前走：行的数据没变（会话停着、没在写）也不能一直停在画出来那一刻。
///
/// 实测（2026-11-25，build 1500，本机 Code 标签页侧栏，隔 20 秒读一次无障碍文字）：文件 66 秒前改过的那一行写
/// 「53秒钟前」，91 秒时写「1分钟前」——行里的字只在那一行的数据变了、被重画时才重算，停着的会话可以一直写着「刚刚」。
@MainActor
final class AgentSessionTimeTextTests: XCTestCase {
    private var savedInterval: TimeInterval = 0

    override func setUp() async throws {
        try await super.setUp()
        AgentHistoryListCache.shared.removeAll()
        savedInterval = AgentSessionTimeText.refreshInterval
    }

    override func tearDown() async throws {
        AgentSessionTimeText.refreshInterval = savedInterval
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    /// 停着的会话（56 秒前写过、之后没再写）：过了一分钟那一刻，行里的字从「xx 秒钟前」换成「1 分钟前」，
    /// 不用等列表重列、也不用等那一行的数据变。
    func testIdleRowTimeAdvancesWithoutNewData() async throws {
        AccessibilityTreeForTests.enable(for: self)
        AgentSessionTimeText.refreshInterval = 0.2
        let modified = Date().addingTimeInterval(-56)
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            AgentHistoryFakeSource.Session(id: "idle", projectID: ClaudeProjectPath.encode("/srv/shop"),
                                           resumeDirectory: "/srv/shop", title: "停着的会话", modifiedAt: modified),
        ])
        let history = AgentHistoryModel(source: source, preferredDirectory: "/srv/shop", followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try await Task.sleep(for: .milliseconds(10)) }

        let view = NSHostingView(rootView: AgentHistorySessionList(history: history).frame(width: 320, height: 400))
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = ProbeWindow.make(contentRect: view.frame, contentView: view, placement: .transparentOnScreen)
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        func rowText() async throws -> String? {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            return Self.axStrings(view).first { $0.contains("停着的会话") }
        }
        var first: String?
        for _ in 0..<20 where first == nil { first = try await rowText() }
        let before = try XCTUnwrap(first, "画出了那一行")
        // 过了一分钟那一刻（数据一点没变）。
        let later = AgentHistoryText.relative(modified.addingTimeInterval(-5))
        XCTAssertFalse(before.contains(later), "一开始还不到一分钟：\(before)")
        let deadline = ContinuousClock.now + .seconds(8)
        var text = before
        while ContinuousClock.now < deadline, !text.contains(later) {
            try await Task.sleep(for: .milliseconds(200))
            text = try await rowText() ?? text
        }
        XCTAssertTrue(text.contains(later), "时间往前走了：现在写「\(text)」，应当有「\(later)」")
    }

    /// 子树里所有无障碍元素的 label / value（同 `ForwardingListContractTests`）。
    private static func axStrings(_ root: Any, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        var out: [String] = []
        let object = root as AnyObject
        if let label = object.accessibilityLabel?(), !label.isEmpty { out.append(label) }
        let valueSelector = NSSelectorFromString("accessibilityValue")
        if object.responds?(to: valueSelector) == true,
           let value = object.perform(valueSelector)?.takeUnretainedValue() as? String, !value.isEmpty {
            out.append(value)
        }
        if let children = object.accessibilityChildren?() {
            for child in children { out += axStrings(child, depth: depth + 1) }
        }
        return out
    }
}
