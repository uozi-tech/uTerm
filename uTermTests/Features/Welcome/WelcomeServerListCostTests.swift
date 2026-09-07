import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 欢迎页服务器列表（`ServerList` / `ServerRow`）的渲染成本探针。
///
/// 形状抄 `ProbeSmokeTests`：真窗口（屏内 `alphaValue = 0`）、真实档 + 极端档、
/// 两臂同轮 ABBA 交替两遍取均值、每档拆窗、往返幅度钳 ≈3 视口。
/// **判据只用结构判据与同轮相对差，绝对毫秒只打印。**
///
/// ## 三臂
///
/// - `legacy`：改前那一版 `ServerRow` 的**逐字拷贝**（`LegacyServerRow`）——
///   plain `Button` 包整行、两个常驻 `.help`、每行现建一个
///   `RelativeDateTimeFormatter`。
/// - `helpGated`：归因臂，只把 `.help` 收成悬停门控。
/// - `tuned`：产品里现在的 `ServerRow`。
///
/// 三臂共用同一个列表外壳（`LazyVStack` + 同一份拖拽修饰器 + 同一份右键菜单），
/// 所以读数差只归因到「行本身」这一处改动。
///
/// ## 这一轮把一条先验推翻了
///
/// 去之前以为 `.help` 悬停门控与 `Button → onTap` 各有各的账。实测
/// **`.help` 那一刀在这里是零收益**：`helpGated` 与 `legacy` 的常驻 NSView
/// 完全相同（91 = 91），帧时间差在噪声内。整笔收益来自 `Button`——
/// 改前臂的类名直方图是 `_FocusRingView×51 KeyViewProxy×11`，改后两者归零。
///
/// ## 规模来源
///
/// 行数 = 用户保存的主机数。个人用户 10~50 台；一个运维团队把整个内网机器
/// 灌进来（`~/.ssh/config` 导入是产品功能，见 `WelcomeView.handleConfigDrop`）
/// 上千台是真实的。Tweaks 的假数据工厂把上限钳在 50
/// （`MockServerFactory.swift:28`）—— 那是调试旋钮的上限，不是数据的上限，
/// 所以探针**不走工厂**，直接构造 `ServerProfile` 数组。
/// 真实档 100 台 / 10 组，极端档 2000 台 / 60 组。
@MainActor
final class WelcomeServerListCostTests: XCTestCase {

    // MARK: - 夹具

    private var windows: [NSWindow] = []

    /// 见 `ProbeSmokeTests`：`uTermTests` 默认隔离是 `nonisolated`，
    /// 不能覆写 `tearDown()` 拆窗，每条用例开头 `defer { closeAllWindows() }`。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 900, height: 620)

    enum Arm: String {
        /// 改前：每行一个 plain `Button` + 两个常驻 `.help` + 每行现建格式化器。
        case legacy
        /// 归因臂：只把两个常驻 `.help` 收成悬停门控，`Button` 与现建格式化器照旧。
        /// `legacy → helpGated` 的差 = tooltip 那一刀的价签。
        case helpGated
        /// 改后：产品里现在的 `ServerRow`（onTap + AX、`.help` 悬停门控、共享格式化器）。
        /// `helpGated → tuned` 的差 = `Button` + 现建格式化器那一刀的价签。
        case tuned
    }

    struct Reading {
        let arm: Arm
        let rows: Int
        let mountMS: Double
        let beats: Int
        let frameP50: Double
        let frameP95: Double
        let overBudget: Double
        let hitP50: Double
        let views: Int
        let scrollableHeight: CGFloat
    }

    /// 探针数据源：不经 `MockServerFactory`（它把上限钳在 50）。
    /// id / 名称 / 分组 / 时间戳全部按序号确定性生成，两臂拿到同一份。
    static func makeProfiles(count: Int, groups: Int) -> [ServerProfile] {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            let p = ServerProfile()
            p.id = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", i))") ?? UUID()
            p.name = "host-\(i)-\(["web", "db", "cache", "edge", "worker"][i % 5])"
            p.host = "10.\(i / 65536 % 256).\(i / 256 % 256).\(i % 256)"
            p.username = "deploy"
            p.port = (i % 5 == 0) ? 2222 : 22
            p.sortOrder = i
            p.group = groups == 0 ? nil : "group-\(i % groups)"
            p.isPinned = i % 17 == 0
            p.lastConnectedAt = i % 3 == 0 ? anchor.addingTimeInterval(-Double(i) * 3600) : nil
            p.sftpOnly = i % 6 == 5
            return p
        }
    }

    static func groupNames(_ groups: Int) -> [String] {
        (0..<groups).map { "group-\($0)" }
    }

    static func groupColorHexes(_ groups: Int) -> [String: String] {
        var result: [String: String] = [:]
        let palette = ["#4F8EF7", "#F7A24F", "#4FF7A2", "#F74F8E", "#A24FF7", "#F7F04F"]
        for i in 0..<groups { result["group-\(i)"] = palette[i % palette.count] }
        return result
    }

    // MARK: - 挂载

    private struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
    }

    private func makeFixture(arm: Arm, profiles: [ServerProfile], groups: Int) throws -> Fixture {
        let size = Self.size
        let harness = ServerListProbeHarness(arm: arm,
                                             profiles: profiles,
                                             existingGroups: Self.groupNames(groups),
                                             groupColorHexes: Self.groupColorHexes(groups))
        let root = AnyView(harness.frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "夹具里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView, "NSScrollView 必须有 documentView")
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        return Fixture(window: unconstrained, host: host, scroll: scroll,
                       document: document, mountMS: mountMS)
    }

    static func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ view: NSView) { n += 1; for sub in view.subviews { walk(sub) } }
        walk(root)
        return n
    }

    static func classHistogram(in root: NSView) -> String {
        var counts: [String: Int] = [:]
        func walk(_ view: NSView) {
            counts[String(describing: type(of: view)), default: 0] += 1
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - 量

    private func measure(arm: Arm, rows: Int, groups: Int) async throws -> Reading {
        let profiles = Self.makeProfiles(count: rows, groups: groups)
        let fixture = try makeFixture(arm: arm, profiles: profiles, groups: groups)
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host

        XCTAssertTrue(ProbeWindow.blindsRealMouse(fixture.window),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += viewport * 0.8
        }
        scrollTo(0)
        layout()
        try await Task.sleep(for: .milliseconds(120))

        let heartbeatStart = Date()
        var beats = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(beats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            beats += 1
        }

        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }

        var hits: [Double] = []
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction)
            layout()
            try await Task.sleep(for: .milliseconds(120))
            for i in 0..<100 {
                let point = NSPoint(x: CGFloat(40 + (i % 9) * 40), y: CGFloat(40 + (i % 11) * 40))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = Reading(arm: arm,
                              rows: rows,
                              mountMS: fixture.mountMS,
                              beats: beats,
                              frameP50: ProbeMetrics.percentile(frames, 0.5),
                              frameP95: ProbeMetrics.percentile(frames, 0.95),
                              overBudget: Double(frames.filter { $0 > 8.33 }.count)
                                  / Double(frames.count) * 100,
                              hitP50: ProbeMetrics.percentile(hits, 0.5),
                              views: Self.viewCount(in: host),
                              scrollableHeight: maxOffset)
        print(String(format: """
            [welcome-list] arm=%@ rows=%d groups=%d mount=%.2fms beats=%d/375 \
            frame-p50=%.3fms frame-p95=%.3fms over-8.33=%.1f%% hit-p50=%.1fus views=%d \
            scrollable=%.0f cpu=%.2fs rss=%.1fMB
            """,
            arm.rawValue, rows, groups, reading.mountMS, reading.beats,
            reading.frameP50, reading.frameP95, reading.overBudget, reading.hitP50,
            reading.views, reading.scrollableHeight,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[welcome-list-views] arm=\(arm.rawValue) rows=\(rows) "
              + Self.classHistogram(in: fixture.host))
        await closeWindows()
        return reading
    }

    private func average(_ readings: [Reading]) -> Reading {
        let n = Double(readings.count)
        return Reading(arm: readings[0].arm,
                       rows: readings[0].rows,
                       mountMS: readings.map(\.mountMS).reduce(0, +) / n,
                       beats: readings.map(\.beats).reduce(0, +) / readings.count,
                       frameP50: readings.map(\.frameP50).reduce(0, +) / n,
                       frameP95: readings.map(\.frameP95).reduce(0, +) / n,
                       overBudget: readings.map(\.overBudget).reduce(0, +) / n,
                       hitP50: readings.map(\.hitP50).reduce(0, +) / n,
                       views: readings.map(\.views).reduce(0, +) / readings.count,
                       scrollableHeight: readings[0].scrollableHeight)
    }

    // MARK: - 用例

    /// 真实档 100 台 / 10 组 + 极端档 2000 台 / 60 组，两臂 ABBA 交替两遍。
    ///
    /// 断言只用结构判据：改后的常驻 NSView 数必须**不随行数涨**，且必须
    /// 显著少于改前（每行一个 `Button` + 两个 `.help` 全在 NSView 里）。
    func testServerListScaleArms() async throws {
        defer { closeAllWindows() }

        var results: [String: [Reading]] = [:]
        func record(_ r: Reading, _ groups: Int) {
            results["\(r.arm.rawValue)-\(r.rows)-\(groups)", default: []].append(r)
        }

        for (rows, groups) in [(100, 10), (2000, 60)] {
            // ABBA：legacy → tuned → tuned → legacy，抵消机器温度漂移。
            record(try await measure(arm: .legacy, rows: rows, groups: groups), groups)
            record(try await measure(arm: .helpGated, rows: rows, groups: groups), groups)
            record(try await measure(arm: .tuned, rows: rows, groups: groups), groups)
            record(try await measure(arm: .tuned, rows: rows, groups: groups), groups)
            record(try await measure(arm: .helpGated, rows: rows, groups: groups), groups)
            record(try await measure(arm: .legacy, rows: rows, groups: groups), groups)
        }

        let realLegacy = average(results["legacy-100-10"]!)
        let realGated = average(results["helpGated-100-10"]!)
        let realTuned = average(results["tuned-100-10"]!)
        let hugeLegacy = average(results["legacy-2000-60"]!)
        let hugeGated = average(results["helpGated-2000-60"]!)
        let hugeTuned = average(results["tuned-2000-60"]!)

        for r in [realLegacy, realGated, realTuned, hugeLegacy, hugeGated, hugeTuned] {
            print(String(format: """
                [welcome-list-avg] arm=%@ rows=%d mount=%.2fms beats=%d frame-p50=%.3fms \
                frame-p95=%.3fms over=%.1f%% hit-p50=%.1fus views=%d
                """,
                r.arm.rawValue, r.rows, r.mountMS, r.beats, r.frameP50, r.frameP95,
                r.overBudget, r.hitP50, r.views))
        }

        // ① 夹具真的能滚 —— 否则上面所有滚动读数都是假的。
        XCTAssertGreaterThan(realTuned.scrollableHeight, 0, "100 台也必须超过一屏")
        XCTAssertGreaterThan(hugeTuned.scrollableHeight, realTuned.scrollableHeight)

        // ② 结构判据：改后 NSView 数不随行数涨（懒栈 + 行内零平台控件）。
        //    100 台与 2000 台之间放 20% 余量（在屏行数随视口略有出入）。
        XCTAssertLessThanOrEqual(Double(hugeTuned.views), Double(realTuned.views) * 1.2 + 8,
                                 "改后 NSView 必须不随行数涨：100 台 \(realTuned.views) "
                                 + "vs 2000 台 \(hugeTuned.views)")

        // ③ 结构判据：改后常驻 NSView 必须显著少于改前（Button + 两个 .help 的价签）。
        XCTAssertLessThan(hugeTuned.views, hugeLegacy.views,
                          "2000 台：改后 \(hugeTuned.views) 必须少于改前 \(hugeLegacy.views)")
        XCTAssertLessThan(realTuned.views, realLegacy.views,
                          "100 台：改后 \(realTuned.views) 必须少于改前 \(realLegacy.views)")

        // ④ 心跳只挡「主线程被占死」这种硬故障。
        // ④ 归因（**先验被数据推翻，这条断言就是把结论钉住**）：
        //    收掉常驻 `.help` 一个 NSView 都不省 —— tooltip 注册在外层平台视图上，
        //    不自建子视图。整笔收益来自 `Button → onTapGesture`：
        //    改前臂的类名直方图里 `_FocusRingView×51` + `KeyViewProxy×11`，
        //    改后两者都是 0（playbook §四「每个 plain Button 另带焦点环宿主」）。
        XCTAssertEqual(hugeGated.views, hugeLegacy.views,
                       "`.help` 悬停门控不产生 NSView 差 —— 形态一变（比如 .help 改挂到"
                       + "自绘 NSViewRepresentable 上）这条会红：\(hugeGated.views) vs \(hugeLegacy.views)")
        XCTAssertLessThan(hugeTuned.views, hugeGated.views,
                          "去掉 Button 才是省 NSView 的那一刀：\(hugeTuned.views) vs \(hugeGated.views)")

        // ⑤ 心跳只挡「主线程被占死」这种硬故障。
        XCTAssertGreaterThan(hugeTuned.beats, 30, "3 秒 8ms 心跳一拍都收不到 = 主线程被占死")
    }
}

// MARK: - 探针外壳

/// 两臂共用的列表外壳：`ScrollView + LazyVStack + ForEach`，加同一份拖拽修饰器
/// 与同一份右键菜单。**只有行不一样** —— 读数差因此只归因到行。
///
/// 右键菜单与拖拽修饰器都是 `ServerList.swift` 里 `private` 的，探针照抄一份
/// （见文件顶部说明）。它们在两臂里完全一致，不参与归因。
private struct ServerListProbeHarness: View {
    let arm: WelcomeServerListCostTests.Arm
    let profiles: [ServerProfile]
    let existingGroups: [String]
    let groupColorHexes: [String: String]

    @State private var selectedID: UUID?
    @State private var draggingProfileID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ServerListLayout.rowSpacing) {
                ForEach(profiles) { profile in
                    row(for: profile)
                        .id(profile.id)
                        .modifier(ProbeRowDragModifier(profileID: profile.id,
                                                       draggingProfileID: $draggingProfileID))
                        .contextMenu { contextMenu(for: profile) }
                }
            }
            .padding(ServerListLayout.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.panel)
    }

    @ViewBuilder
    private func row(for profile: ServerProfile) -> some View {
        switch arm {
        case .legacy, .helpGated:
            LegacyServerRow(profile: profile,
                            query: "",
                            isSelected: selectedID == profile.id,
                            groupColor: ServerGroupBadgeTint.color(for: profile.group,
                                                                  in: groupColorHexes),
                            gatesHelp: arm == .helpGated,
                            onTap: { selectedID = profile.id },
                            onDoubleTap: { selectedID = profile.id })
        case .tuned:
            ServerRow(profile: profile,
                      query: "",
                      isSelected: selectedID == profile.id,
                      groupColor: ServerGroupBadgeTint.color(for: profile.group,
                                                             in: groupColorHexes),
                      onTap: { selectedID = profile.id },
                      onDoubleTap: { selectedID = profile.id })
        }
    }

    @ViewBuilder
    private func contextMenu(for profile: ServerProfile) -> some View {
        if !profile.sftpOnly {
            Button("连接") {}
            Button("在终端窗口打开") {}
        }
        Button("在 SFTP 中打开") {}
        Button(profile.isPinned ? "取消置顶" : "置顶") {}
        Button("编辑…") {}
        Button("复制为新服务器…") {}
        Menu("移动到分组") {
            ForEach(existingGroups, id: \.self) { g in
                Button(g) {}
            }
            if !existingGroups.isEmpty { Divider() }
            Button("未分组") {}
            Button("新分组…") {}
        }
        Divider()
        Button("删除…", role: .destructive) {}
    }
}

private struct ProbeRowDragModifier: ViewModifier {
    let profileID: UUID
    @Binding var draggingProfileID: UUID?

    func body(content: Content) -> some View {
        content.onDrag {
            draggingProfileID = profileID
            return NSItemProvider(object: "profile" as NSString)
        }
    }
}

// MARK: - 改前臂（逐字拷贝）

/// **改前那一版 `ServerRow` 的逐字拷贝**，只改了类型名。
///
/// 抄自 `uTerm/Features/Welcome/Views/ServerRow.swift`（本 commit 的父提交）。
/// 三处后来被改掉的形态在这里原样保留：
/// 1. 整行包在一个 plain `Button` 里；
/// 2. 名称与端点各挂一个**常驻** `.help`；
/// 3. 每行现建一个 `RelativeDateTimeFormatter`（`WelcomeFormat.relative` 旧实现）。
private struct LegacyServerRow: View {
    let profile: ServerProfile
    let query: String
    let isSelected: Bool
    let groupColor: Color?
    /// 归因臂开关：`true` 时把两个 `.help` 收成悬停门控，其余一字不改。
    var gatesHelp = false
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                UDHostDot(color: groupColor ?? UD.accent, pulse: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(HighlightedText.attributed(profile.name, highlighting: query))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(UD.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(whenHovering: !gatesHelp || hover, profile.name)
                        if profile.isPinned {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(UD.warning)
                        }
                    }
                    Text(HighlightedText.attributed(profile.displayEndpoint, highlighting: query))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(UD.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(whenHovering: !gatesHelp || hover, profile.displayEndpoint)
                }

                Spacer(minLength: 6)

                Text(Self.legacyRelative(profile.lastConnectedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)

                UDGroupChip(groupLabel, tint: groupColor)
            }
            .padding(ServerRowLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name)，\(profile.displayEndpoint)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// `WelcomeFormat.relative` 的改前实现：每次调用现建一个格式化器。
    private static func legacyRelative(_ date: Date?) -> String {
        guard let date else { return "从未" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var groupLabel: String {
        if let g = profile.group, !g.isEmpty { return g }
        return "未分组"
    }

    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.06) }
        if hover { return Color.primary.opacity(0.028) }
        return .clear
    }
}
