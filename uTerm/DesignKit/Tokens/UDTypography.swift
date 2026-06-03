import SwiftUI

/// uTerm DesignKit 排版 token —— 设计稿字阶（`kit-core.jsx` TokensType）。
///
/// 界面用 SF Pro / system-ui；代码、数值、终端用等宽。层级靠字号 + 文本透明度，
/// 权重只用 400 / 500 / 600（`.regular` / `.medium` / `.semibold`）。
///
/// 等宽字体：设计稿首选 JetBrains Mono，回退 SF Mono / Menlo。工程未打包字体，
/// 这里直接用系统等宽（即设计稿 fallback 链），与 `WS.mono` 一致。
extension UD {
    // MARK: - 界面字阶 SF Pro Text
    /// 标题 28 / 600。
    nonisolated static let title   = Font.system(size: 28, weight: .semibold)
    /// 小节 16 / 500。
    nonisolated static let h2      = Font.system(size: 16, weight: .medium)
    /// 正文 13 / 400。
    nonisolated static let body    = Font.system(size: 13, weight: .regular)
    /// 控件 12.5 / 500。
    nonisolated static let control = Font.system(size: 12.5, weight: .medium)
    /// 次要 11 / 400。
    nonisolated static let caption = Font.system(size: 11, weight: .regular)

    // MARK: - 等宽字阶 JetBrains Mono（回退系统等宽）
    /// 终端 / 代码 12.5。
    nonisolated static let monoTerminal = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    /// 数值 / 指标 11。
    nonisolated static let monoMetric   = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// 键帽 / 标签 10.5。
    nonisolated static let monoKbd      = Font.system(size: 10.5, weight: .regular, design: .monospaced)

    // MARK: - 任意尺寸 helper
    /// 界面字体（SF Pro / system）。
    nonisolated static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// 等宽字体（设计稿 mono；系统等宽回退）。
    nonisolated static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
