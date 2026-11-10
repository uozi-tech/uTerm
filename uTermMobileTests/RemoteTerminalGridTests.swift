import GhosttyTerminal
import os
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 远控标签（手机是主控端）接入时的网格对齐，同 Mac 的 `RemoteAttachGridTests`（那边两端都是真会话；手机上没有被控端，
/// 这里的「Mac」是一个假后端：自己一个影子终端，按主控端报来的尺寸钉好再拍快照，之后的输出原样转发）。
///
/// 走生产路径：`MobileTerminalController` 的建连任务 → `GhosttyTerminalBridge.bind(any TerminalBackend)` → 输出泵。
/// 后端只实现 `outputItems`（读 `outputStream` 记一次），所以也核了「经 `any TerminalBackend` 调到的是后端自己的
/// `outputItems`」——以前它只写在协议扩展里，远控标签一个字节都收不到。
///
/// 要的结果：本地画面、本地影子、「Mac」三者同一个网格、同一屏内容；先建视图的话第一张快照就是本地网格，画面不必停下来等；
/// 回放进画面时影子与画面的网格一致。
@MainActor
final class RemoteTerminalGridTests: XCTestCase {

    /// 假的被控端：一个影子终端。
    actor FakeMirrorHost: TerminalBackend {
        nonisolated let host: ShadowTerminal
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        private nonisolated let output: AsyncStream<TerminalOutputItem>.Continuation
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated var mirrorsRemoteGrid: Bool { true }
        /// 有人读了 `outputStream`（远控后端没有纯字节流可给，读它就是走错了路）。
        nonisolated let outputStreamReads = OSAllocatedUnfairLock(initialState: 0)
        nonisolated var outputStream: AsyncStream<Data> {
            outputStreamReads.withLock { $0 += 1 }
            return AsyncStream { $0.finish() }
        }
        private var attached = false
        /// 每张快照拍下时的网格。
        private(set) var snapshotGrids: [String] = []

        init(cols: UInt16, rows: UInt16, text: String) {
            host = ShadowTerminal(cols: cols, rows: rows, options: GhosttyTerminalBridge.scrollback.shadowOptions)
            host.feed(Data(text.utf8))
            (outputItems, output) = AsyncStream<TerminalOutputItem>.makeStream()
            exitStream = AsyncStream { _ in }
        }

        func connect() async throws {
            attached = true
            sendSnapshot()
        }

        func write(_ data: Data) async {}

        /// 真被控端钉尺寸是异步的（视图改尺寸 → 引擎在 IO 线程上改网格 → 才拍快照）。打开它，接入之后的改尺寸先挂着，
        /// 由用例 `applyPendingResize()` 放行，好在中间这段核主控端的状态。
        private var holdsResizes = false
        private(set) var pendingResize: String?
        private var pending: (cols: UInt16, rows: UInt16)?

        func setHoldsResizes(_ holds: Bool) { holdsResizes = holds }

        /// 同真被控端：钉住新尺寸再发一张快照；尺寸没变不发。接入之前只记下尺寸。
        func resize(cols: UInt16, rows: UInt16) async {
            guard Int(cols) != host.size.cols || Int(rows) != host.size.rows else { return }
            if attached, holdsResizes {
                pending = (cols, rows)
                pendingResize = "\(cols)x\(rows)"
                return
            }
            host.resize(cols: cols, rows: rows)
            if attached { sendSnapshot() }
        }

        func applyPendingResize() {
            guard let pending else { return }
            self.pending = nil
            pendingResize = nil
            host.resize(cols: pending.cols, rows: pending.rows)
            sendSnapshot()
        }

        func close() async { output.finish() }

        func feed(_ text: String) {
            let data = Data(text.utf8)
            host.feed(data)
            if attached { output.yield(.bytes(data)) }
        }

        private func sendSnapshot() {
            snapshotGrids.append("\(host.size.cols)x\(host.size.rows)")
            output.yield(.snapshot(try! host.snapshot()))
        }
    }

    /// 回放进画面时影子的网格与 surface 的终端在用的网格（IO 线程报过的那个）。
    private final class ReplayGrids: @unchecked Sendable {
        private let lock = NSLock()
        private var grids: [String] = []
        var all: [String] { lock.withLock { grids } }
        func record(_ value: String) { lock.withLock { grids.append(value) } }
    }

    private func recordReplays(of bridge: GhosttyTerminalBridge) -> ReplayGrids {
        let grids = ReplayGrids()
        let shadow = bridge.shadow, session = bridge.session
        bridge.outputPump.onReplayed = {
            let s = shadow.size
            let g = session.reportedGrid.map { "\($0.columns)x\($0.rows)" } ?? "nil"
            grids.record("\(s.cols)x\(s.rows)/\(g)")
        }
        return grids
    }

    private static let hostText = (1...40).map { "host line \($0)" }.joined(separator: "\r\n") + "\r\n$ "

    /// 两种读法对行尾空格处理不同：比之前去掉行尾空白。
    private static func trimmed(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    private func makeController(_ fake: FakeMirrorHost) throws -> (MobileTerminalController, ServerProfile, ModelContainer) {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let profile = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let controller = MobileTerminalController(transportFactory: MobileTerminalTransportFactory { _ in fake })
        return (controller, profile, container)
    }

    private func mount(_ bridge: GhosttyTerminalBridge, size: CGSize) throws -> UIWindow {
        let window = try makeSpikeWindow(size: size)
        bridge.view.frame = CGRect(origin: .zero, size: size)
        window.addSubview(bridge.view)
        return window
    }

    private func assertMirrored(_ bridge: GhosttyTerminalBridge, _ fake: FakeMirrorHost, replays: ReplayGrids,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let host = fake.host
        let aligned = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            guard let grid = bridge.grid else { return false }
            bridge.session.waitForPendingOutput()
            return host.size == grid && bridge.shadow.size == grid
                && bridge.shadow.viewportText() == host.viewportText()
                && Self.trimmed(bridge.session.readViewportText() ?? "") == Self.trimmed(host.viewportText())
        }
        XCTAssertTrue(aligned, "「Mac」、本地影子、本地画面应当同一个网格、同一屏内容："
                      + "「Mac」\(host.size)，本地影子 \(bridge.shadow.size)，本地网格 \(String(describing: bridge.grid))"
                      + "\n「Mac」：\(host.viewportText().debugDescription)"
                      + "\n本地影子：\(bridge.shadow.viewportText().debugDescription)"
                      + "\n本地画面：\((bridge.session.readViewportText() ?? "").debugDescription)"
                      + "\n回放：\(replays.all)；泵：\(bridge.outputPump.currentStats)",
                      file: file, line: line)
        for entry in replays.all {
            let parts = entry.split(separator: "/")
            XCTAssertEqual(parts.first, parts.last, "回放时影子与画面的网格不一致：\(entry)", file: file, line: line)
        }
    }

    /// 本地网格变了、「Mac」还没钉好的那一段：本地影子仍是「Mac」的网格和内容（这期间「Mac」按原网格出的字节照样对得上），
    /// 画面停着等；「Mac」钉好、发来同网格的快照之后三者一致。
    private func assertHeldUntilPinned(_ bridge: GhosttyTerminalBridge, _ fake: FakeMirrorHost, replays: ReplayGrids,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let measured = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { bridge.grid != nil }
        XCTAssertTrue(measured, "surface 没报网格", file: file, line: line)
        var asked: String?
        for _ in 0..<150 {
            asked = await fake.pendingResize
            if asked != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let grid = try XCTUnwrap(bridge.grid, file: file, line: line)
        XCTAssertEqual(asked, "\(grid.cols)x\(grid.rows)", "本地网格应当报给了「Mac」", file: file, line: line)
        let host = fake.host
        XCTAssertNotEqual(host.size.cols, grid.cols, "用例前提：「Mac」还在原网格", file: file, line: line)
        await fake.feed("\r\nwhile pinning \(UUID().uuidString.prefix(4))\r\n$ ")
        let followed = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) {
            bridge.shadow.size == host.size && bridge.shadow.viewportText() == host.viewportText()
        }
        XCTAssertTrue(followed, "「Mac」钉好之前本地影子应当仍跟着它：「Mac」\(host.size)，本地影子 \(bridge.shadow.size)"
                      + "\n「Mac」：\(host.viewportText().suffix(120).debugDescription)"
                      + "\n本地影子：\(bridge.shadow.viewportText().suffix(120).debugDescription)", file: file, line: line)
        XCTAssertTrue(bridge.outputPump.isHoldingForGrid, "网格对不上时画面应当停着等", file: file, line: line)
        await fake.applyPendingResize()
        await assertMirrored(bridge, fake, replays: replays, file: file, line: line)
        XCTAssertFalse(bridge.outputPump.isHoldingForGrid, file: file, line: line)
    }

    /// 画面先建好（网格已知）再接入：接入请求带着本地网格，「Mac」钉好之后才拍第一张快照——只发这一张，
    /// 画面从没停下来等过对齐。之后的输出原样跟上。
    func test_attach_with_known_size_sends_one_snapshot_at_the_local_grid() async throws {
        let fake = FakeMirrorHost(cols: 100, rows: 30, text: Self.hostText)
        let (controller, profile, container) = try makeController(fake)
        let bridge = controller.terminal
        let window = try mount(bridge, size: CGSize(width: 393, height: 500))
        defer { controller.close(); bridge.view.removeFromSuperview(); window.isHidden = true }
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface && bridge.grid != nil
        }
        XCTAssertTrue(ready, "surface 没建起来")
        let grid = try XCTUnwrap(bridge.grid)
        XCTAssertNotEqual(grid.cols, 100, "用例前提：两端网格不一样")
        let replays = recordReplays(of: bridge)

        controller.start(profile: profile, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        await assertMirrored(bridge, fake, replays: replays)
        XCTAssertEqual(bridge.outputPump.currentStats.gridHolds, 0, "第一张快照就是本地网格，不必停画面等")
        let snapshots = await fake.snapshotGrids
        XCTAssertEqual(snapshots, ["\(grid.cols)x\(grid.rows)"], "只发一张、按本地网格拍")
        XCTAssertEqual(fake.outputStreamReads.withLock { $0 }, 0, "读的应当是后端自己的 outputItems")

        await fake.feed("echo after\r\nafter")
        await assertMirrored(bridge, fake, replays: replays)
        XCTAssertTrue(bridge.shadow.viewportText().contains("after"))
    }

    /// 先接入、画面后建（标签还没露出过）：按「Mac」原来的网格接入，影子照收快照；画面建好后报真实网格，对齐之前画面停着，
    /// 「Mac」按新网格钉好发来快照才回放。之后改窗格大小也一样。
    func test_attach_before_the_view_exists_holds_the_picture_until_aligned() async throws {
        let fake = FakeMirrorHost(cols: 100, rows: 30, text: Self.hostText)
        let (controller, profile, container) = try makeController(fake)
        let bridge = controller.terminal
        defer { controller.close() }
        let replays = recordReplays(of: bridge)

        controller.start(profile: profile, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let gotSnapshot = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            bridge.shadow.viewportText().contains("host line 40")
        }
        XCTAssertTrue(gotSnapshot, "没有画面时影子照样收快照：\(bridge.shadow.viewportText().suffix(80))")
        XCTAssertEqual(bridge.shadow.size.cols, 100, "影子跟着「Mac」的网格")

        // 「Mac」钉新尺寸要一会儿：这段时间里它还按原网格出字节。
        await fake.setHoldsResizes(true)
        let window = try mount(bridge, size: CGSize(width: 393, height: 500))
        defer { bridge.view.removeFromSuperview(); window.isHidden = true }
        try await assertHeldUntilPinned(bridge, fake, replays: replays)
        XCTAssertEqual(bridge.outputPump.currentStats.gridHoldTimeouts, 0, "「Mac」应当在超时之前钉好")

        // 改窗格大小：一样停画面等对齐，之后一致。
        let before = try XCTUnwrap(bridge.grid)
        bridge.view.frame = CGRect(x: 0, y: 0, width: 330, height: 420)
        bridge.view.layoutIfNeeded()
        let resized = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            bridge.grid.map { $0 != before } ?? false
        }
        XCTAssertTrue(resized, "本地网格应当变了")
        try await assertHeldUntilPinned(bridge, fake, replays: replays)
        XCTAssertEqual(bridge.outputPump.currentStats.gridHoldTimeouts, 0)
        XCTAssertEqual(fake.outputStreamReads.withLock { $0 }, 0)
    }
}
