import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// 两台 Mac 之间联调「远程 Mac 的文件与命令」用的一对夹具（默认跳过）。
///
/// 两边都跑在测试宿主里，身份是内存里现造的：不读也不写真实的配对记录、钥匙串、正式版的设置，
/// 配对只在夹具里自动允许。除此之外全是线上的那一套——真的加密链路跨局域网、真的命令行服务端与
/// 连接管理（`ControlMacSessions` + `RemoteMacDirectory`）、被控端真的经辅助程序（`uTermShellAgent`，
/// 没有沙盒）读写那台 Mac 的文件。
///
/// 被控的 Mac 上：
/// ```
/// TEST_RUNNER_UTERM_FILES_HARNESS_SERVE=1 TEST_RUNNER_UTERM_FILES_HARNESS_SECONDS=900 \
///   xcodebuild test-without-building … -only-testing:uTermTests/RemoteFilesHarnessTests/test_serve_files_for_manual_check
/// ```
/// 日志里的 `FILES_HARNESS_PORT=<端口>` 是它监听的端口。
///
/// 主控的 Mac 上：
/// ```
/// TEST_RUNNER_UTERM_FILES_HARNESS_CONNECT=192.168.31.3:<端口> \
///   xcodebuild test-without-building … -only-testing:uTermTests/RemoteFilesHarnessTests/test_serve_cli_for_manual_check &
/// export UTERM_CONTROL_SOCKET=~/Library/Containers/com.uozi.uTerm/Data/tmp/umac.sock
/// scripts/utermctl macs
/// scripts/utermctl mac ls -M 调试 ~
/// ```
@MainActor
final class RemoteFilesHarnessTests: XCTestCase {

    /// 被控端：真实的远控服务 + 文件通道，收到配对请求自动允许。
    func test_serve_files_for_manual_check() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UTERM_FILES_HARNESS_SERVE"] == "1" else {
            throw XCTSkip("没有设置 UTERM_FILES_HARNESS_SERVE，跳过联调服务")
        }
        let seconds = environment["UTERM_FILES_HARNESS_SECONDS"].flatMap(Double.init) ?? 600

        // 线上的门禁与执行路径：设置里的「允许打开本机终端」开着才放行，操作交给辅助程序。
        // 设置用一份临时的，不动这台 Mac 上 uTerm 自己的。
        let suite = "files-harness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteControlSettings(defaults: defaults)
        settings.isLocalShellEnabled = true

        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "uTerm 文件联调 Mac", localID: UUID(), advertises: false)
        server.fileAccess = environment["UTERM_FILES_HARNESS_INPROCESS"] == "1"
            ? RemoteFileAccess(refusal: { _ in nil }, perform: { RemoteFileService.handle($0) })
            : .live(settings: settings)
        server.start()
        defer { server.stop() }

        var announced = false
        var served = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !announced, let port = server.port {
                announced = true
                print("FILES_HARNESS_PORT=\(port)")
                let version = try? await LocalShellService.shared.client.ping()
                print("FILES_HARNESS_AGENT=\(version ?? "unreachable")")
            }
            for request in server.pairingRequests {
                print("FILES_HARNESS 自动允许配对：\(request.deviceName)")
                server.approvePairing(request.id)
                served += 1
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("FILES_HARNESS 结束，配对了 \(served) 次")
    }

    /// 主控端：真实的命令行服务端，`macs` / `mac-*` 指向 `UTERM_FILES_HARNESS_CONNECT` 那台 Mac。
    func test_serve_cli_for_manual_check() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["UTERM_FILES_HARNESS_CONNECT"], endpoint.contains(":") else {
            throw XCTSkip("没有设置 UTERM_FILES_HARNESS_CONNECT，跳过联调服务")
        }
        let seconds = environment["UTERM_FILES_HARNESS_SECONDS"].flatMap(Double.init) ?? 600

        let suite = "files-harness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // 调试直连：把这个地址当作一台 Mac 列出来，不走 Bonjour、不走中继。
        defaults.set(endpoint, forKey: DefaultsKey.remoteDebugEndpoint)
        let directory = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                           relayStore: nil, defaults: defaults, adoptsRelayAsDefault: false)
        let macs = ControlMacSessions(directory: directory)

        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            QuickCommand.self, QuickCommandRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let settings = ControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = environment["UTERM_FILES_HARNESS_READONLY"] != "1"
        let handler = ControlHandler(settings: settings, modelContainer: container,
                                     forwardingCoordinator: ForwardingCoordinator(), pool: ControlConnectionPool(),
                                     registry: TerminalSessionRegistry(), macs: macs)

        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "umac.sock").standardizedFileURL
        try? FileManager.default.removeItem(at: socketURL)
        let server = ControlServer(socketURL: socketURL, requestHandler: { request in
            await handler.handle(request)
        })
        XCTAssertNil(server.start())
        defer {
            server.stop()
            _ = macs.release(nil)
            try? FileManager.default.removeItem(at: socketURL)
        }
        print("FILES_HARNESS_SOCKET=\(socketURL.path)")
        print("FILES_HARNESS_MACS=\(directory.macs.map(\.name))")
        try await Task.sleep(for: .seconds(seconds))
    }
}
