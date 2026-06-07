import XCTest
import AppKit
@testable import uTerm

final class ULogoTests: XCTestCase {
    func test_default_size_is_32() {
        let logo = ULogo()
        XCTAssertEqual(logo.size, 32)
    }

    func test_custom_size_propagates() {
        for s: CGFloat in [16, 32, 64, 96, 256] {
            XCTAssertEqual(ULogo(size: s).size, s)
        }
    }

    func test_asset_exists_in_main_bundle() {
        let img = NSImage(named: "ULogoMark")
        XCTAssertNotNil(img, "ULogoMark imageset 必须在 main bundle 内（asset catalog 加入构建）")
    }
}
