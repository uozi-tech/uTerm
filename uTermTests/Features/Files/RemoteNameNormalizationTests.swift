import XCTest
@testable import uTerm

/// 同一个目录里 NFC 与 NFD 写法的 `café.txt`（从 Mac 拷到 Linux 上常见）：Linux 不做归一化，它们是两个文件。
/// Swift 的 `String ==` 却认为它们相等——拿名字当身份的话，列表里两行 id 一样，选中第二个、改名 / 删除 / 打开的
/// 是第一个。这里从列目录一路走到选中、打开、改名、删除，核对每一步动的都是选中的那一个（比的是字节）。
@MainActor
final class RemoteNameNormalizationTests: XCTestCase {

    private let nfc = "caf\u{E9}.txt"          // 63 61 66 C3 A9
    private let nfd = "cafe\u{301}.txt"        // 63 61 66 65 CC 81

    private func entry(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o100644, size: 10, modifiedAt: nil)
    }

    private func bytes(_ text: String?) -> [UInt8] { Array((text ?? "").utf8) }

    func testTheTwoSpellingsAreTwoEntries() {
        XCTAssertEqual(nfc, nfd, "前提：Swift 认为它们是同一个串")
        XCTAssertNotEqual(entry(nfc).id, entry(nfd).id)
        XCTAssertEqual(Set([entry(nfc).id, entry(nfd).id]).count, 2)
        XCTAssertNotEqual(nfc.remoteKey, nfd.remoteKey)
        XCTAssertEqual(nfc.remoteKey, "caf\u{E9}.txt".remoteKey)
    }

    func testSortingKeepsBothAndIsStable() {
        let sorted = RemoteEntrySort.sorted([entry(nfd), entry(nfc)], options: RemoteEntrySortOptions())
        let again = RemoteEntrySort.sorted([entry(nfc), entry(nfd)], options: RemoteEntrySortOptions())
        XCTAssertEqual(sorted.map(\.id), again.map(\.id), "顺序不随服务器给的顺序变")
        XCTAssertEqual(sorted.count, 2)
    }

    /// 选中第二个（按 id 找回来）→ 改名、删除：发给服务器的是它自己的字节。
    func testSelectRenameAndDeleteActOnTheChosenSpelling() async {
        let mock = MockSFTP(tree: ["/srv": [entry(nfc), entry(nfd)]])
        let model = FileBrowserModel(testProvider: mock, startPath: "/srv")
        await model.refresh()
        XCTAssertEqual(model.sortedEntries.count, 2)

        let selectedID = entry(nfd).id
        guard let chosen = model.sortedEntries.first(where: { $0.id == selectedID }) else {
            return XCTFail("按 id 找不回选中的那一行")
        }
        XCTAssertEqual(bytes(chosen.name), bytes(nfd))

        await model.rename(entry: chosen, to: "renamed.txt")
        let renames = await mock.renames
        XCTAssertEqual(bytes(renames.first?.from), bytes("/srv/" + nfd))

        await model.delete(entry: entry(nfc))
        let removed = await mock.removedFiles
        XCTAssertEqual(removed.map(bytes), [bytes("/srv/" + nfc)])
    }

    /// 把 NFD 的名字改成 NFC 的写法是一次真改名（以前按 `String ==` 判成「没改」，直接不发请求）。
    func testRenamingBetweenSpellingsIsARealRename() {
        XCTAssertEqual(bytes(RemoteFileOperations.validatedNewName(nfc, for: entry(nfd))), bytes(nfc))
        XCTAssertNil(RemoteFileOperations.validatedNewName(nfd, for: entry(nfd)))
    }

    /// 预览区：两个文件各开一个标签，内容各是各的；再开一次切到已有的那个，不会串。
    func testPreviewOpensEachSpellingInItsOwnTab() async throws {
        let mock = MockSFTP()
        try await mock.write("/srv/" + nfc, data: Data("composed".utf8))
        try await mock.write("/srv/" + nfd, data: Data("decomposed".utf8))
        let store = RecentFilesStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)"), fileName: "r.json")
        let preview = FilePreviewModel(recentsStore: store, sftpProvider: { mock })

        await preview.open(path: "/srv/" + nfc, fileSize: 8, mtime: nil)
        await preview.open(path: "/srv/" + nfd, fileSize: 10, mtime: nil)
        XCTAssertEqual(preview.buffers.count, 2, "两个文件两个标签")
        let texts = Set(preview.buffers.compactMap(\.text))
        XCTAssertEqual(texts, ["composed", "decomposed"])

        await preview.open(path: "/srv/" + nfd, fileSize: 10, mtime: nil)
        XCTAssertEqual(preview.buffers.count, 2)
    }

    /// 最近打开的文件：两个都记着，不会互相顶掉。
    func testRecentFilesKeepBothSpellings() throws {
        let store = RecentFilesStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)"), fileName: "r.json")
        store.touch(RecentFileEntry(remotePath: "/srv/" + nfc, kindTag: "text", lastOpenedAt: Date()))
        store.touch(RecentFileEntry(remotePath: "/srv/" + nfd, kindTag: "text", lastOpenedAt: Date()))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.id)).count, 2)
    }
}
