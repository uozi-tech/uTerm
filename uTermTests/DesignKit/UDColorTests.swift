import XCTest
import SwiftUI
import AppKit
import UDesignKit
@testable import uTerm

/// 锁定 `UD` 语义 / 文件夹 / 输入 token 的深浅两套精确值（设计稿 --u-status-* /
/// --u-folder-* / --u-input-bg）。暗夜保持 iOS 鲜艳原值；日间为低饱和年轻化版
/// （oklch 转 sRGB）。`UD.dyn` 经 `Color(nsColor: dynamicProvider)` 构造，桥回
/// `NSColor` 后用 `performAsCurrentDrawingAppearance` 锁外观即可解析出具体值。
final class UDColorTests: XCTestCase {
    private func srgb(_ color: Color, _ appearance: NSAppearance.Name) -> (Double, Double, Double, Double) {
        var out: (Double, Double, Double, Double) = (0, 0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            out = (Double(ns.redComponent), Double(ns.greenComponent),
                   Double(ns.blueComponent), Double(ns.alphaComponent))
        }
        return out
    }

    private func assertHex(_ color: Color, _ appearance: NSAppearance.Name,
                           _ hex: UInt32, alpha: Double = 1,
                           _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let c = srgb(color, appearance)
        XCTAssertEqual(c.0, r, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(c.1, g, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(c.2, b, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(c.3, alpha, accuracy: 0.01, message, file: file, line: line)
    }

    // MARK: - 语义状态：暗夜鲜艳（原样）/ 日间低饱和

    func test_semantic_dark_stays_vivid_iOS() {
        // uAppKit 1.22.3 起深色语义色提亮（深色层级与对比度调整）。
        assertHex(UD.success, .darkAqua, 0x6ABE39, "success dark = #6ABE39")
        assertHex(UD.warning, .darkAqua, 0xD89614, "warning dark = #D89614")
        assertHex(UD.caution, .darkAqua, 0xE88B2A, "caution dark = #E88B2A（与 warning 区分）")
        assertHex(UD.danger,  .darkAqua, 0xF07070, "danger dark = #F07070")
        assertHex(UD.info,    .darkAqua, 0x4C9BF5, "info dark = #4C9BF5")
    }

    func test_semantic_light_is_low_saturation_youthful() {
        assertHex(UD.success, .aqua, 0x52C41A, "success light = #52C41A")
        assertHex(UD.warning, .aqua, 0xFAAD14, "warning light = #FAAD14")
        assertHex(UD.caution, .aqua, 0xFA8C16, "caution light = #FA8C16（与 warning 区分）")
        assertHex(UD.danger,  .aqua, 0xFF4D4F, "danger light = #FF4D4F")
        assertHex(UD.info,    .aqua, 0x1677FF, "info light = primary #1677FF")
    }

    // MARK: - 文件夹 / 图标：暗夜原样 / 日间 Finder 风格鲜亮蓝 + 柔青

    func test_folder_and_icon_dark_stays_original() {
        assertHex(UD.folder1,     .darkAqua, 0x5B8FD6, "folder1 dark")
        assertHex(UD.folder2,     .darkAqua, 0x79A9E8, "folder2 dark")
        assertHex(UD.folderArrow, .darkAqua, 0x0E2742, "folderArrow dark")
        assertHex(UD.iconTeal,    .darkAqua, 0x2DD4BF, "iconTeal dark")
    }

    func test_folder_light_is_finder_blue() {
        assertHex(UD.folder1,     .aqua, 0x2B86E6, "folder1 light = Finder 后片蓝")
        assertHex(UD.folder2,     .aqua, 0x4CA7F8, "folder2 light = Finder 前片亮蓝")
        assertHex(UD.folderArrow, .aqua, 0xFFFFFF, "folderArrow light = white")
        assertHex(UD.iconTeal,    .aqua, 0x0FB6AC, "iconTeal light = oklch(0.70 0.12 188) teal")
    }

    // MARK: - 文档图标：暗夜白叠加纸面 / 日间白纸 + 暖中性灰描边 + 折角

    func test_doc_dark_is_white_overlay() {
        assertHex(UD.docBg,     .darkAqua, 0xFFFFFF, alpha: 0.09, "docBg dark = white@9%")
        assertHex(UD.docLine,   .darkAqua, 0xFFFFFF, alpha: 0.26, "docLine dark = white@26%")
        assertHex(UD.docFold,   .darkAqua, 0xFFFFFF, alpha: 0.16, "docFold dark = white@16%")
        assertHex(UD.docDetail, .darkAqua, 0xFFFFFF, alpha: 0.32, "docDetail dark = white@32%")
    }

    func test_doc_light_is_white_paper() {
        assertHex(UD.docBg,     .aqua, 0xFFFFFF, "docBg light = 纯白纸")
        assertHex(UD.docLine,   .aqua, 0xC9C7C4, "docLine light = 暖中性灰描边")
        assertHex(UD.docFold,   .aqua, 0xEEEDEA, "docFold light = 暖白折角")
        assertHex(UD.docDetail, .aqua, 0xA8A6A3, "docDetail light = 暖灰内文线")
    }

    // MARK: - 日间表面 / 中性色：v2「填充即边界」定稿（纯白大表面 + 纯灰中性）

    func test_surfaces_light_are_pure_white_and_neutral_gray() {
        assertHex(UD.bg,      .aqua, 0xFFFFFF, "bg light = 纯白 #FFFFFF")
        assertHex(UD.panel,   .aqua, 0xFFFFFF, "panel light = 纯白 #FFFFFF")
        assertHex(UD.panelHi, .aqua, 0xF0F0F0, "panelHi light = #F0F0F0")
        assertHex(UD.pageBg,  .aqua, 0xF5F5F5, "pageBg light = 画布 #F5F5F5")
        assertHex(UD.text,    .aqua, 0x1F1F1F, "text light = #1F1F1F")
    }

    func test_neutrals_light_use_neutral_black() {
        assertHex(UD.panelHover,  .aqua, 0x000000, alpha: 0.04, "panelHover = 纯黑@4%（半透明，叠在任何面上都可见）")
        assertHex(UD.border,      .aqua, 0x000000, alpha: 0.065, "border = 纯黑@6.5%（uAppKit 1.9.4 起调淡；#F0F0F0 在白卡上看不见分隔线，再淡就没了）")
        assertHex(UD.borderHi,    .aqua, 0xE0E0E0, "borderHi = #E0E0E0（uAppKit 1.9.4 起调淡）")
        // 文本 ramp 真值 = 组件库调色板（Ant Design 预设）日间实色四阶。
        assertHex(UD.text2,       .aqua, 0x595959, "text2 = #595959（正文层）")
        assertHex(UD.text3,       .aqua, 0x8C8C8C, "text3 = #8C8C8C（次要信息层）")
        assertHex(UD.text4,       .aqua, 0xBFBFBF, "text4 = #BFBFBF（仅装饰 / 结构层）")
        assertHex(UD.rowHover,    .aqua, 0x000000, alpha: 0.04,  "rowHover = 纯黑@4%")
    }

    // MARK: - 行选中：canonical 设计里不是中性色，而是 accent tint

    /// uTerm 自有 DesignKit 时期 rowSelected = 中性黑 6%；收编到 UDesignKit 共享包后
    /// 改为 uTable canonical 的 v2 规则——导航类选中态（列表行 / pill / ⌘K 行 / 底部导航）
    /// = accent 14% 填充（与 `UD.accentTint` 同档），无 accent 描边。固定蓝，不随强调色切换。
    @MainActor
    func test_row_selected_is_blue_accent_tint() {
        assertHex(UD.rowSelected, .aqua,     0x1677FF, alpha: 0.12, "rowSelected light = 蓝 accent@12%")
        assertHex(UD.rowSelected, .darkAqua, 0x1668DC, alpha: 0.20, "rowSelected dark = 蓝 accent@20%（uAppKit 1.22.3 起）")
    }

    // MARK: - 输入底：v2 淡灰无描边（深=白 6% / 浅=黑 5%）

    func test_input_bg_light_is_faint_black_overlay() {
        assertHex(UD.inputBg,     .aqua, 0x000000, alpha: 0.05, "inputBg light = black@5%")
        assertHex(UD.inputBgSoft, .aqua, 0x000000, alpha: 0.04, "inputBgSoft light = black@4%")
    }

    func test_input_bg_dark_is_faint_white_overlay() {
        assertHex(UD.inputBg,     .darkAqua, 0xFFFFFF, alpha: 0.06, "inputBg dark = white@6%")
        assertHex(UD.inputBgSoft, .darkAqua, 0xFFFFFF, alpha: 0.05, "inputBgSoft dark = white@5%")
    }

    // MARK: - 模态遮罩：暗夜黑 35% / 日间无遮罩

    func test_backdrop_is_transparent_in_light_mode() throws {
        // UDesignKit 抽成共享包后 UD.backdrop 这个 token 已被移除，先跳过，等确认替代 token 再改回来。
        throw XCTSkip("UD.backdrop 已从 UDesignKit 移除")
    }

    // MARK: - 模态投影：暗夜保留深度 / 日间无 box-shadow

    func test_modal_shadow_color_is_clear_in_light_mode() {
        assertHex(UD.modalShadowColor, .aqua, 0x000000, alpha: 0,
                  "modalShadowColor light = clear")
        assertHex(UD.modalShadowColor, .darkAqua, 0x000000, alpha: 0.6,
                  "modalShadowColor dark = black@60%")
    }
}
