import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 宽屏下「离开设备组？」的确认框是 popover：它要从触发它的那个「…」弹出，而不是屏幕正中央
/// （真机上出过：确认框挂在整页上，箭头指着页面中间）。
@MainActor
final class RemoteLeaveDialogAnchorTests: XCTestCase {
    /// 一行：左边是名字，最右边是挂着确认框的「…」，和「我的设备」里组员那一行同样的摆法。
    private struct Harness: View {
        @State private var confirming = false

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("iPhone Duo")
                    Spacer()
                    MIcon(name: "ellipsis", size: 16, color: M.text3)
                        .frame(width: 32, height: 32)
                        .modifier(LeaveGroupDialog(isPresented: $confirming) {})
                }
                .padding(.horizontal, 24)
                .frame(height: 56)
                // 和那一页一样：内容限在可读宽度里、居中，「…」不贴着屏幕边。
                .frame(maxWidth: M.readableWidth)
                .frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                confirming = true
            }
        }
    }

    func testPopoverPointsAtTheMenuButton() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (window, _) = MobileProbeWindow.make(size: CGSize(width: 1000, height: 700), placement: .visibleOnScreen,
                                                 isolateHost: true, rootView: Harness().environment(\.mAccent, M.accent))
        let controller = try XCTUnwrap(window.rootViewController)
        var dialog: UIViewController?
        for _ in 0..<50 where dialog == nil {
            try await Task.sleep(for: .milliseconds(100))
            dialog = controller.presentedViewController
        }
        let presented = try XCTUnwrap(dialog, "确认框没有弹出来")
        try await Task.sleep(for: .milliseconds(500))
        defer { presented.dismiss(animated: false) }
        // 窄屏是底部操作表，弹得出来就行；位置只在宽屏的 popover 上有意义。
        guard window.traitCollection.horizontalSizeClass == .regular else {
            print("LEAVEDIALOG 窄屏，不核对位置")
            return
        }

        let frame = presented.view.convert(presented.view.bounds, to: window)
        print("LEAVEDIALOG popover=\(frame.integral) window=\(window.bounds.size)")
        // 「…」在第一行、可读宽度的右端：popover 应当对着它（左右差不出半个 popover 的宽度）、贴着那一行，不在屏幕正中。
        let anchorX = window.bounds.midX + min(M.readableWidth, window.bounds.width) / 2 - 24 - 16
        XCTAssertGreaterThan(frame.width, 150, "popover 被挤扁了：\(frame)")
        XCTAssertLessThan(abs(frame.midX - anchorX), frame.width / 2 + 20, "popover 没对着「…」（x≈\(anchorX)）：\(frame)")
        XCTAssertLessThan(frame.minY, 120, "popover 没贴着那一行：\(frame)")
    }
}
