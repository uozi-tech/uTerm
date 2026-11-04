import SwiftTerm
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
        controller.attach(SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500)))
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
        XCTAssertNil(activity.closePrompt)
        controller.close()
    }

    func testAlternateScreenFillsInWhenTheProbeCannotTell() async throws {
        let (controller, _) = try await connected()
        controller.terminalView?.getTerminal().feed(text: "\u{1b}[?1049h")
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
