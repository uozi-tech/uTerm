import SwiftUI

/// uTerm DesignKit 遥测页脚条 —— 窗口底部状态栏（设计稿 `Components.html` StatusBar）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// 单行等宽，左侧平台 / endpoint，右侧 uptime / load / cpu / mem / disk / time。

// MARK: - 单条遥测项

/// 状态栏 / 行内单条遥测项：图标 + 标签，整体按 `color` 着色。
struct UDFooterItem: View, Identifiable {
    let id = UUID()
    let systemImage: String
    let color: Color
    let label: String
    var iconSize: CGFloat = 11

    init(systemImage: String, color: Color, label: String, iconSize: CGFloat = 11) {
        self.systemImage = systemImage
        self.color = color
        self.label = label
        self.iconSize = iconSize
    }

    var body: some View {
        HStack(spacing: UD.Space.xxs) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .opacity(0.9)
            Text(label)
        }
        .font(UD.monoKbd)
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

// MARK: - 状态栏

/// 遥测页脚条：高 22、横向内边距 8、项间距 10、面板底 + 顶部 1px 描边。
struct UDStatusBar: View {
    let leading: [UDFooterItem]
    let trailing: [UDFooterItem]

    /// `nil` → 使用默认示例数据。
    init(items: [UDFooterItem]? = nil) {
        if let items {
            self.leading = items
            self.trailing = []
        } else {
            self.leading = UDStatusBar.sampleLeading
            self.trailing = UDStatusBar.sampleTrailing
        }
    }

    /// 自定义分组（前导组 + 尾随组）。
    init(leading: [UDFooterItem], trailing: [UDFooterItem]) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: UD.Space.md) {
            ForEach(leading) { $0 }
            Spacer(minLength: UD.Space.md)
            ForEach(trailing) { $0 }
        }
        .font(UD.monoKbd)
        .lineLimit(1)
        .padding(.horizontal, UD.Space.sm)
        .frame(height: 22)
        .background(UD.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(UD.border)
                .frame(height: 1)
        }
    }

    // MARK: 默认示例

    static let sampleLeading: [UDFooterItem] = [
        UDFooterItem(systemImage: "shippingbox", color: UD.mPlatform, label: "Ubuntu 22.04 LTS"),
        UDFooterItem(systemImage: "server.rack", color: UD.mEndpoint, label: "root@203.0.113.10:22"),
    ]

    static let sampleTrailing: [UDFooterItem] = [
        UDFooterItem(systemImage: "clock", color: UD.mUptime, label: "47d 16h"),
        UDFooterItem(systemImage: "waveform.path.ecg", color: UD.mLoad, label: "0.42"),
        UDFooterItem(systemImage: "cpu", color: UD.mCPU, label: "8x 2.40GHz"),
        UDFooterItem(systemImage: "chart.bar", color: UD.mMem, label: "1.2 GB · 30.0%"),
        UDFooterItem(systemImage: "cylinder.split.1x2", color: UD.mDisk, label: "42.1 GB · 21.0%"),
        UDFooterItem(systemImage: "calendar", color: UD.mEndpoint, label: "14:22:08"),
    ]
}

// MARK: - 版权页脚

/// 居中版权行（设计稿 about / 设置底部）。
struct UDCopyrightFooter: View {
    var body: some View {
        Text("© 2024–2026 uozi · All rights reserved")
            .font(UD.font(13))
            .foregroundStyle(UD.text4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

#Preview {
    VStack(spacing: UD.Space.xxxl) {
        UDStatusBar()
            .frame(width: 760)
            .clipShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                    .strokeBorder(UD.border, lineWidth: 1)
            )

        HStack(spacing: UD.Space.md) {
            UDFooterItem(systemImage: "cpu", color: UD.mCPU, label: "8x 2.40GHz")
            UDFooterItem(systemImage: "chart.bar", color: UD.mMem, label: "1.2 GB · 30.0%")
            UDFooterItem(systemImage: "clock", color: UD.mUptime, label: "47d 16h")
        }

        UDCopyrightFooter()
            .frame(width: 760)
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
