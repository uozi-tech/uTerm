import XCTest
@testable import uTerm

/// 两端共用的输入 / 尺寸通道（`TerminalInputChannel`）：写入与尺寸同一条 FIFO、同一轮内的尺寸合并、
/// 与上次发出的相同就不发、换绑定时补发尺寸、解绑后丢弃。
@MainActor
final class TerminalInputChannelTests: XCTestCase {

    /// 写入和尺寸记在同一条日志里，才看得出两者之间的先后。
    private actor RecordingBackend: TerminalBackend {
        enum Event: Equatable {
            case write(String)
            case resize(UInt16, UInt16)
            case connect
            case connected
        }

        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        private(set) var events: [Event] = []

        init() {
            outputItems = AsyncStream { $0.finish() }
            exitStream = AsyncStream { $0.finish() }
        }

        func connect() async throws {
            events.append(.connect)
            // 建连要一会儿（actor 可重入）：这期间有人写进来的话，日志里会插在 `.connected` 之前。
            try await Task.sleep(for: .milliseconds(30))
            events.append(.connected)
        }
        func write(_ data: Data) async { events.append(.write(String(decoding: data, as: UTF8.self))) }
        func resize(cols: UInt16, rows: UInt16) async { events.append(.resize(cols, rows)) }
        func close() async {}

        var resizes: [Event] { events.filter { if case .resize = $0 { true } else { false } } }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func waitForEvents(_ backend: RecordingBackend, count: Int) async -> [RecordingBackend.Event] {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let events = await backend.events
            if events.count >= count { return events }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await backend.events
    }

    /// 建连也走这条队列：绑定时补发的尺寸一定先到后端（SSH 拿它当 PTY 初始尺寸，远控的接入请求带上它）；建连期间的
    /// 键入排在建连后面。原来补发尺寸是另起的任务，赶不上建连，两端各在调用点先手动发一次尺寸。
    func testSizeQueuedAtBindReachesTheBackendBeforeConnect() async throws {
        let channel = TerminalInputChannel()
        channel.reportSize(cols: 100, rows: 40)
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: true)
        let connecting = Task { try await channel.connect(backend) }
        // 建连开始了再打字。
        _ = await waitForEvents(backend, count: 2)
        channel.write(Data("typed".utf8))
        try await connecting.value
        let events = await waitForEvents(backend, count: 4)
        XCTAssertEqual(events, [.resize(100, 40), .connect, .connected, .write("typed")])
    }

    /// 解了绑（或换了后端）之后再建连：直接连，不经队列，也不卡住。
    func testConnectAfterUnbindConnectsDirectly() async throws {
        let channel = TerminalInputChannel()
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: false)
        channel.unbind()
        try await channel.connect(backend)
        let events = await backend.events
        XCTAssertEqual(events, [.connect, .connected])
    }

    func testWritesAndResizesKeepTheOrderTheyWereProduced() async {
        let channel = TerminalInputChannel()
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: false)

        channel.write(Data("a".utf8))
        channel.reportSize(cols: 80, rows: 24)
        channel.sendLatestSizeNow()
        for index in 0..<200 { channel.write(Data("\(index),".utf8)) }

        let events = await waitForEvents(backend, count: 202)
        XCTAssertEqual(Array(events.prefix(2)), [.write("a"), .resize(80, 24)])
        XCTAssertEqual(events.dropFirst(2).map { if case .write(let s) = $0 { s } else { "?" } }.joined(),
                       (0..<200).map { "\($0)," }.joined())
    }

    /// 一连串尺寸变化只把最后一个告诉远端：每发一次远端就收一个 SIGWINCH。
    func testReportsInOneTurnCoalesceToTheLastOne() async {
        let channel = TerminalInputChannel()
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: false)

        channel.reportSize(cols: 120, rows: 40)
        channel.reportSize(cols: 100, rows: 30)
        channel.reportSize(cols: 80, rows: 24)
        await settle()

        let resizes = await backend.resizes
        XCTAssertEqual(resizes, [.resize(80, 24)])
        XCTAssertEqual(channel.latestSize?.cols, 80)
        XCTAssertEqual(channel.latestSize?.rows, 24)
    }

    func testUnchangedSizeIsNotSentAgain() async {
        let channel = TerminalInputChannel()
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: false)
        channel.reportSize(cols: 80, rows: 24)
        await settle()

        channel.reportSize(cols: 80, rows: 24)
        await settle()
        // 变过去又变回来（同一轮里）：远端仍是原尺寸，不发。
        channel.reportSize(cols: 100, rows: 30)
        channel.reportSize(cols: 80, rows: 24)
        await settle()

        let resizes = await backend.resizes
        XCTAssertEqual(resizes, [.resize(80, 24)])
    }

    /// 立刻补发不去重：建连成功后、窗格重新显示时要确保远端拿到当前尺寸。
    func testSendLatestSizeNowSendsEvenIfUnchanged() async {
        let channel = TerminalInputChannel()
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: false)
        channel.reportSize(cols: 80, rows: 24)
        await settle()

        channel.sendLatestSizeNow()
        await settle()

        let resizes = await backend.resizes
        XCTAssertEqual(resizes, [.resize(80, 24), .resize(80, 24)])
    }

    /// 尺寸早于后端就绪（首次排布、重连）：`sendingLatestSize` 时接上就补发，排在所有输入前面。
    func testBindingSendsTheLatestSizeOnlyWhenAsked() async {
        let channel = TerminalInputChannel()
        channel.reportSize(cols: 57, rows: 23)

        let quiet = RecordingBackend()
        channel.bind(to: quiet, sendingLatestSize: false)
        channel.write(Data("x".utf8))
        let quietEvents = await waitForEvents(quiet, count: 1)
        XCTAssertEqual(quietEvents, [.write("x")])

        let replaying = RecordingBackend()
        channel.bind(to: replaying, sendingLatestSize: true)
        channel.write(Data("y".utf8))
        let replayed = await waitForEvents(replaying, count: 2)
        XCTAssertEqual(replayed, [.resize(57, 23), .write("y")])
    }

    /// 换了绑定，「上次发出的尺寸」从头算：同一个尺寸在新后端上要再发一次。
    func testRebindingForgetsTheLastSentSize() async {
        let channel = TerminalInputChannel()
        let first = RecordingBackend()
        channel.bind(to: first, sendingLatestSize: false)
        channel.reportSize(cols: 80, rows: 24)
        await settle()

        let second = RecordingBackend()
        channel.bind(to: second, sendingLatestSize: false)
        channel.reportSize(cols: 80, rows: 24)
        await settle()

        let resizes = await second.resizes
        XCTAssertEqual(resizes, [.resize(80, 24)])
    }

    /// 解绑后输入丢弃（无处可去），之前排进队列的照常发完；终端尺寸仍记着。
    func testUnbindDropsLaterInputAndKeepsTheLatestSize() async {
        let channel = TerminalInputChannel()
        let backend = RecordingBackend()
        channel.bind(to: backend, sendingLatestSize: false)
        channel.write(Data("before".utf8))
        channel.reportSize(cols: 90, rows: 33)
        channel.unbind()
        channel.write(Data("after".utf8))
        await settle()

        let events = await backend.events
        XCTAssertEqual(events, [.write("before")], "解绑时还没发出的尺寸也一并作废")
        XCTAssertEqual(channel.latestSize?.cols, 90)
        XCTAssertEqual(channel.latestSize?.rows, 33)
    }
}
