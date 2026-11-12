import SwiftData
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程 Mac 的文件通道，端到端：主控端的 `RemoteMacFileProvider` / 命令行 handler → 真实的加密链路
/// （本机回环）→ 被控端的 `RemoteHostConnection` → 文件服务。
///
/// 被控端这里不起辅助程序（XPC 要真机），`fileAccess` 直接调同一份 `RemoteFileService`；
/// 文件都在测试宿主自己的临时目录里。
@MainActor
final class RemoteMacFilesEndToEndTests: XCTestCase {

    private var root = ""

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("remote-mac-files-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
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

    /// 真做事的文件通道；`allowed` 为 false 时像设置里关了开关一样拒绝。
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        var isOpen: Bool {
            get { lock.withLock { open } }
            set { lock.withLock { open = newValue } }
        }
    }

    private func access(_ gate: Gate) -> RemoteFileAccess {
        RemoteFileAccess(
            refusal: { _ in gate.isOpen ? nil : RemoteFileError(.disabled, "那台 Mac 上没有打开「允许打开本机终端」") },
            perform: { payload in RemoteFileService.handle(payload) })
    }

    private func pairedClient(features: [String]? = nil, gate: Gate = Gate()) async throws -> (RemoteHostServer, RemoteMacClient) {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features ?? RemoteConstants.localFeatures)
        server.fileAccess = access(gate)
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        return (server, client)
    }

    private func path(_ name: String) -> String { root + "/" + name }

    private static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - 文件通道

    func test_provider_browses_and_edits_the_remote_tree() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        XCTAssertTrue(client.supportsFiles)
        let provider = RemoteMacFileProvider(client: client)

        try await provider.createDirectory(path("docs"))
        try await provider.upload(data: Data("hello".utf8), toRemotePath: path("docs/a.txt"))
        let entries = try await provider.list(path: path("docs"))
        XCTAssertEqual(entries.map(\.name), ["a.txt"])
        XCTAssertEqual(entries.first?.size, 5)

        let stat = try await provider.stat(path("docs/a.txt"))
        XCTAssertEqual(stat.size, 5)
        let downloaded = try await provider.download(remotePath: path("docs/a.txt"))
        XCTAssertEqual(downloaded, Data("hello".utf8))

        try await provider.rename(path("docs/a.txt"), to: path("docs/b.txt"))
        try await provider.setPermissions(path: path("docs/b.txt"), mode: 0o600)
        let renamed = try await provider.list(path: path("docs"))
        XCTAssertEqual(renamed.map(\.name), ["b.txt"])
        XCTAssertEqual(renamed.first?.permissions.map { $0 & 0o777 }, 0o600)

        try await provider.removeFile(path("docs/b.txt"))
        try await provider.removeDirectory(path("docs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("docs")))

        let output = try await provider.exec("echo from-the-mac")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "from-the-mac")
    }

    func test_large_file_survives_upload_and_download() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let provider = RemoteMacFileProvider(client: client)
        // 跨好几个传输片、最后一片不满，也超过链路的单帧上限。
        let payload = Self.randomData(5 * 1024 * 1024 + 12_345)
        let source = URL(fileURLWithPath: path("local-source.bin"))
        try payload.write(to: source)

        try await provider.upload(localURL: source, toRemotePath: path("remote.bin"), onProgress: nil)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("remote.bin"))), payload)

        let target = URL(fileURLWithPath: path("local-copy.bin"))
        try await provider.download(remotePath: path("remote.bin"), toLocalURL: target, onProgress: nil)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(client.state, .connected)
    }

    func test_errors_keep_their_kind_across_the_link() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let provider = RemoteMacFileProvider(client: client)
        do {
            _ = try await provider.stat(path("nope"))
            XCTFail("应当失败")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertEqual(client.state, .connected, "操作失败不断开连接")
    }

    func test_switch_off_on_the_mac_refuses_every_request() async throws {
        let gate = Gate()
        let (server, client) = try await pairedClient(gate: gate)
        defer { server.stop() }
        let provider = RemoteMacFileProvider(client: client)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path("a.txt")))
        _ = try await provider.stat(path("a.txt"))

        gate.isOpen = false
        do {
            _ = try await provider.stat(path("a.txt"))
            XCTFail("应当被拒")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error.code, .disabled)
        }
        XCTAssertEqual(client.state, .connected)
    }

    func test_old_mac_without_the_files_feature_is_refused_locally() async throws {
        // 老版本收到不认识的消息会直接断开，所以主控端必须先挡住，不能把请求发出去。
        let (server, client) = try await pairedClient(features: [RemoteFeature.desktop])
        defer { server.stop() }
        XCTAssertFalse(client.supportsFiles)
        do {
            _ = try await RemoteMacFileProvider(client: client).list(path: root)
            XCTFail("应当失败")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error.code, .unsupported)
        }
        XCTAssertEqual(client.state, .connected)
    }

    func test_pending_requests_fail_when_the_link_drops() async throws {
        let (server, client) = try await pairedClient()
        let provider = RemoteMacFileProvider(client: client)
        var request = RemoteFileRequest(op: .waitChange, path: root)
        request.seconds = 60
        let pending = Task { try await provider.perform(request) }
        try await Task.sleep(for: .milliseconds(200))
        server.stop()
        do {
            _ = try await pending.value
            XCTFail("应当失败")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error.code, .unreachable)
        }
    }

    // MARK: - 文件窗口

    /// 「我的 Mac」里的文件窗口：连上后从主目录开始，浏览器本体是 SFTP 窗口的那一套，跑在远控链路上。
    func test_files_window_browses_from_home_with_the_shared_browser_model() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let window = RemoteMacFilesWindowModel(client: client)
        await window.open()
        XCTAssertEqual(window.phase, .browsing)
        let browser = try XCTUnwrap(window.browser)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        XCTAssertEqual(browser.currentPath, home)
        XCTAssertNil(browser.transientError)

        // 进一个目录、建文件夹、上传、改名、删除：都是两端共享的 `FileBrowserModel` 在做。
        await browser.navigate(toPath: root)
        XCTAssertEqual(browser.currentPath, root)
        await browser.makeDirectory(name: "inbox")
        XCTAssertEqual(browser.sortedEntries.map(\.name), ["inbox"])
        await browser.navigate(toPath: path("inbox"))
        let local = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("up-\(UUID().uuidString).txt")
        try Data("uploaded".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        await browser.upload(localURL: local)
        XCTAssertNil(browser.transientError)
        let uploaded = try XCTUnwrap(browser.sortedEntries.first)
        XCTAssertEqual(try String(contentsOfFile: path("inbox/\(uploaded.name)"), encoding: .utf8), "uploaded")
        await browser.rename(entry: uploaded, to: "note.txt")
        XCTAssertEqual(browser.sortedEntries.map(\.name), ["note.txt"])
        await browser.delete(entry: try XCTUnwrap(browser.sortedEntries.first))
        XCTAssertTrue(browser.sortedEntries.isEmpty)
        XCTAssertNil(browser.transientError)

        // 再调一次（断线重连上之后）不重开，目录留在原地。
        await window.open()
        XCTAssertTrue(window.browser === browser)
        XCTAssertEqual(browser.currentPath, path("inbox"))
    }

    func test_files_window_explains_why_it_cannot_open() async throws {
        let gate = Gate()
        gate.isOpen = false
        let (server, client) = try await pairedClient(gate: gate)
        defer { server.stop() }
        let window = RemoteMacFilesWindowModel(client: client)
        await window.open()
        guard case .failed(let message) = window.phase else { return XCTFail("应当停在失败页：\(window.phase)") }
        XCTAssertTrue(message.contains("允许打开本机终端"), message)
        XCTAssertNil(window.browser)

        // 那台 Mac 上把开关打开之后重试就进去了。
        gate.isOpen = true
        await window.open()
        XCTAssertEqual(window.phase, .browsing)

        let (oldServer, oldClient) = try await pairedClient(features: [RemoteFeature.desktop])
        defer { oldServer.stop() }
        let old = RemoteMacFilesWindowModel(client: oldClient)
        await old.open()
        XCTAssertEqual(old.phase, .unsupported)
    }

    // MARK: - 命令行

    @MainActor
    private final class FakeMacs: ControlRemoteMacs {
        let session: ControlMacSession
        private(set) var borrowed = 0
        private(set) var returned = 0

        init(client: RemoteMacClient) {
            session = ControlMacSession(id: UUID().uuidString, name: "studio", provider: RemoteMacFileProvider(client: client))
        }

        func snapshots(session caller: UUID?) -> [ControlMacSnapshot] {
            [ControlMacSnapshot(id: session.id, name: session.name, role: ControlMacRole.host,
                                onLocalNetwork: true, onRelay: nil, connected: true, path: "局域网", supportsFiles: true)]
        }

        func provider(for needle: String, session caller: UUID?) async throws(ControlFailure) -> ControlMacSession {
            guard needle == session.name else {
                throw ControlFailure(code: .host_not_found, message: "没有名为「\(needle)」的已配对 Mac")
            }
            borrowed += 1
            return session
        }

        func finished(_ session: ControlMacSession) { returned += 1 }
        func release(_ needle: String?) -> Int { 0 }
    }

    private struct CLI {
        let handler: ControlHandler
        let settings: ControlSettings
        let macs: FakeMacs
    }

    private func commandLine(_ client: RemoteMacClient) throws -> CLI {
        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let suite = "RemoteMacFilesEndToEndTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = ControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = true
        let macs = FakeMacs(client: client)
        let handler = ControlHandler(settings: settings, modelContainer: container,
                                     forwardingCoordinator: ForwardingCoordinator(),
                                     pool: ControlConnectionPool.shared, registry: TerminalSessionRegistry(),
                                     macs: macs)
        return CLI(handler: handler, settings: settings, macs: macs)
    }

    private func request(_ action: ControlAction, path: String? = nil,
                         _ configure: (inout ControlRequest) -> Void = { _ in }) -> ControlRequest {
        var request = ControlRequest(id: UUID().uuidString, action: action, path: path)
        request.mac = ControlMacArguments(target: "studio")
        configure(&request)
        return request
    }

    private func transfer(_ cli: CLI, _ request: ControlRequest, fd: Int32) async -> (ControlResponse, ControlRequestContext) {
        let context = ControlRequestContext(fileDescriptors: [fd])
        let response = await ControlRequestContext.$current.withValue(context) {
            await cli.handler.handle(request)
        }
        context.closeUntaken()
        return (response, context)
    }

    func test_cli_lists_reads_and_searches() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let cli = try commandLine(client)
        try FileManager.default.createDirectory(atPath: path("src"), withIntermediateDirectories: true)
        try Data("import Foundation\nfunc alpha() {}\nfunc beta() {}\n".utf8).write(to: URL(fileURLWithPath: path("src/a.swift")))

        let listing = await cli.handler.handle(ControlRequest(id: "1", action: .macs))
        XCTAssertTrue(listing.ok, listing.message)
        XCTAssertEqual(listing.mac?.macs?.map(\.name), ["studio"])

        let ls = await cli.handler.handle(request(.macLs, path: path("src")))
        XCTAssertTrue(ls.ok, ls.message)
        XCTAssertEqual(ls.entries?.map(\.name), ["a.swift"])

        let stat = await cli.handler.handle(request(.macStat, path: path("src/a.swift")))
        XCTAssertEqual(stat.stat?.size, 49)
        XCTAssertEqual(stat.stat?.kind, "file")

        let cat = await cli.handler.handle(request(.macCat, path: path("src/a.swift")))
        XCTAssertEqual(cat.file?.text, "import Foundation\nfunc alpha() {}\nfunc beta() {}\n")

        let read = await cli.handler.handle(request(.macRead, path: path("src/a.swift")) {
            $0.mac?.startLine = 2
            $0.mac?.endLine = 2
        })
        XCTAssertEqual(read.mac?.text, "func alpha() {}\n")
        XCTAssertEqual(read.mac?.totalLines, 3)

        let bytes = await cli.handler.handle(request(.macRead, path: path("src/a.swift")) {
            $0.mac?.offset = 7
            $0.mac?.length = 10
        })
        XCTAssertEqual(bytes.file?.text, "Foundation")

        let grep = await cli.handler.handle(request(.macGrep, path: root) { $0.mac?.pattern = "func \\w+" })
        XCTAssertTrue(grep.ok, grep.message)
        XCTAssertEqual(grep.mac?.matches?.map(\.line), [2, 3])

        let find = await cli.handler.handle(request(.macFind, path: root) { $0.mac?.pattern = "*.swift" })
        XCTAssertEqual(find.mac?.found?.count, 1)
        XCTAssertTrue(find.mac?.found?.first?.path.hasSuffix("a.swift") == true)

        let tree = await cli.handler.handle(request(.macTree, path: root))
        XCTAssertTrue(tree.mac?.text?.contains("a.swift") == true)

        let missing = await cli.handler.handle(request(.macStat, path: path("nope")))
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.code, ControlErrorCode.file_not_found.rawValue)

        XCTAssertEqual(cli.macs.borrowed, cli.macs.returned, "每次动作做完都要归还")
    }

    func test_cli_writes_edits_and_runs() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let cli = try commandLine(client)

        let written = await cli.handler.handle(request(.macWrite, path: path("note.txt")) { $0.text = "one two\n" })
        XCTAssertTrue(written.ok, written.message)
        XCTAssertEqual(try String(contentsOfFile: path("note.txt"), encoding: .utf8), "one two\n")

        let again = await cli.handler.handle(request(.macWrite, path: path("note.txt")) { $0.text = "clobber" })
        XCTAssertEqual(again.code, ControlErrorCode.file_exists.rawValue, "默认只肯新建")
        let forced = await cli.handler.handle(request(.macWrite, path: path("note.txt")) {
            $0.text = "one two three\n"
            $0.force = true
        })
        XCTAssertTrue(forced.ok, forced.message)

        let edited = await cli.handler.handle(request(.macEdit, path: path("note.txt")) {
            $0.mac?.oldText = "two"
            $0.mac?.newText = "2"
            $0.mac?.ifMatch = forced.mac?.sha256
        })
        XCTAssertTrue(edited.ok, edited.message)
        XCTAssertEqual(try String(contentsOfFile: path("note.txt"), encoding: .utf8), "one 2 three\n")

        let run = await cli.handler.handle(request(.macRun, path: root) { $0.command = "cat note.txt; exit 4" })
        XCTAssertTrue(run.ok, run.message)
        XCTAssertEqual(run.result?.exitCode, 4)
        XCTAssertEqual(run.result?.output, "one 2 three\n")
        XCTAssertEqual(run.result?.host, "studio")

        let stuck = await cli.handler.handle(request(.macRun, path: root) {
            $0.command = "echo started; sleep 30"
            $0.timeoutSeconds = 1
        })
        XCTAssertEqual(stuck.code, ControlErrorCode.command_timeout.rawValue)
        XCTAssertEqual(stuck.results?.first?.timedOut, true)
        XCTAssertEqual(stuck.results?.first?.output, "started\n")

        let moved = await cli.handler.handle(request(.macMv, path: path("note.txt")) { $0.newPath = self.path("moved.txt") })
        XCTAssertTrue(moved.ok, moved.message)
        let trashed = await cli.handler.handle(request(.macRm, path: path("moved.txt")))
        XCTAssertTrue(trashed.ok, trashed.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("moved.txt")))
    }

    func test_cli_mutations_need_the_second_switch() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let cli = try commandLine(client)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path("a.txt")))
        cli.settings.allowMutations = false

        for blocked in [request(.macRun) { $0.command = "id" },
                        request(.macRm, path: path("a.txt")),
                        request(.macWrite, path: path("b.txt")) { $0.text = "b" },
                        request(.macXattr, path: path("a.txt")) {
                            $0.mac?.attributeAction = "set"
                            $0.mac?.attribute = "com.uozi.test"
                            $0.text = "v"
                        }] {
            let response = await cli.handler.handle(blocked)
            XCTAssertEqual(response.code, ControlErrorCode.mutations_disabled.rawValue, blocked.action.rawValue)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("a.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("b.txt")))

        // 只读的照常能用。
        let listed = await cli.handler.handle(request(.macXattr, path: path("a.txt")))
        XCTAssertTrue(listed.ok, listed.message)
        let stat = await cli.handler.handle(request(.macStat, path: path("a.txt")))
        XCTAssertTrue(stat.ok, stat.message)
    }

    func test_cli_get_and_put_move_bytes_through_the_passed_descriptor() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let cli = try commandLine(client)
        let payload = Self.randomData(2 * 1024 * 1024 + 777)

        // put：本地文件的 fd → 那台 Mac。
        let source = path("local.bin")
        try payload.write(to: URL(fileURLWithPath: source))
        let (put, putContext) = await transfer(cli, request(.macPut, path: path("remote.bin")), fd: open(source, O_RDONLY))
        XCTAssertTrue(put.ok, put.message)
        XCTAssertEqual(put.transfer?.totalBytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("remote.bin"))), payload)
        XCTAssertNotNil(putContext.drainProgress(), "传输过程要报进度")

        // 已存在：不给 force 就拒绝，内容不动。
        let (clash, _) = await transfer(cli, request(.macPut, path: path("remote.bin")), fd: open(source, O_RDONLY))
        XCTAssertEqual(clash.code, ControlErrorCode.file_exists.rawValue)

        // get：那台 Mac → 本地 fd。
        let target = path("copy.bin")
        let (get, _) = await transfer(cli, request(.macGet, path: path("remote.bin")),
                                      fd: open(target, O_RDWR | O_CREAT, 0o644))
        XCTAssertTrue(get.ok, get.message)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), payload)

        // 续传：只补一段，别处不动。
        let partial = path("partial.bin")
        FileManager.default.createFile(atPath: partial, contents: Data(count: payload.count))
        let range = ControlByteRange(offset: 1_000_000, length: 500_000)
        let (resumed, _) = await transfer(cli, request(.macGet, path: path("remote.bin")) { $0.ranges = [range] },
                                          fd: open(partial, O_RDWR))
        XCTAssertTrue(resumed.ok, resumed.message)
        XCTAssertEqual(resumed.transfer?.bytes, 500_000)
        let patched = try Data(contentsOf: URL(fileURLWithPath: partial))
        XCTAssertEqual(patched.subdata(in: 1_000_000..<1_500_000), payload.subdata(in: 1_000_000..<1_500_000))
        XCTAssertEqual(patched.prefix(1_000_000), Data(count: 1_000_000), "区间之外不写")

        // 没交 fd：说清楚，不崩。
        let bare = await cli.handler.handle(request(.macGet, path: path("remote.bin")))
        XCTAssertEqual(bare.code, ControlErrorCode.invalid_request.rawValue)
    }

    func test_cli_reports_unknown_mac() async throws {
        let (server, client) = try await pairedClient()
        defer { server.stop() }
        let cli = try commandLine(client)
        var unknown = request(.macLs, path: root)
        unknown.mac?.target = "nobody"
        let response = await cli.handler.handle(unknown)
        XCTAssertEqual(response.code, ControlErrorCode.host_not_found.rawValue)
    }
}
