import SwiftUI

/// uTerm DesignKit 菜单栏状态面板 —— macOS 菜单栏下拉的状态浮层
/// （设计稿 `Components.html` MenubarPanel）。
///
/// 纯展示组件：只读 `UD` token + 内部 `@State`，不依赖任何 domain model。
/// 自上而下分 5 段：品牌头部、分段切换、进行中会话列表、分隔线、动作列表。
/// 复用既有 `ULogo` 作为品牌标记。
struct UDMenubarPanel: View {
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            segmented
            runningList
            divider
            actionsList
        }
        .frame(width: 340)
        .background(UD.overlayHi)
        .overlay(
            // 浮层细发丝边：单层 UD.border（白 7% / 黑 10%）。
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .udShadow(.lg)
    }

    // MARK: - (a) 头部

    private var header: some View {
        HStack(spacing: 11) {
            ULogo(size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("uTerm")
                    .font(UD.font(13.5, weight: .semibold))
                    .foregroundStyle(UD.text)

                HStack(spacing: 6) {
                    Circle()
                        .fill(UD.success)
                        .frame(width: 6, height: 6)
                    Text("2 个会话进行中")
                        .font(UD.font(11))
                        .foregroundStyle(UD.text3)
                }
            }

            Spacer(minLength: 0)

            UDMenubarIconButton(systemImage: "arrow.up.right")
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - (b) 分段切换

    private var segmented: some View {
        HStack(spacing: 6) {
            UDMenubarPill(title: "进行中 2", selected: selection == 0) { selection = 0 }
            UDMenubarPill(title: "主机 4", selected: selection == 1) { selection = 1 }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - (c) 进行中列表

    private var runningList: some View {
        VStack(spacing: 0) {
            UDMenubarRunningRow(name: "demo-server", meta: "nginx · 12 分钟", color: UD.success)
            UDMenubarRunningRow(name: "api-prod-01", meta: "tail api.log · 4 分钟", color: UD.success)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    // MARK: - (d) 分隔线

    private var divider: some View {
        Rectangle()
            .fill(UD.border)
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: - (e) 动作列表

    private var actionsList: some View {
        VStack(spacing: 0) {
            UDMenubarActionRow(systemImage: "plus", label: "新建主机…", kbd: "⌘N")
            UDMenubarActionRow(systemImage: "magnifyingglass", label: "命令面板…", kbd: "⌘K")
            UDMenubarActionRow(systemImage: "gearshape", label: "设置…", kbd: "⌘,")
            UDMenubarActionRow(systemImage: "power", label: "退出 uTerm", kbd: "⌘Q")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - 头部图标钮

private struct UDMenubarIconButton: View {
    let systemImage: String
    @State private var hovered = false

    var body: some View {
        Button {
        } label: {
            Image(systemName: systemImage)
                .font(UD.font(12))
                .foregroundStyle(UD.text3)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: UD.Radius.sm)
                        .fill(hovered ? UD.panelHover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - 分段药丸

private struct UDMenubarPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(UD.font(11.5, weight: .medium))
                .foregroundStyle(selected ? UD.text : UD.text3)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? UD.dyn(.white(0.08), .black(0.08)) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 进行中行

private struct UDMenubarRunningRow: View {
    let name: String
    let meta: String
    let color: Color
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(UD.font(12.5, weight: .medium))
                    .foregroundStyle(UD.text)
                Text(meta)
                    .font(UD.monoKbd)
                    .foregroundStyle(UD.text4)
            }

            Spacer(minLength: 0)

            Button {
            } label: {
                Text("聚焦")
                    .font(UD.font(11.5, weight: .medium))
                    .foregroundStyle(UD.text)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(UD.accent.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(UD.accent.opacity(0.33), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.sm)
                .fill(hovered ? UD.rowHover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        .onHover { hovered = $0 }
    }
}

// MARK: - 动作行

private struct UDMenubarActionRow: View {
    let systemImage: String
    let label: String
    let kbd: String
    @State private var hovered = false

    var body: some View {
        Button {
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(UD.font(12.5))
                    .foregroundStyle(UD.text3)
                    .frame(width: 16)

                Text(label)
                    .font(UD.font(12.5))
                    .foregroundStyle(UD.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(kbd)
                    .font(UD.mono(10))
                    .foregroundStyle(UD.text4)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.sm)
                    .fill(hovered ? UD.rowHover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

#Preview {
    UDMenubarPanel()
        .padding(40)
        .frame(width: 460, height: 560)
        .background(Color.black)
}
