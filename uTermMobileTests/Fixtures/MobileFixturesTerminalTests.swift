import SwiftUI
import SwiftData
import XCTest
@testable import uTermMobile

/// `MobileFixturesTerminal.swift` 的自证测试 —— 假传输真的按脚本吐、真的回显、
/// 真的能断线重连，注入口真的把 `SSHConnection` 换掉了。
///
/// 这些是探针读数的前提：假传输要是不吐字节，`term-1x2000` 那一档量到的是
/// 「一台什么都不干的终端」——又快又稳又好看，什么都没测到。
@MainActor
final class MobileFixturesTerminalTests: XCTestCase {

    private func host() throws -> (ModelContainer, ServerProfile, HostKeyChallengeRelay) {
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        return (c, h, HostKeyChallengeRelay())
    }

    // MARK: 注入口

    /// 默认工厂就是真 SSH —— 生产路径没被改掉。
    func testLiveFactoryStillBuildsSSHConnection() async throws {
        let (c, h, relay) = try host()
        // `SSHAuthResolver` 在没有 keychain 材料时可能抛 —— 两种结果都算通过，
        // 关键是**没有走到假传输**：要么造出 `SSHConnection`，要么抛认证错。
        do {
            let backend = try await MobileTerminalTransportFactory.live.make(
                MobileTerminalTransportRequest(profile: h, container: c, relay: relay))
            XCTAssertTrue(backend is SSHConnection,
                          "默认工厂造出来的不是 SSHConnection：\(type(of: backend))")
        } catch {
            print("[live-factory] 认证材料解析失败（模拟器上无 keychain 材料，预期内）：\(error)")
        }
    }

    /// 注入的工厂真的被用上了：控制器 `start()` 之后能连上，而且没有任何真实网络。
    func testInjectedFactoryIsUsed() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        XCTAssertEqual(controller.state, .idle)
        controller.start(profile: h, container: c, relay: relay)
        let probeOK0 = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(probeOK0)
        XCTAssertEqual(handles.issuedCount, 1)
        let ledger = await handles.latest!.ledger
        XCTAssertEqual(ledger.connectCount, 1)
        controller.close()
    }

    /// `TermTab` 也能注入 —— 探针挂整屏靠这个。
    func testTermTabAcceptsInjectedFactory() async throws {
        let (c, h, relay) = try host()
        let (tab, handles) = MobileFakeTerminal.tab(host: h, .idle)
        tab.controller.start(profile: h, container: c, relay: relay)
        let probeOK1 = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(probeOK1)
        XCTAssertEqual(handles.issuedCount, 1)
        tab.controller.close()
    }

    // MARK: 节拍

    /// 按节拍吐：1 秒的 600 行/秒脚本，实际吐出的行数落在 ±35% 内。
    ///
    /// 松是有理由的：模拟器上的 `Task.sleep(20ms)` 本身有调度余量（README 基线里
    /// `Task.sleep` 拍比恒在 0.89~0.90），而且并发跑三条 xcodebuild 时更糙。
    /// 这条钉的是「节拍生效」，不是「节拍精确」。
    func testScriptPacesOutput() async throws {
        let transport = MobileFakeTerminalTransport(
            script: MobileFakeTerminalScript(linesPerSecond: 600, seconds: 1, corpus: .plain))
        var received = 0
        let collector = Task {
            for await chunk in transport.outputStream {
                received += chunk.count
                if received > 0, await transport.ledger.scriptFinished { break }
            }
        }
        try await transport.connect()
        try await Task.sleep(for: .milliseconds(1600))
        collector.cancel()
        let ledger = await transport.ledger
        print("[fake-pace] emitted=\(ledger.linesEmitted) lines / \(ledger.bytesEmitted) bytes")
        XCTAssertGreaterThan(ledger.linesEmitted, 390, "吐得太少——节拍没生效")
        XCTAssertLessThan(ledger.linesEmitted, 810, "吐得太多——节拍算错了")
        await transport.close()
    }

    /// 三种语料都带该有的转义序列。
    func testCorpusShapes() {
        let plain = MobileFakeTerminalCorpus.line(3, corpus: .plain, columns: 80)
        XCTAssertFalse(plain.contains("\u{1B}"), "plain 档不该有转义序列")
        XCTAssertTrue(plain.hasSuffix("\r\n"))

        let color = MobileFakeTerminalCorpus.line(3, corpus: .ansiColor, columns: 80)
        XCTAssertTrue(color.contains("\u{1B}[1m"), "缺加粗 SGR")
        XCTAssertTrue(color.contains("\u{1B}[0m"), "缺复位 SGR")

        let cursor = MobileFakeTerminalCorpus.line(3, corpus: .cursorHeavy, columns: 80)
        XCTAssertTrue(cursor.contains("\u{1B}[K"), "缺行内擦除")
        XCTAssertTrue(cursor.contains("\u{1B}7"), "缺光标保存")

        // 确定性：同 index 同输出。
        XCTAssertEqual(MobileFakeTerminalCorpus.line(17, corpus: .ansiColor, columns: 80),
                       MobileFakeTerminalCorpus.line(17, corpus: .ansiColor, columns: 80))
    }

    // MARK: 回显与上行

    /// `sendText` 走到传输，并按脚本回显。
    func testInputEchoesBack() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        controller.start(profile: h, container: c, relay: relay)
        let probeOK2 = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(probeOK2)

        controller.sendText("echo hi\n")
        let transport = handles.latest!
        // 上行是 `Task { await connection.write(...) }`，等它落地。
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) { false }
        let ledger = await transport.ledger
        XCTAssertEqual(ledger.writtenBytes, "echo hi\n".utf8.count)
        let text = await transport.writtenText
        XCTAssertEqual(text, "echo hi\n")
        // 回显：写进去的字节原样回到输出流，因此 `bytesEmitted` 也涨了同样多。
        XCTAssertEqual(ledger.bytesEmitted, ledger.writtenBytes)
        controller.close()
    }

    /// 尺寸早于传输就绪（首次排布、重连）：接上后要补发，否则 PTY 一直停在默认大小。
    func testSizeReportedBeforeConnectReachesTransport() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        controller.terminal.input.reportSize(cols: 57, rows: 23)
        controller.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        _ = await MobileFakeTerminal.waitUntil(timeout: .milliseconds(300)) { false }
        let ledger = await handles.latest!.ledger
        XCTAssertEqual(ledger.lastCols, 57)
        XCTAssertEqual(ledger.lastRows, 23)
        controller.close()
    }

    /// 一连串尺寸变化只把最后一个告诉远端：每发一次远端就收一个 SIGWINCH，全屏程序整屏重绘一遍。
    func testResizeBurstReachesTransportOnce() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        controller.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        for cols in stride(from: UInt16(98), through: 55, by: -4) {
            controller.terminal.input.reportSize(cols: cols, rows: 70)
        }
        controller.terminal.input.reportSize(cols: 55, rows: 81)
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(1)) { false }
        let ledger = await handles.latest!.ledger
        XCTAssertEqual(ledger.resizeCount, 1)
        XCTAssertEqual(ledger.lastCols, 55)
        XCTAssertEqual(ledger.lastRows, 81)
        controller.close()
    }

    /// `resize` 走到传输。
    func testResizeReachesTransport() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        controller.start(profile: h, container: c, relay: relay)
        let probeOK3 = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(probeOK3)
        controller.terminal.input.reportSize(cols: 132, rows: 43)
        let transport = handles.latest!
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(1)) { false }
        let ledger = await transport.ledger
        XCTAssertEqual(ledger.resizeCount, 1)
        XCTAssertEqual(ledger.lastCols, 132)
        XCTAssertEqual(ledger.lastRows, 43)
        controller.close()
    }

    // MARK: 断线 / 重连

    /// 断线：传输往 `exitStream` 送一个元素 → 控制器翻 `.disconnected`。
    func testSimulatedDropClosesSession() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 60, seconds: 30))
        controller.start(profile: h, container: c, relay: relay)
        let probeOK4 = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(probeOK4)
        await handles.latest!.simulateDrop()
        let probeOK5 = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            controller.state == .disconnected
        }
        XCTAssertTrue(probeOK5, "断线后应当翻 .disconnected，实际 \(controller.state)")
        controller.close()
    }

    /// OSC 0 / 2 标题：程序清空标题、或连接断开后都清掉，标签回到主机名（对齐 mac `TerminalSession`）。
    func testShellTitleClearsOnEmptyTitleAndOnDrop() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 60, seconds: 30))
        controller.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        controller.receiveShellTitle("  vim a.txt \n")
        XCTAssertEqual(controller.shellTitle, "vim a.txt")
        controller.receiveShellTitle(" ")
        XCTAssertNil(controller.shellTitle, "程序清空标题时应当清掉")
        controller.receiveShellTitle("htop")
        await handles.latest!.simulateDrop()
        let dropped = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            controller.state == .disconnected
        }
        XCTAssertTrue(dropped)
        XCTAssertNil(controller.shellTitle, "断开后不该还挂着旧标题")
        controller.close()
    }

    /// 重连：第一条传输 `connect()` 抛错 → `.failed` → `restart()` → 第二条连上。
    /// 走的是产品自己的重试路径（连接中页「重试」按钮），不是夹具自己造的。
    func testFailThenRestartReconnects() async throws {
        let (c, h, relay) = try host()
        let (controller, handles) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0,
                                     connectFailure: "假传输：第一次故意连不上"),
            MobileFakeTerminalScript(linesPerSecond: 60, seconds: 5))
        controller.start(profile: h, container: c, relay: relay)
        let probeOK6 = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            if case .failed = controller.state { return true }
            return false
        }
        XCTAssertTrue(probeOK6, "第一条传输应当失败，实际 \(controller.state)")
        XCTAssertEqual(handles.issuedCount, 1)

        controller.restart()
        let probeOK7 = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(probeOK7, "重连后应当 .connected，实际 \(controller.state)")
        XCTAssertEqual(handles.issuedCount, 2, "重连没有向工厂再要一条传输")
        let second = await handles.latest!.ledger
        XCTAssertEqual(second.generation, 1)
        XCTAssertEqual(second.connectCount, 1)
        controller.close()
    }

    /// 认证材料解析失败（工厂抛错）→ 控制器 `.failed` 且不建任何传输。
    func testFactoryThrowSurfacesAsFailed() async throws {
        let (c, h, relay) = try host()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "钥匙串里没有这把密钥" } }
        let controller = MobileTerminalController(
            transportFactory: MobileTerminalTransportFactory { _ in throw Boom() })
        controller.start(profile: h, container: c, relay: relay)
        // 工厂是 async（钥匙串读取离开主线程），失败态在下一跳落地。
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            if case .failed = controller.state { return true }
            return false
        }
        guard case .failed(let message) = controller.state else {
            return XCTFail("应当是 .failed，实际 \(controller.state)")
        }
        XCTAssertTrue(message.hasPrefix("凭据解析失败："), "错误文案变了：\(message)")
        XCTAssertTrue(message.contains("钥匙串里没有这把密钥"))
    }

    // MARK: 字节真的进了终端

    /// 端到端：假传输吐的字节，经入站任务与 `TerminalOutputPump` 的分流，真的进了终端——
    /// 影子终端（永远在吃、当场同步解析）里读得到语料的文字；画面的 surface 就绪了的话，它的视口里也读得到。
    func testBytesReachTerminalBuffer() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (c, h, relay) = try host()
        let (tab, handles) = MobileFakeTerminal.tab(
            host: h, MobileFakeTerminalScript(linesPerSecond: 400, seconds: 6, corpus: .ansiColor))
        let rig = MobileProbeRig(label: "fake-term-e2e")
        rig.mount(TerminalSessionBody(tab: tab, isActive: true, onClose: {})
            .environment(MobileStore())
            .environment(\.mAccent, M.accent)
            .modelContainer(c))
        tab.controller.start(profile: h, container: c, relay: relay)
        let probeOK8 = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(probeOK8)

        let terminal = tab.controller.terminal
        let before = MobileTerminalConsumption.read(tab.controller)
        try await Task.sleep(for: .seconds(3))
        rig.layout()
        let after = MobileTerminalConsumption.read(tab.controller)
        let ledger = await handles.latest!.ledger
        print("[fake-term-e2e] emitted=\(ledger.linesEmitted) advance=\(after.advanced - before.advanced) "
            + "top=\(after.topRow) fed=\(after.fedBytes - before.fedBytes)B")
        XCTAssertGreaterThan(ledger.linesEmitted, 400, "脚本没吐够")
        XCTAssertGreaterThan(after.fedBytes, before.fedBytes, "字节没进影子终端 —— 入站链路断了")
        XCTAssertGreaterThan(after.advanced, before.advanced, "影子终端吃了字节却没有推进行数")
        // 语料每行都带「处理批次 #<序号>」：解析出来的文字里要读得到（不只是字节数在涨）。
        let marker = "处理批次 #"
        let recent = terminal.shadow.recentLines(40).lines.joined(separator: "\n")
        XCTAssertTrue(recent.contains(marker), "影子终端最近 40 行里没有语料：\(recent.suffix(200))")
        XCTAssertTrue(terminal.shadow.viewportText().contains(marker), "影子终端的视口里没有语料")

        // 画面：surface 建好并接上实时字节之后，它的视口里也该有语料（就绪之前的字节由一次回放补上）。
        let surfaceReady = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            terminal.isSurfaceReady && terminal.outputPump.isFeedingSurface
        }
        XCTAssertTrue(surfaceReady, "终端挂在窗口里 3 秒了 surface 还没接上实时字节："
            + "ready=\(terminal.isSurfaceReady) feeding=\(terminal.outputPump.isFeedingSurface)")
        if surfaceReady {
            let reached = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) {
                terminal.session.readViewportText()?.contains(marker) == true
            }
            XCTAssertTrue(reached, "字节没进画面（surface 的视口里没有语料）")
        }
        tab.controller.close()
        await rig.close()
    }
}
