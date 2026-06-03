// uTerm/Views/HostDetailPanel.swift
import SwiftUI

/// 选中主机后右侧滑入的详情面板（设计稿 Variant A · DetailPanel）。
///
/// 这一栏正是设计稿要「填补右侧大量空白」的主角：默认选中第一台主机即可让它常驻。
/// 头部圆点 + 名称 + 分组 → 等宽 `user@host:port` → 2×2 元信息栅格 → 底部大号品牌
/// 「连接」按钮（带 ↵ 提示与柔光）。
///
/// 栅格映射到真实 `ServerProfile` 字段：端口 / 认证 / 上次连接 / 跳板机。设计稿原
/// 型里的「会话数」无对应真实数据，替换为同样真实且有用的「跳板机」。
struct HostDetailPanel: View {
    let profile: ServerProfile
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            endpointLine.padding(.top, 6)
            metaGrid.padding(.top, 22)
            Spacer(minLength: 16)
            connectButton
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.015))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(UD.border)
                .frame(width: 1)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            UDHostDot(pulse: true)
            Text(profile.name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            UDGroupChip(groupLabel)
        }
    }

    private var endpointLine: some View {
        Text("\(profile.username)@\(profile.host)\(Text(":\(profile.port)").foregroundColor(UD.text3))")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(UD.text2)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: meta grid

    private var metaGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ],
            alignment: .leading,
            spacing: 18
        ) {
            metaCell("端口", "\(profile.port)", mono: true)
            metaCell("认证", authLabel)
            metaCell("上次连接", WelcomeFormat.relative(profile.lastConnectedAt))
            metaCell("跳板机", jumpLabel)
        }
    }

    private func metaCell(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .tracking(0.5)
                .foregroundStyle(UD.text3)
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(UD.text)
                .lineLimit(1)
        }
    }

    // MARK: connect

    private var connectButton: some View {
        Button(action: onConnect) {
            HStack(spacing: 10) {
                Text("连接")
                    .font(.system(size: 13.5, weight: .medium))
                Text("↵")
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.18))
                    )
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(UD.accent)
            )
            .shadow(color: UD.accent.opacity(0.45), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: derived

    private var groupLabel: String {
        if let g = profile.group, !g.isEmpty { return g }
        return "未分组"
    }

    private var authLabel: String {
        profile.authMethod == .privateKey ? "SSH 密钥" : "密码"
    }

    private var jumpLabel: String {
        if let jump = profile.jumpHost, !jump.name.isEmpty { return jump.name }
        return "无"
    }
}
