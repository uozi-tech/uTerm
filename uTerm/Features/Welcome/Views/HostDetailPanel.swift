import UDesignKit
// uTerm/Views/HostDetailPanel.swift
import SwiftUI
import AppKit

/// 选中主机后右侧滑入的详情面板（设计稿 Variant A · DetailPanel）。
///
/// 这一栏正是设计稿要「填补右侧大量空白」的主角：默认选中第一台主机即可让它常驻。
/// 头部圆点 + 名称 + 分组 → 等宽 `user@host:port` → 2×2 元信息栅格 → 底部两枚动作
/// 按钮：主操作「在工作区打开」（accent + ↵ 柔光）独占一行；其下并排两枚次操作——
/// 左「在终端中打开」（⌥↵，作为新标签进已有终端窗口）、右「SFTP 浏览文件」（⌘↵）。
///
/// 栅格映射到真实 `ServerProfile` 字段：端口 / 认证 / 上次连接 / 跳板机。设计稿原
/// 型里的「会话数」无对应真实数据，替换为同样真实且有用的「跳板机」。
///
/// 「仅 SFTP」主机（`profile.sftpOnly`）切换到禁用终端的形态：头部分组 chip 换成
/// `仅 SFTP` 强调徽标；「认证」格换成「协议 = 仅 SFTP」；动作区把「SFTP 浏览文件」
/// 升为主操作（accent + ↵），终端入口降级为带锁的禁用提示「终端会话已禁用 · 仅文件传输」。
struct HostDetailPanel: View {
    let profile: ServerProfile
    var groupColor: Color? = nil
    let onConnect: () -> Void
    let onOpenTerminal: () -> Void
    let onBrowseSFTP: () -> Void

    /// 刚复制过的字段（用于「已复制」瞬时反馈，非 nil 即显示）。
    @State private var copiedField: String?
    /// 反馈自动消失的代际令牌：快速连点时只让最后一次的清除生效。
    @State private var copiedToken = 0

    private var fullEndpoint: String { "\(profile.username)@\(profile.host):\(profile.port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            endpointLine.padding(.top, 6)
            metaGrid.padding(.top, 22)
            Spacer(minLength: 16)
            actionButtons
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        // 分区方案 v3.3：与左侧列表同为卡面色，靠 1pt 竖线分开（分隔线两侧同底色）。
        // 曾做成 panelHi 抬升块 + 6pt 间隙，「白卡里套灰卡」，用户要求返工。
        .overlay(alignment: .leading) { Rectangle().fill(UD.border).frame(width: 1) }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            HostAvatar(monogram: profile.monogram,
                       tint: groupColor,
                       reachability: HostReachabilityMonitor.shared.entry(for: profile),
                       size: 28)
            // 主机名点击即复制（与端点行同一套「已复制」反馈）。
            NameCopyButton(name: profile.name) { copy(profile.name, field: "name") }
            Spacer(minLength: 6)
            if profile.sftpOnly {
                SftpOnlyBadge()
            } else {
                UDGroupChip(groupLabel, tint: groupColor)
            }
        }
    }

    /// 端点行重设计为「点击即复制」：用户名 / 主机各为可点段（分别复制 user / IP），
    /// 尾部图标复制完整 `user@host:port`；复制后图标短暂变「✓ 已复制」。
    private var endpointLine: some View {
        HStack(spacing: 0) {
            EndpointCopyChip(text: profile.username, emphasized: false) {
                copy(profile.username, field: "user")
            }
            Text("@")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(UD.text3)
            EndpointCopyChip(text: profile.host, emphasized: true) {
                copy(profile.host, field: "host")
            }
            Text(":\(String(profile.port))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(UD.text3)
            Spacer(minLength: 6)
            copyAllControl
        }
        .animation(.easeInOut(duration: 0.15), value: copiedField != nil)
    }

    /// 尾部复制控件：默认是复制图标，复制后 1.4s 内显示「✓ 已复制」。点击复制完整端点。
    private var copyAllControl: some View {
        Button { copy(fullEndpoint, field: "all") } label: {
            Group {
                if copiedField != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                        Text("已复制")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UD.success)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("复制 \(fullEndpoint)")
    }

    /// 写剪贴板 + 触发瞬时「已复制」反馈（与 SFTP / 密钥详情的复制实现一致）。
    private func copy(_ value: String, field: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
        copiedToken += 1
        let token = copiedToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if token == copiedToken { copiedField = nil }
        }
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
            metaCell("上次连接", UTermFormat.relative(profile.lastConnectedAt))
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
                .truncationMode(.tail)
                .help(value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }

    // MARK: actions

    /// 底部动作区。普通主机：主操作「在工作区打开」（↵）一行，其下并排「在终端中打开」（⌥↵）
    /// 与「SFTP 浏览文件」（⌘↵）。
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
                HStack(spacing: 8) {
                    openTerminalButton
                    browseSFTPButton
                }
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
                .foregroundStyle(UD.text3)
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

    /// 次操作：软底 + ⌥↵ 键帽；⌥+回车在终端中打开。
    private var openTerminalButton: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 8) {
                Text("在终端中打开")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                KbdChip(text: "⌥↵")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(UD.fillSoft)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .option)
    }

    /// 次操作：软底 + ⌘↵ 键帽，复用通用 `KbdChip`；⌘+回车进 SFTP 浏览。
    private var browseSFTPButton: some View {
        Button(action: onBrowseSFTP) {
            HStack(spacing: 8) {
                Text("SFTP 浏览文件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                KbdChip(text: "⌘↵")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(UD.fillSoft)
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

/// 端点行里的可点复制段（用户名 / 主机）：等宽文本，hover 浅 accent 底，点击复制。
private struct EndpointCopyChip: View {
    let text: String
    /// 主机段更亮（UD.text），用户名段次级（UD.text2）。
    let emphasized: Bool
    let onCopy: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onCopy) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(emphasized ? UD.text : UD.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hover ? UD.accent.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("点击复制：\(text)")
    }
}

/// 详情头的主机名：点击复制。悬停叠中性灰底（悬停一律用灰，不用强调色）。
private struct NameCopyButton: View {
    let name: String
    let onCopy: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onCopy) {
            Text(name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover ? UD.panelHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .onHover { hover = $0 }
        .help("点击复制：\(name)")
    }
}

/// 「仅 SFTP」强调徽标 —— 标记仅允许文件传输（无终端会话）的主机。
/// 对齐设计稿 `variant-a.jsx · SftpOnlyBadge`：浅 accent 底 + accent 字。
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
                .fill(UD.accent.opacity(0.12))
        )
        .fixedSize()
    }
}
