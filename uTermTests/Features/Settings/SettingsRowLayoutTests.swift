import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 设置行在窄窗口里的版式：右侧是输入框时，左侧标签不能被挤没。
///
/// 实机（设置窗只剩一栏宽，「模型服务」的 Base URL / API Key 两行）：输入框带布局优先级、先撑到理想宽度，
/// 标签被挤到近乎零宽、一个字一行竖着排——行高被撑到一百多点，标签又被裁得看不见。
@MainActor
final class SettingsRowLayoutTests: XCTestCase {
    private func rowHeight(width: CGFloat, label: String, @ViewBuilder trailing: @escaping () -> some View) -> CGFloat {
        let host = NSHostingView(rootView: SettingsRow(label: label, trailing: trailing).frame(width: width))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTextFieldRowKeepsItsLabelInANarrowPane() {
        for width: CGFloat in [300, 360, 420] {
            let height = rowHeight(width: width, label: "Base URL") {
                UDTextField(placeholder: "如 https://api.openai.com", text: .constant("https://ai.example.com"))
                    .frame(minWidth: 160, maxWidth: 360)
            }
            XCTAssertLessThan(height, 60, "宽 \(width)：行被竖排的标签撑高了")
        }
    }

    func testKeyRowWithButtonKeepsItsLabelInANarrowPane() {
        let height = rowHeight(width: 360, label: "API Key") {
            HStack(spacing: 8) {
                UDTextField(placeholder: "粘贴新 Key", text: .constant(""), isSecure: true, revealable: true)
                    .frame(minWidth: 140, maxWidth: 280)
                UDButton(title: "保存", style: .primary) {}
            }
        }
        XCTAssertLessThan(height, 60, "行被竖排的标签撑高了")
    }
}
