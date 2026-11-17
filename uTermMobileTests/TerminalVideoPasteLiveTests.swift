import CryptoKit
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import uTermMobile

/// 真 sshd 上贴视频：产品的终端标签（真的 `PersistentSSHConnection`、真的终端）连上主机，剪贴板里的视频、
/// 相册交来的视频（`PickedVideo` 那条 Transferable 导入）各贴一次——路径粘进终端，服务器上那个文件大小与 md5 都对得上、
/// 权限是 600。
///
/// 默认跳过。和 `MobileTerminalLiveHostSessionTests` 用同一个容器（`holder/e2e/sshd`）：
///
///     TEST_RUNNER_UTERM_LIVE_SSH_PORT=2298 TEST_RUNNER_UTERM_LIVE_SSH_USER=dev \
///     TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD=dev xcodebuild test … \
///       -only-testing:uTermMobileTests/TerminalVideoPasteLiveTests
@MainActor
final class TerminalVideoPasteLiveTests: XCTestCase {
    private var container: ModelContainer!
    private var profile: ServerProfile!
    private let relay = HostKeyChallengeRelay()

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_LIVE_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_LIVE_SSH_PORT，跳过真 sshd 用例")
        }
        container = try MobileFixtures.emptyContainer()
        profile = ServerProfile()
        profile.name = "video-paste-live"
        profile.host = env["UTERM_LIVE_SSH_HOST"] ?? "127.0.0.1"
        profile.port = port
        profile.username = env["UTERM_LIVE_SSH_USER"] ?? "root"
        profile.authMethod = .password
        container.mainContext.insert(profile)
        try container.mainContext.save()
        try KeychainStore().save(env["UTERM_LIVE_SSH_PASSWORD"] ?? "PASS", profileID: profile.id, kind: .password)
        let id = profile.id
        addTeardownBlock { try? KeychainStore().delete(profileID: id, kind: .password) }
    }

    func testBothSourcesUploadTheWholeVideoAndPasteItsPath() async throws {
        let tab = TermTab(host: profile)
        tab.controller.start(profile: profile, container: container, relay: relay)
        defer { tab.controller.close() }
        await wait("连上") { tab.controller.state == .connected }
        XCTAssertTrue(tab.controller.acceptsVideos)
        // 不回显：粘进来的路径只出现在 echo 那一行，别和命令本身混在一起。
        tab.controller.sendText("stty -echo; clear\n")

        // 剪贴板：24 MB 多一点，跨好几段、最后一段不满。
        let clipboardMovie = pattern(count: 24 * 1_048_576 + 12_345, seed: 5)
        let board = try XCTUnwrap(UIPasteboard(name: .init("uterm-live-\(UUID().uuidString)"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        board.setItems([[UTType.mpeg4Movie.identifier: clipboardMovie]])
        try await pasteAndVerify(clipboardMovie, ext: "mp4", on: tab, marker: "CLIP") {
            try await TerminalPasteSource.clipboard(allowsVideo: true, board: board)
        }

        // 相册：经 PickedVideo 的文件表示交过来。
        let pickedMovie = pattern(count: 3 * 1_048_576 + 7, seed: 11)
        let source = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString).mov")
        try pickedMovie.write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try await pasteAndVerify(pickedMovie, ext: "mov", on: tab, marker: "PICK") {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(for: .quickTimeMovie, openInPlace: false) { done in
                done(source, false, nil)
                return nil
            }
            let picked: TerminalPasteSource.PickedVideo = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: TerminalPasteSource.PickedVideo.self) { continuation.resume(with: $0) }
            }
            return .video(picked.video)
        }
    }

    // MARK: -

    /// 贴一次：等提示说传完，路径已经粘在输入行上；再补一个 echo 前缀把它连同大小、md5、权限打出来核对。
    private func pasteAndVerify(_ movie: Data, ext: String, on tab: TermTab, marker: String,
                                load: @escaping @MainActor () async throws -> TerminalPasteItem) async throws {
        let controller = tab.controller
        // 先打一半命令，路径粘在它后面，回车后 shell 把路径当参数。
        controller.sendText("f=")
        controller.sendPaste(load)
        await wait("上传完", timeout: .seconds(120)) {
            controller.imageNote?.text.contains("/tmp/uterm-video-") == true && controller.imageNote?.progress == nil
        }
        let note = try XCTUnwrap(controller.imageNote?.text)
        let path = try XCTUnwrap(note.range(of: #"/tmp/uterm-video-[0-9-]+-[0-9a-f]{4}\."# + ext,
                                            options: .regularExpression).map { String(note[$0]) }, note)
        controller.sendText("; echo \(marker)=$f; stat -c \(marker)-SIZE=%s:%a \"$f\"; md5sum \"$f\"; rm -f \"$f\"\n")
        let md5 = Insecure.MD5.hash(data: movie).map { String(format: "%02x", $0) }.joined()
        await wait("服务器上的文件核对") {
            let screen = tab.controller.terminal.shadow.viewportText()
            return screen.contains("\(marker)-SIZE=") && screen.contains(md5)
        }
        let screen = tab.controller.terminal.shadow.viewportText()
        XCTAssertTrue(screen.contains("\(marker)=\(path)"), screen)
        XCTAssertTrue(screen.contains("\(marker)-SIZE=\(movie.count):600"), screen)
        XCTAssertTrue(screen.contains(md5), screen)
        controller.sendText("clear\n")
        await wait("清屏") { !tab.controller.terminal.shadow.viewportText().contains(md5) }
    }

    private func pattern(count: Int, seed: UInt8) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: i &* 131 &+ Int(seed) &+ (i >> 16)) }
        }
        return data
    }

    /// 等条件成立；期间出现的主机密钥确认一律信任（只对测试服务器）。
    private func wait(_ what: String, timeout: Duration = .seconds(30), until done: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            if relay.pendingChallenge != nil { relay.resolve(true) }
            guard ContinuousClock.now < deadline else {
                XCTFail("等不到：\(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
