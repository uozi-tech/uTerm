import UIKit
import XCTest
@testable import uTermMobile

/// 回滚区查找在 iOS 真 surface 上的往来：桥的委托把引擎的回报交给两端共用的 `TerminalSearch`，硬件键盘的 ⌘F / ⌘G
/// 落到它上面。状态机本身在 Mac 的 `TerminalSearchTests` 里测（同一份代码）。
@MainActor
final class GhosttySearchMobileTests: XCTestCase {
    private func makeHost() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 500), keepsBridgeDelegate: true)
        try await host.waitUntilReady()
        return host
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func testFindsMatchesInScrollbackAndSteps() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let search = host.bridge.link.search
        var text = ""
        for index in 0..<40 { text += "line \(index) needle\r\nfiller \(index)\r\n" }
        host.feedAndWait(text)

        search.present()
        search.query = "needle"
        let counted = await waitUntil(5) { search.total == 40 }
        XCTAssertTrue(counted, "应当找到 40 处（大半在回滚里），引擎报的是 \(String(describing: search.total))")

        search.next()
        let selected = await waitUntil(5) { search.selected != nil }
        XCTAssertTrue(selected, "跳一下之后引擎报出选中的那一处")

        search.dismiss()
        XCTAssertNil(search.total)
    }

    func testHardwareKeyboardRegistersFindCommands() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let commands = host.view.keyCommands ?? []
        let find = commands.filter { $0.modifierFlags.contains(.command) && ["f", "g"].contains($0.input) }
        XCTAssertEqual(find.count, 3, "⌘F、⌘G、⇧⌘G")
        XCTAssertTrue(find.allSatisfy(\.wantsPriorityOverSystemBehavior))
    }
}
