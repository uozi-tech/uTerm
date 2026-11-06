import XCTest
import SwiftData
@testable import uTerm

/// `FileBrowserModel` 两端共享后新增 / 统一的语义（iOS `MobileSFTPController` 也跑这一份）：
/// 目录加载后发者胜、列不出的目录留在原目录、关掉后在途结果不落地、建连凭据与终端同一套。
@MainActor
final class FileBrowserSharedCoreTests: XCTestCase {
    private func dir(_ names: [(String, Bool)]) -> [RemoteEntry] {
        names.map { RemoteEntry(name: $0.0,
                                posixPermissions: $0.1 ? 0o040755 : 0o100644,
                                size: $0.1 ? nil : 10, modifiedAt: nil) }
    }

    private struct DeniedError: Error, LocalizedError {
        var errorDescription: String? { "Permission denied" }
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: ServerProfile.self, configurations: config)
    }

    // MARK: - 列目录失败

    /// 浏览中进一个列不出的目录：不进去、不翻失败页，给「打开目录失败」提示。
    /// 改前 macOS 先改 `currentPath` 再列，失败就整页「无法浏览文件」，「重新连接」还会再列一次那个目录。
    func testNavigateIntoUnreadableDirectoryStaysPutWithTransientError() async {
        let mock = MockSFTP(tree: ["/home": dir([("locked", true), ("a.txt", false)])])
        await mock.setListError(DeniedError(), at: "/home/locked")
        let model = FileBrowserModel(testProvider: mock, startPath: "/home")
        await model.refresh()

        await model.navigate(toPath: "/home/locked")

        XCTAssertEqual(model.state, .browsing)
        XCTAssertEqual(model.currentPath, "/home")
        XCTAssertEqual(model.entries.map(\.name), ["locked", "a.txt"])
        XCTAssertFalse(model.isNavigating)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.transientError?.hasPrefix("打开目录失败"), true)
    }

    // MARK: - 加载代次

    /// 先发起的慢加载晚回来，不能把列表和路径改回去。
    func testLaterLoadWinsOverSlowerEarlierLoad() async {
        let mock = MockSFTP(tree: [
            "/": dir([("a", true), ("b", true)]),
            "/a": dir([("in-a", false)]),
            "/b": dir([("in-b", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/")
        await model.refresh()
        await mock.holdList("/a")

        let slow = Task { await model.load("/a") }
        await waitUntil { model.isLoading }
        await model.load("/b")
        await mock.releaseList("/a")
        await slow.value

        XCTAssertEqual(model.currentPath, "/b")
        XCTAssertEqual(model.entries.map(\.name), ["in-b"])
        XCTAssertFalse(model.isLoading)
    }

    /// 切目录在途时触发的刷新（如上传完成）列切换的目标，而不是把切换顶回旧目录。
    func testRefreshDuringNavigationListsPendingTarget() async {
        let mock = MockSFTP(tree: [
            "/": dir([("a", true)]),
            "/a": dir([("in-a", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/")
        await model.refresh()
        await mock.holdList("/a")

        let navigation = Task { await model.navigate(toPath: "/a") }
        await waitUntil { model.isNavigating }
        let refresh = Task { await model.refresh() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await mock.releaseList("/a")
        await navigation.value
        await refresh.value

        XCTAssertEqual(model.currentPath, "/a")
        XCTAssertEqual(model.entries.map(\.name), ["in-a"])
        XCTAssertFalse(model.isNavigating)
    }

    /// 关掉之后，在途的目录加载结果不再落地。
    func testDisposeDropsInFlightLoad() async {
        let mock = MockSFTP(tree: ["/": dir([("a", true)]), "/a": dir([("x", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/")
        await model.refresh()
        await mock.holdList("/a")

        let load = Task { await model.load("/a") }
        await waitUntil { model.isLoading }
        model.dispose()
        await mock.releaseList("/a")
        await load.value

        XCTAssertEqual(model.currentPath, "/")
        XCTAssertEqual(model.entries.map(\.name), ["a"])
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - 建连代次

    /// 建连期间被关掉：会话落地后直接关掉，不挂在已关闭的模型上。改前 macOS 会把它接上、泄漏一条 SFTP 通道。
    func testDisposeDuringConnectClosesLateSession() async throws {
        let container = try makeContainer()
        let server = ServerProfile()
        server.host = "127.0.0.1"
        container.mainContext.insert(server)

        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let gate = AsyncGate()
        let model = FileBrowserModel(sftpConnector: { _, _, _ in
            await gate.wait()
            return mock
        })
        let connect = Task { await model.connect(profile: server, modelContainer: container) }
        await waitUntil { model.state == .connecting }

        model.dispose()
        XCTAssertEqual(model.state, .idle)
        await gate.open()
        await connect.value

        XCTAssertNil(model.sftpProvider)
        XCTAssertNotEqual(model.state, .browsing)
        let closed = await mock.didClose
        XCTAssertTrue(closed, "迟到的会话要关掉")
    }

    // MARK: - 平台参数

    /// iOS 的固定排序：显示点文件、不补属主名（不发 exec）。
    func testFixedSortOptionsAndNoOwnerResolution() async {
        let mock = MockSFTP(tree: ["/": dir([("f10", false), (".ssh", false), ("f2", false), ("zdir", true)])])
        let model = FileBrowserModel(
            testProvider: mock, startPath: "/",
            sortOptions: RemoteEntrySortOptions(key: .name, ascending: true,
                                                foldersFirst: true, showHidden: true),
            resolvesOwnerNames: false)
        await model.load("/")

        XCTAssertEqual(model.sortedEntries.map(\.name), ["zdir", ".ssh", "f2", "f10"])
        let commands = await mock.execCommands
        XCTAssertTrue(commands.isEmpty, "不补属主名就不该开 exec：\(commands)")
    }

    /// 操作显式给目录时落在那个目录（iOS 操作单传长按那一刻的目录）。
    func testOperationsUseExplicitDirectory() async {
        let mock = MockSFTP(tree: ["/a": dir([("f", false)]), "/b": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/b")
        await model.refresh()
        let entry = RemoteEntry(name: "f", posixPermissions: 0o100644, size: 1, modifiedAt: nil)

        await model.rename(entry: entry, to: "g", in: "/a")
        await model.setPermissions(entry: entry, mode: 0o600, recursive: false, in: "/a")
        await model.delete(entry: entry, in: "/a")

        let renames = await mock.renames
        XCTAssertEqual(renames.map(\.from), ["/a/f"])
        XCTAssertEqual(renames.map(\.to), ["/a/g"])
        let chmods = await mock.permissionChanges
        XCTAssertEqual(chmods.map(\.path), ["/a/f"])
        let removed = await mock.removedFiles
        XCTAssertEqual(removed, ["/a/f"])
    }

    /// 单次操作失败：提示走统一格式「<动作>失败：<原因>」，浏览照常。
    func testOperationFailureIsTransient() async {
        let mock = MockSFTP(tree: ["/": dir([("f", false)])])
        await mock.setFailingRemovePaths(["/f"])
        let model = FileBrowserModel(testProvider: mock, startPath: "/")
        await model.refresh()

        await model.delete(entry: model.entries[0])

        XCTAssertEqual(model.state, .browsing)
        XCTAssertEqual(model.transientError?.hasPrefix("删除失败："), true)
    }

    // MARK: - 建连凭据（与终端同一套 resolveForConnect）

    /// 跳板机凭据缺失：直接报错，绝不当作没有跳板机去直连目标。
    func testMakeSessionFailsWhenJumpHostCredentialsMissing() async throws {
        let container = try makeContainer()
        let jump = ServerProfile()
        jump.host = "bastion.invalid"
        jump.authMethod = .password
        let target = ServerProfile()
        target.host = "target.invalid"
        target.authMethod = .password
        target.jumpHost = jump
        container.mainContext.insert(jump)
        container.mainContext.insert(target)

        let keychain = FakeKeychain(passwords: [target.id: "pw"])
        do {
            _ = try await SFTPSession.make(profile: target, container: container,
                                           approver: { _ in false }, keychain: keychain)
            XCTFail("跳板机没有凭据时不应建连")
        } catch {
            XCTAssertEqual(error as? SSHAuthError, .missingPassword)
        }
    }

    /// 目标自己的凭据缺失同样在建连前报错。
    func testMakeSessionFailsWhenTargetCredentialsMissing() async throws {
        let container = try makeContainer()
        let target = ServerProfile()
        target.host = "target.invalid"
        target.authMethod = .password
        container.mainContext.insert(target)

        do {
            _ = try await SFTPSession.make(profile: target, container: container,
                                           approver: { _ in false }, keychain: FakeKeychain(passwords: [:]))
            XCTFail("没有凭据时不应建连")
        } catch {
            XCTAssertEqual(error as? SSHAuthError, .missingPassword)
        }
    }
}

/// 只给密码的假钥匙串。
private struct FakeKeychain: KeychainReading, Sendable {
    let passwords: [UUID: String]
    func load(profileID: UUID, kind: SecretKind) throws -> String? {
        kind == .password ? passwords[profileID] : nil
    }
}

/// 一次性闸门：`wait()` 挂起直到 `open()`。
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
