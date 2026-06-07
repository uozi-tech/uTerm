import XCTest
import SwiftUI
import AppKit
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
        assertHex(UD.success, .darkAqua, 0x30D158, "success dark = #30D158")
        assertHex(UD.warning, .darkAqua, 0xFFD60A, "warning dark = #FFD60A")
        assertHex(UD.caution, .darkAqua, 0xFF9F0A, "caution dark = #FF9F0A")
        assertHex(UD.danger,  .darkAqua, 0xFF5A5A, "danger dark = #FF5A5A")
        assertHex(UD.info,    .darkAqua, 0x64D2FF, "info dark = #64D2FF")
    }

    func test_semantic_light_is_low_saturation_youthful() {
        assertHex(UD.success, .aqua, 0x4EB67C, "success light = soft sage")
        assertHex(UD.warning, .aqua, 0xDCB05B, "warning light = soft amber")
        assertHex(UD.caution, .aqua, 0xE08E52, "caution light = soft terracotta")
        assertHex(UD.danger,  .aqua, 0xD8625E, "danger light = soft rose")
        assertHex(UD.info,    .aqua, 0x4D9DD6, "info light = soft blue")
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

    // MARK: - 日间表面 / 中性色：暖中性白 + 纯黑叠加（去灰、不发蓝）

    func test_surfaces_light_are_warm_white() {
        assertHex(UD.bg,      .aqua, 0xFFFFFF, "bg light = 统一纯白 = UDInput 的白 #FFFFFF")
        assertHex(UD.panel,   .aqua, 0xFFFFFF, "panel light = 纯白 #FFFFFF")
        assertHex(UD.panelHi, .aqua, 0xEEEEEA, "panelHi light = 次面板 #EEEEEA")
        assertHex(UD.text,    .aqua, 0x1C1C1E, "text light = 中性主文字 #1C1C1E")
    }

    func test_neutrals_light_use_neutral_black() {
        assertHex(UD.panelHover,  .aqua, 0x000000, alpha: 0.05,  "panelHover = 纯黑@5%")
        assertHex(UD.border,      .aqua, 0x000000, alpha: 0.10,  "border = 纯黑@10%")
        assertHex(UD.borderHi,    .aqua, 0x000000, alpha: 0.16,  "borderHi = 纯黑@16%")
        assertHex(UD.text2,       .aqua, 0x000000, alpha: 0.56,  "text2 = 纯黑@56%")
        assertHex(UD.text3,       .aqua, 0x000000, alpha: 0.40,  "text3 = 纯黑@40%")
        assertHex(UD.text4,       .aqua, 0x000000, alpha: 0.26,  "text4 = 纯黑@26%")
        assertHex(UD.rowHover,    .aqua, 0x000000, alpha: 0.045, "rowHover = 纯黑@4.5%")
        assertHex(UD.rowSelected, .aqua, 0x007AFF, alpha: 0.13,  "rowSelected = accent-soft @13%")
    }

    // MARK: - 输入底：暗夜白叠加细底 / 日间纯白

    func test_input_bg_light_is_pure_white() {
        assertHex(UD.inputBg,     .aqua, 0xFFFFFF, alpha: 1, "inputBg light = white")
        assertHex(UD.inputBgSoft, .aqua, 0xFFFFFF, alpha: 1, "inputBgSoft light = white")
    }

    func test_input_bg_dark_is_faint_white_overlay() {
        assertHex(UD.inputBg,     .darkAqua, 0xFFFFFF, alpha: 0.035, "inputBg dark = white@3.5%")
        assertHex(UD.inputBgSoft, .darkAqua, 0xFFFFFF, alpha: 0.03,  "inputBgSoft dark = white@3%")
    }
}
