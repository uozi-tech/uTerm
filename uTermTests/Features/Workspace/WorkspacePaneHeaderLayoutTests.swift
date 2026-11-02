import AppKit
import SwiftUI
import UDesignKit
import UPaneGroups
import UniformTypeIdentifiers
import XCTest
@testable import uTerm

/// 工作区主卡里三栏的头（文件树头 / 预览·终端标签条 / Agent 头）。
///
/// 分区方案 v3.3：三栏并进同一张内容卡、同为卡面色，栏头同高 40，底部各画一条 1pt
/// `UD.border`。v3.2 曾去掉这条线，用户实测反馈「缺分割线」后加回。这里钉的契约：高度 40，
/// 三栏「头 → 正文」竖向采样都有一条横线，且三条落在同一像素行上（连成一条）。
@MainActor
final class WorkspacePaneHeaderLayoutTests: XCTestCase {
    func testPaneHeadersShareCardHeightAndOneContinuousSeparator() throws {
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
                        showsActiveGroupRing: false,
                        descriptor: { UPaneTabDescriptor(title: $0.payload, icon: .system("doc")) },
                        content: { _, _ in Color.clear },
                        emptyGroup: { _ in Color.clear },
                        onRequestClose: { _ in })
                        .uPaneGroupStyle(.cardDivided)
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
                var lineRows: [Int] = []
                for x in xs {
                    let rows = Array(Int(30 * scale)..<Int(44 * scale))
                    let reds = try rows.map { y in
                        try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: y)?
                            .usingColorSpace(.deviceRGB)).redComponent
                    }
                    let spread = try XCTUnwrap(reds.max()) - XCTUnwrap(reds.min())
                    XCTAssertGreaterThan(spread, 0.02,
                                         "x=\(x) dark=\(dark)：头与正文之间应有一条分隔线")
                    // 线的颜色离卡面最远：日间比卡面暗、暗夜比卡面亮。
                    let target = dark ? try XCTUnwrap(reds.max()) : try XCTUnwrap(reds.min())
                    lineRows.append(rows[try XCTUnwrap(reds.firstIndex(of: target))])
                }
                XCTAssertEqual(Set(lineRows).count, 1,
                               "dark=\(dark)：三栏的头部底线应落在同一像素行，实际 \(lineRows)")
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "pane-headers-\(dark ? "dark" : "light")-\(Int(columnWidth))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
