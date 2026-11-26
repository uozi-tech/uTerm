import XCTest
@testable import uTerm

/// 第三期的共用部分：SSH 主机的 Code 标签页也进 63（每台主机一个）、Code 标签页插进 Mac 的标签顺序、64 号消息带主机。
@MainActor
final class RemoteCodeTabHostsTests: XCTestCase {
    private let host = UUID()

    private func tab(_ server: UUID, runs: [UUID], tool: String = "claude", slot: Int? = nil) -> RemoteCodeTabInfo {
        RemoteCodeTabInfo(id: UUID(), serverID: server, serverName: "h", slot: slot,
                          runs: runs.map { RemoteCodeTabInfo.Run(session: $0, tool: tool, directory: "/w",
                                                                  startedAt: Date(timeIntervalSince1970: 0)) })
    }

    func test_one_code_tab_per_host_and_runs_by_host() {
        let local = (UUID(), UUID()), ssh = UUID(), stray = UUID(), unknown = UUID()
        let tabs = [tab(RemoteConstants.localShellServerID, runs: [local.0]), tab(host, runs: [ssh]),
                    tab(RemoteConstants.localShellServerID, runs: [local.1]), tab(host, runs: [stray]),
                    tab(UUID(), runs: [unknown], tool: "future")]
        XCTAssertEqual(tabs.mirroredPerHost.map(\.serverID), [RemoteConstants.localShellServerID, host, tabs[4].serverID],
                       "每台主机取第一个")
        let client = RemoteMacClient(macName: "Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: tabs))
        XCTAssertEqual(client.codeRunSessionIDs, [local.0], "默认只算本机的（第一期的规则不变）")
        XCTAssertEqual(client.codeRunSessionIDs(serverIDs: [host]), [ssh])
        XCTAssertEqual(client.codeRunSessionIDs(serverIDs: [RemoteConstants.localShellServerID, host]), [local.0, ssh])
        XCTAssertEqual(client.codeRunSessionIDs(serverIDs: [tabs[4].serverID]), [], "认不出的工具不算")
    }

    func test_code_tabs_are_inserted_before_their_slot() {
        let s = (0..<4).map { _ in UUID() }
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertEqual(s.insertingCodeTabs([(a, 1)]), [s[0], a, s[1], s[2], s[3]])
        XCTAssertEqual(s.insertingCodeTabs([(a, 2), (b, 0), (c, 2), (d, nil)]), [b, s[0], s[1], a, c, s[2], s[3]],
                       "按位置排、同位置按给的先后，没报位置的不插")
        XCTAssertEqual(s.insertingCodeTabs([(a, 9), (b, -1)]), [b, s[0], s[1], s[2], s[3], a], "超出范围夹到两头")
        XCTAssertEqual([s[0], a, s[1]].insertingCodeTabs([(a, 2)]), [s[0], s[1], a], "已经在里面的先拿掉")
    }

    func test_action_carries_the_host_and_old_payloads_still_decode() throws {
        let action = RemoteCodeTabAction(action: .start, tool: "claude", directory: "/srv", server: host)
        let decoded = try JSONDecoder().decode(RemoteCodeTabAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.server, host)
        let old = #"{"requestID":"\#(UUID().uuidString)","action":"resume","path":"/p"}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteCodeTabAction.self, from: Data(old.utf8)).server, "之前的设备不带主机")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.codeTabHosts))
    }
}
