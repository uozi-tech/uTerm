import XCTest
@testable import uTerm

/// 「打开」整条链路：真实文件系统上的下载 → 外部应用存盘 → 轮询 → 自动上传，
/// 以及冲突 / 失败 / 关窗前立即上传 / 数据库交 uTable 的分流。系统交互（起应用、弹框）
/// 用 `ExternalOpenSystem` 注入的假实现，远端用 `MockSFTP`。
@MainActor
final class ExternalOpenCoordinatorTests: XCTestCase {
    /// 假的系统层：记录调用，按预设回答。
    @MainActor final class FakeSystem {
        var launched: [(file: URL, app: URL?)] = []
        var hasDefaultApp = true
        var chosenApp: URL? = URL(fileURLWithPath: "/Applications/Chosen.app")
        var chooseCalls = 0
        var uTableAvailable = false
        var uTableOpens: [(UUID, String)] = []
        var confirmInUse = true
        var inUseAsked: [[String]] = []
        var conflictChoice: ExternalOpenSystem.ConflictChoice = .cancel
        var conflictsAsked = 0

        func make(root: URL) -> ExternalOpenSystem {
            ExternalOpenSystem(
                launch: { [unowned self] file, app in launched.append((file, app)); return true },
                hasDefaultApplication: { [unowned self] _ in hasDefaultApp },
                chooseApplication: { [unowned self] _ in chooseCalls += 1; return chosenApp },
                uTableAvailable: { [unowned self] in uTableAvailable },
                openInUTable: { [unowned self] id, path in uTableOpens.append((id, path)); return true },
                confirmOpenWhileInUse: { [unowned self] _, companions in
                    inUseAsked.append(companions); return confirmInUse
                },
                askConflict: { [unowned self] _ in conflictsAsked += 1; return conflictChoice },
                confirmStopSync: { _ in true },
                stagingRoot: root)
        }
    }

    private var root: URL!
    private var sftp: MockSFTP!
    private var fake: FakeSystem!
    private var defaultsSuite: String!
    private var host = ExternalOpenHost(id: UUID(), name: "demo-server", usesJumpHost: false)
    private let remotePath = "/root/projects/cdn_cert/config.ini"
    private let loadedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalOpenCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sftp = MockSFTP()
        await sftp.setFile(remotePath, data: Data("a=1\n".utf8), mtime: loadedAt)
        fake = FakeSystem()
        defaultsSuite = "ExternalOpenCoordinatorTests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private func makeCoordinator() -> ExternalOpenCoordinator {
        let sftp = self.sftp!
        let host = self.host
        return ExternalOpenCoordinator(
            provider: { sftp },
            host: { host },
            preference: ExternalAppPreference(defaults: UserDefaults(suiteName: defaultsSuite)!,
                                              fileExists: { _ in true }),
            system: fake.make(root: root),
            pollInterval: .seconds(3600))   // 测试里手动 pollNow，不让后台轮询插进来
    }

    /// 模拟外部编辑器存盘：写临时文件再 rename（换 inode），跟大多数编辑器一样。
    private func externalSave(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - 下载 → 存盘 → 自动上传

    func testOpenDownloadsLaunchesAndUploadsAfterExternalSave() async throws {
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)

        let session = try XCTUnwrap(coordinator.sessions.first)
        XCTAssertEqual(session.remotePath, remotePath)
        XCTAssertTrue(session.localURL.path.hasPrefix(root.path), "暂存进私有目录")
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "a=1\n")
        XCTAssertEqual(fake.launched.count, 1)
        XCTAssertNil(fake.launched.first?.app, "有默认应用 → 交给系统默认应用")

        await coordinator.pollNow()
        let untouched = await sftp.streamingUploads
        XCTAssertTrue(untouched.isEmpty, "没改动不上传")

        try externalSave("a=2\n", to: session.localURL)
        await coordinator.pollNow()
        let settling = await sftp.streamingUploads
        XCTAssertTrue(settling.isEmpty, "第一次看到新指纹只记下，等它稳定")
        await coordinator.pollNow()

        let uploads = await sftp.streamingUploads
        XCTAssertEqual(uploads.map(\.remotePath), [remotePath])
        XCTAssertEqual(uploads.first?.localURL, session.localURL)
        XCTAssertTrue(coordinator.toasts.contains { $0.kind == .success })
        XCTAssertTrue(coordinator.unsyncedSessions.isEmpty)

        await coordinator.pollNow()
        let afterSync = await sftp.streamingUploads
        XCTAssertEqual(afterSync.count, 1, "传完不重复传")
        coordinator.dispose()
    }

    func testReopeningSameFileReusesLocalCopyWithoutRedownloading() async throws {
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        let local = try XCTUnwrap(coordinator.sessions.first?.localURL)
        try externalSave("local edit\n", to: local)

        await coordinator.open(remotePath: remotePath)

        let downloads = await sftp.streamingDownloads
        XCTAssertEqual(downloads.count, 1, "再次打开不重新下载，免得盖掉没上传的改动")
        XCTAssertEqual(coordinator.sessions.count, 1)
        XCTAssertEqual(fake.launched.map(\.file), [local, local])
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "local edit\n")
        coordinator.dispose()
    }

    // MARK: - 冲突

    func testRemoteChangedAndUserPostponesDoesNotUploadOrRetry() async throws {
        fake.conflictChoice = .cancel
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        let local = try XCTUnwrap(coordinator.sessions.first?.localURL)
        await sftp.setFile(remotePath, data: Data("a=remote\n".utf8), mtime: loadedAt.addingTimeInterval(60))

        try externalSave("a=mine\n", to: local)
        await coordinator.pollNow()
        await coordinator.pollNow()
        XCTAssertEqual(fake.conflictsAsked, 1)
        await coordinator.pollNow()
        await coordinator.pollNow()
        XCTAssertEqual(fake.conflictsAsked, 1, "暂缓后同一版不再反复弹冲突框")
        let uploads = await sftp.streamingUploads
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(coordinator.unsyncedSessions.count, 1)
        coordinator.dispose()
    }

    func testRemoteChangedAndUserKeepsMineOverwritesRemote() async throws {
        fake.conflictChoice = .keepMine
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        let local = try XCTUnwrap(coordinator.sessions.first?.localURL)
        await sftp.setFile(remotePath, data: Data("a=remote\n".utf8), mtime: loadedAt.addingTimeInterval(60))

        try externalSave("a=mine\n", to: local)
        await coordinator.pollNow()
        await coordinator.pollNow()

        let uploads = await sftp.streamingUploads
        XCTAssertEqual(uploads.map(\.remotePath), [remotePath])
        XCTAssertTrue(coordinator.unsyncedSessions.isEmpty)
        coordinator.dispose()
    }

    func testRemoteChangedAndUserTakesRemoteReplacesLocalCopy() async throws {
        fake.conflictChoice = .useRemote
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        let local = try XCTUnwrap(coordinator.sessions.first?.localURL)
        await sftp.setFile(remotePath, data: Data("a=remote\n".utf8), mtime: loadedAt.addingTimeInterval(60))

        try externalSave("a=mine\n", to: local)
        await coordinator.pollNow()
        await coordinator.pollNow()

        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "a=remote\n")
        let uploads = await sftp.streamingUploads
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(coordinator.unsyncedSessions.isEmpty)
        coordinator.dispose()
    }

    // MARK: - 失败 / 关窗前立即上传

    func testUploadFailureShowsRetryAndDoesNotAutoRetrySameVersion() async throws {
        await sftp.setFailingUploadPaths([remotePath])
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        let local = try XCTUnwrap(coordinator.sessions.first?.localURL)

        try externalSave("a=2\n", to: local)
        await coordinator.pollNow()
        await coordinator.pollNow()

        guard case .failed = coordinator.sessions.first?.state else {
            return XCTFail("应标记为上传失败")
        }
        XCTAssertTrue(coordinator.toasts.contains { $0.kind == .failure && $0.retrySessionID != nil })
        await coordinator.pollNow()
        await coordinator.pollNow()
        let attempts = await sftp.streamingUploads
        XCTAssertEqual(attempts.count, 1, "失败的那一版不每秒重试，等用户点重试或再次存盘")
        XCTAssertEqual(coordinator.unsyncedSessions.count, 1)
        coordinator.dispose()
    }

    func testFlushUploadsImmediatelyWithoutWaitingForSettle() async throws {
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        let local = try XCTUnwrap(coordinator.sessions.first?.localURL)
        try externalSave("a=2\n", to: local)
        XCTAssertEqual(coordinator.unsyncedSessions.count, 1)

        let ok = await coordinator.flushPendingUploads()

        XCTAssertTrue(ok)
        let uploads = await sftp.streamingUploads
        XCTAssertEqual(uploads.count, 1)
        XCTAssertTrue(coordinator.unsyncedSessions.isEmpty)
        coordinator.dispose()
    }

    func testFlushReportsFailure() async throws {
        await sftp.setFailingUploadPaths([remotePath])
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        try externalSave("a=2\n", to: try XCTUnwrap(coordinator.sessions.first?.localURL))

        let ok = await coordinator.flushPendingUploads()

        XCTAssertFalse(ok)
        XCTAssertEqual(coordinator.unsyncedSessions.count, 1)
        coordinator.dispose()
    }

    // MARK: - 选应用

    func testWithoutDefaultAppAsksOnceThenRemembers() async throws {
        fake.hasDefaultApp = false
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath)
        XCTAssertEqual(fake.chooseCalls, 1)
        XCTAssertEqual(fake.launched.last?.app?.lastPathComponent, "Chosen.app")

        let other = "/etc/other.ini"
        await sftp.setFile(other, data: Data("x".utf8), mtime: loadedAt)
        await coordinator.open(remotePath: other)
        XCTAssertEqual(fake.chooseCalls, 1, "同扩展名记住了，不再问")
        XCTAssertEqual(fake.launched.last?.app?.lastPathComponent, "Chosen.app")
        coordinator.dispose()
    }

    func testCancellingAppChooserDownloadsNothing() async throws {
        fake.chosenApp = nil
        let coordinator = makeCoordinator()
        await coordinator.open(remotePath: remotePath, route: .chooseApplication)
        let downloads = await sftp.streamingDownloads
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(coordinator.sessions.isEmpty)
        coordinator.dispose()
    }

    // MARK: - 数据库交 uTable

    private let dbPath = "/root/projects/cdn_cert/cert.db"

    private func seedSQLite() async {
        var data = Data("SQLite format 3\u{0}".utf8)
        data.append(Data(repeating: 0, count: 84))
        await sftp.setFile(dbPath, data: data, mtime: loadedAt)
    }

    func testSQLiteGoesToUTableWithoutDownloading() async throws {
        fake.uTableAvailable = true
        await seedSQLite()
        let coordinator = makeCoordinator()

        await coordinator.open(remotePath: dbPath)

        XCTAssertEqual(fake.uTableOpens.map(\.0), [host.id])
        XCTAssertEqual(fake.uTableOpens.map(\.1), [dbPath])
        let downloads = await sftp.streamingDownloads
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(coordinator.sessions.isEmpty, "uTable 自己回写，uTerm 不监听")
        coordinator.dispose()
    }

    func testDbExtensionThatIsNotSQLiteFallsBackToLocalOpen() async throws {
        fake.uTableAvailable = true
        await sftp.setFile(dbPath, data: Data(repeating: 7, count: 64), mtime: loadedAt)
        let coordinator = makeCoordinator()

        await coordinator.open(remotePath: dbPath)

        XCTAssertTrue(fake.uTableOpens.isEmpty)
        XCTAssertEqual(coordinator.sessions.map(\.remotePath), [dbPath])
        coordinator.dispose()
    }

    func testWALCompanionAsksBeforeHandingOff() async throws {
        fake.uTableAvailable = true
        fake.confirmInUse = false
        await seedSQLite()
        await sftp.setFile(dbPath + "-wal", data: Data([1]), mtime: loadedAt)
        let coordinator = makeCoordinator()

        await coordinator.open(remotePath: dbPath)

        XCTAssertEqual(fake.inUseAsked, [["cert.db-wal"]])
        XCTAssertTrue(fake.uTableOpens.isEmpty, "用户取消了就什么都不做")
        let downloads = await sftp.streamingDownloads
        XCTAssertTrue(downloads.isEmpty)
        coordinator.dispose()
    }

    func testJumpHostFallsBackToLocalOpen() async throws {
        fake.uTableAvailable = true
        host = ExternalOpenHost(id: host.id, name: "behind-bastion", usesJumpHost: true)
        await seedSQLite()
        let coordinator = makeCoordinator()

        await coordinator.open(remotePath: dbPath)

        XCTAssertTrue(fake.uTableOpens.isEmpty)
        XCTAssertEqual(coordinator.sessions.map(\.remotePath), [dbPath])
        coordinator.dispose()
    }

    func testWithoutUTableDatabaseOpensLocally() async throws {
        fake.uTableAvailable = false
        await seedSQLite()
        let coordinator = makeCoordinator()

        await coordinator.open(remotePath: dbPath)

        XCTAssertTrue(fake.uTableOpens.isEmpty)
        XCTAssertEqual(coordinator.sessions.map(\.remotePath), [dbPath])
        coordinator.dispose()
    }

    // MARK: - 退出前汇总

    func testAllLiveTracksUndisposedCoordinators() async throws {
        let coordinator = makeCoordinator()
        XCTAssertTrue(ExternalOpenCoordinator.allLive.contains { $0 === coordinator })
        coordinator.dispose()
        XCTAssertFalse(ExternalOpenCoordinator.allLive.contains { $0 === coordinator })
    }
}
