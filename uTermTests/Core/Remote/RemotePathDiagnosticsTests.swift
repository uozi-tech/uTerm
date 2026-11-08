import Foundation
import XCTest
@testable import uTerm

/// 网络诊断：共享的状态模型、汇总与历史分组，以及 Mac 诊断窗口里的几个纯函数。
@MainActor
final class RemotePathDiagnosticsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "RemotePathDiagnosticsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func result(_ mode: RemotePathProbeMode, connected: Bool, failure: String? = nil, runID: UUID? = nil,
                        roundTrip: Double? = nil) -> RemotePathProbeResult {
        var result = RemotePathProbeResult(runID: runID, mode: mode, connected: connected, failure: failure)
        result.roundTripMillis = roundTrip
        return result
    }

    func testFailuresKeepFirstSeenOrderAndCountRepeats() {
        let results = [
            result(.relay, connected: false, failure: "超时"),
            result(.relay, connected: true),
            result(.relay, connected: false, failure: "中继拒绝"),
            result(.relay, connected: false, failure: "超时"),
            result(.relay, connected: false),
            result(.localNetwork, connected: false, failure: "别的路"),
        ]
        XCTAssertEqual(RemotePathProbeSummary.failures(of: .relay, in: results), "超时 ×2；中继拒绝；未知")
        XCTAssertEqual(RemotePathProbeSummary.failures(of: .directIPv4, in: results), "")
    }

    func testMillisFormatting() {
        XCTAssertEqual(RemotePathProbeSummary.millis(3.24), "3.2 ms")
        XCTAssertEqual(RemotePathProbeSummary.millis(42.6), "43 ms")
        XCTAssertNil(RemotePathProbeSummary.millis(nil))
    }

    func testRunsGroupNewestFirstAndChronologicalWithin() {
        let older = UUID(), newer = UUID()
        // 记录本身是最新在前的平铺列表。
        var a = result(.relay, connected: true, runID: newer); a.round = 2
        var b = result(.relay, connected: true, runID: newer); b.round = 1
        let legacy = result(.relay, connected: false)
        let c = result(.localNetwork, connected: true, runID: older)
        let runs = RemotePathMatrixLog.runs([a, b, legacy, c])
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].map(\.round), [1, 2])
        XCTAssertEqual(runs[1].map(\.id), [legacy.id])
        XCTAssertEqual(runs[2].map(\.id), [c.id])
    }

    func testExportTextHasSummariesThenDetails() {
        let results = [result(.relay, connected: true, roundTrip: 20), result(.relay, connected: false, failure: "超时")]
        let lines = RemotePathMatrixLog.exportText(results).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("中继：成功 1/2"), lines[0])
        XCTAssertEqual(lines[1], "")
        XCTAssertTrue(lines[3].contains("失败(超时)"), lines[3])
    }

    func testNetworkLabel() {
        XCTAssertEqual(RemoteNetworkLabel.label(wifi: true, cellular: true, wired: false, ipv6: true), "Wi-Fi · 有 IPv6")
        XCTAssertEqual(RemoteNetworkLabel.label(wifi: false, cellular: false, wired: true, ipv6: false), "有线 · 无 IPv6")
        XCTAssertEqual(RemoteNetworkLabel.label(wifi: false, cellular: false, wired: false, ipv6: false), "其他 · 无 IPv6")
    }

    /// 没有局域网端点也没有中继：每条路立刻判不通，结果逐条记进日志，跑完能看到「上次结果」与结论。
    func testModelRunRecordsEveryResultAndFinishes() async throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let key = try identity.localIdentity().publicKey.rawRepresentation
        let peer = RemotePeer(id: UUID(), name: "办公室 Mac", publicKey: key, pairedAt: .now,
                              platform: RemoteDevicePlatform.mac.rawValue)
        let runner = RemotePathMatrixRunner(identity: identity, localID: UUID())
        let log = RemotePathMatrixLog(defaults: defaults)
        let model = RemotePathDiagnosticsModel(log: log, networkLabel: { "有线 · 有 IPv6" })

        model.run(runner: runner, peer: peer, rounds: 2, modes: [.localNetwork, .relay], note: "测试")
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.currentTotal, 4)
        XCTAssertEqual(model.progressText, "第 1 轮 · 正在测试局域网（1/4）")
        await model.waitUntilFinished()

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.current.map(\.mode), [.localNetwork, .relay, .localNetwork, .relay])
        XCTAssertTrue(model.current.allSatisfy { !$0.connected && $0.note == "测试" && $0.network == "有线 · 有 IPv6" })
        XCTAssertEqual(model.current.first?.failure, "Mac 不在这个局域网里")
        XCTAssertEqual(model.current.last?.failure, "没有配置中继")
        XCTAssertEqual(model.historyCount, 4)
        XCTAssertEqual(model.lastRun.map(\.id), model.current.map(\.id))
        XCTAssertEqual(model.untested, [.directIPv6, .directIPv4])
        XCTAssertNil(RemotePathVerdict.chosen(model.summaries))

        // 新开一个模型（重开窗口）：读回上次结果。
        let reopened = RemotePathDiagnosticsModel(log: log)
        reopened.reloadHistory()
        XCTAssertEqual(reopened.shown.map(\.id), model.current.map(\.id))

        model.clearHistory()
        XCTAssertEqual(model.historyCount, 0)
        XCTAssertTrue(model.shown.isEmpty)
    }

    func testModelRefusesEmptyModes() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let peer = RemotePeer(id: UUID(), name: "Mac", publicKey: try identity.localIdentity().publicKey.rawRepresentation,
                              pairedAt: .now, platform: RemoteDevicePlatform.mac.rawValue)
        let model = RemotePathDiagnosticsModel(log: RemotePathMatrixLog(defaults: defaults))
        model.run(runner: RemotePathMatrixRunner(identity: identity, localID: UUID()), peer: peer, rounds: 1, modes: [],
                  note: "")
        XCTAssertFalse(model.isRunning)
    }

    func testWindowHelpers() {
        XCTAssertEqual(RemoteDiagnosticsContent.estimate(modes: 4, rounds: 2), "40 秒")
        XCTAssertEqual(RemoteDiagnosticsContent.estimate(modes: 4, rounds: 3), "1 分钟")
        XCTAssertEqual(RemoteDiagnosticsContent.estimate(modes: 4, rounds: 10), "3 分钟")
        var run = [result(.relay, connected: true)]
        run[0].network = "Wi-Fi · 有 IPv6"
        XCTAssertEqual(RemoteDiagnosticsContent.context(run), "Wi-Fi · 有 IPv6")
        run[0].note = "家里"
        XCTAssertEqual(RemoteDiagnosticsContent.context(run), "Wi-Fi · 有 IPv6 · 家里")
        XCTAssertNil(RemoteDiagnosticsContent.context([]))
    }
}
