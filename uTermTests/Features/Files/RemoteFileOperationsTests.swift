import XCTest
@testable import uTerm

/// 两端共用的远程文件操作层（`RemoteFileOperations`），直接对 `MockSFTP` 跑。
@MainActor
final class RemoteFileOperationsTests: XCTestCase {
    private func entries(_ items: [(String, Bool)]) -> [RemoteEntry] {
        items.map { RemoteEntry(name: $0.0, posixPermissions: $0.1 ? 0o040755 : 0o100644,
                                size: $0.1 ? nil : 1, modifiedAt: nil) }
    }
    private func dirEntry(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o040755, size: nil, modifiedAt: nil)
    }
    private func fileEntry(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o100644, size: 1, modifiedAt: nil)
    }

    // MARK: 删除

    func testDeleteFileIsSingleRemove() async throws {
        let mock = MockSFTP(tree: [:])
        try await RemoteFileOperations.delete(fileEntry("a.txt"), in: "/srv", provider: mock)
        let files = await mock.removedFiles
        let dirs = await mock.removedDirs
        XCTAssertEqual(files, ["/srv/a.txt"])
        XCTAssertTrue(dirs.isEmpty)
    }

    /// 符号链接只删链接本身，不跟随进目标目录。
    func testDeleteSymlinkUnlinksOnly() async throws {
        let mock = MockSFTP(tree: ["/srv/link": entries([("victim.txt", false)])])
        let link = RemoteEntry(name: "link", posixPermissions: 0o120777, size: 4, modifiedAt: nil)
        try await RemoteFileOperations.delete(link, in: "/srv", provider: mock)
        let files = await mock.removedFiles
        XCTAssertEqual(files, ["/srv/link"])
    }

    func testDeleteDirectoryRemovesChildrenBeforeParentsAndReportsProgress() async throws {
        let mock = MockSFTP(tree: [
            "/srv/d": entries([("inner.txt", false), ("sub", true)]),
            "/srv/d/sub": entries([("deep.txt", false)]),
        ])
        var events: [RemoteFileOperations.DeletionEvent] = []
        try await RemoteFileOperations.delete(dirEntry("d"), in: "/srv", provider: mock,
                                              onProgress: { events.append($0) })
        let files = await mock.removedFiles
        let dirs = await mock.removedDirs
        XCTAssertEqual(Set(files), ["/srv/d/inner.txt", "/srv/d/sub/deep.txt"])
        XCTAssertEqual(dirs, ["/srv/d/sub", "/srv/d"])
        // 阶段切换与收尾两帧必发：0/4 开头、4/4 收尾。
        XCTAssertTrue(events.contains(.deleting(done: 0, total: 4)))
        XCTAssertEqual(events.last, .deleting(done: 4, total: 4))

        var progress = RemoteDeletionProgress.starting("d")
        for event in events { progress.apply(event) }
        XCTAssertEqual(progress.phase, .deleting)
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.fraction, 1)
    }

    func testDeleteCancelledBeforeAnyRemovalThrowsCancelled() async {
        let mock = MockSFTP(tree: ["/srv/d": entries([("a.txt", false)])])
        do {
            try await RemoteFileOperations.delete(dirEntry("d"), in: "/srv", provider: mock,
                                                  isCancelled: { true })
            XCTFail("取消必须抛 DeletionCancelled")
        } catch is RemoteFileOperations.DeletionCancelled {
        } catch {
            XCTFail("意外错误：\(error)")
        }
        let files = await mock.removedFiles
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: 权限

    func testSetPermissionsUsesSetstatAndMasks() async throws {
        let mock = MockSFTP()
        try await RemoteFileOperations.setPermissions(fileEntry("a"), in: "/srv", mode: 0o104755,
                                                      provider: mock)
        let changes = await mock.permissionChanges
        XCTAssertEqual(changes.first?.path, "/srv/a")
        XCTAssertEqual(changes.first?.mode, 0o755)
    }

    func testSetPermissionsRecursiveDirectoryRunsChmodR() async throws {
        let mock = MockSFTP()
        try await RemoteFileOperations.setPermissions(dirEntry("it's dir"), in: "/srv", mode: 0o750,
                                                      recursive: true, provider: mock)
        let commands = await mock.execCommands
        XCTAssertEqual(commands, ["chmod -R 750 '/srv/it'\\''s dir'"])
        let changes = await mock.permissionChanges
        XCTAssertTrue(changes.isEmpty)
    }

    func testSetPermissionsRecursiveOnFileStillUsesSetstat() async throws {
        let mock = MockSFTP()
        try await RemoteFileOperations.setPermissions(fileEntry("a"), in: "/", mode: 0o600,
                                                      recursive: true, provider: mock)
        let commands = await mock.execCommands
        let changes = await mock.permissionChanges
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(changes.first?.path, "/a")
    }

    // MARK: 重命名

    func testRenameTrimsWhitespace() async throws {
        let mock = MockSFTP()
        let sent = try await RemoteFileOperations.rename(fileEntry("a.txt"), to: "  b.txt \n",
                                                         in: "/srv", provider: mock)
        XCTAssertTrue(sent)
        let renames = await mock.renames
        XCTAssertEqual(renames.first?.from, "/srv/a.txt")
        XCTAssertEqual(renames.first?.to, "/srv/b.txt")
    }

    func testRenameSkipsEmptyOrUnchangedName() async throws {
        let mock = MockSFTP()
        let blank = try await RemoteFileOperations.rename(fileEntry("a.txt"), to: "   ",
                                                          in: "/srv", provider: mock)
        let same = try await RemoteFileOperations.rename(fileEntry("a.txt"), to: " a.txt ",
                                                         in: "/srv", provider: mock)
        XCTAssertFalse(blank)
        XCTAssertFalse(same)
        let renames = await mock.renames
        XCTAssertTrue(renames.isEmpty)
    }

    // MARK: 符号链接

    func testResolveSymlinkToDirectoryReturnsListing() async {
        let mock = MockSFTP(tree: ["/srv/logs": entries([("a.log", false)])])
        let link = RemoteEntry(name: "logs", posixPermissions: 0o120777, size: 4, modifiedAt: nil)
        let target = await RemoteFileOperations.resolveSymlink(link, in: "/srv", provider: mock)
        guard case .directory(let path, let listed) = target else {
            return XCTFail("应解析为目录：\(target)")
        }
        XCTAssertEqual(path, "/srv/logs")
        XCTAssertEqual(listed.map(\.name), ["a.log"])
    }

    func testResolveSymlinkToFileReturnsStat() async {
        let mock = MockSFTP()
        await mock.setListError(NSError(domain: "t", code: 20))
        await mock.setFile("/srv/conf", data: Data("hello".utf8), mtime: Date(timeIntervalSince1970: 9))
        let link = RemoteEntry(name: "conf", posixPermissions: 0o120777, size: 4, modifiedAt: nil)
        let target = await RemoteFileOperations.resolveSymlink(link, in: "/srv", provider: mock)
        guard case .file(let path, let size, let mtime) = target else {
            return XCTFail("应解析为文件：\(target)")
        }
        XCTAssertEqual(path, "/srv/conf")
        XCTAssertEqual(size, 5)
        XCTAssertEqual(mtime, Date(timeIntervalSince1970: 9))
    }

    // MARK: 上传查重名

    func testExistingNames() async {
        let mock = MockSFTP(tree: ["/srv": entries([("a", false), ("b", false)])])
        let hits = await RemoteFileOperations.existingNames(["a", "c", "b"], in: "/srv", provider: mock)
        XCTAssertEqual(hits, ["a", "b"])
        let none = await RemoteFileOperations.existingNames([], in: "/srv", provider: mock)
        XCTAssertTrue(none.isEmpty)
    }

    func testExistingNamesEmptyWhenListFails() async {
        let mock = MockSFTP(tree: ["/srv": entries([("a", false)])])
        await mock.setListError(NSError(domain: "t", code: 1))
        let hits = await RemoteFileOperations.existingNames(["a"], in: "/srv", provider: mock)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: 属主名

    func testOwnerStatCommandQuotesPaths() {
        let command = RemoteFileOperations.ownerStatCommand(paths: ["/a b", "/it's"])
        XCTAssertTrue(command.contains("'/a b' '/it'\\''s'"))
        XCTAssertTrue(command.hasPrefix("(stat -c "))
        XCTAssertTrue(command.contains("|| stat -f "))
    }

    func testParseOwnerStatOutputDropsNumericAndUnknownNames() {
        let rows = RemoteFileOperations.parseOwnerStatOutput("0\t0\troot\twheel\n1000\t1000\t1000\tUNKNOWN\nbad\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], .init(uid: 0, gid: 0, ownerName: "root", groupName: "wheel"))
        XCTAssertEqual(rows[1], .init(uid: 1000, gid: 1000, ownerName: nil, groupName: nil))
    }

    func testResolveOwnerNamesAppliesRows() async {
        let mock = MockSFTP()
        await mock.setExecOutput("0\t0\troot\twheel\n")
        let listed = [RemoteEntry(name: "x", posixPermissions: 0o100644, size: 1, modifiedAt: nil,
                                  uid: 0, gid: 0)]
        let resolved = await RemoteFileOperations.resolveOwnerNames(for: listed, in: "/", provider: mock)
        XCTAssertEqual(resolved.first?.ownerName, "root")
        XCTAssertEqual(resolved.first?.groupName, "wheel")
    }
}
