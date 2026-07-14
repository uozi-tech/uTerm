import AppKit
import XCTest
@testable import uTerm

@MainActor
final class MarkdownImageDecoderTests: XCTestCase {
    func testSVGHTMLBlocksNetworkSubresources() {
        let svg = Data("<svg width=\"1\" height=\"1\"></svg>".utf8)
        let html = MarkdownImageDecoder.htmlForSVG(svg, size: CGSize(width: 1, height: 1))

        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("img-src data:"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
    }

    func testSVGBadgeRendersTextLayer() async throws {
        let decoded = await MarkdownImageDecoder.decode(Data(Self.badgeSVG.utf8))
        let image = try XCTUnwrap(decoded)
        let bitmap = try XCTUnwrap(Self.bitmap(from: image))

        XCTAssertGreaterThan(Self.brightPixelCount(in: bitmap, x: 22..<52, y: 5..<16), 15)
        XCTAssertGreaterThan(Self.brightPixelCount(in: bitmap, x: 60..<100, y: 5..<16), 25)
    }

    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        let width = max(1, Int(image.size.width.rounded()))
        let height = max(1, Int(image.size.height.rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width,
                                         pixelsHigh: height,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bitmapFormat: [.alphaFirst],
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func brightPixelCount(in bitmap: NSBitmapImageRep,
                                         x xRange: Range<Int>,
                                         y yRange: Range<Int>) -> Int {
        var count = 0
        for x in xRange where x >= 0 && x < bitmap.pixelsWide {
            for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.5,
                   color.redComponent > 0.75,
                   color.greenComponent > 0.75,
                   color.blueComponent > 0.75 {
                    count += 1
                }
            }
        }
        return count
    }

    private static let badgeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="105" height="20">
      <defs>
        <linearGradient id="workflow-fill" x1="50%" y1="0%" x2="50%" y2="100%">
          <stop stop-color="#444D56" offset="0%"></stop>
          <stop stop-color="#24292E" offset="100%"></stop>
        </linearGradient>
        <linearGradient id="state-fill" x1="50%" y1="0%" x2="50%" y2="100%">
          <stop stop-color="#34D058" offset="0%"></stop>
          <stop stop-color="#28A745" offset="100%"></stop>
        </linearGradient>
      </defs>
      <g fill="none" fill-rule="evenodd">
        <g font-family="Verdana,Geneva,sans-serif" font-size="11">
          <path d="M0,3 C0,1.3431 1.3552,0 3.02702703,0 L55,0 L55,20 L3.02702703,20 C1.3552,20 0,18.6569 0,17 L0,3 Z" fill="url(#workflow-fill)" fill-rule="nonzero"></path>
          <text fill="#FFFFFF"><tspan x="22.1981982" y="14">Build</tspan></text>
        </g>
        <g transform="translate(55)" font-family="Verdana,Geneva,sans-serif" font-size="11">
          <path d="M0 0h46.939C48.629 0 50 1.343 50 3v14c0 1.657-1.37 3-3.061 3H0V0z" fill="url(#state-fill)" fill-rule="nonzero"></path>
          <text fill="#FFFFFF"><tspan x="4" y="14">passing</tspan></text>
        </g>
      </g>
    </svg>
    """
}
