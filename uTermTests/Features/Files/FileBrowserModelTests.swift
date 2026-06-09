import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class FileBrowserModelTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        return ModelContext(container)
    }

    private func dir(_ names: [(String, Bool)]) -> [RemoteEntry] {
        names.map { RemoteEntry(name: $0.0,
                                posixPermissions: $0.1 ? 0o040755 : 0o100644,
                                size: $0.1 ? nil : 10, modifiedAt: nil) }
    }

    /// 轮询直到 condition 成立或超时（async 调度不确定时用）。
    private func waitUntil(timeout: TimeInterval = 3.0,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntilAsync(timeout: TimeInterval = 3.0,
                                _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 写入 n 个临时文件，返回其 URL（每个内容 = 文件名，便于断言字节数）。
    private func tempFiles(_ names: [String]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-xfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let u = dir.appendingPathComponent(name)
            try Data(name.utf8).write(to: u)
            return u
        }
        return (dir, urls)
    }

    func testLoadHomeListsEntries() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("etc", true), ("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        XCTAssertEqual(model.state, .browsing)
        XCTAssertEqual(model.entries.map(\.name), ["etc", "a.txt"])
    }

    func testRefreshResolvesOwnerAndGroupNamesFromStatOutput() async {
        let entries = [
            RemoteEntry(name: "etc", posixPermissions: 0o040755,
                        size: nil, modifiedAt: nil, uid: 0, gid: 0),
            RemoteEntry(name: "app.log", posixPermissions: 0o100644,
                        size: 10, modifiedAt: nil, uid: 1001, gid: 1001),
        ]
        let mock = MockSFTP(tree: ["/srv": entries])
        await mock.setExecOutput("0\t0\troot\troot\n1001\t1001\tdeploy\tdeploy\n")
        let model = FileBrowserModel(testProvider: mock, startPath: "/srv")

        await model.refresh()

        XCTAssertEqual(model.entries.map(\.ownerDisplayText),
                       ["root · root", "deploy · deploy"])
        let commands = await mock.execCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("stat"))
        XCTAssertTrue(commands[0].contains("/srv/etc"))
        XCTAssertTrue(commands[0].contains("/srv/app.log"))
    }

    func testNavigateIntoDirectory() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("etc", true)]),
            "/home/user/etc": dir([("hosts", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.navigate(into: model.entries[0])
        XCTAssertEqual(model.currentPath, "/home/user/etc")
        XCTAssertEqual(model.entries.map(\.name), ["hosts"])
    }

    func testNavigateUp() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("etc", true)]),
            "/home/user/etc": dir([]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.navigate(into: model.entries[0])
        await model.navigateUp()
        XCTAssertEqual(model.currentPath, "/home/user")
    }

    func testNavigateUpAtRootIsNoOp() async {
        let mock = MockSFTP(tree: ["/": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/")
        await model.refresh()
        await model.navigateUp()
        XCTAssertEqual(model.currentPath, "/")
    }

    func testListErrorReachesFailed() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setListError(SFTPTestError.boom)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        guard case .failed = model.state else { return XCTFail("应为 .failed") }
    }

    func testRefreshReconnectsAfterClosedSFTPChannelAndKeepsPath() async throws {
        let context = try makeContext()
        let server = ServerProfile()
        server.name = "s1"
        server.host = "127.0.0.1"
        server.username = "root"
        context.insert(server)
        try context.save()

        let first = MockSFTP(tree: [
            "/home/user": dir([("logs", true)]),
            "/home/user/logs": dir([("old.log", false)]),
        ])
        let second = MockSFTP(tree: [
            "/home/user/logs": dir([("fresh.log", false)]),
        ])
        var connectCount = 0
        let model = FileBrowserModel(sftpConnector: { _, _, _ in
            connectCount += 1
            return connectCount == 1 ? first : second
        })

        await model.connect(profile: server, modelContainer: context.container)
        await model.navigate(toPath: "/home/user/logs")
        XCTAssertEqual(model.entries.map(\.name), ["old.log"])

        let closedChannel = NSError(domain: "Citadel", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "I/O Channel Close",
        ])
        await first.setListError(closedChannel)

        await model.refresh()

        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(model.state, .browsing)
        XCTAssertEqual(model.currentPath, "/home/user/logs")
        XCTAssertEqual(model.entries.map(\.name), ["fresh.log"])
        await waitUntilAsync { await first.didClose }
        let didCloseFirstProvider = await first.didClose
        XCTAssertTrue(didCloseFirstProvider)
    }

    func testUploadForwardsToProvider() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.upload(fileName: "x.txt", data: Data("hi".utf8))
        let uploads = await mock.uploads
        XCTAssertEqual(uploads.first?.path, "/home/user/x.txt")
    }

    func testNavigateToPath() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("etc", true)]),
            "/home/user/etc": dir([("hosts", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.navigate(toPath: "/home/user/etc")
        XCTAssertEqual(model.currentPath, "/home/user/etc")
        XCTAssertEqual(model.entries.map(\.name), ["hosts"])
    }

    func testRestoreCurrentPathUsesPathOnFirstConnect() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("home.txt", false)]),
            "/var/log": dir([("syslog", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")

        model.restoreCurrentPath("/var/log")
        await model.refresh()

        XCTAssertEqual(model.currentPath, "/var/log")
        XCTAssertEqual(model.entries.map(\.name), ["syslog"])
    }

    func testMakeDirectoryForwardsAndRefreshes() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.makeDirectory(name: "newdir")
        let created = await mock.createdDirs
        XCTAssertEqual(created, ["/home/user/newdir"])
    }

    func testRenameForwards() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.rename(entry: model.entries[0], to: "b.txt")
        let renames = await mock.renames
        XCTAssertEqual(renames.first?.from, "/home/user/a.txt")
        XCTAssertEqual(renames.first?.to, "/home/user/b.txt")
    }

    func testMoveRemoteDragItemIntoDirectoryRenamesToTargetDirectory() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("logs", true), ("a.txt", false)]),
            "/home/user/logs": dir([]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        guard let file = model.entries.first(where: { $0.name == "a.txt" }),
              let target = model.entries.first(where: { $0.name == "logs" }) else {
            XCTFail("test fixture should contain a file and target directory")
            return
        }
        let moved = await model.moveRemoteDragItem(model.remoteDragItem(for: file), into: target)

        XCTAssertTrue(moved)
        let renames = await mock.renames
        XCTAssertEqual(renames.first?.from, "/home/user/a.txt")
        XCTAssertEqual(renames.first?.to, "/home/user/logs/a.txt")
    }

    func testMoveRemoteDragItemRejectsDifferentScope() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("logs", true), ("a.txt", false)]),
            "/home/user/logs": dir([]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        guard let target = model.entries.first(where: { $0.name == "logs" }) else {
            XCTFail("test fixture should contain target directory")
            return
        }
        let foreign = RemoteFileDragItem(
            scopeID: UUID(),
            path: "/home/user/a.txt",
            name: "a.txt",
            isDirectory: false)

        let moved = await model.moveRemoteDragItem(foreign, into: target)

        XCTAssertFalse(moved)
        let renames = await mock.renames
        XCTAssertTrue(renames.isEmpty)
    }

    func testMoveRemoteDragItemRejectsDirectoryDroppedIntoItself() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("logs", true)]),
            "/home/user/logs": dir([("archive", true)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user/logs")
        await model.refresh()
        guard let archive = model.entries.first(where: { $0.name == "archive" }) else {
            XCTFail("test fixture should contain nested target directory")
            return
        }
        let source = RemoteFileDragItem(
            scopeID: model.remoteDragScopeID,
            path: "/home/user/logs",
            name: "logs",
            isDirectory: true)

        let moved = await model.moveRemoteDragItem(source, into: archive)

        XCTAssertFalse(moved)
        let renames = await mock.renames
        XCTAssertTrue(renames.isEmpty)
    }

    func testDeleteFile() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.delete(entry: model.entries[0])
        let removed = await mock.removedFiles
        XCTAssertEqual(removed, ["/home/user/a.txt"])
    }

    func testDeleteDirectoryRecurses() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("d", true)]),
            "/home/user/d": dir([("inner.txt", false), ("sub", true)]),
            "/home/user/d/sub": dir([("deep.txt", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.delete(entry: model.entries[0])
        let files = await mock.removedFiles
        let dirs = await mock.removedDirs
        XCTAssertEqual(Set(files), ["/home/user/d/inner.txt", "/home/user/d/sub/deep.txt"])
        XCTAssertEqual(dirs, ["/home/user/d/sub", "/home/user/d"])
    }

    func testShowHiddenFiltersDotfiles() async {
        let mock = MockSFTP(tree: ["/home/user": dir([(".bashrc", false), ("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        model.showHidden = false
        await model.refresh()
        XCTAssertEqual(model.sortedEntries.map(\.name), ["a.txt"])
        model.showHidden = true
        XCTAssertEqual(Set(model.sortedEntries.map(\.name)), [".bashrc", "a.txt"])
    }

    func testEnqueueUploadCompletesAndForwardsToProvider() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        model.enqueueUpload(fileName: "x.txt", data: Data("hi".utf8))
        await waitUntil { model.transfers.first?.status == .done }
        XCTAssertEqual(model.transfers.first?.status, .done)
        let uploads = await mock.uploads
        XCTAssertEqual(uploads.first?.path, "/home/user/x.txt")
    }

    func testUploadShowsSpeedAfterFirstEarlyProgressSample() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setBlockTransfers(true)
        await mock.setUploadPartialProgress(bytesDone: 512 * 1024,
                                            delayNanoseconds: 120_000_000)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")

        model.enqueueUpload(fileName: "big.iso", data: Data(count: 8 * 1024 * 1024))

        await waitUntil { model.transfers.first?.bytesDone == 512 * 1024 }
        let transfer = try? XCTUnwrap(model.transfers.first)
        XCTAssertEqual(transfer?.status, .active)
        XCTAssertGreaterThan(transfer?.speedBytesPerSec ?? 0, 0)

        await mock.release()
        await waitUntil { model.transfers.first?.status == .done }
    }

    func testEnqueueUploadsUploadsEachFileToCurrentDirectory() async throws {
        let (tmp, urls) = try tempFiles(["first.txt", "second.log"])  // 9 + 10 bytes
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")

        model.enqueueUploads(urls)

        await waitUntil { model.transfers.filter { $0.status == .done }.count == 2 }
        let uploads = await mock.uploads
        XCTAssertEqual(Set(uploads.map(\.path)),
                       ["/home/user/first.txt", "/home/user/second.log"])
        XCTAssertEqual(Set(uploads.map(\.bytes)), [9, 10])  // "first.txt"=9, "second.log"=10
    }

    func testEnqueueUploadsRespectsConcurrencyLimit() async throws {
        UserDefaults.standard.set(2, forKey: "sftpMaxConcurrentTransfers")
        defer { UserDefaults.standard.removeObject(forKey: "sftpMaxConcurrentTransfers") }
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setBlockTransfers(true)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        let (tmp, urls) = try tempFiles(["a.txt", "b.txt", "c.txt", "d.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        model.enqueueUploads(urls)

        await waitUntil { model.transfers.filter { $0.status == .active }.count == 2 }
        XCTAssertEqual(model.transfers.count, 4)
        XCTAssertEqual(model.transfers.filter { $0.status == .active }.count, 2)
        XCTAssertEqual(model.transfers.filter { $0.status == .queued }.count, 2)

        await mock.release()
        await waitUntil { model.transfers.allSatisfy { $0.status == .done } }
        XCTAssertEqual(model.transfers.filter { $0.status == .done }.count, 4)
        let uploads = await mock.uploads
        XCTAssertEqual(Set(uploads.map(\.path)),
                       ["/home/user/a.txt", "/home/user/b.txt", "/home/user/c.txt", "/home/user/d.txt"])
    }

    func testCancelQueuedRemovesImmediately() async throws {
        UserDefaults.standard.set(1, forKey: "sftpMaxConcurrentTransfers")
        defer { UserDefaults.standard.removeObject(forKey: "sftpMaxConcurrentTransfers") }
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setBlockTransfers(true)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        let (tmp, urls) = try tempFiles(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }
        model.enqueueUploads(urls)
        await waitUntil { model.transfers.contains { $0.status == .active } }
        let queued = model.transfers.first { $0.status == .queued }!
        model.cancelTransfer(queued.id)
        XCTAssertFalse(model.transfers.contains { $0.id == queued.id })
        XCTAssertEqual(model.transfers.count, 1)
    }

    func testCancelActiveRemovesAfterUnwind() async throws {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setBlockTransfers(true)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        let (tmp, urls) = try tempFiles(["a.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }
        model.enqueueUploads(urls)
        await waitUntil { model.transfers.contains { $0.status == .active } }
        let active = model.transfers.first { $0.status == .active }!
        model.cancelTransfer(active.id)
        await waitUntil { model.transfers.isEmpty }
        XCTAssertTrue(model.transfers.isEmpty)
    }

    func testFailedUploadMarksFailedThenRetryRequeues() async throws {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setFailingUploadPaths(["/home/user/a.txt"])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        let (tmp, urls) = try tempFiles(["a.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }
        model.enqueueUploads(urls)
        await waitUntil { model.transfers.contains { $0.status == .failed } }
        XCTAssertEqual(model.transfers.first?.status, .failed)

        await mock.setFailingUploadPaths([])      // next attempt succeeds
        model.retryTransfer(model.transfers.first!.id)
        await waitUntil { model.transfers.contains { $0.status == .done } }
        XCTAssertEqual(model.transfers.first?.status, .done)
    }

    func testClearFinishedRemovesDoneAndFailed() async throws {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setFailingUploadPaths(["/home/user/b.txt"])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        let (tmp, urls) = try tempFiles(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }
        model.enqueueUploads(urls)
        await waitUntil {
            model.transfers.filter { $0.status == .done || $0.status == .failed }.count == 2
        }
        model.clearFinishedTransfers()
        XCTAssertTrue(model.transfers.isEmpty)
    }
    // MARK: - 权限设置（chmod）

    func testSetPermissionsFileGoesThroughSetstat() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let file = model.entries[0]
        await model.setPermissions(entry: file, mode: 0o755, recursive: false)
        let changes = await mock.permissionChanges
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.path, "/home/user/a.txt")
        XCTAssertEqual(changes.first?.mode, 0o755)
        let execs = await mock.execCommands
        XCTAssertTrue(execs.isEmpty, "非递归不应走 exec chmod -R")
    }

    /// `mode` 高位（文件类型位等）应被 `& 0o777` 截掉，只下发权限位。
    func testSetPermissionsMasksToLow9Bits() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.setPermissions(entry: model.entries[0], mode: 0o100644, recursive: false)
        let changes = await mock.permissionChanges
        XCTAssertEqual(changes.first?.mode, 0o644)
    }

    func testSetPermissionsRecursiveDirectoryRunsChmodR() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("etc", true)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let folder = model.entries[0]
        await model.setPermissions(entry: folder, mode: 0o750, recursive: true)
        let execs = await mock.execCommands
        XCTAssertEqual(execs, ["chmod -R 750 '/home/user/etc'"])
        let changes = await mock.permissionChanges
        XCTAssertTrue(changes.isEmpty, "递归走 exec，不走 setstat")
    }

    /// recursive=true 但目标是文件 → 仍走单个 setstat（chmod -R 对文件无意义）。
    func testSetPermissionsRecursiveOnFileStillUsesSetstat() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.setPermissions(entry: model.entries[0], mode: 0o600, recursive: true)
        let changes = await mock.permissionChanges
        XCTAssertEqual(changes.first?.mode, 0o600)
        let execs = await mock.execCommands
        XCTAssertTrue(execs.isEmpty)
    }

    func testShellQuoteWrapsAndEscapes() {
        XCTAssertEqual(FileBrowserModel.shellQuote("/home/root"), "'/home/root'")
        XCTAssertEqual(FileBrowserModel.shellQuote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(FileBrowserModel.shellQuote("/it's"), "'/it'\\''s'")
    }

    // MARK: - Fix #21：上传目标目录在入队时锚定（槽位激活时不读 live currentPath）

    /// 入队上传后切换目录，传输完成时应落到入队时的目录、而非切换后的当前目录。
    func testEnqueuedUploadLandsInDirectoryCapturedAtEnqueueTime() async throws {
        UserDefaults.standard.set(1, forKey: "sftpMaxConcurrentTransfers")
        defer { UserDefaults.standard.removeObject(forKey: "sftpMaxConcurrentTransfers") }
        let mock = MockSFTP(tree: [
            "/home/user": dir([("sub", true)]),
            "/home/user/sub": dir([]),
        ])
        await mock.setBlockTransfers(true)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()

        let (tmp, urls) = try tempFiles(["a.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 入队时 currentPath = /home/user → 目标目录被锚定为此。
        model.enqueueUploads(urls)
        await waitUntil { model.transfers.contains { $0.status == .active } }

        // 槽位激活后切走到子目录。传输还在阻塞中。
        await model.navigate(toPath: "/home/user/sub")
        XCTAssertEqual(model.currentPath, "/home/user/sub")

        await mock.release()
        await waitUntil { model.transfers.first?.status == .done }

        let uploads = await mock.uploads
        XCTAssertEqual(uploads.first?.path, "/home/user/a.txt",
                       "上传应落到入队时的目录，而非切换后的当前目录")
    }

    /// 重试一个失败的上传时，也应使用入队时锚定的目录（即便 currentPath 已变）。
    func testRetryUsesDirectoryCapturedAtEnqueueTime() async throws {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("sub", true)]),
            "/home/user/sub": dir([]),
        ])
        await mock.setFailingUploadPaths(["/home/user/a.txt"])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let (tmp, urls) = try tempFiles(["a.txt"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        model.enqueueUploads(urls)
        await waitUntil { model.transfers.contains { $0.status == .failed } }

        // 切走目录后再重试 —— 重试仍应走入队时锚定的 /home/user。
        await model.navigate(toPath: "/home/user/sub")
        await mock.setFailingUploadPaths([])
        model.retryTransfer(model.transfers.first!.id)
        await waitUntil { model.transfers.contains { $0.status == .done } }

        let uploads = await mock.uploads
        XCTAssertEqual(uploads.first?.path, "/home/user/a.txt",
                       "重试应使用入队时锚定的目录")
    }

    // MARK: - Fix #24：迟到的进度回调不能回退 / 复活已进入终态的传输

    func testLateProgressDoesNotClobberDoneTransfer() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        model.enqueueUpload(fileName: "x.txt", data: Data(count: 1000))
        await waitUntil { model.transfers.first?.status == .done }
        guard let done = model.transfers.first else { return XCTFail("应有一条传输") }
        XCTAssertEqual(done.status, .done)
        let total = done.bytesTotal
        XCTAssertEqual(done.bytesDone, total)

        // 模拟一条迟到的进度回调：字节数低于 total、带非零瞬时速率。
        model.applyProgress(id: done.id, TransferProgress(bytesDone: 10, bytesTotal: total))

        let after = model.transfers.first
        XCTAssertEqual(after?.status, .done)
        XCTAssertEqual(after?.bytesDone, total, "迟到进度不应把 bytesDone 退回 total 以下")
        XCTAssertEqual(after?.speedBytesPerSec, 0, "已完成的行速率应保持 0")
    }

    func testLateProgressDoesNotReviveFailedTransfer() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        await mock.setFailingUploadPaths(["/home/user/x.txt"])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        model.enqueueUpload(fileName: "x.txt", data: Data(count: 1000))
        await waitUntil { model.transfers.first?.status == .failed }
        guard let failed = model.transfers.first else { return XCTFail("应有一条传输") }

        model.applyProgress(id: failed.id, TransferProgress(bytesDone: 500, bytesTotal: 1000))

        let after = model.transfers.first
        XCTAssertEqual(after?.status, .failed, "迟到进度不应改动失败态")
        XCTAssertEqual(after?.bytesDone, 0, "失败行的 bytesDone 不应被迟到进度改写")
    }

    // MARK: - Fix #2：上传前的远端同名文件（覆盖）检查

    func testExistingRemoteNamesReportsConflicts() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("a.txt", false), ("b.txt", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let conflicts = await model.existingRemoteNames(
            uploadFileNames: ["a.txt", "c.txt"])
        XCTAssertEqual(conflicts, ["a.txt"], "只应报告确实已存在的同名文件")
    }

    func testExistingRemoteNamesEmptyWhenNoConflict() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let conflicts = await model.existingRemoteNames(uploadFileNames: ["new.txt"])
        XCTAssertTrue(conflicts.isEmpty)
    }

    /// 列目录失败时返回空（不误报覆盖、不拦住上传）。
    func testExistingRemoteNamesEmptyWhenListFails() async {
        let mock = MockSFTP(tree: ["/home/user": dir([("a.txt", false)])])
        await mock.setListError(SFTPTestError.boom)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        let conflicts = await model.existingRemoteNames(uploadFileNames: ["a.txt"])
        XCTAssertTrue(conflicts.isEmpty, "列目录失败应返回空，宁可走正常上传也不误报覆盖")
    }

    /// 一批文件里有多个同名冲突时，**全部**冲突都要报出来 —— 拖入多文件修复的核心：
    /// 单个覆盖确认要覆盖整批所有冲突文件，而不是只剩最后一个。
    func testExistingRemoteNamesReportsAllConflictsInBatch() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("a.txt", false), ("b.txt", false), ("c.txt", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let conflicts = await model.existingRemoteNames(
            uploadFileNames: ["a.txt", "b.txt", "c.txt", "new.txt"])
        XCTAssertEqual(Set(conflicts), ["a.txt", "b.txt", "c.txt"],
                       "整批里全部同名冲突都应报出，单个覆盖确认才能覆盖所有被拖入文件")
    }

    /// 通过 forUploading: 的 URL 入口同样要报全部冲突（拖放 / 文件选择器走这条）。
    func testExistingRemoteNamesForUploadingURLsReportsAllConflicts() async {
        let mock = MockSFTP(tree: [
            "/home/user": dir([("a.txt", false), ("b.txt", false)]),
        ])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        let urls = [
            URL(fileURLWithPath: "/local/a.txt"),
            URL(fileURLWithPath: "/local/b.txt"),
            URL(fileURLWithPath: "/local/fresh.txt"),
        ]
        let conflicts = await model.existingRemoteNames(forUploading: urls)
        XCTAssertEqual(Set(conflicts), ["a.txt", "b.txt"],
                       "URL 入口也应报出整批全部冲突")
    }

    func testFileBrowserRowsDoNotDeclareKeyboardFocusRing() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Files/Views/FileBrowserView.swift"
        ), encoding: .utf8)
        let code = sourceCodeWithoutLineComments(source)

        XCTAssertEqual(code.components(separatedBy: ".focusable()").count - 1, 1)
        XCTAssertTrue(code.contains(".focusEffectDisabled()"))
        XCTAssertFalse(code.contains("strokeBorder(UD.accent.opacity(0.6)"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceCodeWithoutLineComments(_ source: String) -> String {
        source.split(separator: "\n")
            .filter { !String($0).trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

enum SFTPTestError: Error { case boom }
