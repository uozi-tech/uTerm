import UPaneGroups
import XCTest
@testable import uTerm

@MainActor
final class FilePreviewModelTests: XCTestCase {

    /// 标签的显示顺序（改造后标签顺序住在 `panes` 里，不再等于 `buffers` 的插入顺序）。
    private func tabPaths(_ m: FilePreviewModel) -> [String] {
        m.panes.allTabs.map(\.payload.remotePath)
    }

    private func tabID(_ m: FilePreviewModel, path: String) -> UUID? {
        m.panes.allTabs.first { $0.payload.remotePath == path }?.id
    }

    private func makeModel() -> (FilePreviewModel, MockSFTP) {
        let mock = MockSFTP()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)")
        let store = RecentFilesStore(rootDirectory: tmp, fileName: "r.json")
        let m = FilePreviewModel(recentsStore: store, sftpProvider: { mock })
        return (m, mock)
    }

    func test_openSamePathTwice_doesNotDuplicate() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("hi".utf8))
        await m.open(path: "/x.swift", fileSize: 2, mtime: nil)
        await m.open(path: "/x.swift", fileSize: 2, mtime: nil)
        XCTAssertEqual(m.buffers.count, 1)
    }

    func test_openLoadsContent() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("let x = 1".utf8))
        await m.open(path: "/x.swift", fileSize: 9, mtime: nil)
        XCTAssertEqual(m.buffers.first?.text, "let x = 1")
        XCTAssertEqual(m.buffers.first?.state, .loaded)
        XCTAssertFalse(m.buffers.first?.isDirty ?? true)
    }

    func test_openWithUnknownSizeUsesBoundedDownload() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/unknown.swift", data: Data("let x = 1".utf8))

        await m.open(path: "/unknown.swift", fileSize: nil, mtime: nil)

        let requests = await mock.boundedDownloads
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/unknown.swift")
        XCTAssertEqual(requests.first?.maximumBytes, 50 * 1024 * 1024)
        XCTAssertEqual(m.activeBuffer?.state, .loaded)
        XCTAssertEqual(m.activeBuffer?.byteSize, 9)
    }

    func test_reloadFromRemoteUsesBoundedDownload() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("old".utf8))
        await m.open(path: "/x.swift", fileSize: 3, mtime: nil)
        let buffer = try XCTUnwrap(m.activeBuffer)
        try await mock.write("/x.swift", data: Data("new".utf8))

        await m.reloadFromRemote(buffer.id)

        let requests = await mock.boundedDownloads
        XCTAssertEqual(requests.map(\.path), ["/x.swift", "/x.swift"])
        XCTAssertTrue(requests.allSatisfy { $0.maximumBytes == 50 * 1024 * 1024 })
        XCTAssertEqual(buffer.text, "new")
    }

    func test_loadMarkdownImage_resolvesRelativePathFromMarkdownDirectory() async throws {
        let (m, mock) = makeModel()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try await mock.write("/srv/nginx-ui/README.md", data: Data("# README".utf8))
        try await mock.write("/srv/nginx-ui/resources/screenshots/dashboard.png", data: imageData)

        await m.open(path: "/srv/nginx-ui/README.md", fileSize: 8, mtime: nil)
        let buffer = try XCTUnwrap(m.buffers.first)
        let loaded = try await m.loadMarkdownImage(
            source: "resources/screenshots/dashboard.png",
            referencedBy: buffer)

        XCTAssertEqual(loaded, imageData)
        let downloaded = await mock.downloadedPaths()
        XCTAssertEqual(downloaded.last, "/srv/nginx-ui/resources/screenshots/dashboard.png")
    }

    func test_loadMarkdownImage_normalizesParentDirectorySegments() async throws {
        let (m, mock) = makeModel()
        let imageData = Data([0xFF, 0xD8, 0xFF])
        try await mock.write("/srv/docs/guide/README.md", data: Data("# README".utf8))
        try await mock.write("/srv/docs/assets/logo.jpg", data: imageData)

        await m.open(path: "/srv/docs/guide/README.md", fileSize: 8, mtime: nil)
        let buffer = try XCTUnwrap(m.buffers.first)
        let loaded = try await m.loadMarkdownImage(
            source: "../assets/logo.jpg",
            referencedBy: buffer)

        XCTAssertEqual(loaded, imageData)
        let downloaded = await mock.downloadedPaths()
        XCTAssertEqual(downloaded.last, "/srv/docs/assets/logo.jpg")
    }

    func test_loadMarkdownImage_rejectsImageOverPerImageCap() async throws {
        let (m, mock) = makeModel()
        let oversized = Data(repeating: 0xAB, count: MarkdownImageCache.perImageByteCap + 1)
        try await mock.write("/srv/docs/README.md", data: Data("# README".utf8))
        try await mock.write("/srv/docs/huge.png", data: oversized)

        await m.open(path: "/srv/docs/README.md", fileSize: 8, mtime: nil)
        let buffer = try XCTUnwrap(m.buffers.first)

        do {
            _ = try await m.loadMarkdownImage(source: "huge.png", referencedBy: buffer)
            XCTFail("expected oversized image to be rejected")
        } catch let error as FilePreviewModel.PreviewDownloadError {
            guard case .markdownImageTooLarge(let bytes) = error else {
                return XCTFail("expected .markdownImageTooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, oversized.count)
        }
        let downloaded = await mock.downloadedPaths()
        XCTAssertFalse(downloaded.contains("/srv/docs/huge.png"),
                       "known oversized images must be rejected before download")
    }

    func test_loadMarkdownImage_rejectsAutomaticHTTPRequests() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/srv/docs/README.md", data: Data("# README".utf8))
        await m.open(path: "/srv/docs/README.md", fileSize: 8, mtime: nil)
        let buffer = try XCTUnwrap(m.buffers.first)

        do {
            _ = try await m.loadMarkdownImage(
                source: "http://127.0.0.1:8080/admin.png", referencedBy: buffer)
            XCTFail("expected external URL to be rejected")
        } catch let error as FilePreviewModel.PreviewDownloadError {
            guard case .unsupportedMarkdownImageSource(let source) = error else {
                return XCTFail("expected unsupported source, got \(error)")
            }
            XCTAssertEqual(source, "http://127.0.0.1:8080/admin.png")
        }
    }

    func test_loadMarkdownImage_cachesWithinCapAndAvoidsRefetch() async throws {
        let (m, mock) = makeModel()
        let small = Data(repeating: 0x01, count: 1_024)
        try await mock.write("/srv/docs/README.md", data: Data("# README".utf8))
        try await mock.write("/srv/docs/ok.png", data: small)

        await m.open(path: "/srv/docs/README.md", fileSize: 8, mtime: nil)
        let buffer = try XCTUnwrap(m.buffers.first)

        let first = try await m.loadMarkdownImage(source: "ok.png", referencedBy: buffer)
        let second = try await m.loadMarkdownImage(source: "ok.png", referencedBy: buffer)

        XCTAssertEqual(first, small)
        XCTAssertEqual(second, small)
        // Second call served from cache → image downloaded exactly once.
        let imageDownloads = await mock.downloadedPaths().filter { $0 == "/srv/docs/ok.png" }
        XCTAssertEqual(imageDownloads.count, 1)
    }

    func test_openDatabaseFileMarksUnpreviewableWithoutDownloading() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/var/app/state.db", data: Data([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65]))

        await m.open(path: "/var/app/state.db", fileSize: 4096, mtime: nil)

        guard case .failed(let message) = m.buffers.first?.state else {
            return XCTFail("expected database file to be unpreviewable")
        }
        XCTAssertTrue(message.contains("不支持预览"))
        let downloaded = await mock.downloadedPaths()
        XCTAssertEqual(downloaded, [])
    }

    func test_openBinaryContentMarksUnpreviewableInsteadOfDecodingText() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/tmp/payload.unknown", data: Data([0x00, 0xff, 0x01, 0x02]))

        await m.open(path: "/tmp/payload.unknown", fileSize: 4, mtime: nil)

        guard case .failed(let message) = m.buffers.first?.state else {
            return XCTFail("expected binary content to be unpreviewable")
        }
        XCTAssertTrue(message.contains("二进制"))
        XCTAssertEqual(m.buffers.first?.text, "")
    }

    func test_save_writesToSFTPAndClearsDirty() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        let buf = m.buffers.first!
        buf.text = "b"; buf.isDirty = true
        let result = await m.save(buf.id)
        if case .saved = result {} else { return XCTFail("expected .saved, got \(result)") }
        XCTAssertFalse(buf.isDirty)
        let onRemote = try await mock.read("/x.swift")
        XCTAssertEqual(String(decoding: onRemote, as: UTF8.self), "b")
    }

    /// 回归：分屏下编辑非聚焦面板的文件，⌘S 经编辑器带入“正在编辑的 buffer id”，
    /// 即使 activeBufferID 指向另一个（未脏）buffer，也必须精确保存被编辑的那个。
    func test_save_savesSpecifiedBuffer_evenWhenNotActive() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil)
        let bufA = m.buffers.first { $0.remotePath == "/a.swift" }!
        let bufB = m.buffers.first { $0.remotePath == "/b.swift" }!
        // 模拟分屏焦点错位：活动标签停在 A（未脏），实际被编辑的是 B。
        m.selectTab(try XCTUnwrap(tabID(m, path: "/a.swift")))
        XCTAssertEqual(m.activeBufferID, bufA.id)
        bufB.text = "edited"; bufB.isDirty = true

        let result = await m.save(bufB.id)        // 编辑器带入 B 的 id
        if case .saved = result {} else { return XCTFail("expected .saved, got \(result)") }
        XCTAssertFalse(bufB.isDirty, "被编辑的 B 应已保存并清脏")
        let onRemote = try await mock.read("/b.swift")
        XCTAssertEqual(String(decoding: onRemote, as: UTF8.self), "edited")
        // A 不应被动到
        let aRemote = try await mock.read("/a.swift")
        XCTAssertEqual(String(decoding: aRemote, as: UTF8.self), "a")
    }

    func test_save_detectsConflict_whenRemoteMtimeAdvanced() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        let buf = m.buffers.first!
        buf.text = "b"; buf.isDirty = true
        // 外部修改远程：mtime 推后
        try await Task.sleep(for: .milliseconds(20))
        try await mock.write("/x.swift", data: Data("X".utf8))
        let result = await m.save(buf.id)
        if case .conflict = result { /* ok */ } else { return XCTFail("expected .conflict") }
    }

    func test_refreshAfterRemoteCommandReloadsVisibleFileWhenMetadataIsUnchanged() async throws {
        let (m, mock) = makeModel()
        let mtime = Date(timeIntervalSince1970: 1_000)
        await mock.setFile("/x.swift", data: Data("old".utf8), mtime: mtime)
        await m.open(path: "/x.swift", fileSize: 3, mtime: mtime)

        // 常见于秒级 mtime 的远端文件系统：内容等长改写，但 size/mtime 快照相同。
        await mock.setFile("/x.swift", data: Data("new".utf8), mtime: mtime)
        await m.refreshAfterRemoteCommand()

        XCTAssertEqual(m.activeBuffer?.text, "new")
        XCTAssertEqual(m.activeBuffer?.state, .loaded)
    }

    func test_refreshAfterRemoteCommandNeverOverwritesDirtyBuffer() async throws {
        let (m, mock) = makeModel()
        let mtime = Date(timeIntervalSince1970: 1_000)
        await mock.setFile("/x.swift", data: Data("old".utf8), mtime: mtime)
        await m.open(path: "/x.swift", fileSize: 3, mtime: mtime)
        let buffer = try XCTUnwrap(m.activeBuffer)
        buffer.text = "local edit"
        buffer.isDirty = true

        await mock.setFile("/x.swift", data: Data("remote".utf8),
                           mtime: mtime.addingTimeInterval(1))
        await m.refreshAfterRemoteCommand()

        XCTAssertEqual(buffer.text, "local edit")
        XCTAssertTrue(buffer.isDirty)
    }

    func test_closeTab_releasesBuffer() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        m.closeTab(try XCTUnwrap(tabID(m, path: "/x.swift")))
        XCTAssertTrue(m.buffers.isEmpty)
        XCTAssertNil(m.activeBufferID)
        XCTAssertEqual(m.panes.groupCount, 1, "最后一个组留着显示「最近打开」空态")
    }

    // MARK: 预览（临时）tab 语义 —— VS Code 风：单击预览打开、双击 / 编辑 / 保存转正

    func test_openAsPreview_replacesPreviousPreviewTab() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)

        XCTAssertEqual(tabPaths(m), ["/b.swift"], "新预览应顶替旧预览")
        let b = try XCTUnwrap(m.buffers.first)
        XCTAssertTrue(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/b.swift"))))
        XCTAssertEqual(m.activeBufferID, b.id)
    }

    func test_openAsPreview_keepsTabPositionAndSkipsPermanentTabs() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))
        try await mock.write("/c.swift", data: Data("c".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil)              // 永久
        await m.open(path: "/c.swift", fileSize: 1, mtime: nil, asPreview: true)

        // 预览 tab 在原位（index 0）被 c 顶替，永久 tab b 不受影响。
        XCTAssertEqual(tabPaths(m), ["/c.swift", "/b.swift"])
        XCTAssertTrue(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/c.swift"))))
        XCTAssertFalse(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/b.swift"))))
    }

    func test_permanentOpen_promotesExistingPreviewTab() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)   // 双击同一文件

        XCTAssertFalse(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/a.swift"))),
                       "永久打开同一路径应把预览 tab 转正")
        // 转正后，下一个预览不再顶替它。
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(tabPaths(m), ["/a.swift", "/b.swift"])
    }

    func test_dirtyPreviewTab_isPromotedNotReplaced() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        let a = try XCTUnwrap(m.buffers.first)
        a.text = "edited"; a.isDirty = true
        XCTAssertFalse(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/a.swift"))),
                       "编辑中的预览 tab 应在变脏那一刻就地转正")

        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(tabPaths(m), ["/a.swift", "/b.swift"],
                       "脏预览不能被顶掉，新预览追加")
        XCTAssertTrue(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/b.swift"))))
    }

    func test_save_promotesPreviewTab() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        let a = try XCTUnwrap(m.buffers.first)
        a.text = "edited"; a.isDirty = true

        let result = await m.save(a.id)
        if case .saved = result {} else { return XCTFail("expected .saved, got \(result)") }
        // 保存清脏后若未显式转正，标签会回退成预览态（又能被顶掉）——须为 false。
        XCTAssertFalse(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/a.swift"))))
    }

    func test_closePreviewTab_clearsPreviewState() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        m.closeTab(try XCTUnwrap(tabID(m, path: "/a.swift")))

        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(tabPaths(m), ["/b.swift"])
        XCTAssertTrue(m.isTransientTab(try XCTUnwrap(tabID(m, path: "/b.swift"))))
    }

    func test_restoreOpenFilesRecreatesTabsAndLoadsAfterProviderIsReady() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.md", data: Data("# A".utf8))
        try await mock.write("/b.swift", data: Data("let b = 1".utf8))

        m.restoreOpenFiles([
            OpenFileSnapshot(remotePath: "/a.md", byteSize: 3, mtimeWhenLoaded: nil),
            OpenFileSnapshot(remotePath: "/b.swift", byteSize: 9, mtimeWhenLoaded: nil),
        ], activeIndex: 1)
        await m.loadRestoredBuffersIfNeeded()

        XCTAssertEqual(m.buffers.map(\.remotePath), ["/a.md", "/b.swift"])
        XCTAssertEqual(m.activeBuffer?.remotePath, "/b.swift")
        XCTAssertEqual(m.buffers[0].text, "# A")
        XCTAssertEqual(m.buffers[1].text, "let b = 1")
        XCTAssertEqual(m.buffers.map(\.state), [.loaded, .loaded])
    }

    // MARK: - 编辑器焦点请求（⌘A/⌘C 需要键盘焦点先落到编辑器）

    func test_open_requestsEditorFocusForOpenedBuffer() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("hi".utf8))

        await m.open(path: "/x.swift", fileSize: 2, mtime: nil)
        let first = try XCTUnwrap(m.editorFocusRequest)
        XCTAssertEqual(first.bufferID, m.buffers[0].id)

        // 重复打开同一路径（已存在 buffer）也应再次请求焦点 —— 代数递增。
        await m.open(path: "/x.swift", fileSize: 2, mtime: nil)
        let second = try XCTUnwrap(m.editorFocusRequest)
        XCTAssertEqual(second.bufferID, m.buffers[0].id)
        XCTAssertGreaterThan(second.generation, first.generation)
    }

    func test_selectTab_requestsEditorFocus() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.md", data: Data("# A".utf8))
        try await mock.write("/b.swift", data: Data("let b = 1".utf8))
        await m.open(path: "/a.md", fileSize: 3, mtime: nil)
        await m.open(path: "/b.swift", fileSize: 9, mtime: nil)
        let before = try XCTUnwrap(m.editorFocusRequest)

        m.selectTab(try XCTUnwrap(tabID(m, path: "/a.md")))

        let after = try XCTUnwrap(m.editorFocusRequest)
        XCTAssertEqual(after.bufferID, m.buffers[0].id)
        XCTAssertGreaterThan(after.generation, before.generation)
    }

    func test_restoreOpenFiles_doesNotRequestEditorFocus() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.md", data: Data("# A".utf8))

        // 会话恢复不该抢焦点（开窗时终端才是默认焦点）。
        m.restoreOpenFiles([
            OpenFileSnapshot(remotePath: "/a.md", byteSize: 3, mtimeWhenLoaded: nil),
        ], activeIndex: 0)
        await m.loadRestoredBuffersIfNeeded()

        XCTAssertNil(m.editorFocusRequest)
    }

    // MARK: - 编辑组模型（P2：改用 uAppKit 的 UPaneGroups）

    /// 分屏出去的第二个组拿到的是**同一个文档**的第二个标签 —— 改造前
    /// `dropBuffer` 建的新面板也是复用同一个 buffer，语义不变。
    func test_dragToOwnEdge_clonesTabOntoSameDocument() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)

        let tab = try XCTUnwrap(m.panes.allTabs.first)
        let group = try XCTUnwrap(m.panes.activeGroupID)
        m.panes.moveTab(tab.id, toGroup: group, zone: .trailing)

        XCTAssertEqual(m.panes.groupCount, 2)
        XCTAssertEqual(m.panes.allTabs.count, 2)
        XCTAssertEqual(m.buffers.count, 1, "两个标签指向同一个文档，不该复制文档")
        XCTAssertTrue(m.panes.allTabs.allSatisfy { $0.payload === m.buffers[0] })
    }

    /// 关标签走引用计数：还有别的标签指着同一个文档时不释放它。
    /// 改造前 `close(bufferID:)` 直接删 buffer，再由
    /// `reconcilePanelsAfterClosingBuffer` 把剩下的面板改指 activeBufferID ——
    /// 结果两个面板显示同一个文件。那段整个删掉了。
    func test_closeTab_keepsDocumentWhileAnotherTabStillReferencesIt() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil)

        let aTab = try XCTUnwrap(tabID(m, path: "/a.swift"))
        let group = try XCTUnwrap(m.panes.activeGroupID)
        m.panes.moveTab(aTab, toGroup: group, zone: .bottom)   // a 搬到新组
        XCTAssertEqual(m.panes.groupCount, 2)

        // 再把 a 克隆一份：同一个文档两个标签。
        let movedTab = try XCTUnwrap(tabID(m, path: "/a.swift"))
        let aGroup = try XCTUnwrap(m.panes.locateTab(movedTab)?.groupID)
        m.panes.moveTab(movedTab, toGroup: aGroup, zone: .trailing)
        XCTAssertEqual(m.panes.allTabs.filter { $0.payload.remotePath == "/a.swift" }.count, 2)

        let aBuffer = try XCTUnwrap(m.buffers.first { $0.remotePath == "/a.swift" })
        m.closeTab(try XCTUnwrap(tabID(m, path: "/a.swift")))
        XCTAssertTrue(m.buffers.contains { $0 === aBuffer }, "还有一个标签指着它，不该释放")

        m.closeTab(try XCTUnwrap(tabID(m, path: "/a.swift")))
        XCTAssertFalse(m.buffers.contains { $0 === aBuffer }, "最后一个引用没了才释放")
        XCTAssertEqual(tabPaths(m), ["/b.swift"])
    }

    /// 持久化是恒等映射：`openFiles` 平铺列表 + `activeFileIndex` 一个字节没变，
    /// 恢复时全部塞进唯一一个组。
    func test_openFileSnapshots_roundTripsThroughOneGroup() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.md", data: Data("# A".utf8))
        try await mock.write("/b.swift", data: Data("let b = 1".utf8))
        await m.open(path: "/a.md", fileSize: 3, mtime: nil)
        await m.open(path: "/b.swift", fileSize: 9, mtime: nil)
        m.selectTab(try XCTUnwrap(tabID(m, path: "/a.md")))

        let (snapshots, activeIndex) = m.openFileSnapshots()
        XCTAssertEqual(snapshots.map(\.remotePath), ["/a.md", "/b.swift"])
        XCTAssertEqual(activeIndex, 0)

        let (restored, _) = makeModel()
        restored.restoreOpenFiles(snapshots, activeIndex: activeIndex)
        XCTAssertEqual(tabPaths(restored), ["/a.md", "/b.swift"])
        XCTAssertEqual(restored.panes.groupCount, 1)
        XCTAssertEqual(restored.activeBuffer?.remotePath, "/a.md")
        XCTAssertTrue(restored.panes.allTabs.allSatisfy { !$0.isTransient },
                      "恢复的标签一律永久，不是预览标签")
    }

    /// 同一个文档被两个标签引用时，快照里只写一条（格式与改造前逐字相同）。
    func test_openFileSnapshots_dedupesDocumentsSharedByTwoTabs() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)
        let tab = try XCTUnwrap(m.panes.allTabs.first)
        m.panes.moveTab(tab.id, toGroup: try XCTUnwrap(m.panes.activeGroupID), zone: .trailing)

        let (snapshots, activeIndex) = m.openFileSnapshots()
        XCTAssertEqual(snapshots.map(\.remotePath), ["/a.swift"])
        XCTAssertEqual(activeIndex, 0)
    }

    /// 拖拽载荷里的 id 既可能是标签 id（组件写的），也可能是 buffer id（旧路径）。
    func test_bufferForDragPayloadID_acceptsBothTabAndBufferIDs() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)

        let buffer = try XCTUnwrap(m.buffers.first)
        let tab = try XCTUnwrap(m.panes.allTabs.first)
        XCTAssertNotEqual(tab.id, buffer.id)
        XCTAssertTrue(m.buffer(forDragPayloadID: tab.id) === buffer)
        XCTAssertTrue(m.buffer(forDragPayloadID: buffer.id) === buffer)
        XCTAssertNil(m.buffer(forDragPayloadID: UUID()))
    }

    /// 预览标签是**每组**至多一个（改造前是全局至多一个）。
    func test_transientTab_isPerGroup() async throws {
        let (m, mock) = makeModel()
        for path in ["/a.swift", "/b.swift", "/c.swift", "/d.swift"] {
            try await mock.write(path, data: Data("x".utf8))
        }
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)               // 永久
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)

        // 把永久标签 a 拖到右边成第二个组，b 的预览标签留在原组。
        let firstGroup = try XCTUnwrap(m.panes.activeGroupID)
        m.panes.moveTab(try XCTUnwrap(tabID(m, path: "/a.swift")),
                        toGroup: firstGroup, zone: .trailing)
        XCTAssertEqual(m.panes.groupCount, 2)

        // 新组里再开一个预览：两个组各自持有一个预览标签。
        await m.open(path: "/c.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(m.panes.allTabs.filter(\.isTransient).count, 2,
                       "两个组各自可以有一个预览标签")

        // 同组内再开预览只顶替**本组**那一个，另一个组的预览标签不受影响。
        await m.open(path: "/d.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(m.panes.allTabs.filter(\.isTransient).count, 2)
        XCTAssertFalse(tabPaths(m).contains("/c.swift"), "本组的预览标签被顶替")
        XCTAssertTrue(tabPaths(m).contains("/b.swift"), "另一个组的预览标签不受影响")
        XCTAssertFalse(m.buffers.contains { $0.remotePath == "/c.swift" },
                       "被顶替的文档要一起收掉，不能漏")
    }
}
