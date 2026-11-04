import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 欢迎窗口的内容要装得进窗口：SwiftUI 放不下时把内容上下对称地溢出，标题栏会被顶出窗口上沿，
/// 红绿灯却还在原位。
@MainActor
final class WelcomeWindowLayoutTests: XCTestCase {

    /// `WelcomeView` 的 `.frame(minHeight:)`。
    private let minimumWindowHeight: CGFloat = 480

    private func height<V: View>(of view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    /// 第一次打开、还没有主机时走空态，这是每个新用户看到的第一屏。
    func testEmptyStateFitsMinimumWindow() {
        let chrome = height(of: WelcomeTitleBar())
            + height(of: WelcomeToolbar(query: .constant(""), onNewServer: {}))
        let empty = height(of: EmptyServersState(onNewServer: {}))

        XCTAssertLessThanOrEqual(chrome + empty, minimumWindowHeight,
                                 "标题栏 + 工具栏 \(chrome)，空态 \(empty)")
    }
}
