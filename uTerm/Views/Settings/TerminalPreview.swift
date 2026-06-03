import SwiftUI
import SwiftTerm

/// 设置 · 终端 tab 内的实时预览面板。用当前 settings 渲染 fake 终端
/// 输出（不接真 SwiftTerm，避免起 PTY）；改 setting 后立即可视。
struct TerminalPreview: View {
    let settings: TerminalSettings

    // SwiftTerm 也定义 Color 类型 —— 全限定 SwiftUI.Color 消歧
    private var bg: SwiftUI.Color { SwiftUI.Color(nsColor: settings.colorScheme.backgroundColor) }
    private var fg: SwiftUI.Color { SwiftUI.Color(nsColor: settings.colorScheme.foregroundColor) }

    private func ansi(_ idx: Int) -> SwiftUI.Color {
        let c = settings.colorScheme.ansiColors[idx]
        return SwiftUI.Color(
            red: Double(c.red) / 65535,
            green: Double(c.green) / 65535,
            blue: Double(c.blue) / 65535
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(settings.fontSize) * (settings.lineHeight - 1)) {
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(UD.border, lineWidth: 1)
        )
        .font(.system(size: CGFloat(settings.fontSize), design: .monospaced))
    }

    @ViewBuilder
    private func promptLine(cmd: String) -> some View {
        HStack(spacing: 0) {
            Text("root@demo-server").foregroundStyle(ansi(2))
            Text(":").foregroundStyle(fg.opacity(0.6))
            Text("~").foregroundStyle(ansi(4))
            Text("$ ").foregroundStyle(fg.opacity(0.6))
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
