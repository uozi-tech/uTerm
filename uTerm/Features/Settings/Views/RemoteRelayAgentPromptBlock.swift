import AppKit
import SwiftData
import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 公网接入：「让 AI 部署 / 更新中继」展开的那一块。
///
/// Agent 靠 uterm 技能经 utermctl 操作用户已保存的主机，所以先把它要的前提列出来（命令行接口、
/// 写入开关、技能装没装），再给一段可以直接复制的提示词。提示词里没有任何密钥：配置由 uTerm
/// 自己经 SFTP 读取（`utermctl relay import`）。
struct RemoteRelayAgentPromptBlock: View {
    enum Purpose {
        case deploy
        case update
    }

    let purpose: Purpose
    /// 预选的主机（更新时是装着中继的那台）。
    var preselectedHost: UUID?

    @Environment(ControlSettings.self) private var control
    @Query(sort: \ServerProfile.name) private var profiles: [ServerProfile]
    @State private var skills = SkillManagerModel()
    @State private var hostID: UUID?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(missingPrerequisites, id: \.self) { text in
                SettingsInlineNote(tone: .warning, text: text)
            }
            if !missingPrerequisites.isEmpty {
                SettingsRow(label: "命令行与技能", hint: "在那一页打开两个开关、给你用的 AI 工具装上 uterm 技能") {
                    UDButton(title: "前往", style: .secondary) {
                        UserDefaults.standard.set(SettingsSection.cli.rawValue, forKey: SettingsTabSelection.key)
                    }
                }
            }
            if purpose == .deploy, !exec.isEmpty {
                SettingsRow(label: "装在哪台主机", hint: "也可以不选，让 AI 先问你") {
                    SettingsPicker(selection: $hostID,
                                   options: [(UUID?.none, String(localized: "让 AI 问我"))]
                                       + exec.map { (Optional($0.id), $0.name) },
                                   menuWidth: 240)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(UD.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.inputBg))
                HStack {
                    Text("贴给 Claude Code、Codex 等装了 uterm 技能的 AI 工具。提示词里没有密钥，配置由 uTerm 自己从服务器读取。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UD.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    UDButton(title: copied ? "已复制" : "复制提示词", style: .primary, systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 12)
        }
        .task {
            if hostID == nil { hostID = preselectedHost }
            await skills.load()
        }
    }

    /// 能跑命令的主机（只传文件的主机装不了服务）。
    private var exec: [ServerProfile] {
        profiles.filter { !$0.sftpOnly }
    }

    private var hostName: String? {
        let id = hostID ?? preselectedHost
        return id.flatMap { id in profiles.first { $0.id == id }?.name }
    }

    private var prompt: String {
        switch purpose {
        case .deploy: return RemoteRelayAgentPrompt.deploy(hostName: hostName)
        case .update: return RemoteRelayAgentPrompt.update(hostName: hostName)
        }
    }

    private var missingPrerequisites: [String] {
        var missing: [String] = []
        if !control.isEnabled { missing.append(String(localized: "命令行接口没有启用：AI 工具连不上 uTerm。")) }
        if !control.allowMutations { missing.append(String(localized: "「允许执行命令与写入」没有打开：AI 没法在主机上安装，也没法导入配置。")) }
        let installed = skills.availableTargets.contains { skills.status(for: $0) == .installed }
        if skills.didLoad, !installed { missing.append(String(localized: "还没有给任何 AI 工具安装 uterm 技能。")) }
        return missing
    }
}
