import UIKit
import XCTest
@testable import uTermMobile

/// 终端里的程序请求预览的文件（OSC 6975）：预览标签放在哪一格、键盘焦点留在哪，以及内容怎么解码。只动模型，不建连接。
@MainActor
final class FilePreviewTabTests: XCTestCase {

    private func term(_ host: ServerProfile) -> TermTab {
        MobileFakeTerminal.tab(host: host, .idle).0
    }

    private func preview(_ host: ServerProfile, _ path: String = "/srv/plan.md",
                         provider: MobileFakeSFTPProvider = MobileFakeSFTPProvider(entries: 0)) -> FilePreviewTab {
        FilePreviewTab(host: host, controller: MobileFilePreviewController(path: path) { provider })
    }

    func testPreviewSplitsOffASecondPaneAndKeepsFocusOnTheTerminal() throws {
        let ws = MobileWorkspace()
        let host = ServerProfile()
        let shell = term(host)
        ws.open(.terminal(shell))
        let terminalPane = ws.focusedPaneID

        let p = preview(host)
        ws.placePreview(p, beside: shell)

        XCTAssertTrue(ws.isSplit)
        XCTAssertEqual(ws.focusedPaneID, terminalPane, "键盘留在终端那一格")
        XCTAssertEqual(ws.activeTab?.id, shell.id)
        let other = try XCTUnwrap(ws.panes.first { $0.id != terminalPane })
        XCTAssertEqual(other.tabIDs, [p.id])
        XCTAssertEqual(other.activeID, p.id)
    }

    func testPreviewGoesToTheOtherPaneWhenAlreadySplit() throws {
        let ws = MobileWorkspace()
        let host = ServerProfile()
        let shell = term(host)
        ws.open(.terminal(shell))
        let terminalPane = ws.focusedPaneID
        ws.split()
        let files = FileTab(host: host)
        ws.open(.files(files))
        ws.activate(shell.id)

        let p = preview(host)
        ws.placePreview(p, beside: shell)

        XCTAssertEqual(ws.panes.count, 2, "两格封顶，不再拆")
        XCTAssertEqual(ws.focusedPaneID, terminalPane)
        let other = try XCTUnwrap(ws.panes.first { $0.id != terminalPane })
        XCTAssertEqual(other.tabIDs, [files.id, p.id])
        XCTAssertEqual(other.activeID, p.id, "预览带到那一格的前台")
    }

    func testExistingPreviewIsReusedAndMovedOutOfTheTerminalPane() throws {
        let ws = MobileWorkspace()
        let host = ServerProfile()
        let shell = term(host)
        ws.open(.terminal(shell))
        let terminalPane = ws.focusedPaneID
        let p = preview(host)
        ws.placePreview(p, beside: shell)
        // 用户把预览拖回了终端那一格。
        ws.move(p.id, toPane: terminalPane)
        ws.activate(shell.id)
        XCTAssertFalse(ws.isSplit)

        XCTAssertTrue(ws.existingPreview(host: host.persistentModelID) === p)
        ws.placePreview(p, beside: shell)

        XCTAssertTrue(ws.isSplit)
        XCTAssertEqual(ws.tabs.count, 2, "不再开第二个预览标签")
        XCTAssertEqual(ws.focusedPaneID, terminalPane)
        XCTAssertEqual(ws.panes.first { $0.id != terminalPane }?.activeID, p.id)
    }

    func testOpeningAHostReusesItsFilesTabNotThePreview() {
        let ws = MobileWorkspace()
        let host = ServerProfile()
        let shell = term(host)
        ws.open(.terminal(shell))
        ws.placePreview(preview(host), beside: shell)
        XCTAssertNil(ws.existing(host: host.persistentModelID, kind: .sftp), "预览标签不是文件浏览标签")
    }

    func testWorkspaceWiresTerminalRequests() {
        let ws = MobileWorkspace()
        let shell = term(ServerProfile())
        var requested: [String] = []
        ws.onFilePreviewRequest = { tab, path in
            XCTAssertTrue(tab === shell)
            requested.append(path)
        }
        ws.open(.terminal(shell))
        shell.controller.onFilePreviewRequest?("/srv/plan.md")
        XCTAssertEqual(requested, ["/srv/plan.md"])
    }

    // MARK: 内容

    func testLoadsMarkdownTextAndImages() async throws {
        let provider = MobileFakeSFTPProvider(entries: 0)
        try await provider.seedFile("/plan.md", data: Data("# Plan".utf8))
        try await provider.seedFile("/main.go", data: Data("package main".utf8))
        try await provider.seedFile("/blob.txt", data: Data([0x41, 0x00, 0x42]))
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { _ in }.pngData())
        try await provider.seedFile("/shot.png", data: png)
        let controller = MobileFilePreviewController(path: "/plan.md") { provider }

        controller.reload()
        try await waitUntilLoaded(controller)
        guard case .loaded(.markdown(let md)) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(md, "# Plan")

        controller.show("/main.go")
        try await waitUntilLoaded(controller)
        guard case .loaded(.text(let code)) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(code, "package main")

        controller.show("/shot.png")
        try await waitUntilLoaded(controller)
        guard case .loaded(.image(let image)) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(image.size.width * image.scale, 4 * UIScreen.main.scale, accuracy: 0.5)

        controller.show("/blob.txt")
        try await waitUntilLoaded(controller)
        guard case .failed = controller.phase else { return XCTFail("二进制内容不当文本显示") }

        controller.close()
    }

    func testOnlyRegularFilesAreOpened() async throws {
        let provider = MobileFakeSFTPProvider(entries: 0)
        try await provider.createDirectory("/proj")
        try await provider.seedFile("/proj/plan.md", data: Data("# Plan".utf8))
        let controller = MobileFilePreviewController(path: "/proj/plan.md") { provider }

        let file = await controller.isOpenableFile("/proj/plan.md")
        let directory = await controller.isOpenableFile("/proj")
        let missing = await controller.isOpenableFile("/proj/nope.md")
        XCTAssertTrue(file)
        XCTAssertFalse(directory, "目录不开预览标签")
        XCTAssertFalse(missing, "正文里像路径的词：不存在就不开")
        controller.close()
    }

    func testMarkdownImagesComeFromTheSameHost() async throws {
        let provider = MobileFakeSFTPProvider(entries: 0)
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { _ in }.pngData())
        for dir in ["/proj", "/proj/docs", "/proj/docs/img"] { try await provider.createDirectory(dir) }
        try await provider.seedFile("/proj/docs/plan.md", data: Data("![chart](img/chart.png)".utf8))
        try await provider.seedFile("/proj/docs/img/chart.png", data: png)
        try await provider.seedFile("/proj/shared.png", data: png)
        let controller = MobileFilePreviewController(path: "/proj/docs/plan.md") { provider }

        let relative = try await controller.markdownImage("img/chart.png")
        XCTAssertEqual(relative.size.width * relative.scale, 4 * UIScreen.main.scale, accuracy: 0.5)
        _ = try await controller.markdownImage("../shared.png?raw=1")
        do {
            _ = try await controller.markdownImage("https://example.com/x.png")
            XCTFail("网址不读")
        } catch MobileFilePreviewController.MarkdownImageError.notOnThisHost {}
        do {
            _ = try await controller.markdownImage("missing.png")
            XCTFail("不存在的图")
        } catch {}
        controller.close()
    }

    private func waitUntilLoaded(_ controller: MobileFilePreviewController) async throws {
        for _ in 0..<200 {
            if case .loading = controller.phase {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                return
            }
        }
        XCTFail("一直在加载")
    }
}
