import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 连接中页的主体（进度环 + 主机名）在各个阶段**位置不动**：连接中、等太久露出「返回」、失败（短 / 长文案）、
/// 已连接。多出来的文字往下长，不把整体顶上去。
///
/// 起因（2026-11 真机 Duo）：「连接中的居中位置发生改变」。旧排版是「顶部 chip / Spacer / 主体 / Spacer / 底部区」
/// 一列竖排，主体居中在 chip 与底部区之间：底部区（失败文案 + 两个按钮）一长高，主体就被往上推。
///
/// 量法：真窗口里挂产品的 `ConnectingCoverView`，控制器状态直接改，截图后用 OCR 找主机名的位置（不给产品开后门）。
@MainActor
final class ConnectingCoverLayoutTests: XCTestCase {
    private static let hostName = "CENTERPROBE"

    private struct Device {
        let name: String
        let size: CGSize
        var fillsScreen = true
    }

    private let devices = [
        Device(name: "duo-folded", size: CGSize(width: 466, height: 678)),
        Device(name: "duo-unfolded", size: CGSize(width: 669, height: 951)),
        Device(name: "iphone", size: CGSize(width: 393, height: 852)),
        Device(name: "duo-landscape", size: CGSize(width: 678, height: 466)),
        Device(name: "pane", size: CGSize(width: 330, height: 520), fillsScreen: false),
    ]

    private struct Mounted {
        let device: Device
        let view: UIView
        let request: MConnectRequest
        let controller: MobileTerminalController
    }

    private func mount(_ device: Device) -> Mounted {
        let host = ServerProfile()
        host.name = Self.hostName
        host.host = "10.31.0.102"
        host.port = 2298
        host.username = "dev"
        let request = MConnectRequest(host: host, kind: .terminal, origin: .hosts)
        let controller = MobileTerminalController()
        controller.state = .connecting
        request.terminal = controller
        let root = ConnectingCoverView(request: request, onFinish: {}, onCancel: {}, onRetry: {},
                                       fillsScreen: device.fillsScreen)
            .environment(\.mAccent, M.accent)
            .frame(width: device.size.width, height: device.size.height)
        let (_, hosting) = MobileProbeWindow.make(size: device.size, placement: .visibleOnScreen, rootView: root)
        hosting.view.layoutIfNeeded()
        return Mounted(device: device, view: hosting.view, request: request, controller: controller)
    }

    private func capture(_ view: UIView) -> Data {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    /// 连接中页顶上 70pt 那条里非底色像素的占比（chip 在不在顶上）。真机上探针窗口会被系统撑到整屏，
    /// 页面按给定尺寸居中摆在里面，所以那一条从页面的上沿算起。
    private func topBandInk(_ mounted: Mounted) -> Double {
        let view = mounted.view
        let top = max(0, (view.bounds.height - mounted.device.size.height) / 2)
        let left = max(0, (view.bounds.width - mounted.device.size.width) / 2)
        let band = CGRect(x: left, y: top, width: mounted.device.size.width, height: 70)
        let image = UIGraphicsImageRenderer(bounds: band).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 0 }
        return VisionTextProbe.inkFraction(cg)
    }

    /// 主机名的竖直中线（点，OCR 读数，误差一两点；以前的位移是 25～70 点）。认不出返回 nil。
    private func nameMidY(_ mounted: Mounted, phase: String) async -> CGFloat? {
        let png = capture(mounted.view)
        _ = attachProbePNG(png, name: "cover-\(mounted.device.name)-\(phase)")
        guard let lines = await VisionTextProbe.lines(png, languageCorrection: false) else { return nil }
        guard let line = lines.first(where: { $0.text.uppercased().replacingOccurrences(of: " ", with: "") == Self.hostName })
        else { return nil }
        return (1 - line.box.midY) * mounted.view.bounds.height
    }

    func testBodyStaysPutAcrossPhases() async throws {
        defer { MobileProbeWindow.closeAll() }
        let all = devices.map(mount)
        try await Task.sleep(for: .milliseconds(600))   // 过了露面延时（150ms）与淡入

        var readings: [String: [(String, CGFloat)]] = [:]
        func record(_ phase: String) async {
            for mounted in all {
                let y = await nameMidY(mounted, phase: phase)
                XCTAssertNotNil(y, "\(mounted.device.name)/\(phase)：没认出主机名")
                if let y { readings[mounted.device.name, default: []].append((phase, y)) }
            }
        }

        await record("connecting")
        // 顶部 chip 在顶上（以前连接中的底部区是空的，chip 被摆到了容器正中、压在进度环下面）。
        // 页面比屏幕高（真机横握时挂竖屏尺寸）就看不到顶上那条，跳过。
        for mounted in all where mounted.device.size.height <= mounted.view.bounds.height {
            XCTAssertGreaterThan(topBandInk(mounted), 0.01, "\(mounted.device.name)：连接中时顶部那条没有 chip")
        }

        // 连接耗时过长（5 秒）露出「返回」逃生口。
        try await Task.sleep(for: .milliseconds(5_200))
        await record("slow")

        // 失败：长文案（折成三行）与短文案。
        let long = "SSH 连接失败：10.31.0.102:2298 在 SSH 握手前就断开了连接，没有收到 SSH 服务的回应：服务器可能没在运行（开着代理或 VPN 时，连不上的主机也会这样表现）"
        for mounted in all { mounted.controller.state = .failed(long) }
        try await Task.sleep(for: .milliseconds(500))
        await record("failed-long")
        for mounted in all { mounted.controller.state = .failed("SSH 连接失败：拒绝连接") }
        try await Task.sleep(for: .milliseconds(500))
        await record("failed-short")

        // 重试 → 连接中 → 已连接（成功态停留，onFinish 什么都不做，页面留着）。
        for mounted in all {
            mounted.request.attempt += 1
            mounted.controller.state = .connecting
        }
        try await Task.sleep(for: .milliseconds(400))
        await record("retrying")
        for mounted in all { mounted.controller.state = .connected }
        try await Task.sleep(for: .milliseconds(500))
        await record("connected")

        for (device, values) in readings.sorted(by: { $0.key < $1.key }) {
            print("[cover-layout] \(device): " + values.map { "\($0.0)=\(String(format: "%.1f", $0.1))" }.joined(separator: " "))
            guard let base = values.first?.1 else { continue }
            for (phase, y) in values {
                XCTAssertEqual(y, base, accuracy: 3, "\(device)：主机名在「\(phase)」时挪了位置（\(y) vs 连接中 \(base)）")
            }
        }
    }
}
