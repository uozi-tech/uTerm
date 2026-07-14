import XCTest
@testable import uTerm

@MainActor
final class FilePreviewModelTests: XCTestCase {

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
        // 模拟分屏焦点错位：activeBufferID 停在 A（未脏），实际被编辑的是 B。
        m.activeBufferID = bufA.id
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

    func test_close_removesBuffer() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        let id = m.buffers.first!.id
        m.close(id, savingIfDirty: false)
        XCTAssertTrue(m.buffers.isEmpty)
        XCTAssertNil(m.activeBufferID)
    }

    // MARK: 预览（临时）tab 语义 —— VS Code 风：单击预览打开、双击 / 编辑 / 保存转正

    func test_openAsPreview_replacesPreviousPreviewTab() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)

        XCTAssertEqual(m.buffers.map(\.remotePath), ["/b.swift"], "新预览应顶替旧预览")
        let b = try XCTUnwrap(m.buffers.first)
        XCTAssertTrue(m.isPreviewTab(b.id))
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
        XCTAssertEqual(m.buffers.map(\.remotePath), ["/c.swift", "/b.swift"])
        XCTAssertTrue(m.isPreviewTab(m.buffers[0].id))
        XCTAssertFalse(m.isPreviewTab(m.buffers[1].id))
    }

    func test_permanentOpen_promotesExistingPreviewTab() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        let a = try XCTUnwrap(m.buffers.first)
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil)   // 双击同一文件

        XCTAssertFalse(m.isPreviewTab(a.id), "永久打开同一路径应把预览 tab 转正")
        // 转正后，下一个预览不再顶替它。
        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(m.buffers.map(\.remotePath), ["/a.swift", "/b.swift"])
    }

    func test_dirtyPreviewTab_isPromotedNotReplaced() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        let a = try XCTUnwrap(m.buffers.first)
        a.text = "edited"; a.isDirty = true
        XCTAssertFalse(m.isPreviewTab(a.id), "编辑中的预览 tab 应视作已转正")

        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(m.buffers.map(\.remotePath), ["/a.swift", "/b.swift"],
                       "脏预览不能被顶掉，新预览追加")
        XCTAssertTrue(m.isPreviewTab(m.buffers[1].id))
    }

    func test_save_promotesPreviewTab() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        let a = try XCTUnwrap(m.buffers.first)
        a.text = "edited"; a.isDirty = true

        let result = await m.save(a.id)
        if case .saved = result {} else { return XCTFail("expected .saved, got \(result)") }
        // 保存清脏后若未显式转正，isPreviewTab 会回退为 true（又能被顶掉）——须为 false。
        XCTAssertFalse(m.isPreviewTab(a.id))
    }

    func test_closePreviewTab_clearsPreviewState() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/a.swift", data: Data("a".utf8))
        try await mock.write("/b.swift", data: Data("b".utf8))

        await m.open(path: "/a.swift", fileSize: 1, mtime: nil, asPreview: true)
        let a = try XCTUnwrap(m.buffers.first)
        m.close(a.id, savingIfDirty: false)

        await m.open(path: "/b.swift", fileSize: 1, mtime: nil, asPreview: true)
        XCTAssertEqual(m.buffers.map(\.remotePath), ["/b.swift"])
        XCTAssertTrue(m.isPreviewTab(m.buffers[0].id))
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
}
