import XCTest
@testable import uTermMobile

/// 重连（同一个终端接上新的后端）时，上一条连接上的程序设过的光标形状（DECSCUSR）复位成设置里的：复位序列 `CSI 0 q`
/// 经输出泵进了影子和画面的同一条字节流，排在新连接的输出前面。全新的终端不发。同 Mac 的 `TerminalSessionTests`。
@MainActor
final class TerminalReconnectCursorTests: XCTestCase {

    /// 只吐给定字节的后端。
    actor ScriptedBackend: TerminalBackend {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        private nonisolated let output: AsyncStream<TerminalOutputItem>.Continuation
        nonisolated let exitStream = AsyncStream<Void> { _ in }

        init() {
            (outputItems, output) = AsyncStream<TerminalOutputItem>.makeStream()
        }

        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async { output.finish() }
        nonisolated func emit(_ text: String) { output.yield(.bytes(Data(text.utf8))) }
    }

    /// 泵的 tap 看到的全部字节（影子刚解析完、交给画面之前）。
    private final class Fed: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var all: Data { lock.withLock { data } }
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        func clear() { lock.withLock { data.removeAll() } }
    }

    func testReconnectResetsTheCursorShapeAProgramSet() async throws {
        let bridge = GhosttyTerminalBridge(controller: GhosttyProbeHost.controller)
        let fed = Fed()
        bridge.outputPump.onFed = { fed.append($0) }

        let first = ScriptedBackend()
        bridge.bind(first)
        XCTAssertNil(fed.all.range(of: TerminalOutputPump.resetCursorShape), "全新的终端不用复位")
        first.emit("\u{1B}[6 q$ ")
        let gotFirst = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) {
            bridge.shadow.viewportText().contains("$")
        }
        XCTAssertTrue(gotFirst)

        fed.clear()
        let second = ScriptedBackend()
        bridge.bind(second)
        second.emit("again")
        let gotSecond = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) {
            bridge.shadow.viewportText().contains("again")
        }
        XCTAssertTrue(gotSecond)
        let after = fed.all
        let reset = try XCTUnwrap(after.range(of: TerminalOutputPump.resetCursorShape), "重连后要复位光标形状")
        let output = try XCTUnwrap(after.range(of: Data("again".utf8)))
        XCTAssertLessThan(reset.lowerBound, output.lowerBound, "复位排在新连接的输出前面")
        bridge.unbind()
    }
}
