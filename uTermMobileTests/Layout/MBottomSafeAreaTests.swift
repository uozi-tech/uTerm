import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 底部安全区（Home 条那一截）不再整段空着（实机反馈：Duo 横握时 Code 标签页键盘条下面、会话列表下面
/// 各空出 34pt 一条）。
///
/// - 键盘条只在键帽下面留出够 Home 条用的一点，其余还给正文；
/// - 竖向列表照常滚进底部安全区（系统列表的样子），侧边那一列（Duo 的状态栏列）仍然裁掉。
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

    private func keyBarBottomGap(bottomInset: CGFloat) async throws -> CGFloat {
        defer { MobileProbeWindow.closeAll() }
        let probe = Probe()
        let size = CGSize(width: 600, height: 400)
        let (window, hosting) = MobileProbeWindow.make(
            size: size, placement: .visibleOnScreen, isolateHost: true,
            rootView: KeyBarHarness(probe: probe))
        hosting.safeAreaRegions = .container
        hosting.additionalSafeAreaInsets.bottom = bottomInset - window.safeAreaInsets.bottom
        hosting.view.setNeedsLayout()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(hosting.view.safeAreaInsets.bottom, bottomInset, accuracy: 0.5, "没设上底部安全区")
        XCTAssertGreaterThan(probe.rowFrame.height, 0, "没量到键盘条")
        return size.height - probe.rowFrame.maxY
    }

    func testKeyBarReclaimsMostOfTheHomeIndicatorInset() async throws {
        let gap = try await keyBarBottomGap(bottomInset: 34)
        XCTAssertEqual(gap, MKeyBarBottomInset.kept, accuracy: 0.5,
                       "键盘条下面只留 \(MKeyBarBottomInset.kept)pt，实际 \(gap)pt")
    }

    func testKeyBarKeepsTheSmallerInsetAsIs() async throws {
        let gap = try await keyBarBottomGap(bottomInset: 6)
        XCTAssertEqual(gap, 6, accuracy: 0.5, "安全区比要留的还小时照安全区留")
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
        let restingGap = window.bounds.height - probe.rowFrame.maxY
        XCTAssertLessThan(restingGap, max(window.safeAreaInsets.bottom, MKeyBarBottomInset.kept) + 0.5,
                          "没键盘时照常往 Home 条那一截伸")
        hosting.rootView = KeyBarHarness(probe: probe, field: .constant(true))
        for _ in 0..<30 where keyboard.frame.height == 0 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(900))
        let covered = keyboard.frame.intersection(window.screen.bounds)
        guard covered.height > 120 else { throw XCTSkip("没弹软键盘（模拟器接着硬件键盘）：到真机上跑") }
        let row = window.convert(probe.rowFrame, from: nil)
        print("KEYBAR-KEYBOARD keyboard=\(covered) row=\(row)")
        XCTAssertLessThanOrEqual(row.maxY, window.convert(covered, from: nil).minY + 0.5, "键盘条被键盘挡住了")
    }

    func testReclaimRule() {
        func reclaimed(_ bottom: CGFloat, container: CGFloat? = nil) -> CGFloat {
            MKeyBarBottomInset.reclaimed(safeAreaBottom: bottom, containerBottom: container ?? bottom)
        }
        XCTAssertEqual(reclaimed(0), 0)
        XCTAssertEqual(reclaimed(34), 34 - MKeyBarBottomInset.kept)
        XCTAssertEqual(reclaimed(21), 21 - MKeyBarBottomInset.kept)
        XCTAssertEqual(reclaimed(4), 0)
        XCTAssertEqual(reclaimed(336, container: 34), 0, "软键盘弹着：不往键盘里伸")
        XCTAssertEqual(reclaimed(55, container: 34), 0, "外接键盘的快捷栏在下面：同样不伸")
    }

    // MARK: - 命中区

    /// 实机事故：命中区也换成上下伸出去的形状（`contentShape(MHorizontalClip())`）后，标签条、键盘条这类横向滚动区
    /// 接住了整屏上下所有的触摸，App 点不动、滚不动。
    ///
    /// 测试宿主里合成的触摸到不了 SwiftUI 的手势（全屏一个 `onTapGesture` 都不响应），UIKit 的 `hitTest` 又看不到
    /// SwiftUI 按命中形状分手势，所以这里守的是写法：`MHorizontalClip` 只许拿来裁画面。
    func testHorizontalClipIsNeverUsedAsHitShape() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uTermMobile")
        // 真机上读不到 Mac 上的源码目录（#filePath 是编译时的路径）：在模拟器上守。
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("读不到源码目录（真机上跑）") }
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

    // MARK: - 竖向列表

    private struct ListHarness: View {
        var body: some View {
            ZStack {
                Color.white.ignoresSafeArea()
                ScrollView {
                    Color.red.frame(height: 3000)
                }
                .mKeepsScrollContentInSafeArea()
            }
        }
    }

    func testVerticalListScrollsIntoBottomInsetButStaysOutOfSideColumn() async throws {
        defer { MobileProbeWindow.closeAll() }
        let size = CGSize(width: 600, height: 400)
        let (window, hosting) = MobileProbeWindow.make(size: size, placement: .visibleOnScreen, isolateHost: true,
                                                       rootView: ListHarness())
        hosting.safeAreaRegions = .container
        hosting.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0,
                                                        bottom: 34 - window.safeAreaInsets.bottom,
                                                        right: 60 - window.safeAreaInsets.right)
        hosting.view.setNeedsLayout()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let insets = hosting.view.safeAreaInsets
        XCTAssertEqual(insets.bottom, 34, accuracy: 0.5)
        XCTAssertEqual(insets.right, 60, accuracy: 0.5)

        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let homeStrip = try XCTUnwrap(redness(of: image, at: CGPoint(x: size.width / 3, y: size.height - 17)))
        let sideColumn = try XCTUnwrap(redness(of: image, at: CGPoint(x: size.width - 30, y: size.height / 2)))
        let body = try XCTUnwrap(redness(of: image, at: CGPoint(x: size.width / 3, y: size.height / 2)))
        XCTAssertTrue(body, "正文里该是列表内容")
        XCTAssertTrue(homeStrip, "列表内容该滚进底部安全区，不是空一条")
        XCTAssertFalse(sideColumn, "侧边那一列（Duo 的状态栏列）仍要裁掉")
    }

    /// 这一点是不是红的（列表内容）。
    private func redness(of image: UIImage, at point: CGPoint) -> Bool? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = Int(point.x * CGFloat(cgImage.width) / image.size.width)
        let y = Int(point.y * CGFloat(cgImage.height) / image.size.height)
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return pixel[0] > 200 && pixel[1] < 80 && pixel[2] < 80
    }
}
