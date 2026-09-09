import AppKit
import SwiftUI
import UDesignKit

/// 设置 ▸ 命令行与技能。
///
/// 两块：本机 IPC 的两个门禁开关（落 `ControlSettings`，`observe` 会顺带起停
/// `ControlServer`），以及把内置技能装进各 AI CLI 的 `~/.<tool>/skills`
/// （Wave 1 接 `SkillManagerModel`，符号链接安装）。
struct CLISettingsView: View {
    @Environment(ControlSettings.self) private var settings
    @State private var copied = false

    var body: some View {
        SettingsScroll {
            interfaceGroup
            skillsGroup
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

    // MARK: - 技能（Wave 1 接 SkillManagerModel）

    private var skillsGroup: some View {
        SettingsGroup(title: "AI 技能") {
            emptyRow("技能安装稍后接入")
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(UD.text3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}
