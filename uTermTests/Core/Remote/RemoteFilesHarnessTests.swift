import Foundation
@preconcurrency import Network
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
///
/// 反方向（被控的 Mac 读写主控端共享的文件夹）：被控端夹具加 `UTERM_FILES_HARNESS_CLI=1`，它会另开一个命令行
/// 服务端（`…/Data/tmp/uhost.sock`）并登记一个假终端，打印 `FILES_HARNESS_SOCKET=` / `FILES_HARNESS_SESSION=`；
/// 主控端跑 `test_share_folders_for_manual_check`，扮一台或几台设备各共享一个文件夹、第一台接管那个终端。
/// 然后在**被控的 Mac** 上：
/// ```
/// export UTERM_CONTROL_SOCKET=<FILES_HARNESS_SOCKET> UTERM_SESSION_ID=<FILES_HARNESS_SESSION>
/// utermctl macs && utermctl mac shares && utermctl mac ls <主控端共享的目录>
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

        let registry = TerminalSessionRegistry()
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "uTerm 文件联调 Mac", localID: UUID(), advertises: false)
        server.fileAccess = environment["UTERM_FILES_HARNESS_INPROCESS"] == "1"
            ? RemoteFileAccess(refusal: { _ in nil }, perform: { RemoteFileService.handle($0) })
            : .live(settings: settings)
        server.start()
        defer { server.stop() }

        // 反方向：这台 Mac 上的命令行去读写连着它的主控设备共享出来的文件夹。开一个真的命令行服务端，
        // 再登记一个假终端——主控端夹具接管它之后，不写 `--mac` 的命令就该落在那台设备上。
        var cli: ControlServer?
        var terminal: TerminalSession?
        if environment["UTERM_FILES_HARNESS_CLI"] == "1" {
            let session = TerminalSession()
            await session.connect(using: MockBackend())
            let sessionID = UUID()
            registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "联调终端",
                                                   windowKind: TerminalWindowKind.workspace, title: "zsh",
                                                   connectedAt: Date()), session: session)
            terminal = session
            let container = try ModelContainer(
                for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
                QuickCommand.self, QuickCommandRun.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            let controlSettings = ControlSettings(defaults: defaults)
            controlSettings.isEnabled = true
            controlSettings.allowMutations = true
            let directory = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                               relayStore: nil, defaults: defaults, adoptsRelayAsDefault: false)
            let handler = ControlHandler(settings: controlSettings, modelContainer: container,
                                         forwardingCoordinator: ForwardingCoordinator(), pool: ControlConnectionPool(),
                                         registry: registry, macs: ControlMacSessions(directory: directory, host: server))
            let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: "uhost.sock").standardizedFileURL
            try? FileManager.default.removeItem(at: socketURL)
            let control = ControlServer(socketURL: socketURL, requestHandler: { request in
                await handler.handle(request)
            })
            XCTAssertNil(control.start())
            cli = control
            print("FILES_HARNESS_SOCKET=\(socketURL.path)")
            print("FILES_HARNESS_SESSION=\(sessionID.uuidString)")
        }
        defer {
            cli?.stop()
            terminal?.dispose()
        }

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

    /// 主控端，反方向：扮一台或几台主控设备连到 `UTERM_FILES_HARNESS_SHARE` 那台被控的 Mac，各自共享一个文件夹。
    ///
    /// `UTERM_FILES_HARNESS_DEVICES` 写成 `名字=文件夹[:rw],名字=文件夹`；带 `:rw` 的是读写共享，其余只读。
    /// `UTERM_FILES_HARNESS_ATTACH` 是被控端夹具打印的终端编号：第一台设备接管它。
    /// 共享的门禁、范围检查、执行都是线上的那一套（范围检查和执行在本机的辅助程序里做）。
    func test_share_folders_for_manual_check() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["UTERM_FILES_HARNESS_SHARE"],
              let separator = endpoint.lastIndex(of: ":"),
              let port = UInt16(endpoint[endpoint.index(after: separator)...]),
              let devices = environment["UTERM_FILES_HARNESS_DEVICES"] else {
            throw XCTSkip("没有设置 UTERM_FILES_HARNESS_SHARE / UTERM_FILES_HARNESS_DEVICES，跳过联调")
        }
        let host = String(endpoint[..<separator])
        let seconds = environment["UTERM_FILES_HARNESS_SECONDS"].flatMap(Double.init) ?? 600

        let suite = "files-harness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteFileSharingStore(defaults: defaults)

        var clients: [RemoteMacClient] = []
        for (index, device) in devices.split(separator: ",").enumerated() {
            let parts = device.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let writable = parts[1].hasSuffix(":rw")
            let folder = writable ? String(parts[1].dropLast(3)) : parts[1]
            let key = "device-\(index)"
            store.add(folder, writable: writable, for: key)
            let client = RemoteMacClient(macName: "被控 Mac",
                                         endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
                                         identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            client.localDeviceOverride = (UUID(), parts[0])
            client.fileSharing = store.access(for: key)
            await client.connect()
            // 被控端夹具自动允许配对；等它点完。
            let deadline = Date().addingTimeInterval(20)
            while client.state != .connected, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            print("FILES_HARNESS_DEVICE=\(parts[0]) state=\(client.state) shares=\(folder) writable=\(writable)")
            XCTAssertEqual(client.state, .connected)
            clients.append(client)
        }
        if let raw = environment["UTERM_FILES_HARNESS_ATTACH"], let session = UUID(uuidString: raw), let first = clients.first {
            _ = try await first.attach(sessionID: session, size: RemoteGridSize(cols: 80, rows: 24),
                                       sink: RemoteChannelSink(onOutput: { _ in }, onClosed: { _, _ in }))
            print("FILES_HARNESS_ATTACHED=\(raw)")
        }
        print("FILES_HARNESS_READY=\(clients.count)")
        try await Task.sleep(for: .seconds(seconds))
        clients.forEach { $0.disconnect() }
    }
}
