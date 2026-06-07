import SwiftUI

extension Color {
    /// 用 0xRRGGBB 形式的整型构造颜色，alpha 默认为 1。
    /// 主要服务于 AppTheme 的 token 定义。
    /// 标 `nonisolated` 让 token 静态属性能在 nonisolated 上下文初始化（项目默认 MainActor 隔离）。
    nonisolated init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
