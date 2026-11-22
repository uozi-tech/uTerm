import UDesignKit
import SwiftUI

/// 设置 · 终端 tab 内的实时预览面板。用当前 settings 渲染 fake 终端
/// 输出（不建真的终端，避免起 PTY）；改 setting 后立即可视。
struct TerminalPreview: View {
    let settings: TerminalSettings
    @Environment(\.colorScheme) private var scheme

    private var resolved: TerminalColorScheme { settings.colorScheme(dark: scheme == .dark) }
    private var bg: SwiftUI.Color { SwiftUI.Color(nsColor: resolved.backgroundColor) }
    private var fg: SwiftUI.Color { SwiftUI.Color(nsColor: resolved.foregroundColor) }

    private func ansi(_ idx: Int) -> SwiftUI.Color {
        let c = resolved.ansiColors[idx]
        return SwiftUI.Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }

    /// 跟真实终端一致使用系统等宽字体。
    private var previewFont: SwiftUI.Font {
        let size = CGFloat(TerminalSettings.fontSize)
        return SwiftUI.Font(TerminalSettings.textFont(ofSize: size))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(TerminalSettings.fontSize) * (TerminalSettings.lineHeight - 1)) {
            promptLine(cmd: "ls -la")
            outputLine(parts: [
                (ansi(6),       "drwxr-xr-x"),
                (fg,            "  4 root  staff   128 May 25 14:22 "),
                (ansi(4),       "src")
            ])
            outputLine(parts: [
                (ansi(6),       "-rw-r--r--"),
                (fg,            "  1 root  staff  2480 May 25 12:08 "),
                (fg,            "README.md")
            ])
            promptLine(cmd: "echo \"hello\"")
            outputLine(parts: [
                (ansi(1),       "error:"),
                (fg,            " not a git repository")
            ])
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        // 浅色下终端底与卡片同为白：留一条 hairline 才看得出预览框（深色下终端底 #000 落在卡片 #141414 上，线几乎不可见）。
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .font(previewFont)
        // 整块作为单个示意元素：VoiceOver 不逐行念假终端输出。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("终端外观实时预览")
    }

    @ViewBuilder
    private func promptLine(cmd: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: "root@demo-server").foregroundStyle(ansi(2))
            Text(verbatim: ":").foregroundStyle(fg.opacity(0.6))
            Text(verbatim: "~").foregroundStyle(ansi(4))
            Text(verbatim: "$ ").foregroundStyle(fg.opacity(0.6))
            Text(cmd).foregroundStyle(fg)
        }
    }

    @ViewBuilder
    private func outputLine(parts: [(SwiftUI.Color, String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<parts.count, id: \.self) { i in
                Text(parts[i].1).foregroundStyle(parts[i].0)
            }
        }
    }
}
