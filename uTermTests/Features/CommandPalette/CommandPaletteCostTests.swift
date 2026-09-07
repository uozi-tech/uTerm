import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// ⌘K 命令面板（`CommandPaletteModel` + `UDCommandPalette`）的渲染成本探针。
///
/// ## 形态
///
/// 面板的行渲染本来就是处方形态：`LazyVStack` + `onTapGesture` + 手工 AX
/// （`UDCommandPalette.CommandPaletteRow`）—— **不用改**。
/// 账在模型侧：`sections` / `results` / `selectedItemID` 三个计算属性互相嵌套，
///
/// ```
/// sections        = group(dedupe(filter(allItems) + dynamicItems))
/// results         = sections.flatMap(\.items)          // 又一遍 sections
/// selectedItemID  = results[selectedIndex].id          // 再一遍
/// ```
///
/// 而 `CommandPaletteHost.paletteOverlay` 一次 body 就要读
/// `model.sections` + `model.selectedItemID` = **两遍**完整的
/// filter + dedupe + group；按一次 ↑/↓ 又要 `moveSelection`（读 `results`）
/// 加回调里的 `model.selectedItemID`，**再两遍**。
///
/// ## 规模来源
///
/// 候选 = 静态项（每台主机一条 + 若干命令 / 设置项，`WelcomeView.welcomeCommandItems`）
/// ＋ 远程搜索命中（上限 200）。真实档 300 项；极端档 2000 主机 + 200 远程命中
/// = 2200 项（与 `WelcomeServerListCostTests` 的 2000 台同源，读数才可比）。
@MainActor
final class CommandPaletteCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 620, height: 620)

    // MARK: - 夹具

    static func makeItems(hosts: Int, remote: Int) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        items.reserveCapacity(hosts + remote + 8)
        for i in 0..<hosts {
            items.append(CommandPaletteItem(
                id: "host.\(i)", kind: .host,
                title: "host-\(i)-\(["web", "db", "cache", "edge", "worker"][i % 5])",
                detail: "deploy@10.\(i / 65536 % 256).\(i / 256 % 256).\(i % 256)",
                hint: "连接") {})
        }
        for i in 0..<remote {
            items.append(CommandPaletteItem(
                id: "file.\(i)", kind: .file,
                title: "/etc/nginx/conf.d/site-\(i).conf",
                detail: "web-\(i % 20)", hint: "打开") {})
        }
        items.append(CommandPaletteItem(id: "cmd.new", kind: .command,
                                        title: "新建服务器", detail: "添加一台主机",
                                        hint: "⌘N") {})
        items.append(CommandPaletteItem(id: "setting.general", kind: .setting,
                                        title: "设置 · 通用", detail: "外观、启动、语言、更新",
                                        hint: "↵") {})
        return items
    }

    // MARK: - 尺 ①：模型侧派生单独称（同轮 ABBA）

    /// **改前那三个计算属性的逐字拷贝**（只改成自由函数）。
    /// 抄自 `uTerm/Features/CommandPalette/CommandPaletteModel.swift`
    /// （本 commit 的父提交）。
    static func legacySections(_ m: CommandPaletteModel) -> [CommandPaletteSection] {
        let merged = dedupeCommandPaletteByID(
            filterCommandPalette(m.allItems, query: m.query) + m.dynamicItems)
        return groupCommandPaletteByMatchPriority(merged, query: m.query)
    }

    static func legacyResults(_ m: CommandPaletteModel) -> [CommandPaletteItem] {
        legacySections(m).flatMap(\.items)
    }

    static func legacySelectedItemID(_ m: CommandPaletteModel) -> String? {
        let r = legacyResults(m)
        return r.indices.contains(m.selectedIndex) ? r[m.selectedIndex].id : nil
    }

    private func time(_ label: String, reps: Int, _ body: () -> Void) -> Double {
        for _ in 0..<3 { body() }   // 预热
        var samples: [Double] = []
        for _ in 0..<reps {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let p50 = ProbeMetrics.percentile(samples, 0.5)
        print(String(format: "[palette-derive] %@ p50=%.3fms", label, p50))
        return p50
    }

    /// 「一次 body」= 读 `sections` + 读 `selectedItemID`；
    /// 「一次 ↑/↓」= `moveSelection(by:)` + 读 `selectedItemID`。
    func testDerivationCostPerBodyAndPerArrowKey() {
        var rows: [(String, Double, Double, Double, Double)] = []
        for (hosts, remote) in [(300, 0), (2000, 200)] {
            let model = CommandPaletteModel()
            model.searchDebounceNanos = 0
            model.open(items: Self.makeItems(hosts: hosts, remote: remote))
            model.setQuery("web")

            // ABBA：legacy → tuned → tuned → legacy
            let lb1 = time("legacy-body items=\(hosts + remote)", reps: 30) {
                _ = Self.legacySections(model)
                _ = Self.legacySelectedItemID(model)
            }
            let tb1 = time("tuned-body items=\(hosts + remote)", reps: 30) {
                _ = model.sections
                _ = model.selectedItemID
            }
            let tb2 = time("tuned-body items=\(hosts + remote)", reps: 30) {
                _ = model.sections
                _ = model.selectedItemID
            }
            let lb2 = time("legacy-body items=\(hosts + remote)", reps: 30) {
                _ = Self.legacySections(model)
                _ = Self.legacySelectedItemID(model)
            }

            let la1 = time("legacy-arrow items=\(hosts + remote)", reps: 30) {
                let count = Self.legacyResults(model).count
                _ = count
                _ = Self.legacySelectedItemID(model)
            }
            let ta1 = time("tuned-arrow items=\(hosts + remote)", reps: 30) {
                model.moveSelection(by: 1)
                _ = model.selectedItemID
            }
            let ta2 = time("tuned-arrow items=\(hosts + remote)", reps: 30) {
                model.moveSelection(by: -1)
                _ = model.selectedItemID
            }
            let la2 = time("legacy-arrow items=\(hosts + remote)", reps: 30) {
                let count = Self.legacyResults(model).count
                _ = count
                _ = Self.legacySelectedItemID(model)
            }

            let legacyBody = (lb1 + lb2) / 2, tunedBody = (tb1 + tb2) / 2
            let legacyArrow = (la1 + la2) / 2, tunedArrow = (ta1 + ta2) / 2
            print(String(format: """
                [palette-derive-avg] items=%d body legacy=%.3fms tuned=%.3fms | \
                arrow legacy=%.3fms tuned=%.3fms
                """, hosts + remote, legacyBody, tunedBody, legacyArrow, tunedArrow))
            rows.append(("\(hosts + remote)", legacyBody, tunedBody, legacyArrow, tunedArrow))

            // 语义闸门：缓存出来的三样必须与改前逐字相等。
            XCTAssertEqual(model.sections.map(\.id), Self.legacySections(model).map(\.id))
            XCTAssertEqual(model.results.map(\.id), Self.legacyResults(model).map(\.id))
            XCTAssertEqual(model.selectedItemID, Self.legacySelectedItemID(model))
        }

        let huge = rows.first { $0.0 == "2200" }!
        XCTAssertLessThan(huge.2, huge.1 / 2,
                          "一次 body 的派生必须求值一次而不是两次：\(huge.2)ms vs 改前 \(huge.1)ms")
        XCTAssertLessThan(huge.4, huge.3 / 2,
                          "一次 ↑/↓ 的派生必须是 O(1)：\(huge.4)ms vs 改前 \(huge.3)ms")
    }

    // MARK: - 尺 ②：真面板挂载 / 击键 / ↑↓ / NSView

    struct Reading {
        let items: Int
        let mountMS: Double
        let keystrokeP50: Double
        let keystrokeP95: Double
        let arrowP50: Double
        let views: Int
    }

    private struct PaletteHarness: View {
        let model: CommandPaletteModel

        var body: some View {
            UDCommandPalette(
                query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                sections: model.sections,
                selectedID: model.selectedItemID,
                onMove: { delta in
                    model.moveSelection(by: delta)
                    return model.selectedItemID
                },
                onExecute: { model.executeSelected() },
                onExecuteItem: { model.execute(itemID: $0) },
                onClose: { model.close() },
                isSearching: model.isSearching)
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
        }
    }

    private func measure(hosts: Int, remote: Int) async throws -> Reading {
        let model = CommandPaletteModel()
        model.searchDebounceNanos = 0
        model.open(items: Self.makeItems(hosts: hosts, remote: remote))

        let host = NSHostingView(rootView: AnyView(
            PaletteHarness(model: model).frame(width: Self.size.width, height: Self.size.height)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: Self.size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(try XCTUnwrap(window as? ProbeWindow.Unconstrained)))

        let mountStart = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - mountStart) * 1000

        // 一次击键：逐字敲出 "web-1" 再退回去，来回 6 轮。
        let word = Array("web-1")
        var keystrokes: [Double] = []
        for round in 0..<6 {
            for i in 0...word.count {
                let next = String(word.prefix(round % 2 == 0 ? i : word.count - i))
                let start = CFAbsoluteTimeGetCurrent()
                model.setQuery(next)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                keystrokes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }

        // 一次 ↑/↓：query 停在有大量命中的词上，连按 60 次。
        model.setQuery("web")
        host.layoutSubtreeIfNeeded()
        var arrows: [Double] = []
        for step in 0..<60 {
            let start = CFAbsoluteTimeGetCurrent()
            model.moveSelection(by: step % 20 == 19 ? -19 : 1)
            _ = model.selectedItemID
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            arrows.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let reading = Reading(items: hosts + remote + 2, mountMS: mountMS,
                              keystrokeP50: ProbeMetrics.percentile(keystrokes, 0.5),
                              keystrokeP95: ProbeMetrics.percentile(keystrokes, 0.95),
                              arrowP50: ProbeMetrics.percentile(arrows, 0.5),
                              views: WelcomeServerListCostTests.viewCount(in: host))
        print(String(format: """
            [palette] items=%d mount=%.2fms keystroke-p50=%.3fms keystroke-p95=%.3fms \
            arrow-p50=%.3fms views=%d cpu=%.2fs
            """, reading.items, reading.mountMS, reading.keystrokeP50, reading.keystrokeP95,
            reading.arrowP50, reading.views, ProbeMetrics.threadCPUSeconds()))
        print("[palette-views] items=\(reading.items) "
              + WelcomeServerListCostTests.classHistogram(in: host))
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
        return reading
    }

    func testPaletteScale() async throws {
        defer { closeAllWindows() }
        let real = try await measure(hosts: 300, remote: 0)
        let huge = try await measure(hosts: 2000, remote: 200)

        // 结构判据：候选表涨 7 倍，常驻 NSView 不该跟着涨
        // （结果区已经是 LazyVStack + onTapGesture + 手工 AX，本来就是处方形态）。
        XCTAssertLessThanOrEqual(Double(huge.views), Double(real.views) * 1.2 + 8,
                                 "面板常驻 NSView 不该跟候选数走：300 项 \(real.views) "
                                 + "vs 2200 项 \(huge.views)")
        // 只挡硬故障；绝对毫秒打印。
        XCTAssertLessThan(huge.arrowP50, 100, "按一次 ↑/↓ 不该到 100ms")
    }
}
