import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 远程桌面顶栏的读数条：窄屏上另起一行时不能被截断，宽了才带补充读数。
@MainActor
final class RemoteDesktopStatsStripTests: XCTestCase {
    /// 每一项都取位数最多的读数。
    private var widest: [RemoteDesktopStat] {
        var audio = RemoteAudioReceiver.Snapshot()
        audio.bufferedMillis = 288
        audio.targetMillis = 300
        audio.counters.concealed = 128
        return RemoteDesktopStat.items(
            latency: RemoteDesktopLatency(p50Millis: 1280, p95Millis: 2400),
            video: .init(framesPerSecond: 120, megabitsPerSecond: 28.6, decodeMillis: 16.9), audio: audio)
    }

    private func fittedWidth(_ items: [RemoteDesktopStat], in width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: RemoteDesktopStatsStrip(items: items))
        return host.sizeThatFits(in: CGSize(width: width, height: 100)).width
    }

    /// 最窄的一种：Duo 分屏 330pt，扣掉顶栏两侧让出的距离（默认各 24pt）。
    func test_fits_the_narrowest_bar_without_details() {
        let available: CGFloat = 330 - 2 * 24
        let narrow = fittedWidth(widest, in: available)
        XCTAssertLessThanOrEqual(narrow, available, "窄屏上只留主数值也要放得下")
        XCTAssertGreaterThan(fittedWidth(widest, in: 900), narrow, "放得下时带上 p95 与声音缓冲的目标")
    }

    /// 截图给人看（按需）：`TEST_RUNNER_UTERM_STYLE_SHOTS_DIR=/path`。
    func test_snapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_STYLE_SHOTS_DIR")
        }
        var audio = RemoteAudioReceiver.Snapshot()
        audio.bufferedMillis = 88
        audio.targetMillis = 150
        let typical = RemoteDesktopStat.items(
            latency: RemoteDesktopLatency(p50Millis: 30, p95Millis: 128),
            video: .init(framesPerSecond: 5, megabitsPerSecond: 13.5, decodeMillis: 5.9), audio: audio)
        audio.counters.concealed = 12
        let slow = RemoteDesktopStat.items(
            latency: RemoteDesktopLatency(p50Millis: 236, p95Millis: 410),
            video: .init(framesPerSecond: 24, megabitsPerSecond: 3.2, decodeMillis: 18.4), audio: audio)
        for (name, width) in [("wide", CGFloat(620)), ("narrow", 282)] {
            let view = VStack(alignment: .leading, spacing: 14) {
                RemoteDesktopStatsStrip(items: typical)
                RemoteDesktopStatsStrip(items: slow)
            }
            .frame(width: width, alignment: .leading)
            .padding(12)
            .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let data = try XCTUnwrap(renderer.uiImage?.pngData())
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("remote-stats-\(name).png"))
        }
    }
}
