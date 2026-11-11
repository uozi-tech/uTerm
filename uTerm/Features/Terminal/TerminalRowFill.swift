import Foundation

/// 「按行填满」（user 定的显示规则，两端共用）：窗格高度除不尽一行时，不把不到一行的空白全堆在底部，而是把它摊进行距
/// （每行拉高几个像素），拉不完的零头再上下均分。全部按物理像素算（Ghostty 的格子高是整数像素）。
///
/// 规则：
/// 1. **行数只由自然行高定**：rows = ⌊H ÷ h0⌋（H = 视图高，h0 = 不加调整时的格子高）。拉伸不改变用户看到几行。
/// 2. **格子高** h = min(⌊H ÷ rows⌋, h0 + ⌊h0 ÷ 4⌋)，调整量 = h − h0（写进 surface 自己的 `adjust-cell-height`）。
///    h ≥ h0，且 H − rows·h0 < h0 ≤ h，所以 ⌊H ÷ h⌋ 仍是 rows——拉伸本身不会多出或少掉一行。
/// 3. **零头** r = H − rows·h（不封顶时 r ≤ rows − 1，也恒小于一行）：上面 ⌊r ÷ 2⌋、下面 ⌈r ÷ 2⌉。上面那份由宿主把
///    surface 视图往下挪（`TerminalSurfaceLink.rowFillOffset`），下面那份留在 surface 底部（引擎照常铺底色）。
///    宽度方向不动：列数、格子宽、右边的余量都和以前一样。
///
/// 取舍：
/// - **不在 rows 与 rows ± 1 之间挑余量最小的。** rows + 1 要把格子压到自然高度以下，字形上下会被裁、挤在一起；
///   rows − 1 为了「填得更满」藏掉一行内容，正是这条规则要避免的（不能为好看少给用户看东西）。所以行数固定，
///   只在「拉多少」和「零头怎么分」上做文章。
/// - **整数像素的代价**：行数多时（Mac 2x 屏 12pt 一行 28 px，窗格 40 行以上很常见）余量不到 rows 个像素时一个像素都
///   拉不了（每行要么都加 1、要么都不加），这时完全靠上下均分；行数少、格子大的时候（手机、分屏的小窗格）拉伸才是主力。
///   两种情况下每边的空白都不超过 ⌈r ÷ 2⌉ 像素（< 半行）。
/// - **封顶 25%**：只有 1–3 行的小窗格余量可能比一行的四分之一还多，全摊进去行距会大得像排版坏了；超出的部分照样
///   上下均分。4 行以上 ⌊H ÷ rows⌋ − h0 本来就 < h0 ÷ 4，封顶不起作用。
/// - 行高只在尺寸停稳之后调（换一次要给 surface 推一份配置、换字形网格），拖动、转屏、键盘升降途中不调。
nonisolated struct TerminalRowFill: Equatable, Sendable {
    /// 行数（与不调整时相同）。0 = 视图矮于一行，不调。
    let rows: Int
    /// 调整后的格子高（物理像素）。
    let cellHeight: Int
    /// 相对自然格子高的调整量（物理像素，≥ 0）。
    let adjustment: Int

    /// 最多拉高多少像素：自然格子高的四分之一。
    static func maxAdjustment(naturalCellHeight: Int) -> Int { max(0, naturalCellHeight / 4) }

    /// - viewHeight: 视图高（物理像素，引擎量的 surface 高）。
    /// - naturalCellHeight: 不加调整时的格子高（物理像素）。
    init(viewHeight: Int, naturalCellHeight: Int) {
        guard naturalCellHeight > 0, viewHeight >= naturalCellHeight else {
            rows = 0
            cellHeight = max(naturalCellHeight, 0)
            adjustment = 0
            return
        }
        rows = viewHeight / naturalCellHeight
        cellHeight = min(viewHeight / rows, naturalCellHeight + Self.maxAdjustment(naturalCellHeight: naturalCellHeight))
        adjustment = cellHeight - naturalCellHeight
    }

    /// 网格摆进视图后上下各剩多少像素：零头 r = H − rows·h，上 ⌊r ÷ 2⌋、下 ⌈r ÷ 2⌉。
    static func margins(viewHeight: Int, rows: Int, cellHeight: Int) -> (top: Int, bottom: Int) {
        let rest = max(0, viewHeight - rows * cellHeight)
        return (rest / 2, rest - rest / 2)
    }
}
