import SwiftUI

/// uTerm DesignKit 标签页 —— 编辑器 / 终端 Tab + 标签栏容器（设计稿 `Components.html` Tabs）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入与闭包回调，不依赖任何 domain model。
/// `UDPreviewTab` 用于编辑器 / 预览页（文档图标 + 脏标记）；`UDTermTab` 用于终端会话
/// （连接点 + 终端实体底）；`UDTabBar` 把若干 Tab 收进顶部圆角、底描边的标签栏。

// MARK: - 编辑器 / 预览 Tab

/// 编辑器 / 预览标签页。激活态顶部 2px accent 边、左右 1px 描边、实体面板底；
/// 非激活态透明，hover 提亮文本与底。脏标记为 accent 小圆点。
struct UDPreviewTab: View {
    let name: String
    var active: Bool = false
    var dirty: Bool = false
    /// 前导图标（默认通用文档；调用方可按文件类型传入）。
    var systemImage: String = "doc"
    /// 激活态底色（默认 `UD.panel`；调用方可传编辑器正文色保持无缝接缝）。
    var activeBackground: Color? = nil
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var hovered = false

    private let height: CGFloat = 36

    var body: some View {
        // 整片 tab 的「选中」用 `.onTapGesture`（手势），而不是把整片包成外层 `Button`。
        // macOS 上 `Button` 套 `Button` 时，外层控件会吞掉落在内层关闭按钮上的点击，
        // `onClose` 永不触发、tab 关不掉。手势会让位给子控件，内层关闭 `Button` 才能
        // 拦下自己区域的点击。
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(active ? UD.text2 : UD.text4)

            Text(name)
                .font(UD.mono(12))
                .foregroundStyle(active ? UD.text : (hovered ? UD.text2 : UD.text3))

            if dirty {
                Circle()
                    .fill(UD.accent)
                    .frame(width: 6, height: 6)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active || hovered ? UD.text3 : .clear)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(tabBackground)
        .overlay(activeTopBorder, alignment: .top)
        .overlay(activeSideBorders)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var tabBackground: some View {
        if active {
            activeBackground ?? UD.panel
        } else if hovered {
            UD.rowHover
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var activeTopBorder: some View {
        if active {
            Rectangle()
                .fill(UD.accent)
                .frame(height: 2)
        }
    }

    @ViewBuilder
    private var activeSideBorders: some View {
        if active {
            HStack(spacing: 0) {
                Rectangle().fill(UD.border).frame(width: 1)
                Spacer(minLength: 0)
                Rectangle().fill(UD.border).frame(width: 1)
            }
        }
    }
}

// MARK: - 终端 Tab

/// 终端会话标签页。前导为连接状态点（激活 success / 否则 text4，或调用方指定），
/// 激活态底为终端实体面（或调用方指定，以与下方终端正文无缝衔接）。
struct UDTermTab: View {
    let name: String
    var active: Bool = false
    /// 连接状态点色（默认按激活态 success / text4；调用方可传连接状态色）。
    var dotColor: Color? = nil
    /// 激活态底色（默认 `UD.terminal`；调用方可传终端正文色保持无缝接缝）。
    var activeBackground: Color? = nil
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var hovered = false

    private let height: CGFloat = 36

    var body: some View {
        // 整片 tab 的「选中」用 `.onTapGesture`（手势），而不是把整片包成外层 `Button`。
        // macOS 上 `Button` 套 `Button` 时，外层控件会吞掉落在内层关闭按钮上的点击，
        // `onClose` 永不触发、tab 关不掉。手势会让位给子控件，内层关闭 `Button` 才能
        // 拦下自己区域的点击。
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor ?? (active ? UD.success : UD.text4))
                .frame(width: 6, height: 6)

            Text(name)
                .font(UD.mono(12))
                .foregroundStyle(active ? UD.text : (hovered ? UD.text2 : UD.text3))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active || hovered ? UD.text3 : .clear)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(tabBackground)
        .overlay(activeTopBorder, alignment: .top)
        .overlay(activeSideBorders)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var tabBackground: some View {
        if active {
            activeBackground ?? UD.terminal
        } else if hovered {
            UD.rowHover
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var activeTopBorder: some View {
        if active {
            Rectangle()
                .fill(UD.accent)
                .frame(height: 2)
        }
    }

    @ViewBuilder
    private var activeSideBorders: some View {
        if active {
            HStack(spacing: 0) {
                Rectangle().fill(UD.border).frame(width: 1)
                Spacer(minLength: 0)
                Rectangle().fill(UD.border).frame(width: 1)
            }
        }
    }
}

// MARK: - 标签栏容器

/// 标签栏容器。底对齐排布若干 Tab，顶部圆角 8、四周 1px 描边、底 1px 描边、面板底。
struct UDTabBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            content
        }
        .background(UD.panel)
        .overlay(
            Rectangle()
                .fill(UD.border)
                .frame(height: 1),
            alignment: .bottom
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 8
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 8
            )
            .strokeBorder(UD.border, lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        UDTabBar {
            UDPreviewTab(name: "README.md", active: true)
            UDPreviewTab(name: "main.swift")
            UDPreviewTab(name: "Untitled.txt", dirty: true)
        }

        UDTabBar {
            UDTermTab(name: "zsh — node01", active: true)
            UDTermTab(name: "ssh — db02")

            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UD.text3)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
