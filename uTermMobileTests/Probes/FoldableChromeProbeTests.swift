import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// iOS 27.1 起系统给折叠屏的几个接口（铰链、竖向栏、折痕保留区、不带高度的横条区域），在 iPhone Duo
/// 各个姿态下实际报什么；同一时刻旁边列出 `MChromeGeometry` 现在靠推断得到的判据，两边对照：
///
/// - `isUnfoldedPhone`（屏幕短边 ≥ 600pt）↔ 铰链状态（`UIHingeInteraction`）；
/// - `hasSideStatusColumn` / `statusColumn` ↔ `traitCollection.verticalBarEdge` 与 SwiftUI 的
///   `\.toolbarVerticalEdge`。2026-11-15 首轮实录后 App 已改成：状态栏矩形取 UIKit 的遮挡保留区
///   （SwiftUI 的在真机上漏报状态栏）、侧列听 `verticalBarEdge`，所以 `OLD` 那几列现在是改后的判据；
/// - `statusRowHeight` 与 `MStatusBarAvoidance` 里写死的 136pt 底板宽度 ↔ 27.2 不带 extent 的
///   `LayoutRegion.bar(onEdge:)`（顶边、左右两边各量一次）。
///
/// 量法：在宿主 App 的场景里另开一扇透明、不接触摸的窗口，UIKit 与 SwiftUI 各量一份，不动 App 自己的界面。
/// 判据部分用 App 自己的 `MChromeGeometry.measure` + 与 `MTopBarProbe` 相同的取法重算，所以和 App 里
/// 下发的 `\.mChrome` 是同一套算法、同一块窗口。
@MainActor
final class FoldableChromeProbeTests: XCTestCase {
    /// 没有铰链的设备（普通 iPhone 模拟器）：铰链为空、没有竖向栏。要换掉 `isUnfoldedPhone` 与
    /// `hasSideStatusColumn`，靠的就是这两个接口在非折叠屏上报「没有」。
    func testNonFoldableReportsNoHingeAndNoVerticalBar() async throws {
        guard #available(iOS 27.1, *) else { throw XCTSkip("iOS 27.1 才有") }
        let probe = try FoldProbe.open()
        defer { probe.close() }
        let reading = try await probe.settledReading()
        print("FOLD \(reading.line)")
        if reading.hinge != nil { throw XCTSkip("这台有铰链，读数见 testRecordPostures") }
        XCTAssertEqual(reading.verticalBarEdge, "unspecified")
        XCTAssertEqual(reading.swiftUIVerticalEdge, "nil")
        XCTAssertFalse(reading.old.isUnfoldedPhone)
    }

    /// 真机手动：`TEST_RUNNER_UTERM_FOLD_PROBE=1` 时录 `UTERM_FOLD_PROBE_SECONDS`（默认 150）秒，
    /// 读数一变就打一行 `FOLD`，铰链每次更新打一行 `HINGE`（状态变或角度变 ≥ 5° 才打）。
    /// 录的时候依次换姿态：折叠竖握 → 折叠横握 → 半开 → 展开竖握 → 展开横握 → 再合上。别锁屏。
    func testRecordPostures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UTERM_FOLD_PROBE"] != nil else { throw XCTSkip("按需") }
        guard #available(iOS 27.1, *) else { throw XCTSkip("iOS 27.1 才有") }
        let seconds = Double(environment["UTERM_FOLD_PROBE_SECONDS"] ?? "") ?? 150
        let probe = try FoldProbe.open()
        defer { probe.close() }
        probe.onHinge = { line in print("HINGE \(line)") }
        print("FOLD ready seconds=\(Int(seconds))：依次折叠竖握 / 折叠横握 / 半开 / 展开竖握 / 展开横握 / 合上")

        // 等人动手（开合或转屏，最多 5 分钟）再开始计时，免得录完了人还没看到提示。
        let initial = try await probe.settledReading()
        print("FOLD #initial \(initial.line)")
        var waited = 0
        while waited < 3000 {
            let now = probe.reading()
            if now.hinge?.prefix(6) != initial.hinge?.prefix(6) || now.screen != initial.screen
                || now.window != initial.window { break }
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        print("FOLD started waited=\(waited)")

        var seen: [String] = []
        var last = ""
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let line = probe.reading().line
            if line != last {
                print("FOLD \(String(format: "%6.2f", Date().timeIntervalSince(start))) \(line)")
                last = line
                if !seen.contains(line) { seen.append(line) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("FOLD done distinct=\(seen.count) hingeUpdates=\(probe.hingeUpdates)")
        for (index, line) in seen.enumerated() { print("FOLD #\(index) \(line)") }
    }
}

// MARK: - 读数

/// `MChromeGeometry` 的判据（与 App 同算法、同一套 UIKit 输入）。
nonisolated struct FoldOldHeuristics: Equatable, Sendable {
    var isUnfoldedPhone = false
    var hasSideStatusColumn = false
    var statusColumn: String = "nil"
    var statusRowHeight: String = "nil"
    var statusBar: String = "nil"
}

/// SwiftUI 那一侧量到的东西。
nonisolated struct FoldSwiftUIReading: Equatable, Sendable {
    var chrome = MChromeGeometry()
    var division: [String] = []
    var occlusion: [String] = []
}

nonisolated struct FoldReading: Equatable, Sendable {
    var screen = CGSize.zero
    var window = CGSize.zero
    var orientation = ""
    var sizeClass = ""
    var safeArea = UIEdgeInsets.zero
    var hinge: String?
    var verticalBarEdge = ""
    var swiftUIVerticalEdge = ""
    var topBar48: String = "nil"
    var topBarDefault: String = "nil"
    var leftBarDefault: String = "nil"
    var rightBarDefault: String = "nil"
    var cornerSafeArea: String = "nil"
    var containerMargins: String = ""
    var occlusion: [String] = []
    var division: [String] = []
    /// SwiftUI `GeometryProxy.reservedRegions` 报的（对照用：真机上不含状态栏）。
    var swiftUIOcclusion: [String] = []
    var swiftUIDivision: [String] = []
    var old = FoldOldHeuristics()

    var line: String {
        let s = safeArea
        return "screen=\(Int(screen.width))x\(Int(screen.height)) win=\(Int(window.width))x\(Int(window.height)) "
            + "\(orientation) \(sizeClass) safe=t\(Int(s.top)) l\(Int(s.left)) b\(Int(s.bottom)) r\(Int(s.right)) | "
            + "NEW hinge=\(hinge ?? "nil") vbar=\(verticalBarEdge) swiftUIVEdge=\(swiftUIVerticalEdge) "
            + "barTop48=\(topBar48) barTop=\(topBarDefault) barL=\(leftBarDefault) barR=\(rightBarDefault) "
            + "corner=\(cornerSafeArea) margins=\(containerMargins) "
            + "occl=[\(occlusion.joined(separator: " "))] div=[\(division.joined(separator: " "))] "
            + "swOccl=[\(swiftUIOcclusion.joined(separator: " "))] swDiv=[\(swiftUIDivision.joined(separator: " "))] | "
            + "OLD unfolded=\(old.isUnfoldedPhone) sideCol=\(old.hasSideStatusColumn) col=\(old.statusColumn) "
            + "row=\(old.statusRowHeight) statusBar=\(old.statusBar)"
    }
}

nonisolated func foldRect(_ rect: CGRect) -> String {
    "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
}

// MARK: - 探针窗口

@available(iOS 27.1, *)
@MainActor
private final class FoldProbe {
    private let window: UIWindow
    private let controller: FoldProbeController

    var onHinge: ((String) -> Void)? {
        get { controller.onHinge }
        set { controller.onHinge = newValue }
    }
    var hingeUpdates: Int { controller.hingeUpdates }

    private init(window: UIWindow, controller: FoldProbeController) {
        self.window = window
        self.controller = controller
    }

    static func open() throws -> FoldProbe {
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene(), "没有前台场景")
        let controller = FoldProbeController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        // 不 makeKey：键盘焦点与 App 自己的窗口都不动。
        window.isHidden = false
        return FoldProbe(window: window, controller: controller)
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// 等布局与系统的保留区稳定：连续两次读数相同才算。
    func settledReading() async throws -> FoldReading {
        var previous = reading()
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            let current = reading()
            if current == previous, current.window != .zero { return current }
            previous = current
        }
        return previous
    }

    func reading() -> FoldReading { controller.reading() }
}

@available(iOS 27.1, *)
@MainActor
private final class FoldProbeController: UIViewController {
    var onHinge: ((String) -> Void)?
    private(set) var hingeUpdates = 0
    private var hinge: (status: String, degrees: Int)?
    private var lastHingeLine = ""
    private let sink = FoldSwiftUISink()
    private lazy var host = UIHostingController(rootView: FoldSwiftUIProbe(sink: sink))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let interaction = UIHingeInteraction { [weak self] _, update in
            self?.record(update.hinge)
        }
        view.addInteraction(interaction)
    }

    private func record(_ value: UIHinge?) {
        hingeUpdates += 1
        guard let value else {
            hinge = nil
            report("nil")
            return
        }
        let degrees = Int((value.angle * 180 / .pi).rounded())
        let status = Self.describe(value.status)
        let changed = hinge.map { $0.status != status || abs($0.degrees - degrees) >= 5 } ?? true
        hinge = (status, degrees)
        if changed { report("\(status) \(degrees)°") }
    }

    private func report(_ text: String) {
        let line = "#\(hingeUpdates) \(text)"
        guard line != lastHingeLine else { return }
        lastHingeLine = line
        onHinge?(line)
    }

    private static func describe(_ status: UIHinge.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .closed: "closed"
        case .partiallyOpen: "partiallyOpen"
        case .fullyOpen: "fullyOpen"
        @unknown default: "status\(status.rawValue)"
        }
    }

    private static func describe(_ edge: UIVerticalBarEdge) -> String {
        switch edge {
        case .unspecified: "unspecified"
        case .leading: "leading"
        case .trailing: "trailing"
        @unknown default: "edge\(edge.rawValue)"
        }
    }

    private func regions(_ kind: UIView.ReservedRegion.Kind) -> [String] {
        guard let window = view.window else { return [] }
        return view.reservedRegions(kind: kind, options: .includeInactive).map { region in
            let frame = view.convert(region.frame, to: window)
            return foldRect(frame) + (region.isActive ? "" : "·off")
        }
    }

    func reading() -> FoldReading {
        var r = FoldReading()
        guard let window = view.window else { return r }
        let traits = traitCollection
        r.screen = window.screen.bounds.size
        r.window = window.bounds.size
        r.orientation = window.windowScene.map { "\($0.effectiveGeometry.interfaceOrientation.rawValue)" }
            .map { "o\($0)" } ?? "o?"
        r.sizeClass = (traits.horizontalSizeClass == .regular ? "R" : "C") + (traits.verticalSizeClass == .regular ? "R" : "C")
        r.safeArea = view.safeAreaInsets
        r.hinge = hinge.map { "\($0.status) \($0.degrees)°" }
        r.verticalBarEdge = Self.describe(traits.verticalBarEdge)
        r.swiftUIVerticalEdge = sink.verticalEdge

        func rect(_ region: UIView.LayoutRegion) -> String {
            foldRect(view.convert(view.bounds.inset(by: view.edgeInsets(for: region)), to: window))
        }
        let topBar48 = view.convert(view.bounds.inset(by: view.edgeInsets(
            for: .bar(onEdge: UIRectEdge.top, extent: MChromeGeometry.topBarExtent))), to: window)
        r.topBar48 = foldRect(topBar48)
        if #available(iOS 27.2, *) {
            r.topBarDefault = rect(.bar(onEdge: UIRectEdge.top))
            r.leftBarDefault = rect(.bar(onEdge: UIRectEdge.left))
            r.rightBarDefault = rect(.bar(onEdge: UIRectEdge.right))
        }
        let cornerInsets = view.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
        let corner = view.convert(view.bounds.inset(by: cornerInsets), to: window)
        r.cornerSafeArea = foldRect(corner)
        r.occlusion = regions(.occlusion)
        r.division = regions(.division)

        // 判据：SwiftUI 量的那份（与 App 根视图同一个 measure）叠上与 MTopBarProbe 相同的 UIKit 各项。
        var probe = MChromeProbeResult()
        probe.topBar = topBar48
        probe.cornerSafeArea = corner
        probe.isUnfoldedPhone = MChromeGeometry.isUnfoldedPhone(idiom: traits.userInterfaceIdiom,
                                                                screenSize: window.screen.bounds.size)
        probe.occlusion = view.reservedRegions(kind: .occlusion, options: .includeInactive).map {
            MChromeGeometry.RawRegion(frame: view.convert($0.frame, to: window), active: $0.isActive)
        }
        probe.reportsVerticalBarEdge = true
        probe.verticalBarEdge = switch traits.verticalBarEdge {
        case .leading: .leading
        case .trailing: .trailing
        default: nil
        }
        r.swiftUIOcclusion = sink.reading.occlusion
        r.swiftUIDivision = sink.reading.division
        let chrome = sink.reading.chrome.merging(probe)
        let m = chrome.containerMargins
        r.containerMargins = "t\(Int(m.top)) l\(Int(m.leading)) b\(Int(m.bottom)) r\(Int(m.trailing))"
        r.old.isUnfoldedPhone = chrome.isUnfoldedPhone
        r.old.hasSideStatusColumn = chrome.hasSideStatusColumn
        r.old.statusColumn = chrome.statusColumn.map { "\($0.edge) w\(Int($0.width)) bottom\(Int($0.statusBottom))" } ?? "nil"
        r.old.statusRowHeight = chrome.statusRowHeight.map { "\(Int($0))" } ?? "nil"
        r.old.statusBar = chrome.statusBar.map(foldRect) ?? "nil"
        return r
    }
}

/// SwiftUI 探针把量到的值写进这里，UIKit 那边轮询时取。
@MainActor
private final class FoldSwiftUISink {
    var reading = FoldSwiftUIReading()
    var verticalEdge = "unset"
}

@available(iOS 27.1, *)
private struct FoldSwiftUIProbe: View {
    let sink: FoldSwiftUISink
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        Color.clear
            .onGeometryChange(for: FoldSwiftUIReading.self) { proxy in
                let origin = proxy.frame(in: .global).origin
                func list(_ kind: ReservedRegion.Kind) -> [String] {
                    proxy.reservedRegions(kind: kind, options: .includeInactive).map {
                        foldRect($0.frame.offsetBy(dx: origin.x, dy: origin.y)) + ($0.isActive ? "" : "·off")
                    }
                }
                return FoldSwiftUIReading(chrome: MChromeGeometry.measure(proxy),
                                          division: list(.division), occlusion: list(.occlusion))
            } action: { sink.reading = $0 }
            .onChange(of: verticalEdge, initial: true) { _, edge in
                sink.verticalEdge = switch edge {
                case nil: "nil"
                case .leading?: "leading"
                case .trailing?: "trailing"
                }
            }
    }
}
