import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import XCTest
@testable import uTerm

/// 剪贴板里是视频时 Mac 终端怎么走：SSH 终端传成服务器上的文件、把路径粘进去，本机 shell 照常粘贴。
@MainActor
final class TerminalVideoPasteTests: XCTestCase {

    /// 记录写入与收到的视频；收到时把本机拷贝的内容读出来（送完会被删）。
    private actor VideoBackend: TerminalImageReceiving, TerminalVideoReceiving {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated let programsCanReadMacClipboard: Bool
        nonisolated let receivesFiles: Bool
        private let outputContinuation: AsyncStream<TerminalOutputItem>.Continuation
        private let exitContinuation: AsyncStream<Void>.Continuation
        private(set) var written: [Data] = []
        private(set) var delivered: [(video: TerminalVideo, bytes: Data)] = []
        private let failure: TerminalImageError?

        init(canReadClipboard: Bool = false, receivesFiles: Bool = true, failure: TerminalImageError? = nil) {
            programsCanReadMacClipboard = canReadClipboard
            self.receivesFiles = receivesFiles
            self.failure = failure
            (outputItems, outputContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
            (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        }

        func connect() async throws {}
        func write(_ data: Data) async { written.append(data) }
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {
            outputContinuation.finish()
            exitContinuation.finish()
        }
        func deliverImage(_ image: uTerm.TerminalImage) async throws -> TerminalImageDelivery {
            .file(path: "/tmp/shot.png")
        }
        func deliverVideo(_ video: TerminalVideo) async throws -> String {
            if let failure { throw failure }
            delivered.append((video, (try? Data(contentsOf: video.localURL)) ?? Data()))
            return "/tmp/clip.\(video.fileExtension)"
        }
    }

    private let movie = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    private var pasteboard: NSPasteboard!
    private var session: TerminalSession!
    private var view: GhosttySurfaceView!
    private var attentions: [TerminalAttention] = []
    private var directory: URL!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        session = TerminalSession()
        view = session.ghostty.view
        view.pasteboard = pasteboard
        attentions = []
        session.attentionSink = { [unowned self] in self.attentions.append($0) }
        directory = FileManager.default.temporaryDirectory.appending(path: "video-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appending(path: name)
        try bytes.write(to: url)
        return url
    }

    /// 像 Finder 拷文件一样放进剪贴板。
    private func copyFiles(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    private func reportAgent() {
        session.feedOutput(text: "\u{1b}]7501;state=idle:app=claude-code\u{1b}\\")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }

    // MARK: 从剪贴板取视频

    func testFinderCopiedVideoFile() throws {
        let url = try file("demo clip.MOV", movie)
        copyFiles([url])
        guard case .file(let read)? = TerminalClipboardVideo.fromPasteboard(pasteboard) else {
            return XCTFail("应当读成视频文件")
        }
        XCTAssertEqual(read.standardizedFileURL.path, url.standardizedFileURL.path)
    }

    /// 拷了别的文件、拷了几个文件：照常粘贴（粘出来是文件名）。
    func testOtherFilesAndSeveralVideosAreNotTaken() throws {
        copyFiles([try file("notes.pdf", Data([1, 2, 3]))])
        XCTAssertNil(TerminalClipboardVideo.fromPasteboard(pasteboard))
        copyFiles([try file("a.mov", movie), try file("b.mp4", movie)])
        XCTAssertNil(TerminalClipboardVideo.fromPasteboard(pasteboard))
    }

    func testVideoDataOnClipboard() {
        pasteboard.clearContents()
        pasteboard.setData(movie, forType: NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier))
        XCTAssertEqual(TerminalClipboardVideo.fromPasteboard(pasteboard), .data(movie, type: .mpeg4Movie))
    }

    /// 同时带文字时用户要的是文字。
    func testTextWinsOverVideoData() {
        pasteboard.clearContents()
        pasteboard.setData(movie, forType: NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier))
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(TerminalClipboardVideo.fromPasteboard(pasteboard))
    }

    /// 视频数据写成本机私有文件，扩展名按类型取。
    func testVideoDataBecomesAPrivateCopy() throws {
        let video = try TerminalClipboardVideo.data(movie, type: .mpeg4Movie).privateCopy()
        addTeardownBlock { video.discardLocalCopy() }
        XCTAssertEqual(video.fileExtension, "mp4")
        XCTAssertEqual(video.size, Int64(movie.count))
        XCTAssertEqual(try Data(contentsOf: video.localURL), movie)
        XCTAssertEqual(video.localURL.deletingLastPathComponent().standardizedFileURL.path,
                       TerminalVideo.copiesDirectory.standardizedFileURL.path)
    }

    // MARK: ⌘V

    /// SSH 终端：拷一份传过去，路径用括号粘贴送进终端；送完删掉拷贝，用户的原文件不动。
    func testCommandVOverSSHUploadsAndPastesPath() async throws {
        let backend = VideoBackend()
        await session.connect(using: backend)
        session.feedOutput(text: "\u{1b}[?2004h")
        let original = try file("demo clip.MOV", movie)
        copyFiles([original])

        view.paste(self)

        let expected = Data("\u{1b}[200~/tmp/clip.mov \u{1b}[201~".utf8)
        try await waitUntil { await backend.written.contains(expected) }
        let delivered = await backend.delivered
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.bytes, movie)
        XCTAssertEqual(delivered.first?.video.size, Int64(movie.count))
        let copy = try XCTUnwrap(delivered.first?.video.localURL)
        XCTAssertNotEqual(copy, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: original), movie)
    }

    /// 本机 shell 的程序读得到这台 Mac 上的文件，不接管。
    func testLocalShellIsNotTaken() async throws {
        await session.connect(using: VideoBackend(canReadClipboard: true))
        reportAgent()
        XCTAssertFalse(session.pasteVideo(.file(try file("a.mov", movie))))
    }

    /// 收不了文件的终端（远控着的 Mac 上开着的 SSH 终端）照常粘贴。
    func testTerminalWithoutFilesIsNotTaken() async throws {
        await session.connect(using: VideoBackend(receivesFiles: false))
        XCTAssertFalse(session.pasteVideo(.file(try file("a.mov", movie))))
    }

    func testBackendWithoutVideoSupportFallsBackToNormalPaste() async throws {
        await session.connect(using: MockBackend())
        XCTAssertFalse(session.pasteVideo(.file(try file("a.mov", movie))))
    }

    func testDeliveryFailureIsShown() async throws {
        await session.connect(using: VideoBackend(failure: .notConnected))
        XCTAssertTrue(session.pasteVideo(.data(movie, type: .quickTimeMovie)))
        try await waitUntil { await MainActor.run { !self.attentions.isEmpty } }
        XCTAssertEqual(attentions.first?.title, "视频发送失败")
    }

    // MARK: ⌃V

    private func controlV() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\u{16}", charactersIgnoringModifiers: "v",
                                       isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
    }

    func testControlVOverSSHWithAgentUploads() async throws {
        let backend = VideoBackend()
        await session.connect(using: backend)
        reportAgent()
        copyFiles([try file("a.mp4", movie)])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        defer { window.close() }

        XCTAssertTrue(view.performKeyEquivalent(with: try controlV()))

        try await waitUntil { await !backend.delivered.isEmpty }
        let delivered = await backend.delivered
        XCTAssertEqual(delivered.first?.video.fileExtension, "mp4")
    }

    /// vim、zsh 里 Ctrl+V 有自己的含义。
    func testControlVWithoutAgentGoesToProgram() async throws {
        await session.connect(using: VideoBackend())
        XCTAssertFalse(session.handleControlVVideo(.file(try file("a.mov", movie))))
    }
}
