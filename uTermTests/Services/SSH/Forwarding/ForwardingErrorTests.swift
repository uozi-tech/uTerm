import XCTest
import Foundation
import NIOCore
@testable import uTerm

final class ForwardingErrorTests: XCTestCase {

    private func rule(_ name: String = "Web 转发", kind: ForwardKind = .local) -> ForwardingRuleSnapshot {
        ForwardingRuleSnapshot(
            id: UUID(), serverID: UUID(), name: name, kind: kind,
            listenHost: "127.0.0.1", listenPort: 8080,
            destHost: "127.0.0.1", destPort: 80, autostart: false)
    }

    // MARK: - bind in use → .conflict

    func testEADDRINUSEClassifiesAsConflict() {
        let err = POSIXError(.EADDRINUSE)
        let classified = ForwardingError.classify(err, rule: rule())
        XCTAssertEqual(classified.kind, .conflict)
        XCTAssertTrue(classified.message.hasPrefix("Web 转发"),
                      "message 应以规则名开头：\(classified.message)")
    }

    func testNSErrorEADDRINUSECodeClassifiesAsConflict() {
        // NIO 常把 bind 失败包成 POSIX domain 的 NSError（errno 48）。
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE), userInfo: nil)
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .conflict)
    }

    func testAddressInUseTextClassifiesAsConflict() {
        let err = NSError(domain: "NIO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bind failed: Address already in use"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .conflict)
    }

    // MARK: - unreachable

    func testConnectionRefusedClassifiesAsUnreachable() {
        let err = POSIXError(.ECONNREFUSED)
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unreachable)
    }

    func testTimedOutClassifiesAsUnreachable() {
        let err = POSIXError(.ETIMEDOUT)
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unreachable)
    }

    func testNoRouteToHostClassifiesAsUnreachable() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH), userInfo: nil)
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unreachable)
    }

    func testConnectionRefusedTextClassifiesAsUnreachable() {
        let err = NSError(domain: "x", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unreachable)
    }

    // MARK: - denied (server rejected bind / channel creation)

    func testChannelCreationFailedClassifiesAsDenied() {
        // 模拟 Citadel SSHClientError.channelCreationFailed —— 远端拒绝绑定/开通道。
        let err = NSError(domain: "Citadel.SSHClientError", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "channelCreationFailed"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule(kind: .remote)).kind, .denied)
    }

    func testRemoteRejectTextClassifiesAsDenied() {
        let err = NSError(domain: "x", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "administratively prohibited: port forwarding is disabled"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule(kind: .remote)).kind, .denied)
    }

    func testPermissionDeniedTextClassifiesAsDenied() {
        // 裸 "Permission denied"（无方法限定词）→ 远端绑定拒绝。
        let err = NSError(domain: "x", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .denied)
    }

    func testEACCESClassifiesAsDenied() {
        // errno EACCES：本地绑定被拒（如特权端口）→ .denied。
        let err = POSIXError(.EACCES)
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .denied)
    }

    func testEPERMClassifiesAsDenied() {
        // errno EPERM：特权端口绑定 → .denied。
        let err = POSIXError(.EPERM)
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .denied)
    }

    // MARK: - NIOCore.IOError（NIO 实际抛出的类型 —— 回归：errnoCode 必须被读取）

    // NIO 的 bind/listen/connect 失败抛 `NIOCore.IOError`，它不是 POSIXError、桥接
    // NSError 的 domain 也不是 NSPOSIXErrorDomain、localizedDescription 只是通用的
    // 「未能完成操作（NIOCore.IOError 错误1）」。修复前这些全部落到 .unknown，把可恢复
    // 错误显示成无意义的「错误1」（即线上 -L TimescaleDB 报错的真因）。

    func testIOErrorEADDRINUSEClassifiesAsConflict() {
        // -L 转 DB 最常见：本地端口已被占用（本机已跑 Postgres/Timescale 或转发未关）。
        let err = IOError(errnoCode: EADDRINUSE, reason: "bind(descriptor:ptr:bytes:)")
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .conflict)
    }

    func testIOErrorECONNREFUSEDClassifiesAsUnreachable() {
        let err = IOError(errnoCode: ECONNREFUSED, reason: "connect")
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unreachable)
    }

    func testIOErrorEPERMClassifiesAsDenied() {
        // 沙盒/特权端口 bind 被拒 errno 1 —— 用户看到的「NIOCore.IOError 错误1」。
        let err = IOError(errnoCode: EPERM, reason: "bind")
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .denied)
    }

    func testIOErrorEACCESClassifiesAsDenied() {
        let err = IOError(errnoCode: EACCES, reason: "bind")
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .denied)
    }

    func testIOErrorUnknownErrnoFallsBackToUnknown() {
        // 不在已知集合的 errno 仍走 .unknown（兜底不变）。
        let err = IOError(errnoCode: ENOTTY, reason: "ioctl")
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unknown)
    }

    // MARK: - denied 文案按方向区分（本地 bind 权限 vs 远端 GatewayPorts）

    func testLocalDeniedMessageMentionsPrivilegedPortNotGatewayPorts() {
        let msg = ForwardingError.classify(IOError(errnoCode: EPERM, reason: "bind"),
                                           rule: rule(kind: .local)).message
        XCTAssertTrue(msg.contains("管理员权限"), "本地 -L 拒绝应提示管理员权限：\(msg)")
        XCTAssertFalse(msg.contains("GatewayPorts"), "本地 -L 拒绝不应误报 GatewayPorts：\(msg)")
    }

    func testRemoteDeniedMessageMentionsGatewayPorts() {
        let msg = ForwardingError.classify(IOError(errnoCode: EPERM, reason: "bind"),
                                           rule: rule(kind: .remote)).message
        XCTAssertTrue(msg.contains("GatewayPorts"), "远端 -R 拒绝应提示 GatewayPorts：\(msg)")
    }

    // MARK: - auth

    func testAuthenticationFailedTextClassifiesAsAuth() {
        let err = NSError(domain: "Citadel", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "AuthenticationFailed"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .auth)
    }

    func testAllAuthOptionsFailedTextClassifiesAsAuth() {
        let err = NSError(domain: "x", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "allAuthenticationOptionsFailed"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .auth)
    }

    func testPermissionDeniedPublickeyClassifiesAsAuth() {
        // 回归：SSH 认证被拒（含方法限定词）必须归 .auth，而非 .denied。
        let err = NSError(domain: "NSSSH", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Permission denied (publickey)."])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .auth)
    }

    func testPermissionDeniedPasswordClassifiesAsAuth() {
        let err = NSError(domain: "NSSSH", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Permission denied (password)."])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .auth)
    }

    func testPermissionDeniedKeyboardInteractiveClassifiesAsAuth() {
        let err = NSError(domain: "NSSSH", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Permission denied (keyboard-interactive)."])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .auth)
    }

    // MARK: - fallthrough

    func testUnknownErrorClassifiesAsUnknown() {
        let err = NSError(domain: "x", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "完全无法识别的怪事"])
        XCTAssertEqual(ForwardingError.classify(err, rule: rule()).kind, .unknown)
    }

    func testMessageAlwaysLeadsWithRuleName() {
        let r = rule("数据库隧道")
        XCTAssertTrue(ForwardingError.classify(POSIXError(.EADDRINUSE), rule: r).message
                        .hasPrefix("数据库隧道"))
        XCTAssertTrue(ForwardingError.classify(POSIXError(.ECONNREFUSED), rule: r).message
                        .hasPrefix("数据库隧道"))
    }

    func testEquatable() {
        let a = ForwardingError(kind: .conflict, message: "x")
        let b = ForwardingError(kind: .conflict, message: "x")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ForwardingError(kind: .unreachable, message: "x"))
    }
}
