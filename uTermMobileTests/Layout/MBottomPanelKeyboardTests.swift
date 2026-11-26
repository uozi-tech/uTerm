import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 底部面板弹出时，底下那个视图的键盘要收起来（真机反馈：Code 标签页里终端开着键盘，点「＋」弹出新会话面板，
/// 键盘还留着、挡住面板下半截）。面板是盖在透明 `fullScreenCover` 上的，第一响应者不会因此自动换掉。
@MainActor
final class MBottomPanelKeyboardTests: XCTestCase {
    struct Token: Identifiable { let id = 1 }

    /// 代替终端：一个先成为第一响应者的输入视图。
    private struct FocusedField: UIViewRepresentable {
        let field: UITextField

        func makeUIView(context: Context) -> UITextField { field }
        func updateUIView(_ uiView: UITextField, context: Context) {}
    }

    private struct Harness: View {
        let field: UITextField
        @Binding var item: Token?

        var body: some View {
            FocusedField(field: field)
                .frame(height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mBottomPanel(item: $item) { _ in
                    Text(verbatim: "panel").frame(height: 120)
                }
        }
    }

    @Observable final class Box { var item: Token? }

    func testPresentingPanelResignsUnderlyingFirstResponder() async throws {
        defer { MobileProbeWindow.closeAll() }
        let field = UITextField()
        let box = Box()
        let (window, _) = MobileProbeWindow.make(
            placement: .visibleOnScreen, isolateHost: true,
            rootView: Harness(field: field, item: Binding(get: { box.item }, set: { box.item = $0 })))
        let controller = try XCTUnwrap(window.rootViewController)

        for _ in 0..<50 where !field.isFirstResponder {
            try await Task.sleep(for: .milliseconds(50))
            _ = field.becomeFirstResponder()
        }
        XCTAssertTrue(field.isFirstResponder, "夹具：输入框没能先拿到键盘")

        box.item = Token()
        var presented: UIViewController?
        for _ in 0..<50 where presented == nil {
            try await Task.sleep(for: .milliseconds(100))
            presented = controller.presentedViewController
        }
        let cover = try XCTUnwrap(presented, "面板没有弹出来")
        defer { cover.dismiss(animated: false) }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(field.isFirstResponder, "面板弹出后底下的输入框还拿着键盘")
    }
}
