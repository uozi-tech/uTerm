import XCTest
@testable import uTermMobile

/// 关标签前的前台判断：真控制器 + 假传输。
@MainActor
final class MobileCloseConfirmationTests: XCTestCase {
    private func connected() async throws -> (MobileTerminalController, MobileFakeTerminalTransport) {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, handles) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0))
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let isConnected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(isConnected)
        return (controller, try XCTUnwrap(handles.latest))
    }

    func testRunningProgramComesFromTheBackend() async throws {
        let (controller, transport) = try await connected()
        await transport.setForegroundActivity(.running("npm"))
        let activity = await controller.foregroundActivity()
        XCTAssertEqual(activity, .running("npm"))
        controller.close()
    }

    func testIdleNeedsNoConfirmation() async throws {
        let (controller, transport) = try await connected()
        await transport.setForegroundActivity(.idle)
        let activity = await controller.foregroundActivity()
        XCTAssertNil(activity.closePrompt())
        controller.close()
    }

    func testAlternateScreenFillsInWhenTheProbeCannotTell() async throws {
        let (controller, _) = try await connected()
        // 是否在备用屏读的是影子终端：喂进去当场解析，不需要画面。
        controller.terminal.feed(Data("\u{1b}[?1049h".utf8))
        let activity = await controller.foregroundActivity()
        XCTAssertEqual(activity, .running(nil))
        controller.close()
    }

    func testClosedTabHasNothingToInterrupt() async throws {
        let (controller, transport) = try await connected()
        await transport.setForegroundActivity(.running("npm"))
        controller.close()
        let activity = await controller.foregroundActivity()
        XCTAssertEqual(activity, .idle)
    }
}
