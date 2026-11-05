import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 在 Mac 上新开终端前问开在哪：主目录 + 最近的工作区，路径缩写成 `~`，点哪个回哪个。
@MainActor
final class MacWorkspaceDialogTests: XCTestCase {
    private struct Harness: View {
        let workspaces: RemoteLocalWorkspaces
        let onPick: (String?) -> Void

        @State private var choices: RemoteLocalWorkspaces?

        var body: some View {
            Color.clear
                .macWorkspaceDialog($choices, onPick: onPick)
                .task {
                    try? await Task.sleep(for: .milliseconds(300))
                    choices = workspaces
                }
        }
    }

    func testDialogListsHomeAndRecentDirectories() async throws {
        defer { MobileProbeWindow.closeAll() }
        let workspaces = RemoteLocalWorkspaces(requestID: UUID(), home: "/Users/me",
                                               directories: ["/Users/me/Workspace/uTerm", "/opt/app"])
        let root = Harness(workspaces: workspaces, onPick: { _ in }).environment(\.mAccent, M.accent)
        let (window, _) = MobileProbeWindow.make(size: CGSize(width: 402, height: 874),
                                                 placement: .visibleOnScreen,
                                                 isolateHost: true, rootView: root)
        let controller = try XCTUnwrap(window.rootViewController)
        var dialog: UIViewController?
        for _ in 0..<50 where dialog == nil {
            try await Task.sleep(for: .milliseconds(100))
            dialog = controller.presentedViewController
        }
        let presented = try XCTUnwrap(dialog, "选择框没有弹出来")
        defer { presented.dismiss(animated: false) }
        let alert = try XCTUnwrap(presented as? UIAlertController, "\(type(of: presented))")
        XCTAssertEqual(alert.title, "在哪个目录打开？")
        XCTAssertEqual(alert.actions.map(\.title), ["主目录", "~/Workspace/uTerm", "/opt/app", "取消"])
    }
}
