import XCTest
@testable import uTerm

/// 与 iOS 模拟器联调用的远控服务（默认跳过）。
///
/// 只有设置了环境变量 `UTERM_HARNESS_SERVER_ID`（手机上那台主机的 UUID）时才运行；经
/// `xcodebuild test-without-building` 传入时写成 `TEST_RUNNER_UTERM_HARNESS_SERVER_ID=…`。
/// 在本机广播一个真实的远控服务，会话由假后端驱动、回显键盘输入，收到配对请求自动允许，
/// 最多持续 3 分钟。模拟器里的 uTermMobile 在主机页「我的 Mac」里就能发现并接入它。
/// 另设 `UTERM_HARNESS_DESKTOP=1` 时同时提供远程桌面：画面是合成的色块 + 细线（每秒换一张），
/// 手机发来的输入打印在日志里（不注入真实系统）。
/// 另设 `UTERM_HARNESS_FOLLOW=1` 时，按 `runFollowScript` 开关终端，给手机验证自动跟进
///（手机侧用例：`RemoteFollowRealMacTests`）。
@MainActor
final class RemoteSimulatorHarnessTests: XCTestCase {

    func test_serve_simulator_for_manual_check() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["UTERM_HARNESS_SERVER_ID"], let serverID = UUID(uuidString: raw) else {
            throw XCTSkip("没有设置 UTERM_HARNESS_SERVER_ID，跳过联调服务")
        }
        let seconds = environment["UTERM_HARNESS_SECONDS"].flatMap(Double.init) ?? 180
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let firstID = UUID()
        registry.register(TerminalSessionEntry(id: firstID, serverID: serverID, serverName: "联调主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh · 联调",
                                               connectedAt: Date()), session: session)
        let desktop = environment["UTERM_HARNESS_DESKTOP"] == "1"
        let fakeMac = FakeDesktopMac()
        fakeMac.detail = true
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "uTerm 联调 Mac", localID: UUID(),
                                      // 默认不广播：Debug 测试宿主通常没有「本地网络」权限（Bonjour 注册报 NoAuth）。
                                      // 模拟器用 `-RemoteDebugEndpoint 127.0.0.1:<端口>` 直连，端口见日志。
                                      advertises: environment["UTERM_HARNESS_ADVERTISE"] == "1",
                                      desktopEnvironment: desktop ? fakeMac.environment() : .disabled)
        server.start()
        defer { server.stop(); session.dispose() }

        let prompt = "\u{1b}[32mdemo\u{1b}[0m:\u{1b}[34m~\u{1b}[0m % "
        await backend.emitOutput(Data("远控联调：键盘输入会回显。\r\n\(prompt)".utf8))

        let deadline = Date().addingTimeInterval(seconds)
        var echoed = 0
        var lastStatus = ""
        var reportedInputs = 0
        var runningSource: SyntheticFrameSource?
        var followSessions: [TerminalSession] = []
        defer { followSessions.forEach { $0.dispose() } }
        let followScript = environment["UTERM_HARNESS_FOLLOW"] != "1" ? nil : Task { @MainActor in
            await Self.runFollowScript(registry: registry, serverID: serverID, firstID: firstID, first: session) {
                followSessions.append($0)
            }
        }
        defer { followScript?.cancel() }
        while Date() < deadline {
            if desktop {
                if let source = fakeMac.latestSource, source !== runningSource, source.isStarted {
                    runningSource = source
                    source.prepareCycle(count: 6)
                    source.run(fps: 1)
                    print("[联调] 桌面流开始：\(source.width)×\(source.height)")
                }
                let inputs = fakeMac.injector.all
                for input in inputs.dropFirst(reportedInputs) { print("[联调] 桌面输入：\(input)") }
                reportedInputs = inputs.count
            }
            let status = "\(server.status) port=\(server.port.map(String.init) ?? "-") devices=\(server.connectedDevices)"
            if status != lastStatus {
                print("[联调] 服务状态：\(status)")
                lastStatus = status
            }
            for request in server.pairingRequests {
                print("[联调] 配对请求：\(request.deviceName) 核对码 \(request.code)，自动允许")
                server.approvePairing(request.id)
            }
            // 简易 shell：回显输入，回车换行并重新打印提示符。
            let written = await backend.writtenData
            for chunk in written.dropFirst(echoed) {
                var out = Data()
                for byte in chunk {
                    switch byte {
                    case 0x0d: out.append(contentsOf: Array("\r\n\(prompt)".utf8))
                    case 0x7f: out.append(contentsOf: [0x08, 0x20, 0x08])
                    default: out.append(byte)
                    }
                }
                await backend.emitOutput(out)
            }
            echoed = written.count
            try? await Task.sleep(for: .milliseconds(20))
        }
        print("[联调] 结束；被接管过：\(session.remoteController ?? "否")，已信任设备：\(server.trustedPeers.map(\.name))")
    }

    /// 被接管后：新开一个终端 → 关掉它 → 把终端全关 → 隔一会儿再开一个。
    private static func runFollowScript(registry: TerminalSessionRegistry, serverID: UUID, firstID: UUID,
                                        first: TerminalSession, retain: (TerminalSession) -> Void) async {
        func open(_ title: String) async -> (id: UUID, session: TerminalSession) {
            let session = TerminalSession()
            await session.connect(using: MockBackend())
            let id = UUID()
            registry.register(TerminalSessionEntry(id: id, serverID: serverID, serverName: "联调主机",
                                                   windowKind: TerminalWindowKind.workspace, title: title,
                                                   connectedAt: Date()), session: session)
            retain(session)
            print("[联调] 开了终端：\(title)")
            return (id, session)
        }
        func waitUntilControlled(_ session: TerminalSession) async {
            while session.remoteController == nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await waitUntilControlled(first)
        try? await Task.sleep(for: .seconds(1))
        let added = await open("zsh · 新开")
        await waitUntilControlled(added.session)
        try? await Task.sleep(for: .seconds(2))
        registry.unregister(id: added.id)
        print("[联调] 关了新开的终端")
        try? await Task.sleep(for: .seconds(2))
        registry.unregister(id: firstID)
        print("[联调] 终端全关了")
        try? await Task.sleep(for: .seconds(6))
        _ = await open("zsh · 又开")
    }
}
