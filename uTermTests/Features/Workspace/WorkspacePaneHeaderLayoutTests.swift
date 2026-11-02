import AppKit
import SwiftUI
import UDesignKit
import UPaneGroups
import UniformTypeIdentifiers
import XCTest
@testable import uTerm

/// 工作区主卡里三栏的头（文件树头 / 预览·终端标签条 / Agent 头）。
///
/// 改前（v2）钉的是「三条 1pt 底部分隔线落在同一条基线 y=35」。分区方案 v3.2 把三栏并进
/// 同一张内容卡、同为卡面色，栏头**不再画底部分隔线**（头与正文靠位置分区），而且三者同高
/// 40、横向对齐。于是这里改钉新契约：高度 40，且头与正文之间一条横线都没有 —— 采样列从
/// 头一路扫到正文，颜色必须是同一个卡面色。
@MainActor
final class WorkspacePaneHeaderLayoutTests: XCTestCase {
    func testPaneHeadersShareCardHeightWithoutSeparators() throws {
        XCTAssertEqual(WorkspacePaneHeaderLayout.height, 40)
        XCTAssertEqual(AssistantHeaderLayout.height, WorkspacePaneHeaderLayout.height)

        for dark in [false, true] {
            for columnWidth in [240.0, 320.0] {
                let panes = UPaneGroupsModel<String>()
                let fileBrowser = FileBrowserContent(model: FileBrowserModel())
                let agentHeader = AssistantView(
                    serverContext: "", model: AssistantModel(),
                    activeProviderIDString: .constant("")).header
                let view = HStack(spacing: 0) {
                    fileBrowser.frame(width: columnWidth)
                    UPaneGroupArea(
                        model: panes, dragType: .plainText,
                        stripHeight: WorkspacePaneHeaderLayout.height,
                        showsActiveGroupRing: true,
                        descriptor: { UPaneTabDescriptor(title: $0.payload, icon: .system("doc")) },
                        content: { _, _ in Color.clear },
                        emptyGroup: { _ in Color.clear },
                        onRequestClose: { _ in })
                        .uPaneGroupStyle(.card)
                        .uPaneGroupWells()
                        .frame(width: 480)
                    VStack(spacing: 0) {
                        agentHeader
                        Color.clear
                    }.frame(width: columnWidth)
                }
                .frame(width: columnWidth * 2 + 480, height: 120)
                .background(UD.panel)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: columnWidth * 2 + 480, height: 120),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil }
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()

                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
                // 文件树头的路径文字 / Agent 头的按钮都在列中段之外：取靠右的空白处采样，
                // 只看「头 → 正文」这一段竖向有没有横线。
                let xs = [columnWidth / 2, columnWidth + 240, columnWidth + 480 + columnWidth / 2]
                for x in xs {
                    let reds = try (Int(30 * scale)..<Int(48 * scale)).map { y in
                        try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: y)?
                            .usingColorSpace(.deviceRGB)).redComponent
                    }
                    let spread = try XCTUnwrap(reds.max()) - XCTUnwrap(reds.min())
                    XCTAssertLessThan(spread, 0.01,
                                      "x=\(x) dark=\(dark)：头与正文之间不该再有分隔线")
                }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "pane-headers-\(dark ? "dark" : "light")-\(Int(columnWidth))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
