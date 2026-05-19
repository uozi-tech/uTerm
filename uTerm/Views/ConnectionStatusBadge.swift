import SwiftUI

/// 连接状态的语义色调。视图层把它映射为具体颜色。
nonisolated enum StatusTint: Equatable, Sendable {
    case neutral, warning, success, caution, error

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .warning: return .yellow
        case .success: return .green
        case .caution: return .orange
        case .error: return .red
        }
    }
}

/// 把一个 `TerminalSession.ConnectionState` 映射为状态栏 / 工具栏要显示的
/// 文案与色调。纯映射，便于单测。
nonisolated struct ConnectionStatusDisplay: Equatable, Sendable {
    let tint: StatusTint
    let label: String

    init(state: TerminalSession.ConnectionState) {
        switch state {
        case .idle:
            tint = .neutral; label = "未连接"
        case .connecting:
            tint = .warning; label = "连接中"
        case .connected:
            tint = .success; label = "已连接"
        case .disconnected:
            tint = .caution; label = "已断开"
        case .failed:
            tint = .error; label = "连接失败"
        }
    }
}

/// 彩色圆点 +（可选）文字的连接状态徽标。
struct ConnectionStatusBadge: View {
    let state: TerminalSession.ConnectionState
    /// true = 圆点 + 文字；false = 仅圆点（紧凑，用于工具栏）。
    var showsLabel: Bool = true

    var body: some View {
        let display = ConnectionStatusDisplay(state: state)
        HStack(spacing: 5) {
            Circle()
                .fill(display.tint.color)
                .frame(width: 8, height: 8)
            if showsLabel {
                Text(display.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(display.label)
    }
}
