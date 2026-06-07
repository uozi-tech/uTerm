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
}

enum SFTPTestError: Error { case boom }
