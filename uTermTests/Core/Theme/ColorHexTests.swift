import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class ColorHexTests: XCTestCase {

    /// 把 SwiftUI.Color 转成 sRGB 三通道 0...1 浮点。
    /// NSColor(Color) 直接走是 catalog 色空间，需要先转 sRGB 再取分量。
    private func srgb(_ color: Color) -> (Double, Double, Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    func test_hex_pureBlack() {
        let (r, g, b) = srgb(Color(hex: 0x000000))
        XCTAssertEqual(r, 0.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
    }

    func test_hex_pureWhite() {
        let (r, g, b) = srgb(Color(hex: 0xFFFFFF))
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 1.0, accuracy: 0.01)
        XCTAssertEqual(b, 1.0, accuracy: 0.01)
    }

    func test_hex_termiusBase() {
        // #1B1D23 = (27, 29, 35)
        let (r, g, b) = srgb(Color(hex: 0x1B1D23))
        XCTAssertEqual(r, 27.0/255.0, accuracy: 0.01)
        XCTAssertEqual(g, 29.0/255.0, accuracy: 0.01)
        XCTAssertEqual(b, 35.0/255.0, accuracy: 0.01)
    }

    func test_alpha_default() {
        let ns = NSColor(Color(hex: 0x000000)).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(ns.alphaComponent), 1.0, accuracy: 0.001)
    }

    func test_alpha_custom() {
        let ns = NSColor(Color(hex: 0x000000, alpha: 0.5)).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(ns.alphaComponent), 0.5, accuracy: 0.001)
    }
}
