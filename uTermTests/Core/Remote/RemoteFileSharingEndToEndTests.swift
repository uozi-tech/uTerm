import SwiftData
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 反过来的文件通道，端到端：被控 Mac 上的命令行 handler / `RemoteMacFileProvider` → 真实的加密链路（本机回环）
/// → 主控端的 `RemoteMacClient` → 共享文件夹的范围检查 → 文件服务。
///
/// 一个被控端（`RemoteHostServer`）同时连着几台主控端，各自共享各自的文件夹：请求不能串到别的设备上，
/// 没点名时按「发命令的终端此刻被谁接管」取。辅助程序这里不起（XPC 要真机），范围检查和执行调的是同一份代码。
@MainActor
final class RemoteFileSharingEndToEndTests: XCTestCase {

    private var base = ""

    override func setUp() async throws {
        try await super.setUp()
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        base = temporary.appendingPathComponent("remote-sharing-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: base)
        try await super.tearDown()
    }

    // MARK: - 夹具

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 被控的那台 Mac：开着两个终端。
    private struct Host {
        let server: RemoteHostServer
        let registry: TerminalSessionRegistry
        let sessions: [UUID]
        let terminals: [TerminalSession]
    }

    private func makeHost() async throws -> Host {
        let registry = TerminalSessionRegistry()
        var ids: [UUID] = []
        var terminals: [TerminalSession] = []
        for index in 0..<2 {
            let session = TerminalSession()
            await session.connect(using: MockBackend())
            let id = UUID()
            registry.register(TerminalSessionEntry(id: id, serverID: UUID(), serverName: "本机", windowKind: TerminalWindowKind.workspace,
                                                   title: "zsh \(index + 1)", connectedAt: Date()), session: session)
            ids.append(id)
            terminals.append(session)
        }
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "被控 Mac", localID: UUID(), advertises: false)
        server.start()
        _ = await waitUntil { server.port != nil }
        addTeardownBlock { @MainActor in
            server.stop()
            terminals.forEach { $0.dispose() }
        }
        return Host(server: server, registry: registry, sessions: ids, terminals: terminals)
    }

    /// 一台主控端。`shares` 为 nil 时像手机、老版本一样不提供文件。
    private struct Controller {
        let id: UUID
        let name: String
        let client: RemoteMacClient
        let store: RemoteFileSharingStore
        let folder: String
    }

    private func connect(_ name: String, to host: Host, sharesFiles: Bool = true) async throws -> Controller {
        let folder = base + "/" + name
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("from \(name)\n".utf8).write(to: URL(fileURLWithPath: folder + "/who.txt"))

        let suite = "RemoteFileSharingEndToEndTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteFileSharingStore(defaults: defaults)

        let port = try XCTUnwrap(host.server.port)
        let client = RemoteMacClient(macName: "被控 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let id = UUID()
        client.localDeviceOverride = (id, name)
        if sharesFiles { client.fileSharing = store.inProcessAccess(for: "host") }
        let pending = host.server.pairingRequests.count
        let connecting = Task { await client.connect() }
        _ = await waitUntil { host.server.pairingRequests.count > pending }
        host.server.approvePairing(try XCTUnwrap(host.server.pairingRequests.last?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        addTeardownBlock { @MainActor in client.disconnect() }
        return Controller(id: id, name: name, client: client, store: store, folder: folder)
    }

    private func takeOver(_ session: UUID, by controller: Controller) async throws -> RemoteAttachment {
        try await controller.client.attach(sessionID: session, size: RemoteGridSize(cols: 80, rows: 24),
                                           sink: RemoteChannelSink(onOutput: { _ in }, onClosed: { _, _ in }))
    }

    private struct CLI {
        let handler: ControlHandler
        let settings: ControlSettings
    }

    /// 被控 Mac 上的命令行：真的 `ControlMacSessions`，没有配对过的 Mac，只有连着它的主控设备。
    private func commandLine(_ host: Host) throws -> CLI {
        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let suite = "RemoteFileSharingEndToEndTests.cli.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = ControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = true
        let directory = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                           relayStore: nil, defaults: defaults, adoptsRelayAsDefault: false)
        let handler = ControlHandler(settings: settings, modelContainer: container,
                                     forwardingCoordinator: ForwardingCoordinator(),
                                     pool: ControlConnectionPool.shared, registry: host.registry,
                                     macs: ControlMacSessions(directory: directory, host: host.server))
        return CLI(handler: handler, settings: settings)
    }

    private func request(_ action: ControlAction, path: String? = nil, target: String? = nil,
                         session: UUID? = nil) -> ControlRequest {
        var request = ControlRequest(id: UUID().uuidString, action: action, path: path)
        var arguments = ControlMacArguments(target: target)
        arguments.session = session?.uuidString
        request.mac = arguments
        return request
    }

    private func provider(_ host: Host, _ controller: Controller) throws -> RemoteMacFileProvider {
        let connection = try XCTUnwrap(host.server.fileConnection(toDevice: controller.id))
        return RemoteMacFileProvider(send: { request, body, timeout in
            try await connection.performFile(request, body: body, timeout: timeout)
        })
    }

    private func failure(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> RemoteFileError? {
        do {
            try await work()
            XCTFail("应当失败", file: file, line: line)
            return nil
        } catch let error as RemoteFileError {
            return error
        } catch {
            XCTFail("不是 RemoteFileError：\(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - 链路

    func test_host_reads_and_writes_only_what_the_controller_shares() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        let files = try provider(host, laptop)

        // 什么都没共享：一律拒绝，但问「共享了什么」照常回空列表。
        let nothing = await failure { _ = try await files.download(remotePath: laptop.folder + "/who.txt") }
        XCTAssertEqual(nothing?.code, .disabled)
        let empty = try await files.perform(RemoteFileRequest(op: .roots)).reply.roots
        XCTAssertEqual(empty, [])

        // 只读共享：读得到、写不了；共享之外的读不到。改共享立刻生效，不用重连。
        laptop.store.add(laptop.folder, writable: false, for: "host")
        let text = try await files.download(remotePath: laptop.folder + "/who.txt")
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "from laptop\n")
        let names = try await files.list(path: laptop.folder).map(\.name)
        XCTAssertEqual(names, ["who.txt"])
        let roots = try await files.perform(RemoteFileRequest(op: .roots)).reply.roots
        XCTAssertEqual(roots, [RemoteFileRoot(path: laptop.folder, writable: false)])
        let denied = await failure { try await files.write(laptop.folder + "/new.txt", data: Data("x".utf8)) }
        XCTAssertEqual(denied?.code, .permissionDenied)
        let outside = await failure { _ = try await files.list(path: self.base) }
        XCTAssertEqual(outside?.code, .permissionDenied)

        // 读写共享：写得进去，文件真落在主控端的文件夹里。
        laptop.store.setWritable(true, path: laptop.folder, for: "host")
        try await files.write(laptop.folder + "/new.txt", data: Data("written by host\n".utf8))
        XCTAssertEqual(try String(contentsOfFile: laptop.folder + "/new.txt", encoding: .utf8), "written by host\n")

        // 跑命令在这个方向上永远不行。
        var exec = RemoteFileRequest(op: .exec, path: laptop.folder)
        exec.command = "id"
        let refused = await failure { _ = try await files.perform(exec) }
        XCTAssertEqual(refused?.code, .disabled)
    }

    func test_transfers_a_large_file_from_the_controller() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        laptop.store.add(laptop.folder, writable: true, for: "host")
        var bytes = Data(count: 3 * 1024 * 1024 + 4321)
        bytes.withUnsafeMutableBytes { raw in
            for index in 0..<raw.count { raw[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 9) }
        }
        try bytes.write(to: URL(fileURLWithPath: laptop.folder + "/big.bin"))
        let files = try provider(host, laptop)

        let local = URL(fileURLWithPath: base + "/downloaded.bin")
        try await files.download(remotePath: laptop.folder + "/big.bin", toLocalURL: local, onProgress: { _ in })
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        try await files.upload(localURL: local, toRemotePath: laptop.folder + "/echo.bin", onProgress: { _ in })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: laptop.folder + "/echo.bin")), bytes)
    }

    func test_controllers_that_do_not_share_are_refused_without_sending() async throws {
        let host = try await makeHost()
        let phone = try await connect("phone", to: host, sharesFiles: false)
        XCTAssertNil(host.server.fileConnection(toDevice: phone.id))
        let listed = try XCTUnwrap(host.server.connectedControllers().first)
        XCTAssertEqual(listed.name, "phone")
        XCTAssertFalse(listed.sharesFiles)
    }

    func test_pending_requests_fail_when_the_controller_drops() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        laptop.store.add(laptop.folder, writable: false, for: "host")
        let files = try provider(host, laptop)
        var wait = RemoteFileRequest(op: .waitChange, path: laptop.folder)
        wait.seconds = 30
        let pending = Task { try await files.perform(wait) }
        try await Task.sleep(for: .milliseconds(200))
        laptop.client.disconnect()
        do {
            _ = try await pending.value
            XCTFail("连接断了应当失败")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error.code, .unreachable)
        }
        _ = await waitUntil { host.server.connectedControllers().isEmpty }
        XCTAssertTrue(host.server.connectedControllers().isEmpty)
    }

    // MARK: - 命令行：几台设备同时连着

    func test_cli_lists_connected_controllers_and_marks_the_current_one() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        let studio = try await connect("studio", to: host)
        let phone = try await connect("phone", to: host, sharesFiles: false)
        _ = try await takeOver(host.sessions[0], by: studio)
        _ = await waitUntil { host.server.controller(ofSession: host.sessions[0]) != nil }
        let cli = try commandLine(host)

        let response = await cli.handler.handle(request(.macs, session: host.sessions[0]))
        XCTAssertTrue(response.ok, response.message)
        let macs = try XCTUnwrap(response.mac?.macs)
        XCTAssertEqual(macs.map(\.name), ["laptop", "phone", "studio"])
        XCTAssertEqual(macs.map(\.role), Array(repeating: ControlMacRole.controller, count: 3))
        XCTAssertEqual(macs.map(\.id), [laptop, phone, studio].map { ControlMacRole.controllerPrefix + $0.id.uuidString })
        XCTAssertEqual(macs.map(\.current), [false, false, true])
        XCTAssertEqual(macs.map(\.supportsFiles), [true, false, true])
    }

    func test_cli_without_target_uses_the_device_holding_this_terminal() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        let studio = try await connect("studio", to: host)
        laptop.store.add(laptop.folder, writable: false, for: "host")
        studio.store.add(studio.folder, writable: false, for: "host")
        // 两个终端各归一台设备。
        _ = try await takeOver(host.sessions[0], by: laptop)
        _ = try await takeOver(host.sessions[1], by: studio)
        _ = await waitUntil { host.server.controller(ofSession: host.sessions[1]) != nil }
        let cli = try commandLine(host)

        let first = await cli.handler.handle(request(.macCat, path: laptop.folder + "/who.txt", session: host.sessions[0]))
        XCTAssertTrue(first.ok, first.message)
        XCTAssertEqual(first.file?.text, "from laptop\n")
        XCTAssertEqual(first.mac?.name, "laptop")
        XCTAssertEqual(first.mac?.role, ControlMacRole.controller)

        let second = await cli.handler.handle(request(.macCat, path: studio.folder + "/who.txt", session: host.sessions[1]))
        XCTAssertTrue(second.ok, second.message)
        XCTAssertEqual(second.file?.text, "from studio\n")
        XCTAssertEqual(second.mac?.name, "studio")

        // 在第一个终端里读另一台设备共享的路径：请求落在 laptop 上，laptop 没共享那个目录 → 拒绝，不会串到 studio。
        let crossed = await cli.handler.handle(request(.macCat, path: studio.folder + "/who.txt", session: host.sessions[0]))
        XCTAssertFalse(crossed.ok)
        XCTAssertEqual(crossed.code, ControlErrorCode.permission_denied.rawValue)

        // `@controller` 是同一个意思；点名就不看终端。
        let explicit = await cli.handler.handle(request(.macCat, path: laptop.folder + "/who.txt",
                                                        target: ControlMacRole.currentController, session: host.sessions[0]))
        XCTAssertEqual(explicit.file?.text, "from laptop\n")
        let named = await cli.handler.handle(request(.macCat, path: studio.folder + "/who.txt", target: "studio",
                                                     session: host.sessions[0]))
        XCTAssertEqual(named.file?.text, "from studio\n")
        let byID = await cli.handler.handle(request(.macCat, path: studio.folder + "/who.txt",
                                                    target: ControlMacRole.controllerPrefix + studio.id.uuidString))
        XCTAssertEqual(byID.file?.text, "from studio\n")
    }

    func test_cli_follows_the_terminal_when_another_device_takes_it_over() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        let studio = try await connect("studio", to: host)
        laptop.store.add(laptop.folder, writable: false, for: "host")
        studio.store.add(studio.folder, writable: false, for: "host")
        let cli = try commandLine(host)
        let terminal = host.sessions[0]

        _ = try await takeOver(terminal, by: laptop)
        _ = await waitUntil { host.server.controller(ofSession: terminal)?.deviceID == laptop.id }
        let before = await cli.handler.handle(request(.macShares, session: terminal))
        XCTAssertEqual(before.mac?.name, "laptop")
        XCTAssertEqual(before.mac?.roots, [ControlMacRoot(path: laptop.folder, writable: false)])

        // 换了一台设备接管同一个终端：同一条命令现在落在新的那台上。
        _ = try await takeOver(terminal, by: studio)
        _ = await waitUntil { host.server.controller(ofSession: terminal)?.deviceID == studio.id }
        let after = await cli.handler.handle(request(.macShares, session: terminal))
        XCTAssertEqual(after.mac?.name, "studio")
        XCTAssertEqual(after.mac?.roots, [ControlMacRoot(path: studio.folder, writable: false)])
    }

    func test_cli_refuses_to_guess_between_devices() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        let studio = try await connect("studio", to: host)
        let cli = try commandLine(host)

        // 不在 uTerm 的终端里发的（没有终端编号）：两台都连着，分不出来。
        let blind = await cli.handler.handle(request(.macShares))
        XCTAssertEqual(blind.code, ControlErrorCode.host_ambiguous.rawValue)
        XCTAssertTrue(blind.message.contains(ControlMacRole.controllerPrefix + laptop.id.uuidString), blind.message)
        XCTAssertTrue(blind.message.contains(ControlMacRole.controllerPrefix + studio.id.uuidString), blind.message)

        // 在终端里发的，但这个终端此刻没人接管：同样不猜。
        let idle = await cli.handler.handle(request(.macShares, session: host.sessions[0]))
        XCTAssertEqual(idle.code, ControlErrorCode.host_ambiguous.rawValue)

        // 只剩一台时就是它。
        studio.client.disconnect()
        _ = await waitUntil { host.server.connectedControllers().count == 1 }
        let only = await cli.handler.handle(request(.macShares))
        XCTAssertTrue(only.ok, only.message)
        XCTAssertEqual(only.mac?.name, "laptop")
    }

    func test_cli_does_not_fall_back_when_the_terminal_is_held_by_a_device_without_files() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        laptop.store.add(laptop.folder, writable: false, for: "host")
        let phone = try await connect("phone", to: host, sharesFiles: false)
        _ = try await takeOver(host.sessions[0], by: phone)
        _ = await waitUntil { host.server.controller(ofSession: host.sessions[0]) != nil }
        let cli = try commandLine(host)

        // 这个终端是 phone 在用：不提供文件就直说，不悄悄换成 laptop。
        let held = await cli.handler.handle(request(.macCat, path: laptop.folder + "/who.txt", session: host.sessions[0]))
        XCTAssertFalse(held.ok)
        XCTAssertTrue(held.message.contains("phone"), held.message)
        XCTAssertTrue(held.message.contains("laptop"), held.message)

        // 没人接管的另一个终端里：只有 laptop 一台肯提供文件，用它。
        let other = await cli.handler.handle(request(.macCat, path: laptop.folder + "/who.txt", session: host.sessions[1]))
        XCTAssertEqual(other.file?.text, "from laptop\n")

        // 一台都没有时说清楚。
        laptop.client.disconnect()
        _ = await waitUntil { host.server.connectedControllers().count == 1 }
        let none = await cli.handler.handle(request(.macShares, session: host.sessions[1]))
        XCTAssertEqual(none.code, ControlErrorCode.invalid_request.rawValue)
        XCTAssertTrue(none.message.contains("phone"), none.message)
    }

    func test_cli_write_needs_both_the_local_switch_and_a_writable_share() async throws {
        let host = try await makeHost()
        let laptop = try await connect("laptop", to: host)
        laptop.store.add(laptop.folder, writable: false, for: "host")
        let cli = try commandLine(host)
        var write = request(.macWrite, path: laptop.folder + "/note.txt")
        write.text = "hi\n"

        // 那边只读：拒绝。
        let readOnly = await cli.handler.handle(write)
        XCTAssertEqual(readOnly.code, ControlErrorCode.permission_denied.rawValue)

        // 那边读写了，但本机没开「允许执行命令与写入」：还是不行。
        laptop.store.setWritable(true, path: laptop.folder, for: "host")
        cli.settings.allowMutations = false
        let gated = await cli.handler.handle(write)
        XCTAssertEqual(gated.code, ControlErrorCode.mutations_disabled.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: laptop.folder + "/note.txt"))

        cli.settings.allowMutations = true
        let done = await cli.handler.handle(write)
        XCTAssertTrue(done.ok, done.message)
        XCTAssertEqual(try String(contentsOfFile: laptop.folder + "/note.txt", encoding: .utf8), "hi\n")

        // 跑命令：本机开关开着也不行，那台 Mac 不接受。
        var run = request(.macRun)
        run.command = "id"
        let refused = await cli.handler.handle(run)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.code, ControlErrorCode.permission_denied.rawValue)
    }

    // MARK: - 设置

    func test_shared_folders_persist_and_are_forgotten_with_the_mac() throws {
        let suite = "RemoteFileSharingEndToEndTests.store.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteFileSharingStore(defaults: defaults)
        XCTAssertNil(store.scope(for: "mini"))
        store.add("/Users/me/project/", writable: false, for: "mini")
        store.add("/Users/me/notes", writable: true, for: "mini")
        store.add("/Users/me/project", writable: true, for: "mini")
        store.add("/Users/me/other", writable: false, for: "studio")
        XCTAssertEqual(store.roots(for: "mini"), [RemoteFileRoot(path: "/Users/me/project", writable: true),
                                                   RemoteFileRoot(path: "/Users/me/notes", writable: true)])

        let reloaded = RemoteFileSharingStore(defaults: defaults)
        XCTAssertEqual(reloaded.shares, store.shares)
        reloaded.remove("/Users/me/notes", for: "mini")
        reloaded.removeAll(for: "studio")
        XCTAssertEqual(RemoteFileSharingStore(defaults: defaults).shares,
                       ["mini": [RemoteFileRoot(path: "/Users/me/project", writable: true)]])
        reloaded.removeAll(for: "mini")
        XCTAssertNil(defaults.data(forKey: DefaultsKey.remoteSharedFolders))
    }
}
