//
//  TerminalSurfaceCoordinator+CellHeight.swift
//  uTerm 本地补丁（不在上游）：单个 surface 的行高调整（`adjust-cell-height`）。
//

import Foundation
import GhosttyKit

extension TerminalSurfaceCoordinator {
    /// 把这个 surface 的格子高调整成「自然高度 + `pixels`」（物理像素；Ghostty 把字形在格子里垂直居中）。
    /// 宿主拿它把窗格高度除不尽一行的那点余量摊进行距（uTerm 的「按行填满」）。
    ///
    /// 做法是给这个 surface 单独推一份配置：app 此刻的配置加一行 `adjust-cell-height`
    /// （`TerminalController.uTermSurfaceConfig`）。引擎为它换一套字形网格、按新格子高重算尺寸（行列数由宿主保证不变），
    /// 经 IO 线程报一次 resize（`InMemoryTerminalSession` 把格子像素带在里面）。别的 surface 不受影响。
    /// 代价：每推一次要重新解析配置、建（或复用）一套字形网格，宿主只在尺寸停稳后推；配置里的其余项原样重放一遍
    /// （和 app 改配置时一样：光标默认样式、默认配色、mode 2031 的配色报告）。
    ///
    /// app 的配置之后整份推下来（切日夜、改设置）时这项归 0（`onConfigChange` 里清），宿主按新的格子高重新算。
    /// 没有 surface、值没变时什么也不做；配置解析失败返回 false。
    @discardableResult
    func setCellHeightAdjustment(_ pixels: Int) -> Bool {
        guard let controller, let raw = surface?.rawValue else { return false }
        guard pixels != cellHeightAdjustment else { return true }
        let extra = pixels == 0 ? "" : "adjust-cell-height = \(pixels)"
        guard let config = controller.uTermSurfaceConfig(appending: extra) else { return false }
        defer { ghostty_config_free(config) }
        isApplyingSurfaceConfig = true
        ghostty_surface_update_config(raw, config)
        isApplyingSurfaceConfig = false
        cellHeightAdjustment = pixels
        TerminalDebugLog.log(.metrics, "cell height adjustment=\(pixels)")
        return true
    }
}
