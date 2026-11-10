import AppKit
import SwiftData
import XCTest
@testable import uTerm

/// 真 sshd 上的大输出、改尺寸、断线重连：带真 surface 的会话，后端是真的 `SSHConnection`。
/// 走的是 App 里同一条链：后端 `outputItems` → 输出泵 → 影子 → surface；键入和尺寸走 `TerminalInputChannel`。
///
/// 默认跳过。环境变量（xcodebuild 传给测试宿主要加 `TEST_RUNNER_` 前缀）与 `AgentE2ETests` 同一组：
/// - `UTERM_E2E_SSH_PORT`、`UTERM_E2E_SSH_USER`：127.0.0.1 上的 sshd，登录 shell 的提示符里要有 `$` 或 `%`
/// - `UTERM_E2E_SSH_KEY_B64`：base64 编码的私钥（测试宿主有沙盒，读不了任意路径）
///
/// 对端要有 `seq`、`stty`。
@MainActor
final class SSHStreamE2ETests: XCTestCase {

    private var port = 0
    private var user = ""
    private var pem = ""
    private var rig: GhosttySurfaceRig!
    private var connection: SSHConnection?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["UTERM_E2E_SSH_PORT"].flatMap(Int.init),
              let user = env["UTERM_E2E_SSH_USER"],
              let key = env["UTERM_E2E_SSH_KEY_B64"].flatMap({ Data(base64Encoded: $0) }) else {
            throw XCTSkip("没设 UTERM_E2E_SSH_*")
        }
        self.port = port
        self.user = user
        pem = String(decoding: key, as: UTF8.self)
        rig = await GhosttySurfaceRig(size: NSSize(width: 900, height: 520), connectsBackend: false)
    }

    override func tearDown() async throws {
        await connection?.close()
        rig?.close()
    }

    private var session: TerminalSession { rig.session }

    private func makeConnection() throws -> SSHConnection {
        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return SSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .privateKey(username: user, pem: pem, passphrase: nil),
            jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container),
            hostKeyApprover: { _ in true })
    }

    private func connect() async throws {
        let connection = try makeConnection()
        self.connection = connection
        await session.connect(using: connection)
        XCTAssertEqual(session.connectionState, .connected)
        try await waitUntil("shell 提示符") { self.screen().contains("$") || self.screen().contains("%") }
    }

    private func type(_ text: String) {
        session.sendHostBytes(Data(text.utf8))
    }

    private func screen(lines: Int = 60) -> String {
        session.snapshotScreen(lines: lines, maxBytes: 1 << 20).lines.joined(separator: "\n")
    }

    private func waitUntil(_ what: String, seconds: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("等「\(what)」超时。连接：\(session.connectionState)\n影子：\n\(screen())\n画面：\n\(rig.surfaceText)")
        throw CancellationError()
    }

    /// `seq 1 n` 输出的字节数（每个数字加一个换行，终端里是 CRLF）。
    private static func seqBytes(_ n: Int) -> Int {
        (1...n).reduce(0) { $0 + String($1).utf8.count + 2 }
    }

    /// 屏上最后若干行是连续的数字，并以 `last` 结尾：中间没丢、没乱序。
    private func assertTailIsContiguous(endingAt last: Int, lines: Int = 300,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let numbers = session.snapshotScreen(lines: lines + 40, maxBytes: 1 << 20).lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(Int.init)
        let tail = numbers.suffix(lines)
        XCTAssertEqual(tail.last, last, "末尾应当是 \(last)", file: file, line: line)
        XCTAssertEqual(Array(tail), Array((last - tail.count + 1)...last), "末尾数字不连续", file: file, line: line)
    }

    /// 二十万行一口气过来：影子吃够全部字节，末尾连续，surface 也画到最后一行；主线程没被卡死（等待循环一直在跑）。
    func testLargeOutputResizeAndReconnect() async throws {
        try await connect()

        // 大输出。命令行回显里是 `$((40+2))`，只有真跑完才出现 42。
        let fedBefore = session.shadow.totalFedBytes
        let started = ContinuousClock.now
        type("seq 1 200000; echo SEQ-$((40+2))-END\r")
        try await waitUntil("seq 跑完", seconds: 90) { self.screen(lines: 5).contains("SEQ-42-END") }
        let elapsed = ContinuousClock.now - started
        let fed = session.shadow.totalFedBytes - fedBefore
        XCTAssertGreaterThanOrEqual(fed, Self.seqBytes(200_000), "影子少吃了字节：\(fed)")
        assertTailIsContiguous(endingAt: 200_000)
        try await waitUntil("画面画到最后") { self.rig.surfaceText.contains("SEQ-42-END") }
        print("SSHStreamE2E: seq 200000 用时 \(elapsed)，影子吃了 \(fed) 字节；泵 \(session.outputPump.currentStats)")

        // 改尺寸：远端 PTY 跟着变。
        let before = session.currentProcessSize
        rig.window.setContentSize(NSSize(width: 1200, height: 700))
        rig.container.frame = rig.window.contentView?.bounds ?? .zero
        rig.container.layoutSubtreeIfNeeded()
        try await waitUntil("本地网格变了") { self.session.currentProcessSize != before }
        // 尺寸是异步发出去的：等它稳定再问远端。
        try await Task.sleep(for: .milliseconds(500))
        let size = session.currentProcessSize
        type("stty size | sed 's/ /x/; s/^/SIZE=/'\r")
        try await waitUntil("远端尺寸 \(size.rows)x\(size.cols)") {
            self.screen(lines: 5).contains("SIZE=\(size.rows)x\(size.cols)")
        }

        // 断线：从服务端杀掉这条会话的 sshd 进程，本地翻成断开，不挂住。
        type("kill -9 $PPID\r")
        try await waitUntil("断开") { self.session.connectionState == .disconnected }
        await connection?.close()

        // 同一个会话换一条新连接：照常可用，大输出依旧完整。
        try await connect()
        type("echo RE-$((1+2))-OK\r")
        try await waitUntil("重连后可用") { self.screen(lines: 5).contains("RE-3-OK") }
        let fedBeforeSecond = session.shadow.totalFedBytes
        type("seq 1 50000; echo SEQ2-$((40+2))-END\r")
        try await waitUntil("重连后 seq 跑完", seconds: 60) { self.screen(lines: 5).contains("SEQ2-42-END") }
        XCTAssertGreaterThanOrEqual(session.shadow.totalFedBytes - fedBeforeSecond, Self.seqBytes(50_000))
        assertTailIsContiguous(endingAt: 50_000)
        try await waitUntil("重连后画面画到最后") { self.rig.surfaceText.contains("SEQ2-42-END") }
    }
}
