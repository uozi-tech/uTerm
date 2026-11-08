import XCTest
@testable import uTerm

@MainActor
final class RemoteControlPresentationTests: XCTestCase {
    func testServerStatus() {
        XCTAssertEqual(RemoteControlPresentation.serverStatus(.listening, hasConnectedDevices: false).symbol,
                       "dot.radiowaves.left.and.right")
        XCTAssertEqual(RemoteControlPresentation.serverStatus(.listening, hasConnectedDevices: true).symbol,
                       "iphone.radiowaves.left.and.right")
        XCTAssertEqual(RemoteControlPresentation.serverStatus(.listening, hasConnectedDevices: true).tone, .active)
        XCTAssertEqual(RemoteControlPresentation.serverStatus(.stopped, hasConnectedDevices: false).tone, .neutral)
        XCTAssertEqual(RemoteControlPresentation.serverStatus(.failed("x"), hasConnectedDevices: false).tone, .danger)
    }

    func testConnectedHint() {
        XCTAssertNil(RemoteControlPresentation.connectedHint([]))
        XCTAssertEqual(RemoteControlPresentation.connectedHint(["iPhone", "iPad"]), "已连接：iPhone、iPad")
    }

    func testHelper() {
        XCTAssertEqual(RemoteControlPresentation.helperDisplay(.unknown), .hidden)
        XCTAssertEqual(RemoteControlPresentation.helperDisplay(.checking), .progress)
        XCTAssertEqual(RemoteControlPresentation.helperDisplay(.ok("1.0")),
                       .badge(symbol: "checkmark.circle.fill", tone: .success, label: "正常"))
        XCTAssertEqual(RemoteControlPresentation.helperDisplay(.failed("x")),
                       .badge(symbol: "exclamationmark.triangle.fill", tone: .danger, label: "无法连接"))
        XCTAssertEqual(RemoteControlPresentation.helperHint(.failed("连不上 XPC")), "连不上 XPC")
        XCTAssertTrue(RemoteControlPresentation.helperHint(.unknown).contains("辅助程序"))
    }

    func testRelayStatus() {
        XCTAssertEqual(RemoteControlPresentation.relayStatusLabel(nil), "正在连接")
        XCTAssertEqual(RemoteControlPresentation.relayStatusLabel(.connecting), "正在连接")
        XCTAssertEqual(RemoteControlPresentation.relayStatusLabel(.registered), "已连接中继")
        XCTAssertEqual(RemoteControlPresentation.relayStatusLabel(.failed("x")), "无法连接")
        XCTAssertEqual(RemoteControlPresentation.relayStatusLabel(.superseded), "被其他设备顶替")
        XCTAssertEqual(RemoteControlPresentation.relayStatusLabel(.stopped), "已停止")

        XCTAssertEqual(RemoteControlPresentation.relayStatusHint(.failed("超时")), "超时")
        XCTAssertNotNil(RemoteControlPresentation.relayStatusHint(.superseded))
        XCTAssertNil(RemoteControlPresentation.relayStatusHint(.registered))
        XCTAssertNil(RemoteControlPresentation.relayStatusHint(nil))

        XCTAssertEqual(RemoteControlPresentation.relayStatus(.registered).tone, .success)
        XCTAssertEqual(RemoteControlPresentation.relayStatus(.failed("x")).tone, .danger)
        XCTAssertEqual(RemoteControlPresentation.relayStatus(.superseded).tone, .danger)
        XCTAssertEqual(RemoteControlPresentation.relayStatus(nil).symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(RemoteControlPresentation.relayStatus(nil).tone, .neutral)
    }

    func testRelaySubtitleAndUpdateTexts() {
        let config = RemoteRelayConfig(name: "家", host: "relay.example.com", port: 47310, relayID: "r", key: "k")
        XCTAssertEqual(RemoteControlPresentation.relaySubtitle(config, version: nil), "家 · relay.example.com:47310")
        XCTAssertEqual(RemoteControlPresentation.relaySubtitle(config, version: "1.1.0"), "家 · relay.example.com:47310 · v1.1.0")
        XCTAssertTrue(RemoteControlPresentation.relayUpdateHint(running: "1.0.0", host: "box").contains("「box」"))
        XCTAssertTrue(RemoteControlPresentation.relayUpdateHint(running: nil, host: nil).contains("指定所在主机"))
        XCTAssertNil(RemoteControlPresentation.relayUpdateNote(.idle))
        XCTAssertEqual(RemoteControlPresentation.relayUpdateNote(.failed("x"))?.tone, .danger)
        XCTAssertEqual(RemoteControlPresentation.relayUpdateNote(.openedTerminal)?.tone, .warning)
    }

    func testRelayCheckNotes() {
        let ok = RemoteRelayCheckResult(tcp: .ok, auth: .ok, udp: .ok, rttMs: 12, problems: [])
        XCTAssertEqual(RemoteControlPresentation.relayCheckNotes(ok).map(\.tone), [.success])
        XCTAssertTrue(RemoteControlPresentation.relayCheckNotes(ok)[0].text.contains("12 ms"))
        let noUDP = RemoteRelayCheckResult(tcp: .ok, auth: .ok, udp: .failed, problems: ["udp"])
        XCTAssertEqual(RemoteControlPresentation.relayCheckNotes(noUDP).map(\.tone), [.warning, .warning])
        let down = RemoteRelayCheckResult(tcp: .failed, auth: .skipped, udp: .failed, problems: ["tcp", "udp"])
        XCTAssertEqual(RemoteControlPresentation.relayCheckNotes(down).first?.tone, .danger)
        XCTAssertEqual(RemoteControlPresentation.relayCheckNotes(down).count, 3)
    }

    func testHints() {
        XCTAssertTrue(RemoteControlPresentation.relayHint(nil).contains("uterm 技能"))
        XCTAssertTrue(RemoteControlPresentation.pairingHint(hasInvitation: true).contains("10 分钟"))
        XCTAssertTrue(RemoteControlPresentation.pairingHint(hasInvitation: false).contains("扫码配对"))
    }
}
