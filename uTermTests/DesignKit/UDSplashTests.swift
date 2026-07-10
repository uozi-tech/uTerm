import XCTest
@testable import uTerm

final class UDSplashTests: XCTestCase {
    /// 星点表直接搬运自设计稿 `splash.jsx` 的 `SPLASH_STARS`：26 颗、坐标百分比、
    /// 透明度合法——确定性坐标保证开屏画面稳定可截图。
    func test_star_field_matches_design_and_stays_in_bounds() {
        let stars = UDNebulaField.stars
        XCTAssertEqual(stars.count, 26)
        for s in stars {
            XCTAssertTrue((0...100).contains(s.x), "x 超出百分比范围: \(s)")
            XCTAssertTrue((0...100).contains(s.y), "y 超出百分比范围: \(s)")
            XCTAssertGreaterThan(s.r, 0)
            XCTAssertTrue((0...1).contains(s.o), "不透明度非法: \(s)")
        }
    }

    /// 「星空之上」（v2 定稿，唯一保留方向）的尺寸档对齐设计稿：
    /// compact（iPhone）/ big（iPad）。
    func test_size_ladder_matches_design() {
        XCTAssertEqual(UDSplashNebula(big: false).logoSize, 104)
        XCTAssertEqual(UDSplashNebula(big: false).wordSize, 46)
        XCTAssertEqual(UDSplashNebula(big: true).logoSize, 132)
        XCTAssertEqual(UDSplashNebula(big: true).wordSize, 58)
    }
}
