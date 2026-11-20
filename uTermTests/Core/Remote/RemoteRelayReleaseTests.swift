import XCTest
@testable import uTerm

/// 中继发布物、版本比较、提示词、STUN 编解码、更新提醒——都是纯逻辑，不联网。
@MainActor
final class RemoteRelayReleaseTests: XCTestCase {

    // MARK: - 版本

    func testVersionsCompareNumerically() throws {
        XCTAssertLessThan(try XCTUnwrap(RemoteRelayVersion("1.9.0")), try XCTUnwrap(RemoteRelayVersion("1.10.0")))
        XCTAssertEqual(RemoteRelayVersion("1.1"), RemoteRelayVersion("1.1.0"))
        XCTAssertNil(RemoteRelayVersion("1.x"))
        XCTAssertNil(RemoteRelayVersion(""))
        XCTAssertTrue(RemoteRelayVersion.isUpdate(latest: "1.1.0", running: "1.0.0"))
        XCTAssertFalse(RemoteRelayVersion.isUpdate(latest: "1.1.0", running: "1.1.0"))
        XCTAssertFalse(RemoteRelayVersion.isUpdate(latest: "1.0.0", running: "1.1.0"), "自己编的新版不提示回退")
        XCTAssertFalse(RemoteRelayVersion.isUpdate(latest: nil, running: "1.0.0"))
        XCTAssertFalse(RemoteRelayVersion.isUpdate(latest: "garbage", running: "1.0.0"))
    }

    func testLatestJSONIsParsedStrictly() {
        XCTAssertEqual(RemoteRelayRelease.parseLatest(Data(#"{ "version": "1.2.3" }"#.utf8)), "1.2.3")
        XCTAssertNil(RemoteRelayRelease.parseLatest(Data(#"{ "version": "latest" }"#.utf8)))
        XCTAssertNil(RemoteRelayRelease.parseLatest(Data("<html>".utf8)))
    }

    // MARK: - 安装脚本

    func testInstallerSummaryKeepsOnlyKeyValueLines() {
        let output = """
        previous=1.0.0
        uterm-relay install: 端口 47310 已被占用
        relay: 2 hosts online
        version=1.1.0
        updated=yes
        """
        XCTAssertEqual(RemoteRelayRelease.summary(output),
                       ["previous": "1.0.0", "version": "1.1.0", "updated": "yes"])
    }

    func testUpdateCommandUsesSudoOnlyForNonRoot() throws {
        try XCTSkipUnless(RemoteRelayRelease.isAvailable, "这个构建没有配置中继发布地址")
        let command = try XCTUnwrap(RemoteRelayRelease.updateCommand)
        XCTAssertTrue(command.contains("sudo -n"))
        XCTAssertTrue(command.contains(try XCTUnwrap(RemoteRelayRelease.installScriptURL).absoluteString))
        XCTAssertTrue(command.hasSuffix("sh -s -- update"))
        XCTAssertTrue(RemoteRelayRelease.needsPassword("sudo: a password is required"))
        XCTAssertFalse(RemoteRelayRelease.needsPassword("version=1.1.0"))
    }

    /// 发布地址是构建配置：空、没展开的 `$(…)`、不是 http(s) 都当没配。
    func testReleaseURLComesFromBuildConfiguration() {
        let key = RemoteRelayRelease.infoKey
        XCTAssertNil(RemoteRelayRelease.configuredBaseURL(nil))
        XCTAssertNil(RemoteRelayRelease.configuredBaseURL([key: ""]))
        XCTAssertNil(RemoteRelayRelease.configuredBaseURL([key: "  "]))
        XCTAssertNil(RemoteRelayRelease.configuredBaseURL([key: "$(UTERM_RELAY_RELEASE_URL)"]))
        XCTAssertNil(RemoteRelayRelease.configuredBaseURL([key: "file:///tmp/relay"]))
        XCTAssertEqual(RemoteRelayRelease.configuredBaseURL([key: "https://dl.example.com/relay"])?.absoluteString,
                       "https://dl.example.com/relay")
    }

    // MARK: - 提示词

    func testDeployPromptNamesTheHostAndTheRules() {
        let prompt = RemoteRelayAgentPrompt.deploy(hostName: "relay-sz")
        XCTAssertTrue(prompt.contains("「relay-sz」"))
        XCTAssertTrue(prompt.contains("references/relay.md"))
        XCTAssertTrue(prompt.contains("relay import"))
        XCTAssertTrue(prompt.contains("relay check"))
        XCTAssertTrue(prompt.contains("随机"))
        XCTAssertTrue(prompt.contains("不要运行 uterm-relay config"))
        XCTAssertTrue(RemoteRelayAgentPrompt.deploy(hostName: nil).contains("问我装在哪台"))
        XCTAssertTrue(RemoteRelayAgentPrompt.update(hostName: "relay-sz").contains("「relay-sz」"))
    }

    // MARK: - 管理主机

    func testManagedHostsRoundTrip() throws {
        let suite = "RemoteRelayReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosts = RemoteRelayManagedHosts(defaults: defaults)
        let id = UUID()
        hosts.set(id, for: "r1")
        XCTAssertEqual(hosts.host(for: "r1"), id)
        XCTAssertNil(hosts.host(for: "r2"))
        hosts.set(nil, for: "r1")
        XCTAssertNil(hosts.host(for: "r1"))
    }

    // MARK: - STUN

    func testSTUNRequestIsLongEnoughForAnIPv6Answer() {
        let transaction = [UInt8](repeating: 7, count: 12)
        let request = RemoteRelaySTUNProbe.makeRequest(transaction: transaction)
        XCTAssertGreaterThanOrEqual(request.count, 44, "中继按协议只回不大于请求的包")
        XCTAssertEqual(Int(request[2]) << 8 | Int(request[3]), request.count - 20, "长度字段 = 属性总长")
        XCTAssertEqual(Array(request[8..<20]), transaction)
    }

    func testSTUNAnswerDecodesTheMappedAddress() {
        let transaction: [UInt8] = Array(1...12)
        var answer: [UInt8] = [0x01, 0x01, 0x00, 0x0C, 0x21, 0x12, 0xA4, 0x42] + transaction
        // XOR-MAPPED-ADDRESS 203.0.113.5:40000
        let port = UInt16(40000) ^ 0x2112
        let ip: [UInt8] = [203, 0, 113, 5]
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        answer += [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, UInt8(port >> 8), UInt8(port & 0xFF)]
        answer += (0..<4).map { ip[$0] ^ cookie[$0] }
        XCTAssertEqual(try RemoteRelaySTUNProbe.parse(Data(answer), transaction: transaction)?.get(), "203.0.113.5:40000")
        XCTAssertNil(RemoteRelaySTUNProbe.parse(Data(answer), transaction: Array(repeating: 0, count: 12)),
                     "别人的事务不算")
        var error = answer
        error[1] = 0x11
        XCTAssertNotNil(try RemoteRelaySTUNProbe.parse(Data(error), transaction: transaction)?.get(),
                        "回 500 也说明 UDP 通了")
    }

    // MARK: - 更新提醒

    func testMonitorNotifiesOncePerVersion() async throws {
        let suite = "RemoteRelayReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notified: [(String, String)] = []
        let monitor = RemoteRelayUpdateMonitor(defaults: defaults, fetchLatest: { "1.1.0" },
                                               notify: { notified.append(($0, $1)) })

        await monitor.refresh()
        XCTAssertEqual(monitor.latestVersion, "1.1.0")
        XCTAssertFalse(monitor.updateAvailable, "还不知道中继在跑哪个版本")
        XCTAssertTrue(notified.isEmpty)

        monitor.noteRunning("1.0.0")
        XCTAssertEqual(monitor.runningVersion, "1.0.0")
        XCTAssertTrue(monitor.updateAvailable)
        XCTAssertEqual(notified.map(\.1), ["1.1.0"])

        monitor.noteRunning("1.0.0")
        XCTAssertEqual(notified.count, 1, "同一个版本只提醒一次")

        monitor.noteRunning(nil)
        XCTAssertFalse(monitor.updateAvailable, "不知道版本就不提醒")

        monitor.noteRunning("1.1.0")
        XCTAssertFalse(monitor.updateAvailable)
    }

    func testMonitorFetchesAtMostOncePerDay() async throws {
        let suite = "RemoteRelayReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        defaults.set(now.addingTimeInterval(-60), forKey: DefaultsKey.remoteRelayLatestCheckedAt)
        defaults.set("1.0.0", forKey: DefaultsKey.remoteRelayLatestVersion)
        let monitor = RemoteRelayUpdateMonitor(defaults: defaults, fetchLatest: { XCTFail("一天之内不该再取"); return "9.9.9" },
                                               notify: { _, _ in })
        XCTAssertEqual(monitor.latestVersion, "1.0.0", "启动时读缓存")
        monitor.refreshIfStale(now: now)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(monitor.latestVersion, "1.0.0")
    }
}
