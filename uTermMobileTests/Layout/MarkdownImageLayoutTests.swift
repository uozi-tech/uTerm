import Markdown
import XCTest
@testable import uTermMobile

/// 文档预览里段落按图片切开（`MMDParagraphLayout`）：文字照原顺序留着，图片单独画，挨着的图放一行。
final class MarkdownImageLayoutTests: XCTestCase {

    /// 每段写成一个字符串：文字段是去掉两头空白的纯文字，图片段是 `[img a.png, b.png]`。
    private func layout(_ markdown: String) throws -> [String] {
        let document = Document(parsing: markdown)
        let paragraph = try XCTUnwrap(document.child(at: 0) as? Paragraph)
        return MMDParagraphLayout.segments(paragraph).map { segment in
            switch segment {
            case .text(let nodes):
                return nodes.map { node -> String in
                    if node is SoftBreak || node is LineBreak { return " " }
                    return (node as? InlineMarkup)?.plainText ?? ""
                }.joined().trimmingCharacters(in: .whitespaces)
            case .images(let images):
                return "[img " + images.map { $0.source ?? "" }.joined(separator: ", ") + "]"
            }
        }
    }

    func testImageInTheMiddleOfASentenceSplitsTheText() throws {
        XCTAssertEqual(try layout("Before the chart ![c](chart.png) and **after** it."),
                       ["Before the chart", "[img chart.png]", "and after it."])
    }

    func testAdjacentImagesShareARow() throws {
        XCTAssertEqual(try layout("Badges: ![a](a.svg) ![b](b.png)\n![c](c.png) done"),
                       ["Badges:", "[img a.svg, b.png, c.png]", "done"])
    }

    func testImageOnlyParagraph() throws {
        XCTAssertEqual(try layout("![shot](out/shot.png)"), ["[img out/shot.png]"])
    }

    func testTextBetweenImagesKeepsItsOrder() throws {
        XCTAssertEqual(try layout("![a](a.png) vs ![b](b.png)"),
                       ["[img a.png]", "vs", "[img b.png]"])
    }

    func testParagraphWithoutImagesIsOneTextSegment() throws {
        XCTAssertEqual(try layout("Just *text* here."), ["Just text here."])
    }
}

/// 截图给人看（按需）：`TEST_RUNNER_UTERM_STYLE_SHOTS_DIR=/path`。真的预览标签 + 假 SFTP 里的图。
@MainActor
final class MarkdownImagePreviewShotTests: XCTestCase {
    func testSnapshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_STYLE_SHOTS_DIR")
        }
        func png(_ size: CGSize, _ color: UIColor) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            }.pngData())
        }
        let provider = MobileFakeSFTPProvider(entries: 0)
        for d in ["/proj", "/proj/img"] { try await provider.createDirectory(d) }
        try await provider.seedFile("/proj/img/chart.png", data: try png(CGSize(width: 900, height: 500), .systemBlue))
        try await provider.seedFile("/proj/img/a.png", data: try png(CGSize(width: 90, height: 20), .systemGreen))
        try await provider.seedFile("/proj/img/b.png", data: try png(CGSize(width: 110, height: 20), .systemOrange))
        try await provider.seedFile("/proj/img/wide.png", data: try png(CGSize(width: 1200, height: 300), .systemPink))
        try await provider.seedFile("/proj/plan.md", data: Data("""
        # Plan

        Badges: ![build](img/a.png) ![license](img/b.png) and some text after them.

        The chart below ![chart](img/chart.png) shows the trend, and this sentence continues after it.

        Two side by side: ![w1](img/wide.png) ![w2](img/chart.png)

        Missing one ![gone](img/missing.png) stays as alt text.
        """.utf8))
        let host = ServerProfile()
        let tab = FilePreviewTab(host: host, controller: MobileFilePreviewController(path: "/proj/plan.md") { provider })
        tab.controller.reload()
        for (name, width) in [("narrow", CGFloat(330)), ("wide", 669)] {
            let (window, hostVC) = MobileProbeWindow.make(size: CGSize(width: width, height: 900),
                                                          placement: .visibleOnScreen,
                                                          rootView: FilePreviewSessionBody(tab: tab, onClose: {}))
            try await Task.sleep(for: .seconds(1.5))
            let image = UIGraphicsImageRenderer(bounds: hostVC.view.bounds).image { _ in
                hostVC.view.drawHierarchy(in: hostVC.view.bounds, afterScreenUpdates: true)
            }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("md-images-\(name).png"))
            window.isHidden = true
        }
        tab.controller.close()
    }
}
