import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// `UDSidebarRow`（uAppKit / UDesignKit）图标色的**墨迹闸门**。
///
/// 改前那一版写的是 `selected ? UD.accent : (iconColor ?? UD.text3)` —— 只要行
/// 被选中就无条件盖掉调用方显式传进来的 `iconColor`。欢迎页侧栏的分组行正是靠这个
/// 参数把圆点画成分组色（`WelcomeSidebar.navRow(iconColor: g.color)`），于是选中
/// 某个分组时那个圆点被染成 accent 蓝，行里再也看不出这是哪个分组（用户报的问题）。
///
/// uAppKit v1.4.1 改成 `iconColor ?? (selected ? UD.accent : UD.text3)`：显式传的
/// 颜色是语义色，选中态不覆盖；没传的调用方照旧「选中变 accent」。
///
/// 判据取**离屏渲染出来的墨迹**而不是源码字符串 —— 组件在另一个仓库，源码闸门
/// 钉不住它。两臂同一份夹具、只差 `iconColor`，所以差只归因到这一处。
@MainActor
final class UDSidebarRowIconTintTests: XCTestCase {

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

    private static let size = NSSize(width: 200, height: 28)
    /// 图标画在行左侧：`padding(.horizontal, 8)` + `frame(width: 14)`。
    private static let iconRect = NSRect(x: 8, y: 4, width: 14, height: 20)

    /// 分组色的替身：饱和度高、且与 accent 蓝在 r/b 两个通道上方向相反。
    private static let groupRed = Color(.sRGB, red: 0.90, green: 0.16, blue: 0.16)

    /// 渲染一行，返回图标区的平均 sRGB。
    private func iconInk(selected: Bool, iconColor: Color?) throws -> (r: Double, g: Double, b: Double) {
        let row = ZStack {
            UD.bg
            UDSidebarRow(systemImage: "circle.fill",
                         label: "生产环境",
                         count: 6,
                         selected: selected,
                         action: {},
                         iconColor: iconColor)
        }
        .frame(width: Self.size.width, height: Self.size.height)

        let host = NSHostingView(rootView: AnyView(row))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.appearance = NSAppearance(named: .darkAqua)
        // 判据是像素，不是时间 —— 走屏外档。
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: Self.size),
                                      styleMask: [.borderless],
                                      contentView: host,
                                      placement: .offScreen)
        window.appearance = NSAppearance(named: .darkAqua)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: Self.iconRect),
                                "取不到图标区位图")
        host.cacheDisplay(in: Self.iconRect, to: rep)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sum.r += Double(c.redComponent)
                sum.g += Double(c.greenComponent)
                sum.b += Double(c.blueComponent)
                n += 1
            }
        }
        XCTAssertGreaterThan(n, 0, "图标区必须有像素")
        return (sum.r / Double(n), sum.g / Double(n), sum.b / Double(n))
    }

    /// 选中 + 显式 `iconColor`：圆点必须仍是那个语义色，**不是** accent。
    func testSelectedRowKeepsExplicitIconColorInsteadOfAccent() throws {
        defer { closeAllWindows() }

        let tinted = try iconInk(selected: true, iconColor: Self.groupRed)
        let accent = try iconInk(selected: true, iconColor: nil)
        print(String(format: "[sidebar-dot] tinted rgb=(%.3f, %.3f, %.3f)  "
                     + "accent rgb=(%.3f, %.3f, %.3f)",
                     tinted.r, tinted.g, tinted.b, accent.r, accent.g, accent.b))

        // ① 传了分组色的那臂：红通道压过蓝通道（accent 是蓝，方向相反）。
        XCTAssertGreaterThan(tinted.r, tinted.b + 0.05,
                             "选中行的圆点必须仍是传进来的分组色（红），"
                             + "实得 rgb=(\(tinted.r), \(tinted.g), \(tinted.b))")
        // ② 没传颜色的那臂：仍旧跟随选中态变成 accent（蓝）——这条不能被顺手改掉。
        XCTAssertGreaterThan(accent.b, accent.r + 0.05,
                             "没传 iconColor 的选中行必须仍是 accent 蓝，"
                             + "实得 rgb=(\(accent.r), \(accent.g), \(accent.b))")
        // ③ 两臂必须真的不同 —— 否则上面两条可能都在量同一片背景。
        let delta = abs(tinted.r - accent.r) + abs(tinted.g - accent.g) + abs(tinted.b - accent.b)
        XCTAssertGreaterThan(delta, 0.1, "两臂墨迹必须有肉眼可见的差：delta=\(delta)")
    }

    /// 没选中时显式 `iconColor` 一直是生效的（改动不能把这条弄丢）。
    func testUnselectedRowStillUsesExplicitIconColor() throws {
        defer { closeAllWindows() }

        let tinted = try iconInk(selected: false, iconColor: Self.groupRed)
        let plain = try iconInk(selected: false, iconColor: nil)
        print(String(format: "[sidebar-dot-idle] tinted rgb=(%.3f, %.3f, %.3f)  "
                     + "plain rgb=(%.3f, %.3f, %.3f)",
                     tinted.r, tinted.g, tinted.b, plain.r, plain.g, plain.b))

        XCTAssertGreaterThan(tinted.r, tinted.b + 0.05, "未选中行的圆点也是分组色")
        // 中性灰：三通道彼此接近。
        XCTAssertLessThan(abs(plain.r - plain.b), 0.05,
                          "没传 iconColor 的未选中行是中性灰，"
                          + "实得 rgb=(\(plain.r), \(plain.g), \(plain.b))")
    }

    /// 欢迎页侧栏的接线不能掉：分组行必须把分组色传给 `UDSidebarRow`。
    func testWelcomeSidebarPassesGroupColorAsIconColor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeSidebar.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("iconColor: g.color"),
                      "分组行的圆点必须画成分组色 —— 上面两条墨迹闸门守的就是它")
    }
}
