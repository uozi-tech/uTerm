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
