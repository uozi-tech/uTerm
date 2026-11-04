import XCTest
@testable import uTerm

/// 真彩提示的失败路径。正常路径见 `RemoteTrueColorTests`。
@MainActor
final class RemoteTrueColorOfferFailureTests: XCTestCase {

    private struct Boom: LocalizedError {
        var errorDescription: String? { "磁盘满了" }
    }

    private actor Backend: TerminalBackend, TerminalTrueColorConfiguring {
        nonisolated let outputStream = AsyncStream<Data> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        nonisolated let trueColorHostKey = "failure-\(UUID().uuidString):22"
        private let probeFails: Bool
        private let enableFails: Bool
        private(set) var probes = 0

        init(probeFails: Bool = false, enableFails: Bool = false) {
            self.probeFails = probeFails
            self.enableFails = enableFails
        }

        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func trueColorStatus() async throws -> RemoteTrueColor.Status {
            probes += 1
            if probeFails { throw Boom() }
            return .canEnable(rcFile: "/h/.zshenv")
        }
        func enableTrueColor() async throws -> String {
            if enableFails { throw Boom() }
            return "/h/.zshenv"
        }
    }

    private func agentReports(_ session: TerminalSession) {
        session.applyProgramStatus(.report(id: "", record: ProgramStatusRecord(state: .idle)), isLooking: false)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待超时", file: file, line: line)
    }

    func testProbeFailureShowsNoOffer() async throws {
        let session = TerminalSession()
        let backend = Backend(probeFails: true)
        await session.connect(using: backend)
        agentReports(session)
        try await waitUntil { await backend.probes == 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(session.trueColorOffer)
    }

    func testEnableFailureIsShownAndCanBeDismissed() async throws {
        let session = TerminalSession()
        await session.connect(using: Backend(enableFails: true))
        agentReports(session)
        try await waitUntil { session.trueColorOffer != nil }

        session.enableTrueColor()

        try await waitUntil { session.trueColorOffer == .failed("磁盘满了") }
        session.closeTrueColorOffer()
        XCTAssertNil(session.trueColorOffer)
    }

    func testAgentReportsAgainAfterDismissingBannerOnSameConnectionDoNotReopenIt() async throws {
        let session = TerminalSession()
        let backend = Backend()
        await session.connect(using: backend)
        agentReports(session)
        try await waitUntil { session.trueColorOffer != nil }

        session.closeTrueColorOffer()
        agentReports(session)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(session.trueColorOffer)
        let probes = await backend.probes
        XCTAssertEqual(probes, 1)
    }

    func testReconnectChecksAgain() async throws {
        let session = TerminalSession()
        let first = Backend()
        await session.connect(using: first)
        agentReports(session)
        try await waitUntil { session.trueColorOffer != nil }
        session.markFailed("断了")

        let second = Backend()
        await session.connect(using: second)
        agentReports(session)

        try await waitUntil { session.trueColorOffer == .available(rcFile: "/h/.zshenv") }
        let probes = await second.probes
        XCTAssertEqual(probes, 1)
    }

    /// 本机 shell、手机远控的后端没有这项能力：Agent 报告状态不会触发探测，操作也都是空操作。
    func testBackendWithoutTheCapabilityNeverOffers() async throws {
        let session = TerminalSession()
        await session.connect(using: MockBackend())

        agentReports(session)
        session.enableTrueColor()
        session.dismissTrueColorOfferForHost()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(session.trueColorOffer)
        XCTAssertFalse(session.trueColorChecked)
    }

    func testRCLineMatchesTheFileTheBannerShows() {
        XCTAssertTrue(RemoteTrueColor.rcLine(forFile: "/h/.config/fish/conf.d/uterm.fish").contains("set -gx COLORTERM"))
        XCTAssertTrue(RemoteTrueColor.rcLine(forFile: "/h/.zshenv").contains("export COLORTERM=truecolor"))
    }
}
