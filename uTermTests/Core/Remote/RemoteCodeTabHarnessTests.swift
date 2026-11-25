import Foundation
import XCTest
@testable import uTerm

/// 和模拟器里的 iOS 用例（`CodeTabPairedMacRealTests`）一起跑「配对的 Mac 上 Code 标签页新开会话」（默认跳过）。
///
/// 这台 Mac 上起一个真的远控服务（收到配对请求自动允许，身份是内存里现造的，不读写真实的配对记录与设置），文件请求
/// 走线上那一套（`RemoteFileAccess.live`：经辅助程序读这台 Mac 的真实文件系统，iOS 那头只读不写）。只有「新建本机终端」
/// 换成假的：登记一个回显输入的终端，标题记下要它开在哪个目录——真开 shell 的话，iOS 那头打进来的 `claude` 会在这台
/// Mac 上真的跑起来。
///
/// ```
/// TEST_RUNNER_UTERM_CODE_HARNESS_SERVE=1 xcodebuild test-without-building … \
///   -only-testing:uTermTests/RemoteCodeTabHarnessTests &
/// # 日志里 CODE_HARNESS_PORT=<端口>
/// TEST_RUNNER_UTERM_HARNESS_PORT=<端口> xcodebuild test-without-building … -destination <模拟器> \
///   -only-testing:uTermMobileTests/CodeTabPairedMacRealTests
/// ```
/// 收到 iOS 那头打进来的新会话命令就结束；要它开的目录、打进来的命令都要对上，否则这条用例失败。
@MainActor
final class RemoteCodeTabHarnessTests: XCTestCase {
    /// 给 iOS 的「最近的工作区」：都在沙盒外、名字里带空格，iOS 那头选的就是第一个。
    static let workspaces = ["/Library/Application Support", "/usr/share"]

    @MainActor
    private final class Opened {
        var directories: [String?] = []
        var shells: [(session: TerminalSession, backend: MockBackend)] = []
    }

    func test_serve_code_tab_for_simulator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UTERM_CODE_HARNESS_SERVE"] == "1" else {
            throw XCTSkip("没有设置 UTERM_CODE_HARNESS_SERVE，跳过联调服务")
        }
        let seconds = environment["UTERM_CODE_HARNESS_SECONDS"].flatMap(Double.init) ?? 300
        let suite = "code-harness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteControlSettings(defaults: defaults)
        settings.isLocalShellEnabled = true

        let registry = TerminalSessionRegistry()
        let opened = Opened()
        let prompt = "\u{1b}[?2004hharness % "
        let opener = RemoteLocalShellOpener(workspaces: { Self.workspaces }, open: { directory in
            let session = TerminalSession()
            let backend = MockBackend()
            await session.connect(using: backend)
            let id = UUID()
            registry.register(TerminalSessionEntry(id: id, serverID: RemoteConstants.localShellServerID,
                                                   serverName: LocalShellIdentity.serverName,
                                                   windowKind: TerminalWindowKind.terminal,
                                                   title: "zsh · " + (directory ?? "~"), connectedAt: Date()),
                              session: session)
            opened.directories.append(directory)
            opened.shells.append((session, backend))
            await backend.emitOutput(Data(prompt.utf8))
            print("[CODE_HARNESS] 开终端：\(directory ?? "（主目录）")")
            return .success(id)
        })
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "uTerm Code 联调 Mac", localID: UUID(), advertises: false)
        server.fileAccess = .live(settings: settings)
        server.localShellOpener = opener
        server.start()
        defer {
            server.stop()
            opened.shells.forEach { $0.session.dispose() }
        }
        for _ in 0..<100 where server.port == nil { try await Task.sleep(for: .milliseconds(50)) }
        print("CODE_HARNESS_PORT=\(try XCTUnwrap(server.port))")

        let deadline = Date().addingTimeInterval(seconds)
        var echoed: [Int] = []
        var typed = ""
        while Date() < deadline {
            for request in server.pairingRequests {
                print("[CODE_HARNESS] 配对请求：\(request.deviceName)，自动允许")
                server.approvePairing(request.id)
            }
            for (index, shell) in opened.shells.enumerated() {
                if echoed.count <= index { echoed.append(0) }
                let written = await shell.backend.writtenData
                for chunk in written.dropFirst(echoed[index]) {
                    typed += String(decoding: chunk, as: UTF8.self)
                    var out = Data()
                    for byte in chunk { byte == 0x0d ? out.append(contentsOf: Array("\r\n\(prompt)".utf8)) : out.append(byte) }
                    await shell.backend.emitOutput(out)
                }
                echoed[index] = written.count
            }
            if typed.contains("claude"), typed.contains("\r") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        print("[CODE_HARNESS] 打进来的：\(typed.debugDescription)")
        // 留一会儿让 iOS 那头读到回显再断。
        try await Task.sleep(for: .seconds(3))

        XCTAssertEqual(opened.directories, [Self.workspaces[0]], "iOS 要 Mac 在选的目录里开终端")
        XCTAssertTrue(typed.contains("cd -- '/Library/Application Support' && claude"), "打进来的命令：\(typed.debugDescription)")
    }
}
