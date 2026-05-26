import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class ColorAdaptiveTests: XCTestCase {

    /// 在 aqua appearance 下 resolve 应得 light hex (0xFFFFFF = white)。
    func test_adaptive_aqua_returns_light_hex() {
        let color = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
        let ns = NSColor(color)
        let aqua = NSAppearance(named: .aqua)!
        var resolvedAqua: NSColor!
        aqua.performAsCurrentDrawingAppearance {
            resolvedAqua = ns.usingColorSpace(.sRGB)
        }
        XCTAssertNotNil(resolvedAqua)
        XCTAssertEqual(resolvedAqua.redComponent,   1.0, accuracy: 0.01)
        XCTAssertEqual(resolvedAqua.greenComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(resolvedAqua.blueComponent,  1.0, accuracy: 0.01)
    }

    /// 在 darkAqua appearance 下 resolve 应得 dark hex (0x000000 = black)。
    func test_adaptive_darkAqua_returns_dark_hex() {
        let color = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
        let ns = NSColor(color)
        let darkAqua = NSAppearance(named: .darkAqua)!
        var resolvedDark: NSColor!
        darkAqua.performAsCurrentDrawingAppearance {
            resolvedDark = ns.usingColorSpace(.sRGB)
        }
        XCTAssertNotNil(resolvedDark)
        XCTAssertEqual(resolvedDark.redComponent,   0.0, accuracy: 0.01)
        XCTAssertEqual(resolvedDark.greenComponent, 0.0, accuracy: 0.01)
        XCTAssertEqual(resolvedDark.blueComponent,  0.0, accuracy: 0.01)
    }

    /// 验证 light hex 解码正确（0xFF0000 = pure red）。
    func test_adaptive_decodes_hex_components_correctly() {
        let color = Color.adaptive(light: 0xFF0000, dark: 0x00FF00)
        let ns = NSColor(color)
        let aqua = NSAppearance(named: .aqua)!
        var resolved: NSColor!
        aqua.performAsCurrentDrawingAppearance {
            resolved = ns.usingColorSpace(.sRGB)
        }
        XCTAssertEqual(resolved.redComponent,   1.0, accuracy: 0.01)
        XCTAssertEqual(resolved.greenComponent, 0.0, accuracy: 0.01)
        XCTAssertEqual(resolved.blueComponent,  0.0, accuracy: 0.01)
    }
}
