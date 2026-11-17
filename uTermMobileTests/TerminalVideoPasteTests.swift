import CoreTransferable
import NIOCore
import Synchronization
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import uTermMobile

/// 终端键盘条贴视频：剪贴板 / 相册来的视频拷成本机私有文件、按段流式传成远端 `/tmp` 下的文件、把路径粘进终端；
/// 远控 Mac 的终端（只收图片）对视频直说不支持。
@MainActor
final class TerminalVideoPasteTests: XCTestCase {

    // MARK: - 流式上传

    /// 按段读本机文件写到远端：内容一字不差；任何时候在途的字节不超过一段（几百 MB 的视频不整份进内存）；
    /// 进度单调、最后报到总数。
    func testStreamsTheFileSegmentBySegment() async throws {
        let bytes = Data((0..<300_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = try temporaryFile(bytes, ext: "mov")
        let remote = RecordingPipelineFile()
        let reports = Mutex<[(Int64, Int64)]>([])
        try await SFTPPipeline.write(remote, contentsOf: url, segmentBytes: 100_000) { written, total in
            reports.withLock { $0.append((written, total)) }
        }
        XCTAssertEqual(remote.assembled, bytes)
        XCTAssertLessThanOrEqual(remote.peakOutstandingBytes, 100_000)
        let progress = reports.withLock { $0 }
        XCTAssertEqual(progress.first?.0, 0)
        XCTAssertEqual(progress.last?.0, Int64(bytes.count))
        XCTAssertTrue(progress.allSatisfy { $0.1 == Int64(bytes.count) })
        XCTAssertEqual(progress.map(\.0), progress.map(\.0).sorted())
    }

    func testRemotePathIsShellSafe() {
        let url = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(TerminalVideo(localURL: url, fileExtension: "MP4", size: 1).fileExtension, "mp4")
        XCTAssertEqual(TerminalVideo(localURL: url, fileExtension: "m o'v", size: 1).fileExtension, "mov")
        XCTAssertEqual(TerminalVideo(localURL: url, fileExtension: "", size: 1).fileExtension, "mov")
        let path = TerminalVideo(localURL: url, fileExtension: "m4v", size: 1).temporaryRemotePath()
        XCTAssertNotNil(path.range(of: #"^/tmp/uterm-video-\d{8}-\d{6}-[0-9a-f]{4}\.m4v$"#, options: .regularExpression),
                        path)
        let image = TerminalImage(format: .png, data: Data()).temporaryRemotePath()
        XCTAssertNotNil(image.range(of: #"^/tmp/uterm-image-\d{8}-\d{6}-[0-9a-f]{4}\.png$"#, options: .regularExpression),
                        image)
    }

    // MARK: - 来源

    /// 剪贴板里的视频：读成本机临时目录里的一份拷贝，扩展名按类型来。
    func testClipboardVideoBecomesAPrivateCopy() async throws {
        let movie = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
        let board = try XCTUnwrap(UIPasteboard(name: .init("uterm-test-\(UUID().uuidString)"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        board.setItems([[UTType.mpeg4Movie.identifier: movie]])

        let item = try await TerminalPasteSource.clipboard(allowsVideo: true, board: board)
        guard case .video(let video) = item else { return XCTFail("应当读成视频：\(item)") }
        addTeardownBlock { video.discardLocalCopy() }
        XCTAssertEqual(video.fileExtension, "mp4")
        XCTAssertEqual(video.size, Int64(movie.count))
        XCTAssertEqual(try Data(contentsOf: video.localURL), movie)
        XCTAssertEqual(video.localURL.deletingLastPathComponent().standardizedFileURL.path,
                       TerminalPasteSource.copiesDirectory.standardizedFileURL.path)
    }

    /// 收不了视频的终端（远控 Mac）：剪贴板里只有视频时直说，不读内容。
    func testClipboardVideoOnAnImageOnlyTerminalSaysSo() async throws {
        let board = try XCTUnwrap(UIPasteboard(name: .init("uterm-test-\(UUID().uuidString)"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        board.setItems([[UTType.quickTimeMovie.identifier: Data([1, 2, 3])]])
        do {
            _ = try await TerminalPasteSource.clipboard(allowsVideo: false, board: board)
            XCTFail("应当报不支持")
        } catch TerminalPasteSource.Failure.videoUnsupported {
        }
    }

    /// 相册的视频经 `PickedVideo` 的文件表示交过来（PhotosPickerItem 走的就是这条 Transferable 导入）：当场拷走。
    func testPickedVideoTransferCopiesTheReceivedFile() async throws {
        let movie = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let source = try temporaryFile(movie, ext: "mov")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(for: .quickTimeMovie, openInPlace: false) { done in
            done(source, false, nil)
            return nil
        }
        let picked: TerminalPasteSource.PickedVideo = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: TerminalPasteSource.PickedVideo.self) { continuation.resume(with: $0) }
        }
        addTeardownBlock { picked.video.discardLocalCopy() }
        XCTAssertNotEqual(picked.video.localURL, source)
        XCTAssertEqual(picked.video.fileExtension, "mov")
        XCTAssertEqual(try Data(contentsOf: picked.video.localURL), movie)
    }

    func testPickerTreatsLivePhotosAsImages() {
        XCTAssertTrue(TerminalPasteSource.isVideo([.quickTimeMovie]))
        XCTAssertTrue(TerminalPasteSource.isVideo([.mpeg4Movie]))
        XCTAssertFalse(TerminalPasteSource.isVideo([.livePhoto, .heic]))
        XCTAssertFalse(TerminalPasteSource.isVideo([.jpeg]))
        XCTAssertEqual(TerminalPasteSource.videoType(in: [UTType.png.identifier, UTType.mpeg4Movie.identifier]),
                       UTType.mpeg4Movie.identifier)
        XCTAssertNil(TerminalPasteSource.videoType(in: [UTType.png.identifier, UTType.utf8PlainText.identifier]))
    }

    // MARK: - 控制器

    /// 直连主机：视频交给后端，路径（带一个空格）粘进终端，提示说传到了哪；本机拷贝送完删掉。
    func testControllerUploadsTheVideoAndPastesItsPath() async throws {
        let recorder = MediaRecorder()
        let controller = try await connectedController(MediaBackend(recorder))
        XCTAssertTrue(controller.acceptsImages)
        XCTAssertTrue(controller.acceptsVideos)

        let video = try localVideo(Data(repeating: 7, count: 4096))
        controller.sendPaste { .video(video) }
        let done = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            controller.imageNote?.text.contains(MediaRecorder.uploadedPath) == true
        }
        XCTAssertTrue(done, "提示：\(String(describing: controller.imageNote))")
        XCTAssertEqual(recorder.receivedVideos, [Data(repeating: 7, count: 4096)])
        let typed = await MobileFakeTerminal.waitUntil {
            recorder.typedText.contains(MediaRecorder.uploadedPath + " ")
        }
        XCTAssertTrue(typed, "终端收到：\(recorder.typedText)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.localURL.path), "本机拷贝应当删掉")
        controller.close()
    }

    /// 远控 Mac 的终端只收图片：键盘条不提供视频；万一送来视频（系统粘贴），说清楚不支持，拷贝照样删掉。
    func testImageOnlyBackendRefusesVideosPlainly() async throws {
        let recorder = MediaRecorder()
        let controller = try await connectedController(ImageOnlyBackend(recorder))
        XCTAssertTrue(controller.acceptsImages)
        XCTAssertFalse(controller.acceptsVideos)

        let video = try localVideo(Data([1, 2, 3]))
        controller.sendPaste { .video(video) }
        let expected = TerminalPasteSource.Failure.videoUnsupported.errorDescription
        let shown = await MobileFakeTerminal.waitUntil { controller.imageNote?.text == expected }
        XCTAssertTrue(shown, "提示：\(String(describing: controller.imageNote))")
        XCTAssertTrue(recorder.typedText.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.localURL.path))
        controller.close()
    }

    // MARK: - 夹具

    private func connectedController(_ backend: any TerminalBackend) async throws -> MobileTerminalController {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let controller = MobileTerminalController(transportFactory: MobileTerminalTransportFactory { _ in backend })
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        return controller
    }

    private func localVideo(_ data: Data) throws -> TerminalVideo {
        let url = try temporaryFile(data, ext: "mp4", directory: TerminalPasteSource.copiesDirectory)
        return TerminalVideo(localURL: url, fileExtension: "mp4", size: Int64(data.count))
    }

    private func temporaryFile(_ data: Data, ext: String,
                               directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "video-paste-test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// 记下每片写到哪、同时在途多少字节的假远端文件。
private final class RecordingPipelineFile: SFTPPipelineFile, Sendable {
    private struct State {
        var pieces: [UInt64: Data] = [:]
        var outstanding = 0
        var peak = 0
    }
    private let state = Mutex(State())

    func writeChunk(_ data: ByteBuffer, at offset: UInt64) async throws {
        let bytes = Data(data.readableBytesView)
        state.withLock {
            $0.outstanding += bytes.count
            $0.peak = max($0.peak, $0.outstanding)
        }
        await Task.yield()
        state.withLock {
            $0.outstanding -= bytes.count
            $0.pieces[offset] = bytes
        }
    }

    func readChunk(from offset: UInt64, length: UInt32) async throws -> ByteBuffer { ByteBuffer() }

    var peakOutstandingBytes: Int { state.withLock { $0.peak } }

    var assembled: Data {
        state.withLock { state in
            state.pieces.keys.sorted().reduce(into: Data()) { $0.append(state.pieces[$1]!) }
        }
    }
}

/// 假后端记下的东西：终端输入（文字）和收到的视频内容。
private final class MediaRecorder: Sendable {
    static let uploadedPath = "/tmp/uterm-video-test.mp4"
    private let typed = Mutex("")
    private let videos = Mutex<[Data]>([])

    var typedText: String { typed.withLock { $0 } }
    var receivedVideos: [Data] { videos.withLock { $0 } }
    func type(_ data: Data) { typed.withLock { $0 += String(decoding: data, as: UTF8.self) } }
    /// 拷贝在送完之前必须还在：当场读出内容。
    func receive(_ video: TerminalVideo) throws -> String {
        let data = try Data(contentsOf: video.localURL)
        videos.withLock { $0.append(data) }
        return Self.uploadedPath
    }
}

/// 只收图片的后端（远控 Mac 的终端那样）。
private actor ImageOnlyBackend: TerminalImageReceiving {
    nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
    nonisolated let exitStream = AsyncStream<Void> { _ in }
    nonisolated let recorder: MediaRecorder
    init(_ recorder: MediaRecorder) { self.recorder = recorder }

    nonisolated var programsCanReadMacClipboard: Bool { false }
    func connect() async throws {}
    func write(_ data: Data) async { recorder.type(data) }
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async {}
    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        .file(path: "/tmp/uterm-image-test.png")
    }
}

/// 图片、视频都收的后端（直连 SSH 那样）。
private actor MediaBackend: TerminalImageReceiving, TerminalVideoReceiving {
    nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
    nonisolated let exitStream = AsyncStream<Void> { _ in }
    nonisolated let recorder: MediaRecorder
    init(_ recorder: MediaRecorder) { self.recorder = recorder }

    nonisolated var programsCanReadMacClipboard: Bool { false }
    func connect() async throws {}
    func write(_ data: Data) async { recorder.type(data) }
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async {}
    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        .file(path: "/tmp/uterm-image-test.png")
    }
    func deliverVideo(_ video: TerminalVideo) async throws -> String { try recorder.receive(video) }
}
