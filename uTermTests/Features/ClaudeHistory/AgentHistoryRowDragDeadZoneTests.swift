import AppKit
import SwiftUI
import UAppKitBridge
import UDesignKit
import XCTest
@testable import uTerm

/// 侧栏的会话行（用户报的：点一下行、手一抖就冒出拖动的预览，同标签页那次）：SwiftUI 的 `.onDrag` 在 Mac 上没有死区，
/// 按下后动 0.5pt 就起拖动、把预览画出来，这次点击也被吞掉。行要换成 uAppKit 的 `.dragSource`，拖过死区才起。
///
/// 真的拖动会话要真按住鼠标，单测里起不了；死区本身的行为在 uAppKit 的 `DragSourceProbeTests` 里测，
/// 这里钉住每一行都挂着带死区的拖拽源。
@MainActor
final class AgentHistoryRowDragDeadZoneTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "row-drag-dead-zone-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func probes(in view: NSView) -> [DragSourceProbeView] {
        (view as? DragSourceProbeView).map { [$0] } ?? view.subviews.flatMap(probes)
    }

    func testEverySessionRowDragsOnlyPastADeadZone() async throws {
        let now = Date()
        let sessions = (0..<4).map { n in
            Session(id: "s\(n)", projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop",
                    title: "会话 \(n)", modifiedAt: now.addingTimeInterval(-TimeInterval(n * 60)))
        }
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(history.visibleFiles.count, 4)

        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                                      key: true, placement: .transparentOnScreen)
        let host = NSHostingView(rootView: AgentHistorySessionList(history: history).frame(width: 300, height: 600))
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

        let found = probes(in: host)
        XCTAssertEqual(found.count, 4, "每一行一个带死区的拖拽源")
        for probe in found {
            XCTAssertGreaterThanOrEqual(probe.deadZone, DragSourceProbeView.defaultDeadZone)
            XCTAssertTrue(probe.isObserving)
        }
    }
}
