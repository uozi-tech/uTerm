import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 键盘条与底部安全区。2026-11-26 试过让键盘条伸进 Home 条那一截、列表滚进底部安全区（8dae154b / d6ea18eb），
/// 真机上键盘弹起时键盘条躲到键盘后面、整个 App 点不动滚不动，已整个撤回；这里留下当时的两条回归。
@MainActor
final class MBottomSafeAreaTests: XCTestCase {
    /// 键盘条最下面那一行的下沿离窗口底边多远。
    private final class Probe {
        var rowFrame: CGRect = .zero
    }

    private struct KeyBarHarness: View {
        let probe: Probe
        /// 键盘条上面放一个输入框，用来弹真的系统键盘。
        var field: Binding<Bool>?

        var body: some View {
            VStack(spacing: 0) {
                if let field {
                    FocusField(focused: field)
                }
                Color.blue
                MKeyBar(panel: .constant(Int?.none), softKeyboardUp: .constant(false)) {
                    Color.red
                        .frame(width: MKeyCapMetrics.minWidth,
                               height: MKeyCapMetrics.height + 2 * MKeyCapMetrics.verticalHitInset)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.rowFrame = $0 }
                } row: {
                    Color.green.frame(width: 40, height: MKeyCapMetrics.height)
                } trailing: {
                    Color.green.frame(width: 40, height: MKeyCapMetrics.height)
                } content: { _ in
                    EmptyView()
                }
            }
        }
    }

    private struct FocusField: View {
        @Binding var focused: Bool
        @FocusState private var focus: Bool
        @State private var text = ""

        var body: some View {
            TextField("", text: $text)
                .focused($focus)
                .frame(height: 44)
                .onChange(of: focused, initial: true) { _, value in focus = value }
        }
    }

    /// 真弹系统键盘：键盘条整个在键盘上面（实机反馈：键盘弹起时键盘条躲到了键盘后面）。
    /// 模拟器接着硬件键盘时不弹，跳过（到真机上跑）。
    func testKeyBarStaysAboveTheSoftwareKeyboard() async throws {
        defer { MobileProbeWindow.closeAll() }
        final class KeyboardBox: @unchecked Sendable { var frame: CGRect = .zero }
        let keyboard = KeyboardBox()
        let observer = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            keyboard.frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let probe = Probe()
        var focused = false
        let binding = Binding(get: { focused }, set: { focused = $0 })
        let (window, hosting) = MobileProbeWindow.make(placement: .visibleOnScreen, isolateHost: true,
                                                       rootView: KeyBarHarness(probe: probe, field: binding))
        hosting.safeAreaRegions = .all
        try await Task.sleep(for: .milliseconds(400))
        hosting.rootView = KeyBarHarness(probe: probe, field: .constant(true))
        for _ in 0..<30 where keyboard.frame.height == 0 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(900))
        let covered = keyboard.frame.intersection(window.screen.bounds)
        guard covered.height > 120 else { throw XCTSkip("没弹软键盘（模拟器接着硬件键盘）：到真机上跑") }
        let row = window.convert(probe.rowFrame, from: nil)
        print("KEYBAR-KEYBOARD keyboard=\(covered) row=\(row)")
        XCTAssertLessThanOrEqual(row.maxY, window.convert(covered, from: nil).minY + 0.5, "键盘条被键盘挡住了")
    }

    // MARK: - 命中区

    /// 实机事故：命中区换成上下伸出去 1 万点的形状（当时的 `contentShape(MHorizontalClip())`）后，标签条、键盘条这类
    /// 横向滚动区接住了整屏上下所有的触摸，App 点不动、滚不动。
    ///
    /// 测试宿主里合成的触摸到不了 SwiftUI 的手势（全屏一个 `onTapGesture` 都不响应），UIKit 的 `hitTest` 又看不到
    /// SwiftUI 按命中形状分手势，所以这里守的是写法：别再用那种形状当命中区。
    func testNoOversizedHitShape() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uTermMobile")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//")[0]
                if code.contains("contentShape(MHorizontalClip") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "没扫到源码，路径可能不对：\(root.path)")
        XCTAssertEqual(offenders, [], "MHorizontalClip 上下伸出去 1 万点，拿它当命中区会吃掉整屏的触摸")
    }
}
