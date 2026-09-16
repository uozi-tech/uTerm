import AppKit
import SwiftUI
import UDesignKit
import UPaneGroups
import UniformTypeIdentifiers
import XCTest
@testable import uTerm

@MainActor
final class WorkspacePaneHeaderLayoutTests: XCTestCase {
    func testRenderedSeparatorsAlignWithPaneGroupStrip() throws {
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
                        .frame(width: 480)
                    VStack(spacing: 0) {
                        agentHeader
                        Color.clear
                    }.frame(width: columnWidth)
                }
                .frame(width: columnWidth * 2 + 480, height: 120)
                .background(UD.bg)
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
                let xs = [columnWidth / 2, columnWidth + 240, columnWidth + 480 + columnWidth / 2]
                // Sample both sides of the seam as well as the line itself. uAppKit 1.4.10 moved
                // UPaneGroupArea's separator from below stripHeight (y=36) to inside it (y=35);
                // the side headers must follow or the seams drift 1pt apart again.
                let lineRows = try xs.map { x -> [Int] in
                    let samples = try (Int(34 * scale)..<Int(39 * scale)).map { y in
                        let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: y)?
                            .usingColorSpace(.deviceRGB))
                        return (y, color.redComponent)
                    }
                    let extreme = try XCTUnwrap(dark
                        ? samples.map(\.1).max() : samples.map(\.1).min())
                    XCTAssertGreaterThan(try XCTUnwrap(samples.map(\.1).max())
                        - XCTUnwrap(samples.map(\.1).min()), 0.02,
                        "The fixture must actually render a separator")
                    return samples.filter { abs($0.1 - extreme) < 0.001 }.map(\.0)
                }
                XCTAssertEqual(lineRows[0], lineRows[1], "File/preview seam, dark=\(dark)")
                XCTAssertEqual(lineRows[2], lineRows[1], "Agent/preview seam, dark=\(dark)")
                XCTAssertEqual(lineRows[1], Array(Int(35 * scale)..<Int(36 * scale)))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "pane-headers-\(dark ? "dark" : "light")-\(Int(columnWidth))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
