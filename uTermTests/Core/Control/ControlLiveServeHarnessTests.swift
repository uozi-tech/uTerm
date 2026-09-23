import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// 端到端联调用的**服务夹具**：在测试宿主（与 uTerm 同一个沙盒容器）里起一个真
/// `ControlServer` + 真 `ControlHandler` + 真连接池，主机「bench」指向本机 sshd，
/// 保持服务 `UTERM_SERVE_SECONDS` 秒。期间从沙盒外用真 `scripts/utermctl` 打它 ——
/// fd 跨沙盒传递、进度流、续传、quarantine 这些只有真边界才验得出来。默认跳过。
///
/// ```
/// TEST_RUNNER_UTERM_SERVE_SSH_PORT=2298 TEST_RUNNER_UTERM_SERVE_SECONDS=600 \
///   xcodebuild test-without-building … -only-testing:uTermTests/ControlLiveServeHarnessTests &
/// export UTERM_CONTROL_SOCKET=~/Library/Containers/com.uozi.uTerm/Data/tmp/ue2e.sock
/// scripts/utermctl sftp get -H bench /root/big /tmp/big.bin
/// ```
///
/// 账号 root / `UTERM_SERVE_PASSWORD`（缺省 `PASS`）；主机密钥首连时用 `utermctl trust` 钉。
final class ControlLiveServeHarnessTests: XCTestCase {

    private struct StubKeychain: KeychainReading {
        let password: String
        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            kind == .password ? password : nil
        }
    }

    @MainActor
    func testServeForLiveClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_SERVE_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_SERVE_SSH_PORT，跳过端到端服务夹具")
        }
        let seconds = Double(env["UTERM_SERVE_SECONDS"] ?? "") ?? 300

        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            QuickCommand.self, QuickCommandRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let profile = ServerProfile()
        profile.name = "bench"
        profile.host = "127.0.0.1"
        profile.port = port
        profile.username = "root"
        container.mainContext.insert(profile)
        try container.mainContext.save()
        HostConnectionSpec.keychainOverride = StubKeychain(password: env["UTERM_SERVE_PASSWORD"] ?? "PASS")
        defer { HostConnectionSpec.keychainOverride = nil }

        let settings = ControlSettings(defaults: UserDefaults(suiteName: "serve.\(UUID().uuidString)")!)
        settings.isEnabled = true
        settings.allowMutations = true
        let pool = ControlConnectionPool()
        let handler = ControlHandler(
            settings: settings, modelContainer: container,
            forwardingCoordinator: ForwardingCoordinator(), pool: pool,
            registry: TerminalSessionRegistry())

        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "ue2e.sock").standardizedFileURL
        try? FileManager.default.removeItem(at: socketURL)
        let server = ControlServer(socketURL: socketURL, requestHandler: { request in
            await handler.handle(request)
        })
        XCTAssertNil(server.start())
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }
        print("SERVE socket \(socketURL.path) for \(Int(seconds)) s")
        try await Task.sleep(for: .seconds(seconds))
        await pool.disconnectAll()
    }
}
