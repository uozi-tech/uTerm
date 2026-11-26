import SwiftUI
import XCTest
@testable import uTermMobile

/// 标签条拖动排序的逐帧探针：挂一条真的 `WorkspaceTabStrip`，让被拖的标签实时换位，按时间截几帧，
/// 用 OCR 量别的标签的位置——让位要有中间帧（真的在滑）、「减弱动态效果」时第一帧就到位（不滑）。
///
/// 系统拖拽的浮起预览由 UIKit 画在单独的拖拽层，截不到；这里截的是标签条本身：空位、让位、落位。
/// 设了 `UTERM_STYLE_SHOTS_DIR` 时各帧写成 PNG（`tab-reorder-<机型>-<阶段>-<毫秒>.png`），否则只进 xcresult。
@MainActor
final class TabReorderAnimationProbeTests: XCTestCase {

    private struct Device {
        let name: String
        let width: CGFloat
        /// Duo 展开竖屏：标签条坐进状态行（更高、标签放大）。
        var statusRow = false
    }

    private static let devices = [
        Device(name: "iphone", width: 402),
        Device(name: "duo-folded", width: 466),
        Device(name: "duo-unfolded", width: 669, statusRow: true),
    ]

    private static let titles = ["ALPHA", "BRAVO", "CHARLIE", "DELTA"]

    private struct StripHost: View {
        let workspace: MobileWorkspace
        let drag: WorkspaceTabDragTracker
        let frames: WorkspaceStripFrames

        var body: some View {
            let pane = workspace.panes[0]
            VStack(spacing: 0) {
                WorkspaceTabStrip(tabs: workspace.tabs(in: pane), activeID: pane.activeID,
                                  onSelect: { _ in }, onClose: { _ in }, onNew: { _ in }, onBack: {}, onAgent: {},
                                  showsAgentButton: false,
                                  paneID: pane.id, drag: drag, frames: frames)
                Spacer(minLength: 0)
            }
            .coordinateSpace(.named(WorkspaceTabStrip.coordinateSpace))
            .background(M.surface)
        }
    }

    private func chrome(for device: Device) -> MChromeGeometry {
        guard device.statusRow else { return MChromeGeometry() }
        var duo = MChromeGeometry(root: CGRect(x: 0, y: 41, width: device.width, height: 910),
                                  safeAreaInsets: EdgeInsets(top: 41, leading: 0, bottom: 0, trailing: 0))
        duo.topBar = CGRect(x: 0, y: 0, width: 520, height: 48)
        duo.isUnfoldedPhone = true
        return duo
    }

    private struct Rig {
        let window: UIWindow
        let view: UIView
        let workspace: MobileWorkspace
        let drag: WorkspaceTabDragTracker
        let ids: [UUID]
    }

    private func mount(_ device: Device) async throws -> Rig {
        let workspace = MobileWorkspace()
        var ids: [UUID] = []
        for title in Self.titles {
            let (tab, _) = MobileFakeTerminal.tab(host: ServerProfile(), .idle)
            tab.controller.shellTitle = title
            workspace.open(.terminal(tab))
            ids.append(tab.id)
        }
        workspace.activate(ids[0])
        let drag = WorkspaceTabDragTracker()
        let root = StripHost(workspace: workspace, drag: drag, frames: WorkspaceStripFrames())
            .environment(\.mAccent, M.accent)
            .environment(\.mChrome, chrome(for: device))
            .frame(width: device.width, height: 120)
        let (window, host) = MobileProbeWindow.make(size: CGSize(width: device.width, height: 120), rootView: root)
        window.overrideUserInterfaceStyle = .dark
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        return Rig(window: window, view: host.view, workspace: workspace, drag: drag, ids: ids)
    }

    private func capture(_ view: UIView) -> Data {
        UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    /// OCR 认出的某个标题的中心横坐标（点）。
    private func centerX(of title: String, in png: Data, width: CGFloat) async -> CGFloat? {
        guard let lines = await VisionTextProbe.lines(png, languageCorrection: false) else { return nil }
        return lines.first { $0.text.uppercased().contains(title) }.map { $0.box.midX * width }
    }

    private func save(_ png: Data, _ name: String) {
        attachProbePNG(png, name: name)
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? png.write(to: url.appendingPathComponent("\(name).png"))
    }

    /// 按时间截一串帧：`at` 是动作发生后多少毫秒截。
    private func frames(_ rig: Rig, at times: [Int], name: String, _ action: () -> Void) async throws -> [Data] {
        let start = ContinuousClock.now
        action()
        var shots: [Data] = []
        for ms in times {
            let wait = start.advanced(by: .milliseconds(ms)) - ContinuousClock.now
            if wait > .zero { try await Task.sleep(for: wait) }
            let png = capture(rig.view)
            save(png, "\(name)-\(ms)ms")
            shots.append(png)
        }
        return shots
    }

    /// 把 DELTA 拖到第一位：别的标签往右让位要有中间帧；松手后空位淡回成标签。
    func testOthersSlideOverWhileDraggingAndTheTabLandsAfterDrop() async throws {
        defer { MobileProbeWindow.closeAll() }
        for device in Self.devices {
            let rig = try await mount(device)
            let before = capture(rig.view)
            save(before, "tab-reorder-\(device.name)-0-before")
            let startX = await centerX(of: "BRAVO", in: before, width: device.width)
            let start = try XCTUnwrap(startX, device.name)

            rig.drag.begin(rig.ids[3])
            let sliding = try await frames(rig, at: [40, 90, 140, 400], name: "tab-reorder-\(device.name)-1-slide") {
                rig.drag.update(.reorder(index: 0), in: rig.workspace, move: WorkspaceTabDragTracker.moveAnimation)
            }
            let endX = await centerX(of: "BRAVO", in: sliding[3], width: device.width)
            let end = try XCTUnwrap(endX, device.name)
            XCTAssertGreaterThan(end - start, 40, "\(device.name)：BRAVO 给 DELTA 让出位置")
            var intermediate = false
            for shot in sliding.prefix(3) {
                if let x = await centerX(of: "BRAVO", in: shot, width: device.width),
                   x > start + 4, x < end - 4 { intermediate = true }
            }
            XCTAssertTrue(intermediate, "\(device.name)：让位是滑过去的，不是一下跳到位")
            XCTAssertEqual(rig.workspace.panes[0].tabIDs.first, rig.ids[3])

            _ = try await frames(rig, at: [0, 60, 120, 300], name: "tab-reorder-\(device.name)-2-land") {
                rig.drag.drop(.reorder(index: 0), in: rig.workspace, move: WorkspaceTabDragTracker.moveAnimation,
                              land: .easeOut(duration: 0.2))
            }
            XCTAssertFalse(rig.drag.isPlaceholder(rig.ids[3]))
            MobileProbeWindow.close(rig.window)
        }
    }

    /// 「减弱动态效果」：不滑，第一帧就到位。
    func testReduceMotionMovesWithoutSliding() async throws {
        defer { MobileProbeWindow.closeAll() }
        let device = Self.devices[0]
        let rig = try await mount(device)
        let startX = await centerX(of: "BRAVO", in: capture(rig.view), width: device.width)
        let start = try XCTUnwrap(startX)
        rig.drag.begin(rig.ids[3])
        let shots = try await frames(rig, at: [40, 400], name: "tab-reorder-reduce-motion") {
            rig.drag.update(.reorder(index: 0), in: rig.workspace, move: nil)
        }
        let firstX = await centerX(of: "BRAVO", in: shots[0], width: device.width)
        let lastX = await centerX(of: "BRAVO", in: shots[1], width: device.width)
        let first = try XCTUnwrap(firstX), last = try XCTUnwrap(lastX)
        XCTAssertGreaterThan(last - start, 40)
        XCTAssertEqual(first, last, accuracy: 3, "第一帧就已经到位")
    }
}
