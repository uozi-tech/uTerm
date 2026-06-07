// uTerm/Views/HostDetailPanel.swift
import SwiftUI

/// 选中主机后右侧滑入的详情面板（设计稿 Variant A · DetailPanel）。
///
/// 这一栏正是设计稿要「填补右侧大量空白」的主角：默认选中第一台主机即可让它常驻。
/// 头部圆点 + 名称 + 分组 → 等宽 `user@host:port` → 2×2 元信息栅格 → 底部两枚动作
/// 按钮：主操作「在工作区打开」（accent + ↵ 柔光）+ 次操作「SFTP 浏览文件」
/// （描边底 + ⌘↵）。原先单一「连接」按钮按设计稿拆成这两条独立动作。
///
/// 栅格映射到真实 `ServerProfile` 字段：端口 / 认证 / 上次连接 / 跳板机。设计稿原
/// 型里的「会话数」无对应真实数据，替换为同样真实且有用的「跳板机」。
///
/// 「仅 SFTP」主机（`profile.sftpOnly`）切换到禁用终端的形态：头部分组 chip 换成
/// `仅 SFTP` 强调徽标；「认证」格换成「协议 = 仅 SFTP」；动作区把「SFTP 浏览文件」
/// 升为主操作（accent + ↵），终端入口降级为带锁的禁用提示「终端会话已禁用 · 仅文件传输」。
struct HostDetailPanel: View {
    let profile: ServerProfile
    let onConnect: () -> Void
    let onBrowseSFTP: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            endpointLine.padding(.top, 6)
            metaGrid.padding(.top, 22)
            Spacer(minLength: 16)
            actionButtons
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
            if profile.sftpOnly {
                SftpOnlyBadge()
            } else {
                UDGroupChip(groupLabel)
            }
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
            if profile.sftpOnly {
                metaCell("协议", "仅 SFTP")
            } else {
                metaCell("认证", authLabel)
            }
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

    // MARK: actions

    /// 底部动作区。普通主机：主操作「在工作区打开」（↵）+ 次操作「SFTP 浏览文件」（⌘↵）。
    /// 「仅 SFTP」主机：主操作升为「SFTP 浏览文件」（↵），终端入口降级为带锁的禁用提示。
    @ViewBuilder
    private var actionButtons: some View {
        if profile.sftpOnly {
            VStack(spacing: 9) {
                sftpPrimaryButton
                terminalDisabledPill
            }
        } else {
            VStack(spacing: 9) {
                openWorkspaceButton
                browseSFTPButton
            }
        }
    }

    /// 「仅 SFTP」主操作：accent 实心 + 内嵌 ↵ 键帽 + 柔光，回车直达 SFTP 浏览。
    private var sftpPrimaryButton: some View {
        Button(action: onBrowseSFTP) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                Text("SFTP 浏览文件")
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

    /// 终端禁用提示：虚线描边 + 锁图标，非交互。对齐设计稿「终端会话已禁用 · 仅文件传输」。
    private var terminalDisabledPill: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
            Text("终端会话已禁用")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("仅文件传输")
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text4)
        }
        .foregroundStyle(UD.text3)
        .padding(.horizontal, 13)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(UD.fillFaint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(UD.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    /// 主操作：accent 实心 + 内嵌 ↵ 键帽 + 柔光，回车直达工作区。
    private var openWorkspaceButton: some View {
        Button(action: onConnect) {
            HStack(spacing: 10) {
                Text("在工作区打开")
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

    /// 次操作：描边软底 + ⌘↵ 键帽，复用通用 `KbdChip`；⌘+回车进 SFTP 浏览。
    private var browseSFTPButton: some View {
        Button(action: onBrowseSFTP) {
            HStack(spacing: 8) {
                Text("SFTP 浏览文件")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(UD.text)
                KbdChip(text: "⌘↵")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(UD.fillSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(UD.borderHi, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
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

/// 「仅 SFTP」强调徽标 —— 标记仅允许文件传输（无终端会话）的主机。
/// 对齐设计稿 `variant-a.jsx · SftpOnlyBadge`：accent 描边 + 浅 accent 底 + accent 字。
struct SftpOnlyBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .medium))
            Text("仅 SFTP")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.2)
        }
        .foregroundStyle(UD.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(UD.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(UD.accent.opacity(0.23), lineWidth: 1)
        )
        .fixedSize()
    }
}
