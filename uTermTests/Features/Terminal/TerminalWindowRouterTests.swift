import XCTest
@testable import uTerm

/// 「在终端中打开」的路由：没有终端窗口时交还调用方新开；有的话把主机送进最近活跃的那个。
/// 路由是进程级单例，每个用例用新的窗口 id 并在结束时注销，互不串味。
@MainActor
final class TerminalWindowRouterTests: XCTestCase {
    private let router = TerminalWindowRouter.shared
    private var registered: [UUID] = []

    override func tearDown() async throws {
        for id in registered { router.unregister(windowID: id) }
        registered = []
        try await super.tearDown()
    }

    /// 登记一个不带 NSWindow 的窗口，返回它的 id 与收到的主机列表的读取器。
    private func registerWindow() -> (id: UUID, received: () -> [UUID]) {
        let id = UUID()
        var received: [UUID] = []
        router.register(windowID: id, window: nil) { received.append($0) }
        registered.append(id)
        return (id, { received })
    }

    func testNoWindowFallsBackToCaller() {
        XCTAssertFalse(router.openInExistingWindow(serverID: UUID()))
    }

    func testOpensTabInMostRecentlyActiveWindow() {
        let first = registerWindow()
        let second = registerWindow()
        let server = UUID()

        // 新登记的窗口就是最近活跃的。
        XCTAssertTrue(router.openInExistingWindow(serverID: server))
        XCTAssertEqual(second.received(), [server])
        XCTAssertEqual(first.received(), [])

        // 前一个窗口重新成为 key 后，落点跟着换。
        router.markActive(windowID: first.id)
        let other = UUID()
        XCTAssertTrue(router.openInExistingWindow(serverID: other))
        XCTAssertEqual(first.received(), [other])
        XCTAssertEqual(second.received(), [server])
    }

    func testUnregisteredWindowIsNoLongerATarget() {
        let first = registerWindow()
        let second = registerWindow()
        router.unregister(windowID: second.id)

        let server = UUID()
        XCTAssertTrue(router.openInExistingWindow(serverID: server))
        XCTAssertEqual(first.received(), [server])
        XCTAssertEqual(second.received(), [])
    }

    func testMarkActiveIgnoresUnknownWindow() {
        let known = registerWindow()
        router.markActive(windowID: UUID())

        let server = UUID()
        XCTAssertTrue(router.openInExistingWindow(serverID: server))
        XCTAssertEqual(known.received(), [server])
    }
}
