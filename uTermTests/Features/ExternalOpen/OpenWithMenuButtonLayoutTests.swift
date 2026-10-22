import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 「无法预览」页里「打开 / 打开方式 / 下载…」三个按钮并排：下拉按钮必须与 `UDButton`
/// 同高（系统 `Menu` 的按钮样式按 AppKit 控件尺寸画，会矮一截）。
@MainActor
final class OpenWithMenuButtonLayoutTests: XCTestCase {
    private func fittingHeight<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testMenuButtonMatchesUDButtonHeight() {
        let udButton = fittingHeight(
            UDButton(title: RemoteFileAction.download.title, style: .secondary,
                     systemImage: RemoteFileAction.download.systemImage) {})
        let menuButton = fittingHeight(OpenWithMenuButton(path: "/srv/cert.db") { _ in })

        XCTAssertEqual(udButton, 32, accuracy: 0.5)
        XCTAssertEqual(menuButton, udButton, accuracy: 0.5)
    }
}
