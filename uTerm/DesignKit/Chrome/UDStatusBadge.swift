import SwiftUI

/// uTerm DesignKit 状态徽章 —— 连接状态胶囊（设计稿 `Components.html` StatusBadge）。
///
/// 纯展示组件：只读 `UD` token + 一个 `State` 入参，不依赖任何 domain model。
/// 已连接 / 连接中带呼吸光晕（pulse），已断开 / 连接失败为静态点。
struct UDStatusBadge: View {
    /// 连接状态。决定点色、文案与是否呼吸。
    enum State {
        case idle
        case connected
        case connecting
        case disconnected
        case failed

        /// 状态点 / 光晕颜色。
        var color: Color {
            switch self {
            case .idle:         return UD.text3
            case .connected:    return UD.success
            case .connecting:   return UD.warning
            case .disconnected: return UD.caution
            case .failed:       return UD.danger
            }
        }

        /// 中文文案。
        var label: String {
            switch self {
            case .idle:         return "未连接"
            case .connected:    return "已连接"
            case .connecting:   return "连接中"
            case .disconnected: return "已断开"
            case .failed:       return "连接失败"
            }
        }

        /// 是否呼吸（光晕脉冲）。
        var pulse: Bool {
            switch self {
            case .connected, .connecting:       return true
            case .idle, .disconnected, .failed: return false
            }
        }
    }

    let state: State

    init(state: State) {
        self.state = state
    }

    @SwiftUI.State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 7

    var body: some View {
        HStack(spacing: UD.Space.xs) {
            dot
            Text(state.label)
                .font(UD.caption)
                .foregroundStyle(UD.text2)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(
            // 淡灰填充胶囊、无描边（v2）。
            Capsule()
                .fill(UD.dyn(.white(0.055), .black(0.065)))
        )
    }

    private var dot: some View {
        ZStack {
            if state.pulse && !reduceMotion {
                Circle()
                    .fill(state.color)
                    .opacity(0.2)
                    .padding(-1)
                    .scaleEffect(animate ? 1.1 : 0.9)
                    .opacity(animate ? 0.0 : 0.2)
                    .animation(
                        .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                        value: animate
                    )
                    .onAppear { animate = true }
            }
            Circle()
                .fill(state.color)
                .frame(width: dotSize, height: dotSize)
        }
        .frame(width: dotSize, height: dotSize)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: UD.Space.lg) {
        UDStatusBadge(state: .connected)
        UDStatusBadge(state: .connecting)
        UDStatusBadge(state: .disconnected)
        UDStatusBadge(state: .failed)
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
