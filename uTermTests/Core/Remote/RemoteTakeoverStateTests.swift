import XCTest
@testable import uTerm

/// 两端共用的远控对账与展示逻辑：接管状态机、手排检测、标签名，以及连接 / 诊断页上的文字。
final class RemoteTakeoverStateTests: XCTestCase {

    // MARK: - 接管状态机

    func test_update_reports_gone_and_fresh_like_the_follower() {
        let a = UUID(), b = UUID(), c = UUID()
        var state = RemoteTakeoverState(takingOver: [a, b])
        var step = state.update([a, b])
        XCTAssertTrue(step.gone.isEmpty)
        XCTAssertTrue(step.fresh.isEmpty, "接管时已有的不重开")
        step = state.update([a, c])
        XCTAssertEqual(step.gone, [b])
        XCTAssertEqual(step.fresh, [c])
        XCTAssertFalse(step.firstListIsEmpty)
    }

    func test_first_list_empty_only_when_waiting_for_the_first_list() {
        var waiting = RemoteTakeoverState(takingOver: [], listReceived: false)
        XCTAssertTrue(waiting.awaitingFirstList)
        XCTAssertTrue(waiting.update([]).firstListIsEmpty, "接管时还没列表，第一份是空的")
        XCTAssertFalse(waiting.awaitingFirstList)
        XCTAssertFalse(waiting.update([]).firstListIsEmpty, "只算第一份")

        var nonEmpty = RemoteTakeoverState(takingOver: [], listReceived: false)
        XCTAssertFalse(nonEmpty.update([UUID()]).firstListIsEmpty, "第一份不空")
        XCTAssertFalse(nonEmpty.awaitingFirstList)

        var received = RemoteTakeoverState(takingOver: [])
        XCTAssertFalse(received.awaitingFirstList)
        XCTAssertFalse(received.update([]).firstListIsEmpty, "接管时列表已到：交给调用方当场决定，不再报")
    }

    func test_arrangement_stops_after_arranging_by_hand() {
        let order = [UUID(), UUID()]
        var state = RemoteTakeoverState(takingOver: order)
        XCTAssertEqual(state.arrangement(order), order)
        XCTAssertNil(state.arrangement(nil), "老 Mac 不发排位：不动")
        state.noteArrangedByHand()
        XCTAssertTrue(state.arrangedByHand)
        XCTAssertNil(state.arrangement(order), "亲手排过之后不再跟 Mac 的顺序")
        _ = state.update(order)
        XCTAssertTrue(state.arrangedByHand, "列表更新不清掉，直到重新接管")
    }

    /// 亲手排过之后，Mac 推来的顺序和本机的排法对上了（Mac 照本机排好了）就重新跟着 Mac；对不上（Mac 排不了）就保持本机的。
    func test_following_resumes_once_the_mac_order_matches_the_hand_arrangement() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var state = RemoteTakeoverState(takingOver: [a, b, c])
        state.noteArrangedByHand()

        state.noteMacOrder([a, b, c], layout: [[b, a, c]])
        XCTAssertTrue(state.arrangedByHand, "Mac 还没照着排（或排不了）：保持本机的排法")
        state.noteMacOrder(nil, layout: [[b, a, c]])
        XCTAssertTrue(state.arrangedByHand, "老 Mac 不发排位：保持")

        state.noteMacOrder([b, a, d, c], layout: [[b, a], [c]])
        XCTAssertFalse(state.arrangedByHand, "每一格都和 Mac 的顺序一致：重新跟着 Mac")
        XCTAssertEqual(state.arrangement([b, a, d, c]), [b, a, d, c])
    }

    // MARK: - 手排检测

    func test_reordered_by_hand_detects_relative_order_changes_within_a_group() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertFalse(RemoteTabArrangement.reorderedByHand(from: [[a, b, c]], to: [[a, b, c]]))
        XCTAssertTrue(RemoteTabArrangement.reorderedByHand(from: [[a, b, c]], to: [[b, a, c]]))
        XCTAssertTrue(RemoteTabArrangement.reorderedByHand(from: [[a, b, c]], to: [[a, c, b]]))
    }

    func test_reordered_by_hand_ignores_new_gone_and_cross_group_moves() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertFalse(RemoteTabArrangement.reorderedByHand(from: [[a, b]], to: [[d, a, b]]), "新开的插在哪都不算")
        XCTAssertFalse(RemoteTabArrangement.reorderedByHand(from: [[a, b, c]], to: [[a, c]]), "关掉的不算")
        XCTAssertFalse(RemoteTabArrangement.reorderedByHand(from: [[a, b, c]], to: [[a, c], [b]]),
                       "拆到别的组不算，各组各排各的")
        XCTAssertFalse(RemoteTabArrangement.reorderedByHand(from: [[a, b], [c]], to: [[c, a, b]]),
                       "从别的组并过来的不跟本组比")
        XCTAssertTrue(RemoteTabArrangement.reorderedByHand(from: [[a, b], [c, d]], to: [[a, b], [d, c]]),
                      "第二组里换了顺序")
        XCTAssertFalse(RemoteTabArrangement.reorderedByHand(from: [], to: [[a, b]]), "还没快照")
    }

    // MARK: - 标签名

    private func info(tabTitle: String?, title: String = "zsh") -> RemoteSessionInfo {
        RemoteSessionInfo(id: UUID(), serverID: UUID(), serverName: "测试主机", title: title,
                          windowKind: TerminalWindowKind.workspace, connectedAt: nil, tabTitle: tabTitle)
    }

    func test_remote_tab_title_prefers_the_mac_tab_title() {
        XCTAssertEqual(RemoteSessionInfo.remoteTabTitle(info(tabTitle: "部署"), shellTitle: "vim", fallback: "主机"), "部署")
        XCTAssertEqual(RemoteSessionInfo.remoteTabTitle(info(tabTitle: nil), shellTitle: "vim", fallback: "主机"), "vim",
                       "老 Mac 不发标签名：用终端自己的标题")
        XCTAssertEqual(RemoteSessionInfo.remoteTabTitle(info(tabTitle: nil, title: "web-01"), shellTitle: nil,
                                                        fallback: "主机"), "web-01")
        XCTAssertEqual(RemoteSessionInfo.remoteTabTitle(nil, shellTitle: nil, fallback: "主机"), "主机")
    }

    func test_remote_tab_title_is_clipped_like_local_tabs() {
        let long = String(repeating: "长", count: 40)
        let title = RemoteSessionInfo.remoteTabTitle(info(tabTitle: long), shellTitle: nil, fallback: "")
        XCTAssertEqual(title, TerminalTitle.clippedForTab(long))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThan(title.count, long.count)
    }

    // MARK: - 在哪能连上

    private func mac(source: RemoteMacDirectory.Mac.Source = .paired, onLAN: Bool,
                     onRelay: Bool) -> RemoteMacDirectory.Mac {
        RemoteMacDirectory.Mac(id: UUID().uuidString, deviceID: nil, name: "工作室",
                               publicKey: nil, source: source,
                               endpoint: onLAN ? .hostPort(host: "192.168.1.2", port: 1) : nil,
                               isOnRelay: onRelay)
    }

    func test_reachability_label_styles() {
        XCTAssertEqual(mac(onLAN: true, onRelay: true).reachabilityLabel(.status), "在线 · 局域网")
        XCTAssertEqual(mac(onLAN: false, onRelay: true).reachabilityLabel(.status), "在线 · 公网")
        XCTAssertEqual(mac(onLAN: false, onRelay: false).reachabilityLabel(.status), "不在线")
        XCTAssertEqual(mac(source: .nearby, onLAN: true, onRelay: false).reachabilityLabel(.status), "局域网 · 未配对")

        XCTAssertEqual(mac(onLAN: true, onRelay: true).reachabilityLabel(.path), "局域网")
        XCTAssertEqual(mac(onLAN: false, onRelay: true).reachabilityLabel(.path), "公网")
        XCTAssertEqual(mac(onLAN: false, onRelay: false).reachabilityLabel(.path), "不在线")

        XCTAssertEqual(mac(onLAN: true, onRelay: true).reachabilityLabel(.routes), "在线 · 局域网 · 中继")
        XCTAssertEqual(mac(onLAN: false, onRelay: true).reachabilityLabel(.routes), "在线 · 中继")
        XCTAssertEqual(mac(onLAN: false, onRelay: false).reachabilityLabel(.routes), "不在线")
    }

    func test_reachability_label_can_override_the_local_network_half() {
        // 「只走公网」时 endpoint 为 nil，诊断照样按 Bonjour 结果报局域网。
        let relayOnly = mac(onLAN: false, onRelay: true)
        XCTAssertEqual(relayOnly.reachabilityLabel(.routes, onLocalNetwork: true), "在线 · 局域网 · 中继")
        XCTAssertEqual(mac(onLAN: true, onRelay: false).reachabilityLabel(.routes, onLocalNetwork: false), "不在线")
    }

    // MARK: - 配对

    func test_pairing_code_is_grouped_in_threes() {
        XCTAssertEqual(RemotePairingCode.grouped("123456"), "123 456")
    }

    func test_invitation_summary_mentions_the_relay_and_trust() {
        var invitation = RemotePairingInvitation(macID: UUID(), macName: "工作室", macKey: Data(count: 32),
                                                 token: Data(count: RemotePairingInvitation.tokenLength))
        let lanOnly = invitation.summary
        XCTAssertTrue(lanOnly.contains("「工作室」"))
        XCTAssertTrue(lanOnly.contains("同一局域网"))
        XCTAssertTrue(lanOnly.hasSuffix("只接受你信任的人发来的邀请。"))
        XCTAssertTrue(lanOnly.contains("这台 Mac"), "本机是 Mac")

        invitation.relay = RemoteRelayConfig(name: "家里", host: "relay.example.com", port: 47310,
                                             relayID: "6f1c00aa", key: "k")
        let viaRelay = invitation.summary
        XCTAssertTrue(viaRelay.contains("中继「家里」"))
        XCTAssertFalse(viaRelay.contains("同一局域网"))
        XCTAssertTrue(viaRelay.hasSuffix("只接受你信任的人发来的邀请。"))
    }
}

/// 网络诊断页上两端共用的文字与状态。
final class RemotePathDiagnosticsPresentationTests: XCTestCase {

    private func summary(_ mode: RemotePathProbeMode, ok: Int, of attempts: Int = 3,
                         roundTrip: Double? = nil) -> RemotePathProbeSummary {
        RemotePathProbeSummary(mode: mode, attempts: attempts, successes: ok, medianSetupMillis: ok > 0 ? 100 : nil,
                               medianRoundTripMillis: ok > 0 ? roundTrip : nil, medianP95Millis: nil,
                               meanLossPercent: ok > 0 ? 0 : nil)
    }

    func test_enabled_modes_come_from_the_skipped_list() {
        XCTAssertEqual(RemotePathProbeMode.enabled(skipping: ""), RemotePathProbeMode.allCases)
        let skipped = RemotePathProbeMode.relay.rawValue + "," + RemotePathProbeMode.directIPv6.rawValue
        XCTAssertEqual(RemotePathProbeMode.enabled(skipping: skipped),
                       RemotePathProbeMode.allCases.filter { $0 != .relay && $0 != .directIPv6 })
        XCTAssertEqual(RemotePathProbeMode.enabled(skipping: "unknown"), RemotePathProbeMode.allCases,
                       "认不出的跳过项忽略")
    }

    func test_skipped_raw_round_trips_toggles() {
        var raw = RemotePathProbeMode.skippedRaw("", setting: .relay, enabled: false)
        XCTAssertEqual(raw, RemotePathProbeMode.relay.rawValue)
        XCTAssertFalse(RemotePathProbeMode.enabled(skipping: raw).contains(.relay))
        raw = RemotePathProbeMode.skippedRaw(raw, setting: .localNetwork, enabled: false)
        XCTAssertEqual(Set(RemotePathProbeMode.allCases).subtracting(RemotePathProbeMode.enabled(skipping: raw)),
                       [.relay, .localNetwork])
        raw = RemotePathProbeMode.skippedRaw(raw, setting: .relay, enabled: true)
        XCTAssertEqual(raw, RemotePathProbeMode.localNetwork.rawValue)
        XCTAssertEqual(RemotePathProbeMode.skippedRaw(raw, setting: .localNetwork, enabled: true), "")
    }

    func test_tone_by_pass_rate() {
        XCTAssertEqual(summary(.relay, ok: 3).tone, .passed)
        XCTAssertEqual(summary(.relay, ok: 1).tone, .partial)
        XCTAssertEqual(summary(.relay, ok: 0).tone, .failed)
    }

    func test_verdict_title_and_detail() {
        XCTAssertEqual(RemotePathVerdict.title(chosen: nil, untested: []), "现在无法连接这台 Mac")
        XCTAssertEqual(RemotePathVerdict.title(chosen: nil, untested: [.relay]), "测试过的路径都不通")
        let relay = summary(.relay, ok: 3, roundTrip: 99.6)
        XCTAssertEqual(RemotePathVerdict.title(chosen: relay, untested: []), "实际会走\(RemotePathProbeMode.relay.label)")

        let detail = RemotePathVerdict.detail(chosen: relay, untested: [], skipsLocalNetwork: false)
        XCTAssertTrue(detail.contains("往返约 100 ms"), detail)
        XCTAssertFalse(detail.contains("只走公网"))
        let skipping = RemotePathVerdict.detail(chosen: relay, untested: [.localNetwork], skipsLocalNetwork: true)
        XCTAssertTrue(skipping.contains("「只走公网」已打开"))
        XCTAssertTrue(skipping.contains("这次未测试\(RemotePathProbeMode.localNetwork.label)"))
        XCTAssertTrue(RemotePathVerdict.detail(chosen: nil, untested: [], skipsLocalNetwork: false)
            .hasPrefix("各路径的失败原因见下方。"))
        XCTAssertTrue(RemotePathVerdict.detail(chosen: summary(.relay, ok: 3), untested: [], skipsLocalNetwork: false)
            .contains("往返未测出"))
    }

    func test_context_is_nil_when_there_is_nothing_to_say() {
        XCTAssertNil(RemotePathMatrixLog.context([]))
    }

    func test_new_shell_plan_asks_only_with_recent_workspaces() {
        XCTAssertEqual(RemoteNewShellPlan(nil), .openDirectly, "老 Mac 不报工作区")
        let none = RemoteLocalWorkspaces(requestID: UUID(), home: "/Users/a", directories: [])
        XCTAssertEqual(RemoteNewShellPlan(none), .openDirectly)
        let some = RemoteLocalWorkspaces(requestID: UUID(), home: "/Users/a", directories: ["/Users/a/src"])
        XCTAssertEqual(RemoteNewShellPlan(some), .ask(some))
    }
}
