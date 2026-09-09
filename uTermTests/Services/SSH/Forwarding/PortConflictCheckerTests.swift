import XCTest
@testable import uTerm

final class PortConflictCheckerTests: XCTestCase {

    private func snap(_ kind: ForwardKind, _ port: Int, id: UUID = UUID(),
                      name: String? = nil) -> ForwardingRuleSnapshot {
        ForwardingRuleSnapshot(id: id, serverID: UUID(), name: name ?? "规则\(port)", kind: kind,
                               listenHost: "127.0.0.1", listenPort: port,
                               destHost: nil, destPort: 0, autostart: false)
    }

    // MARK: sameSide —— local/dynamic 本地侧，remote 远端侧

    func testSameSideLocalAndDynamicShareLocalSide() {
        XCTAssertTrue(PortConflictChecker.sameSide(.local, .dynamic))
        XCTAssertTrue(PortConflictChecker.sameSide(.local, .local))
        XCTAssertTrue(PortConflictChecker.sameSide(.dynamic, .dynamic))
    }

    func testSameSideRemoteOnlyMatchesRemote() {
        XCTAssertTrue(PortConflictChecker.sameSide(.remote, .remote))
        XCTAssertFalse(PortConflictChecker.sameSide(.remote, .local))
        XCTAssertFalse(PortConflictChecker.sameSide(.remote, .dynamic))
    }

    // MARK: conflict vs 同侧规则

    func testConflictWithSameSideRuleOnSamePort() {
        let existing = snap(.local, 8080)
        let result = PortConflictChecker.conflict(kind: .dynamic, listenPort: 8080,
                                                  excluding: nil, against: [existing])
        XCTAssertEqual(result, PortConflictChecker.Conflict(port: 8080, occupant: "规则8080", source: .rule))
    }

    func testNoConflictAcrossSides() {
        // remote 远端绑定，local 本地绑定 —— 不同侧，同端口不冲突
        let existing = snap(.remote, 8080)
        let result = PortConflictChecker.conflict(kind: .local, listenPort: 8080,
                                                  excluding: nil, against: [existing])
        XCTAssertNil(result)
    }

    func testConflictExcludesSelf() {
        let me = UUID()
        let existing = snap(.local, 8080, id: me)
        let result = PortConflictChecker.conflict(kind: .local, listenPort: 8080,
                                                  excluding: me, against: [existing])
        XCTAssertNil(result)   // 编辑自身规则不算冲突
    }

    // MARK: conflict vs 知名端口

    func testConflictWithWellKnownPort() {
        let result = PortConflictChecker.conflict(kind: .local, listenPort: 22,
                                                  excluding: nil, against: [])
        XCTAssertEqual(result, PortConflictChecker.Conflict(port: 22, occupant: "SSH", source: .wellKnownPort))
    }

    func testWellKnownNotAppliedToRemoteSide() {
        // 远端绑定口（remote）落在知名端口（22）上不算本地系统端口冲突
        let result = PortConflictChecker.conflict(kind: .remote, listenPort: 22,
                                                  excluding: nil, against: [])
        XCTAssertNil(result)
    }

    func testWellKnownAppliedToLocalSide() {
        // 本地绑定（local）落在知名端口 22 → 报 SSH 冲突
        let result = PortConflictChecker.conflict(kind: .local, listenPort: 22,
                                                  excluding: nil, against: [])
        XCTAssertEqual(result, PortConflictChecker.Conflict(port: 22, occupant: "SSH", source: .wellKnownPort))
    }

    func testWellKnownPortTableContents() {
        XCTAssertEqual(PortConflictChecker.wellKnownPorts[22], "SSH")
        XCTAssertEqual(PortConflictChecker.wellKnownPorts[631], "CUPS")
        XCTAssertEqual(PortConflictChecker.wellKnownPorts[5000], "AirPlay")
    }

    func testRuleConflictTakesPrecedenceOverWellKnown() {
        // 同侧规则与知名端口同号时，先报规则冲突（更可操作）
        let existing = snap(.local, 22)
        let result = PortConflictChecker.conflict(kind: .local, listenPort: 22,
                                                  excluding: nil, against: [existing])
        XCTAssertEqual(result, PortConflictChecker.Conflict(port: 22, occupant: "规则22", source: .rule))
    }

    /// `occupant` 两支都是名字：规则起名叫 "AirPlay" 时，光看字符串分不出这条是
    /// 真规则冲突还是知名端口提醒。`source` 就是为这个存在的（CLI 据它决定拦还是提醒）。
    func testSourceDistinguishesRuleNamedAfterAService() {
        let existing = snap(.local, 5000, name: "AirPlay")
        let clash = PortConflictChecker.conflict(kind: .local, listenPort: 5000,
                                                 excluding: nil, against: [existing])
        XCTAssertEqual(clash?.occupant, "AirPlay")
        XCTAssertEqual(clash?.source, .rule, "规则冲突，不是知名端口提醒")

        let wellKnown = PortConflictChecker.conflict(kind: .local, listenPort: 5000,
                                                    excluding: nil, against: [])
        XCTAssertEqual(wellKnown?.occupant, "AirPlay")
        XCTAssertEqual(wellKnown?.source, .wellKnownPort)
    }

    // MARK: suggestFreePort —— 跳过同侧已占 + 知名端口

    func testSuggestFreePortSkipsTakenSameSide() {
        let rules = [snap(.local, 8080), snap(.dynamic, 8081)]
        let free = PortConflictChecker.suggestFreePort(after: 8080, kind: .local, against: rules)
        XCTAssertEqual(free, 8082)   // 8081 被同侧 dynamic 占
    }

    func testSuggestFreePortSkipsWellKnown() {
        let free = PortConflictChecker.suggestFreePort(after: 21, kind: .local, against: [])
        XCTAssertEqual(free, 23)     // 22 是 SSH 知名端口
    }

    func testSuggestFreePortIgnoresCrossSideRules() {
        // remote 占 8081 不影响 local 侧的建议
        let rules = [snap(.remote, 8081)]
        let free = PortConflictChecker.suggestFreePort(after: 8080, kind: .local, against: rules)
        XCTAssertEqual(free, 8081)
    }

    // MARK: isPrivileged —— <1024 且不冲突

    func testIsPrivilegedBelow1024NoConflict() {
        XCTAssertTrue(PortConflictChecker.isPrivileged(80, hasConflict: false))
        XCTAssertTrue(PortConflictChecker.isPrivileged(1023, hasConflict: false))
    }

    func testNotPrivilegedAt1024OrAbove() {
        XCTAssertFalse(PortConflictChecker.isPrivileged(1024, hasConflict: false))
        XCTAssertFalse(PortConflictChecker.isPrivileged(8080, hasConflict: false))
    }

    func testNotPrivilegedWhenAlreadyConflicting() {
        // 已有冲突时不再叠加特权警告（避免双重提示）
        XCTAssertFalse(PortConflictChecker.isPrivileged(80, hasConflict: true))
    }
}
