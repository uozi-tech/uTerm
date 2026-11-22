import AppKit
import Markdown
import SwiftUI
import XCTest
@testable import uTerm

/// 文档预览里段落按图片切开（`MarkdownParagraphLayout`，两端共用）在 Mac 上的样子。截图给人看（按需）：
/// `TEST_RUNNER_UTERM_STYLE_SHOTS=1`，图挂成 XCTest 附件（测试宿主带沙盒，写不进仓库）。
@MainActor
final class MarkdownImageRowsSnapshotTests: XCTestCase {
    func testSnapshot() async throws {
        let env = ProcessInfo.processInfo.environment
        guard (env["UTERM_STYLE_SHOTS"] ?? "").isEmpty == false else {
            throw XCTSkip("设置 UTERM_STYLE_SHOTS=1 才拍")
        }
        func png(_ size: CGSize, _ color: NSColor) -> Data {
            let image = NSImage(size: size, flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            return rep.representation(using: .png, properties: [:])!
        }
        let images: [String: Data] = [
            "img/a.png": png(CGSize(width: 90, height: 20), .systemGreen),
            "img/b.png": png(CGSize(width: 110, height: 20), .systemOrange),
            "img/chart.png": png(CGSize(width: 900, height: 500), .systemBlue),
            "img/wide.png": png(CGSize(width: 1200, height: 300), .systemPink),
        ]
        let document = Document(parsing: """
        # Plan

        Badges: [![build](img/a.png)](https://ci.example/run) [![license](img/b.png)](LICENSE) and some text after them.

        The chart below ![chart](img/chart.png) shows the trend, and this sentence continues after it.

        Two side by side: ![w1](img/wide.png) ![w2](img/chart.png)

        Missing one ![gone](img/missing.png) stays as alt text.
        """)
        let loader: MarkdownImageLoader = { source in
            guard let data = images[source] else { throw CocoaError(.fileNoSuchFile) }
            return data
        }
        let size = NSSize(width: 640, height: 900)
        let host = NSHostingView(rootView: ScrollView {
            MarkdownBlocks(document: document, style: .preview, imageLoader: loader)
                .padding(16)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], contentView: host, placement: .offScreen)
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let attachment = XCTAttachment(data: try XCTUnwrap(rep.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "md-images-mac.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
