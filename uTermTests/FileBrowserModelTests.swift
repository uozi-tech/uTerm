import XCTest
@testable import uTerm

@MainActor
final class FileBrowserModelTests: XCTestCase {
    private func dir(_ names: [(String, Bool)]) -> [RemoteEntry] {
        names.map { RemoteEntry(name: $0.0,
                                posixPermissions: $0.1 ? 0o040755 : 0o100644,
                                size: $0.1 ? nil : 10, modifiedAt: nil) }
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

    func testUploadWithProgressSetsAndClearsTransfer() async {
        let mock = MockSFTP(tree: ["/home/user": dir([])])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        await model.refresh()
        await model.uploadWithProgress(fileName: "x.txt", data: Data("hi".utf8))
        XCTAssertNil(model.transfer)
        let uploads = await mock.uploads
        XCTAssertEqual(uploads.first?.path, "/home/user/x.txt")
    }
}

enum SFTPTestError: Error { case boom }
