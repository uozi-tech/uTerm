import AppKit
import SwiftUI
import UDesignKit

/// 设置 ▸ 命令行与技能。
///
/// 两块：本机 IPC 的两个门禁开关（落 `ControlSettings`，`observe` 会顺带起停
/// `ControlServer`），以及把内置技能装进各 AI CLI 的 `~/.<tool>/skills`
/// （落 `SkillManagerModel`，直接链到 app 包内的符号链接）。
struct CLISettingsView: View {
    /// 只链客户端到 PATH、不装技能的可选开关。默认关 —— 技能自带的那份才是主路径。
    @AppStorage(BinLinkInstaller.enabledDefaultsKey) private var linkToLocalBin = false

    @Environment(ControlSettings.self) private var settings
    @Environment(BackgroundServiceSettings.self) private var backgroundSettings
    @State private var skills = SkillManagerModel()
    @State private var copied = false

    var body: some View {
        SettingsScroll {
            interfaceGroup
            backgroundGroup
            skillsGroup
        }
        .task {
            backgroundSettings.refreshLoginItemStatus()
            await skills.load()
            await skills.reconcileBinLink(enabled: linkToLocalBin)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            backgroundSettings.refreshLoginItemStatus()
        }
    }

    private var backgroundGroup: some View {
        SettingsGroup(title: "后台服务") {
            SettingsRow(label: "登录后在后台启动", hint: "登录 macOS 后启动 uTerm 的本机服务，不弹窗口，也不显示 Dock 图标。") {
                UDToggle(Binding(
                    get: { backgroundSettings.launchAtLogin },
                    set: { backgroundSettings.setLaunchAtLogin($0) }
                ))
            }
            SettingsRow(label: "允许 CLI 按需启动", hint: "uTerm 未运行时，utermctl 可以静默启动一个后台实例并等待接口就绪。") {
                UDToggle(Binding(
                    get: { backgroundSettings.allowOnDemandLaunch },
                    set: { backgroundSettings.allowOnDemandLaunch = $0 }
                ))
            }
            if let error = backgroundSettings.loginItemError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(UD.danger)
            } else if backgroundSettings.needsLoginItemApproval {
                Text("等待系统批准。请前往系统设置 ▸ 通用 ▸ 登录项与扩展，允许 uTerm 后台项目。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.caution)
            } else if backgroundSettings.loginItemStatus == .notFound {
                Text("登录后台启动尚未注册，或系统尚未识别该组件。开启后会再次向系统注册。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.text3)
            }
        }
    }

    // MARK: - 接口

    private var interfaceGroup: some View {
        SettingsGroup(title: "命令行接口") {
            SettingsRow(
                label: "启用命令行接口",
                hint: "本机的 AI 工具可以经 uTerm 使用你已保存的主机执行命令、读写文件、启停隧道。密码与私钥不会离开 uTerm。"
            ) {
                UDToggle(
                    Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 })
                )
            }

            SettingsRow(
                label: "允许执行命令与写入",
                hint: "放开 run、SFTP 写入、端口转发启停与终端注入。执行任意 shell 命令等同于对该主机的完全访问，请按需开启。"
            ) {
                UDToggle(
                    Binding(get: { settings.allowMutations }, set: { settings.allowMutations = $0 })
                )
                .disabled(!settings.isEnabled)
                .opacity(settings.isEnabled ? 1 : 0.45)
            }

            socketRow

            if let error = settings.startupError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    private var socketRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("接口地址")
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                Text(settings.socketPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UD.text3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            SettingsInlineButton(title: copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(settings.socketPath, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }

    // MARK: - 技能

    @ViewBuilder
    private var skillsGroup: some View {
        SettingsGroup(title: "AI 技能") {
            if !skills.didLoad {
                emptyRow("正在检测本机的 AI 命令行工具…")
            } else if skills.availableTargets.isEmpty {
                emptyRow("没有检测到 Claude、Codex、Cursor 或 CodeBuddy 的命令行配置目录（~/.claude、~/.codex、~/.cursor、~/.codebuddy）。装好其中之一后回到这里即可安装技能。")
            } else {
                ForEach(skills.availableTargets, id: \.self) { target in
                    targetRow(target)
                }
            }

            binLinkRow

            if let error = skills.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            emptyRow(
                "安装会在该工具的 skills 目录里建符号链接，直接指向 uTerm.app 内的 "
                    + SkillDefinition.catalog.map(\.slug).joined(separator: "、")
                    + " 四份技能与 utermctl 客户端；uTerm 升级后技能内容自动跟着更新，移动 uTerm.app 后下次启动会自动改指。"
            )
        }
    }

    private func targetRow(_ target: SkillTarget) -> some View {
        let status = skills.status(for: target)
        let busy = skills.isBusy(target)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: target.iconSystemName)
                .font(.system(size: 14))
                .foregroundStyle(UD.text2)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                Text(status.conflictReason ?? statusHint(status))
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text3)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            statusPill(status)
            if status.canInstall {
                UDButton(title: "安装", style: .primary, isLoading: busy) {
                    Task { await skills.install(target) }
                }
                .disabled(busy)
            } else if status.canUninstall {
                UDButton(title: "卸载", style: .secondary, isLoading: busy) {
                    Task { await skills.uninstall(target) }
                }
                .disabled(busy)
            }
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }

    /// 可选的 PATH 链接。与技能安装分开：不装技能也能只要这条链接。
    private var binLinkRow: some View {
        SettingsRow(
            label: "同时链接到 ~/.local/bin/utermctl",
            hint: binLinkHint
        ) {
            UDToggle(Binding(
                get: { linkToLocalBin },
                set: { newValue in
                    linkToLocalBin = newValue
                    Task { await skills.setBinLinkEnabled(newValue) }
                }
            ))
            .disabled(skills.binLinkBusy)
        }
    }

    private var binLinkHint: String {
        let base = "让你在自己的终端里也能直接敲 utermctl。链接指向 uTerm.app 内的脚本，与技能自带的那份同源；移动 uTerm.app 后下次启动会自动改指。"
        switch skills.binLinkStatus {
        case .installed:
            return base + "（已链接）"
        case .conflict(let reason):
            return base + "（\(reason)）"
        case .brokenLink:
            return base + "（链接指向旧位置，关掉再打开开关即可修复）"
        case .notInstalled:
            return base
        }
    }

    private func statusHint(_ status: SkillInstallStatus) -> String {
        switch status {
        case .installed: return "技能已安装，可直接在对话里使用"
        case .notInstalled: return "尚未安装"
        case .brokenLink: return "链接指向旧位置或有技能缺失，点安装即可修复"
        case .conflict: return "目标位置被占用"
        }
    }

    private func statusPill(_ status: SkillInstallStatus) -> some View {
        let color: Color = switch status {
        case .installed: UD.accent
        case .brokenLink: UD.caution
        case .conflict: UD.danger
        case .notInstalled: UD.text4
        }
        return Text(status.displayLabel)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
            .overlay(Capsule(style: .continuous).stroke(color.opacity(0.35), lineWidth: 1))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(UD.text3)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}
