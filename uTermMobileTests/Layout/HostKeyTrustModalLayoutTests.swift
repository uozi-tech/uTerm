import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 主机密钥信任弹层（含「连接方式变弱了」那一问）的排版。
@MainActor
final class HostKeyTrustModalLayoutTests: XCTestCase {
    private var challenges: [(String, HostKeyChallenge)] {
        [
            ("unknown", HostKeyChallenge(host: "10.31.0.102", port: 2298, kind: .unknown,
                                         newFingerprint: "SHA256:mEB3wv/XmQal9WkPq2dlrDafyp7SH1UsbSMRT34",
                                         oldFingerprint: nil)),
            ("mismatch", HostKeyChallenge(host: "10.31.0.102", port: 2298, kind: .mismatch,
                                          newFingerprint: "SHA256:mEB3wv/XmQal9WkPq2dlrDafyp7SH1UsbSMRT34",
                                          oldFingerprint: "SHA256:jv9/36tlLmpA62xYzJHNscJ0h9Cn8pdWGGJF1k")),
            ("weak", HostKeyChallenge(host: "10.31.0.102", port: 2298, kind: .weakAlgorithms,
                                      newFingerprint: "", oldFingerprint: nil)),
        ]
    }

    private func modal(_ challenge: HostKeyChallenge, width: CGFloat) -> some View {
        MCenterModalContainer(width: width) {
            HostKeyTrustModal(challenge: challenge, onCancel: {}, onTrust: {})
        }
        .frame(width: width + 44)
        .environment(\.mAccent, M.accent)
    }

    /// 窄屏上提示框的字会折成多行：弹层要按折行后的高度长高，不能把字挤出框底。
    func test_modal_grows_with_wrapped_banner_text() {
        for (name, challenge) in challenges where name != "unknown" {
            let wide = UIHostingController(rootView: modal(challenge, width: 400))
                .sizeThatFits(in: CGSize(width: 444, height: 2000)).height
            let narrow = UIHostingController(rootView: modal(challenge, width: 300))
                .sizeThatFits(in: CGSize(width: 344, height: 2000)).height
            XCTAssertGreaterThan(narrow, wide, "\(name)：窄了以后文字多折几行，弹层应更高")
        }
    }

    /// 高度不够（终端的键盘弹着、横屏、分屏的矮格子）时卡片改成可滚动，不再超出给它的高度——
    /// 以前是外面的高度把提示框的字挤扁、溢出框底，按钮也可能被顶到键盘后面。
    func test_modal_stays_within_short_height() {
        for (name, challenge) in challenges {
            let natural = UIHostingController(rootView: modal(challenge, width: 360))
                .sizeThatFits(in: CGSize(width: 404, height: 2000)).height
            let short = natural * 0.6
            let fitted = UIHostingController(rootView: modal(challenge, width: 360))
                .sizeThatFits(in: CGSize(width: 404, height: short)).height
            XCTAssertLessThanOrEqual(fitted, short + 0.5, "\(name)：放不下时不应超出给的高度")
        }
    }

    /// 截图给人看（按需）：`TEST_RUNNER_UTERM_STYLE_SHOTS_DIR=/path`。
    func test_snapshot() throws {
        let dir = try Self.shotsDirectory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, challenge) in challenges {
            for scheme in [ColorScheme.light, .dark] {
                let view = modal(challenge, width: 360)
                    .background(M.bg)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let data = try XCTUnwrap(renderer.uiImage?.pngData())
                let file = "host-key-\(name)-\(scheme == .dark ? "dark" : "light").png"
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            }
        }
    }

    /// 真窗口里的样子（按需）：同 `MobileRootView` 的背板 + 卡片。竖屏 iPhone 整屏、竖屏弹着键盘（底下 336pt
    /// 被键盘大小的一块占掉，同根视图的 overlay 只拿到上面那截），横屏弹着键盘（放不下，截滚动起点和滚到底），
    /// 以及本机屏幕原尺寸（真机上跑看实际设备）。
    func test_on_screen_snapshot() async throws {
        let dir = try Self.shotsDirectory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { MobileProbeWindow.closeAll() }
        let cases: [(tag: String, size: CGSize?, keyboard: CGFloat, scrolls: Bool?)] = [
            ("device", nil, 0, nil),
            ("full", CGSize(width: 393, height: 852), 0, false),
            ("keyboard", CGSize(width: 393, height: 852), 336, false),
            ("landscape-keyboard", CGSize(width: 852, height: 393), 170, true),
        ]
        for (name, challenge) in challenges where name != "unknown" {
            for (tag, size, keyboard, scrolls) in cases {
                let root = VStack(spacing: 0) {
                    ZStack {
                        M.backdrop
                        MCenterModalContainer(width: 400) {
                            HostKeyTrustModal(challenge: challenge, onCancel: {}, onTrust: {})
                        }
                    }
                    if keyboard > 0 { Color.gray.opacity(0.5).frame(height: keyboard) }
                }
                .background(M.bg)
                .environment(\.mAccent, M.accent)
                let (window, host) = MobileProbeWindow.make(size: size, placement: .visibleOnScreen, rootView: root)
                defer { MobileProbeWindow.close(window) }
                for _ in 0..<6 {
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(80))
                }
                try write(host.view, to: dir, "host-key-onscreen-\(name)-\(tag).png")
                if scrolls == true {
                    let scroll = try XCTUnwrap(Self.scrollView(in: host.view), "\(name)：矮了应变成可滚动")
                    let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
                    XCTAssertGreaterThan(bottom, 0)
                    scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    try await Task.sleep(for: .milliseconds(120))
                    try write(host.view, to: dir, "host-key-onscreen-\(name)-\(tag)-end.png")
                } else if scrolls == false {
                    XCTAssertNil(Self.scrollView(in: host.view), "\(name)：放得下时不该套滚动")
                }
            }
        }
    }

    /// 截图目录：`UTERM_STYLE_SHOTS_DIR`，没设就跳过；写相对路径时落在本进程的临时目录（真机上用，图另挂成附件）。
    private static func shotsDirectory() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_STYLE_SHOTS_DIR")
        }
        return dir.hasPrefix("/") ? dir : (NSTemporaryDirectory() as NSString).appendingPathComponent(dir)
    }

    private func write(_ view: UIView, to dir: String, _ file: String) throws {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }
}
