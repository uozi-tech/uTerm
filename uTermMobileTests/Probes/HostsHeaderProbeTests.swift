import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// iPhone Duo 外屏的页头：标题钉在顶上不收起，滚过去的内容不能从标题底下透出来。
/// 要整屏真安全区才有意义，其它机型跳过。跑法：Duo 模拟器（iOS-27-2-iPhone19-4 runtime）或 Duo 真机，
/// 跑的时候别碰屏幕，手指会把程序设的滚动偏移拖走。
@MainActor
final class HostsHeaderProbeTests: XCTestCase {
    private static let duoCoverWidth: CGFloat = 466

    func testContentScrolledUnderPinnedTitleDoesNotShowThrough() async throws {
        defer { MobileProbeWindow.closeAll() }
        try requireDuoCover()
        let container = try MobileFixtures.modelContainer(seed: .realistic)
        let window = try await mount(MobileRootView(), container: container)
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .seconds(1))

        let scroll = try XCTUnwrap(window.descendants(of: UIScrollView.self).first {
            !$0.descendants(of: UISegmentedControl.self).isEmpty
        })
        // 标题上方那一条：不含标题文字，分段控件滚上来时正好经过这里。
        let band = CGRect(x: 0, y: 2, width: 360, height: 24)
        let atRest = window.pixels(in: band)
        scroll.setContentOffset(CGPoint(x: 0, y: 67.5 - scroll.adjustedContentInset.top), animated: false)
        try await Task.sleep(for: .seconds(1))
        let segment = try XCTUnwrap(window.descendants(of: UISegmentedControl.self).first)
        XCTAssertTrue(window.convert(segment.bounds, from: segment).intersects(band), "分段控件要滚到这一条里才测得到")

        XCTAssertEqual(window.pixels(in: band), atRest, "内容从标题底下透出来了")
    }

    /// Duo 外屏上标题固定在顶部：滚动、下拉过头都不动。
    func testTitlesStayFixedOnDuoCover() async throws {
        defer { MobileProbeWindow.closeAll() }
        try requireDuoCover()
        let container = try MobileFixtures.modelContainer(seed: .realistic)
        try await assertTitleFixed("主机", window: mount(HostsScreen(), container: container))
        MobileProbeWindow.closeAll()
        try await assertTitleFixed("设置", window: mount(SettingsScreen(), container: container))
        MobileProbeWindow.closeAll()
        try await assertTitleFixed("命令", window: mount(CommandsScreen(), container: container))
    }

    /// 手指上滑时系统会把导航栏滑走（iOS 27），进程内合成不了触摸，这里读回配置：主机、设置、命令都关掉了，
    /// 没声明固定的页面不受影响。真实手势的验收用 `testRecordHandDrag`。
    func testPinnedPagesDisableBarMinimization() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("iOS 27 才有") }
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        func behaviors<V: View>(_ view: V) async throws -> [UIBarMinimizationBehavior] {
            let window = try await mount(view, container: container)
            defer { MobileProbeWindow.closeAll() }
            return try XCTUnwrap(window.rootViewController).withDescendants
                .filter { !$0.navigationItem.title.isNilOrEmpty }
                .map(\.navigationItem.navigationBarMinimization.minimizationBehavior)
        }
        for (name, found) in [("主机", try await behaviors(HostsScreen())),
                              ("设置", try await behaviors(SettingsScreen())),
                              ("命令", try await behaviors(CommandsScreen()))] {
            XCTAssertTrue(found.contains(.never), "\(name)：\(found.map(\.rawValue))")
        }
        let plain = try await behaviors(MScreen(title: "普通页") { Text("内容") })
        XCTAssertFalse(plain.isEmpty)
        XCTAssertFalse(plain.contains(.never), "普通页：\(plain.map(\.rawValue))")
    }

    /// 懒加载的估高在滚动中不断被修正，真机上（手指甩动 + 真实数据）修正时整块内容被挪位：滑回顶部偏移正常，
    /// 内容却往下错开 317pt，手指不动就一直空着。程序滚动挪不动内容，复现不了错位本身，但能复现它的前提：
    /// 总高度在变。主机数量在 `eagerHostLimit` 以内时总高度必须从头到尾不变。
    func testHostsContentHeightStaysConstantWhileScrolling() async throws {
        defer { MobileProbeWindow.closeAll() }
        for (servers, groups) in [(23, 5), (23, 12), (HostsScreen.eagerHostLimit, 10)] {
            let seed = MobileFixtures.Seed(servers: servers, groups: groups, keys: 4, commands: 0, runs: 0, sessions: 0)
            let container = try MobileFixtures.modelContainer(seed: seed)
            let window = try await mount(HostsScreen(), container: container)
            let scroll = try XCTUnwrap(window.descendants(of: UIScrollView.self).first {
                !$0.descendants(of: UISegmentedControl.self).isEmpty
            })
            let segment = try XCTUnwrap(scroll.descendants(of: UISegmentedControl.self).first)
            func contentY() -> CGFloat { window.convert(segment.bounds, from: segment).minY + scroll.contentOffset.y }
            let rest = contentY()
            let top = -scroll.adjustedContentInset.top
            var heights = Set<Int>()
            func glide(toBottom: Bool) async throws {
                for _ in 0..<300 {
                    let end = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                    let goal = toBottom ? end : top
                    let current = scroll.contentOffset.y
                    if abs(goal - current) < 1 { break }
                    let next = current + min(400, abs(goal - current)) * (goal > current ? 1 : -1)
                    scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                    try await Task.sleep(for: .milliseconds(16))
                    heights.insert(Int(scroll.contentSize.height))
                    XCTAssertEqual(contentY(), rest, accuracy: 1, "\(servers) 台：内容被挪位了")
                }
            }
            for _ in 0..<2 {
                try await glide(toBottom: true)
                try await glide(toBottom: false)
            }
            XCTAssertEqual(heights.count, 1, "\(servers) 台 \(groups) 组：总高度在变 \(heights.sorted())")
            MobileProbeWindow.closeAll()
        }
    }

    /// 普通 iPhone 不受外屏的处理影响：大标题照常收起。
    func testTitleStillCollapsesOnRegularPhone() async throws {
        defer { MobileProbeWindow.closeAll() }
        let screen = try XCTUnwrap(MobileProbeWindow.activeScene()).screen.bounds.size
        guard screen.width < 450 else { throw XCTSkip("只看普通 iPhone") }
        let container = try MobileFixtures.modelContainer(seed: .realistic)
        let window = try await mount(HostsScreen(), container: container)
        let scroll = try XCTUnwrap(window.descendants(of: UIScrollView.self).first)
        let restInset = scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: 0, y: 300 - restInset), animated: false)
        try await Task.sleep(for: .seconds(1))
        XCTAssertLessThan(scroll.adjustedContentInset.top, restInset, "大标题应随滚动收起")
    }

    /// 真机手动：进程内合成不了触摸，真实拖动只能录人的手指。`UTERM_RECORD_DRAG=1` 时打开整个 App 外壳，
    /// 等第一次触摸（最多 5 分钟），之后录 40 秒：标题实际显示的位置、滚动偏移，并隔几秒留一张截图。
    func testRecordHandDrag() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_RECORD_DRAG"] != nil else { throw XCTSkip("按需") }
        defer { MobileProbeWindow.closeAll() }
        // `UTERM_RECORD_DRAG=real`：不挂夹具，只读宿主 App 自己的主窗口（真实数据、真实的「我的 Mac」）。
        let usesRealApp = ProcessInfo.processInfo.environment["UTERM_RECORD_DRAG"] == "real"
        let window: UIWindow
        if usesRealApp {
            try await Task.sleep(for: .seconds(2))
            let scene = try XCTUnwrap(MobileProbeWindow.activeScene())
            window = try XCTUnwrap(scene.windows.first { $0.windowLevel == .normal && !$0.isHidden })
        } else {
            let container = try MobileFixtures.modelContainer(seed: .realistic)
            window = try await mount(MobileRootView(), container: container)
            window.overrideUserInterfaceStyle = .dark
        }
        let duration: TimeInterval = usesRealApp ? 120 : 40

        func tracking() -> UIScrollView? {
            window.descendants(of: UIScrollView.self).first { $0.isTracking || $0.isDecelerating }
        }
        print("DRAG waiting")
        var waited = 0
        while tracking() == nil, waited < 6000 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        print("DRAG started waited=\(waited)")

        var last = ""
        var lastHosts = ""
        var stuckShots = 0
        var shots = 0
        var lastShot = Date.distantPast
        let start = Date()
        while Date().timeIntervalSince(start) < duration {
            let titles = window.descendants(of: UILabel.self)
                .filter { ["主机", "命令", "设置"].contains($0.text ?? "") && $0.bounds.height > 10 && !$0.isHidden }
                .map { label -> String in
                    let shown = label.layer.presentation() ?? label.layer
                    let rect = shown.convert(shown.bounds, to: window.layer.presentation() ?? window.layer)
                    return "\(label.text ?? "") \(rect.integral) f=\(label.font.pointSize) a=\(shown.opacity)"
                }
            let scroll = tracking()
            let state = scroll.map {
                let farthest = $0.contentSize.height - $0.bounds.height + $0.adjustedContentInset.bottom
                return "off=\(Int($0.contentOffset.y)) adj=\(Int($0.adjustedContentInset.top)) "
                    + "end=\(Int(farthest)) w=\(Int(window.bounds.width)) \($0.isTracking ? "T" : "d")"
            } ?? "idle"
            let line = "\(state) \(titles)"
            // 卡住发生在手指离开之后，上面的 tracking() 这时已经取不到滚动视图，要单独看主机列表。
            if let hosts = window.descendants(of: UIScrollView.self).first(where: { scroll in
                scroll.descendants(of: UISegmentedControl.self).contains { $0.titleForSegment(at: 0) == "全部" }
            }), let segment = hosts.descendants(of: UISegmentedControl.self).first(where: {
                $0.titleForSegment(at: 0) == "全部"
            }) {
                let off = hosts.contentOffset.y
                let top = -hosts.adjustedContentInset.top
                let end = hosts.contentSize.height - hosts.bounds.height + hosts.adjustedContentInset.bottom
                let contentY = window.convert(segment.bounds, from: segment).minY + off
                let moving = hosts.isTracking || hosts.isDecelerating || hosts.isDragging
                let outside = off < top - 1 || off > end + 1
                let status = outside ? (moving ? "PAST" : "STUCK") : "ok"
                let segmentY = Int(window.convert(segment.bounds, from: segment).minY)
                // 到顶静止时分段控件该紧贴标题栏；比这低就是顶部有空白，哪怕偏移本身没出范围。
                let blankAtRest = !moving && off <= top + 1 && CGFloat(segmentY) > -top + 8
                let hostsLine = "\(status)\(blankAtRest ? " BLANK" : "") contentY=\(Int(contentY)) adj=\(Int(-top)) "
                    + "\(outside || blankAtRest ? "off=\(Int(off)) end=\(Int(end)) segY=\(segmentY)" : "")"
                if hostsLine != lastHosts {
                    print("HOSTS \(String(format: "%.2f", Date().timeIntervalSince(start))) \(hostsLine) "
                        + "T=\(hosts.isTracking) d=\(hosts.isDecelerating) off=\(Int(off)) h=\(Int(hosts.contentSize.height))")
                    lastHosts = hostsLine
                }
                if outside || blankAtRest, !moving, stuckShots < 3 {
                    let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                    })
                    shot.name = "stuck-off\(Int(off))"
                    shot.lifetime = .keepAlways
                    add(shot)
                    stuckShots += 1
                }
            }
            if line != last {
                print("DRAG \(String(format: "%.2f", Date().timeIntervalSince(start))) \(line)")
                last = line
            }
            if !usesRealApp, let scroll, scroll.isTracking, shots < 8, Date().timeIntervalSince(lastShot) > 3 {
                let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                })
                shot.name = "drag-off\(Int(scroll.contentOffset.y))"
                shot.lifetime = .keepAlways
                add(shot)
                shots += 1
                lastShot = Date()
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func requireDuoCover() throws {
        let screen = try XCTUnwrap(MobileProbeWindow.activeScene()).screen.bounds.size
        guard screen.width == Self.duoCoverWidth else { throw XCTSkip("只在 iPhone Duo 外屏上有意义") }
    }

    private func mount<V: View>(_ view: V, container: ModelContainer) async throws -> UIWindow {
        let lan = LANSyncCoordinator(role: .receiver, preferences: SharedPreferencesSync(),
                                     dataStore: LANSyncDataStore(container: container))
        let root = view
            .mMeasuresChrome()
            .environment(MobileStore())
            .environment(CloudKitSyncMonitor())
            .environment(lan)
            .environment(RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())))
            .modelContainer(container)
        let (window, host) = MobileProbeWindow.make(placement: .visibleOnScreen, rootView: root)
        host.safeAreaRegions = .all
        try await Task.sleep(for: .seconds(1.5))
        for _ in 0..<20 where window.descendants(of: UIScrollView.self).isEmpty {
            try await Task.sleep(for: .milliseconds(250))
        }
        return window
    }

    private func assertTitleFixed(_ title: String, window: UIWindow) async throws {
        func titleFrame() throws -> CGRect {
            let label = try XCTUnwrap(window.descendants(of: UILabel.self).first {
                $0.text == title && $0.bounds.height > 0 && $0.alpha > 0
            }, "没找到标题 \(title)")
            return window.convert(label.bounds, from: label)
        }
        let scroll = try XCTUnwrap(window.descendants(of: UIScrollView.self).first)
        let rest = try titleFrame()
        let top = scroll.adjustedContentInset.top
        for y: CGFloat in [150, -100, 0] {
            scroll.setContentOffset(CGPoint(x: 0, y: y - top), animated: false)
            try await Task.sleep(for: .milliseconds(500))
            let frame = try titleFrame()
            // 标题上滚后系统会把字号收小，这是标准行为；要保证的是它留在栏里、左对齐不动。
            XCTAssertEqual(frame.minX, rest.minX, "\(title) 在偏移 \(y) 时横向移动了")
            XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(title) 在偏移 \(y) 时移出了屏幕")
            XCTAssertLessThanOrEqual(frame.maxY, top, "\(title) 在偏移 \(y) 时掉出了标题栏")
            XCTAssertEqual(scroll.adjustedContentInset.top, top, "\(title) 的标题栏高度在偏移 \(y) 时变了")
        }
    }
}

final class MChromeSideStatusColumnTests: XCTestCase {
    private func geometry(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 34, trailing: CGFloat = 0) -> MChromeGeometry {
        MChromeGeometry(safeAreaInsets: EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
    }

    func testDuoCoverCountsEvenWithoutReportedStatusBar() {
        let cover = geometry(trailing: 84)
        XCTAssertNil(cover.statusBar, "没有探针结果时没有状态栏矩形")
        XCTAssertTrue(cover.hasSideStatusColumn)
    }

    func testOtherLayoutsDoNotCount() {
        XCTAssertFalse(geometry(top: 62).hasSideStatusColumn, "普通 iPhone 竖屏")
        XCTAssertFalse(geometry(leading: 62, bottom: 21, trailing: 62).hasSideStatusColumn, "普通 iPhone 横屏")
        XCTAssertFalse(geometry(top: 82).hasSideStatusColumn, "Duo 展开竖屏")
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

private extension UIViewController {
    var withDescendants: [UIViewController] {
        [self] + children.flatMap(\.withDescendants)
    }
}

private extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + $0.descendants(of: type) }
    }

    func pixels(in rect: CGRect) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            drawHierarchy(in: bounds.offsetBy(dx: -rect.minX, dy: -rect.minY), afterScreenUpdates: true)
        }.pngData() ?? Data()
    }
}
