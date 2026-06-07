import XCTest
@testable import uTerm

final class RecentFilesStoreTests: XCTestCase {

    private func makeStore() -> RecentFilesStore {
        // 用临时目录避免污染真实 ApplicationSupport
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)")
        return RecentFilesStore(rootDirectory: tmp,
                                fileName: "recents-\(UUID()).json")
    }

    func test_saveLoad_roundtrip() throws {
        let store = makeStore()
        let entries = [
            RecentFileEntry(remotePath: "/a", kindTag: "code:swift", lastOpenedAt: Date(timeIntervalSince1970: 100)),
            RecentFileEntry(remotePath: "/b", kindTag: "markdown",   lastOpenedAt: Date(timeIntervalSince1970: 200)),
        ]
        store.save(entries)
        XCTAssertEqual(store.load(), entries)
    }

    func test_load_missingFile_returnsEmpty() {
        XCTAssertTrue(makeStore().load().isEmpty)
    }

    func test_touch_addsNewAtTop() {
        let store = makeStore()
        store.save([])
        let now = Date()
        store.touch(RecentFileEntry(remotePath: "/a", kindTag: "x", lastOpenedAt: now))
        XCTAssertEqual(store.load().map(\.remotePath), ["/a"])
    }

    func test_touch_dedupesByPath_keepingNewer() {
        let store = makeStore()
        store.save([
            RecentFileEntry(remotePath: "/a", kindTag: "x", lastOpenedAt: Date(timeIntervalSince1970: 100)),
            RecentFileEntry(remotePath: "/b", kindTag: "y", lastOpenedAt: Date(timeIntervalSince1970: 200)),
        ])
        store.touch(RecentFileEntry(remotePath: "/a", kindTag: "x", lastOpenedAt: Date(timeIntervalSince1970: 300)))
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.remotePath), ["/a", "/b"])
        XCTAssertEqual(loaded[0].lastOpenedAt.timeIntervalSince1970, 300)
    }

    func test_touch_truncatesAt20() {
        let store = makeStore()
        var entries: [RecentFileEntry] = []
        for i in 0..<25 {
            entries.append(RecentFileEntry(remotePath: "/p\(i)", kindTag: "x", lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(i))))
        }
        store.save(entries)
        store.touch(RecentFileEntry(remotePath: "/new", kindTag: "x", lastOpenedAt: .now))
        XCTAssertEqual(store.load().count, 20)
        XCTAssertEqual(store.load().first?.remotePath, "/new")
    }
}
