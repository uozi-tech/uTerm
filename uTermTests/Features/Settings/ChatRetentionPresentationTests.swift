import XCTest
@testable import uTerm

final class ChatRetentionPresentationTests: XCTestCase {
    func testOptionsIncludeDefaultAndNeverClean() {
        let days = ChatRetentionPresentation.options.map(\.days)
        XCTAssertEqual(days, [0, 30, 90, 180, 365])
        XCTAssertTrue(days.contains(ChatHistoryStore.defaultRetentionDays), "默认值必须是一个预设档")
    }

    func testLabels() {
        XCTAssertEqual(ChatRetentionPresentation.label(for: 0), "不清理")
        XCTAssertEqual(ChatRetentionPresentation.label(for: 180), "180 天")
        XCTAssertEqual(ChatRetentionPresentation.label(for: 45), "45 天", "不在预设里的值（mac 上填的）照样显示")
    }

    func testFootersShareWordingWithPlatformVariants() {
        let base = "超过该天数未更新的 AI 对话会在启动时清理，连同其中的消息。"
        XCTAssertEqual(ChatRetentionPresentation.footer(for: 30, platform: .iOS), base + "该设置与 Mac 同步。")
        XCTAssertEqual(ChatRetentionPresentation.footer(for: 30, platform: .macOS), base + "快捷命令的执行日志固定保留 30 天。")
        XCTAssertTrue(ChatRetentionPresentation.footer(for: 0, platform: .iOS).contains("不清理"))
        XCTAssertTrue(ChatRetentionPresentation.footer(for: 0, platform: .macOS).contains("填 0 表示不清理"))
    }
}
