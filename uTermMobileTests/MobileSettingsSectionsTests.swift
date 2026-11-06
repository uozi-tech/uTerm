import XCTest
@testable import uTermMobile

/// iOS 设置根页的分区组装与「连接」页的预设档（纯数据，不建界面）。
@MainActor
final class MobileSettingsSectionsTests: XCTestCase {
    /// iOS 可用的每个分区在根页恰好出现一次，mac 专属的分区不出现。
    func testRootPageAssemblesEveryIOSSectionOnce() {
        let order = SettingsScreen.sectionOrder
        XCTAssertEqual(Set(order).count, order.count, "根页有重复分区：\(order)")
        let expected = SettingsSection.allCases.filter { $0.availability.includes(.iOS) }
        XCTAssertEqual(Set(order), Set(expected))
        XCTAssertFalse(order.contains(.general))
        XCTAssertFalse(order.contains(.cli))
        XCTAssertEqual(order.last, .about, "「关于」排在最后（版权之前）")
    }

    /// 预设档必须包含同步清单里的默认值，否则缺键时菜单显示的是一个选不回来的值。
    func testConnectionPresetsIncludeDefaults() {
        XCTAssertTrue(ConnectionPresentation.timeoutOptions.contains(30))
        XCTAssertEqual(ConnectionPresentation.defaultTimeout, 30)
        XCTAssertTrue(SSHHostKeyPolicy.allCases.contains(.ask))
        XCTAssertTrue(ConnectionPresentation.sftpConcurrencyOptions.contains(4))
        XCTAssertEqual(ConnectionPresentation.defaultSFTPConcurrency, 4)
    }

    /// 预设档升序、无重复（菜单按这个顺序列）。
    func testConnectionPresetsAreSortedAndUnique() {
        for options in [ConnectionPresentation.timeoutOptions, ConnectionPresentation.sftpConcurrencyOptions] {
            XCTAssertEqual(options, options.sorted())
            XCTAssertEqual(Set(options).count, options.count)
        }
    }

    func testNonPresetValuesStillGetALabel() {
        XCTAssertEqual(ConnectionPresentation.timeoutLabel(45), "45 秒")
        XCTAssertEqual(ConnectionPresentation.sftpConcurrencyLabel(64), "64 个")
        XCTAssertEqual(ChatRetentionPresentation.label(for: 7), "7 天")
    }
}
