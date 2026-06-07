import SwiftUI
import SwiftData

/// 新建 / 编辑一台服务器的模态表单（设计稿 `new-server.jsx`）。外观随全局主题。
///
/// 字段写入 `ServerProfile`；密码写钟匙串（按 profile.id）；私钥改为**引用密钥库**
/// （`profile.keyID` 指向一把 `SSHKey`，私钥正文由密钥库的钟匙串条目承载）；跳板机
/// 改为**引用一台已有服务器**（`profile.jumpHost` 指向用户选中的 profile）。
struct ServerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    /// nil = 新建；非 nil = 编辑现有 profile。
    let editing: ServerProfile?

    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]
    @Query(sort: \SSHKey.createdAt, order: .reverse) private var allKeys: [SSHKey]

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var group = ""
    @State private var authMethod: AuthMethod = .privateKey
    @State private var password = ""
    @State private var keyID: UUID?
    @State private var sftpOnly = false
    @State private var useJumpHost = false
    @State private var jumpProfileID: UUID?

    @State private var keyPickerOpen = false
    @State private var jumpPickerOpen = false
    /// 主机字段是否已被用户编辑过——避免开屏即把必填项标红。
    @State private var hostTouched = false

    private let keychain = KeychainStore()

    private var selectedKey: SSHKey? { allKeys.first { $0.id == keyID } }

    /// 可作跳板机的服务器：除自己外的全部 profile。
    private var availableJumps: [ServerProfile] {
        allProfiles.filter { $0.id != editing?.id }
    }
    private var selectedJump: ServerProfile? { availableJumps.first { $0.id == jumpProfileID } }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(UD.border).frame(height: 1)
            formBody
            Rectangle().fill(UD.border).frame(height: 1)
            footer
        }
        .frame(width: 540)
        .frame(maxHeight: 640)
        .background(UD.bg)
        .background(WorkspaceWindowAppearance())
        .onAppear(perform: loadForEditing)
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        ZStack {
            Text(editing == nil ? "新建服务器" : "编辑服务器")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
            HStack {
                Spacer()
                UDIconButton(systemImage: "xmark") { dismiss() }
                    .accessibilityLabel("关闭")
                    .help("关闭")
            }
            .padding(.trailing, 10)
        }
        .frame(height: 44)
    }

    // MARK: - 表单体

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                targetSection
                groupSection
                sftpSection
                jumpSection
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
        }
    }

    private var targetSection: some View {
        DarkFormSection(title: "目标服务器") {
            DarkFormField(label: "名称") {
                UDTextField(placeholder: "例如：api-prod", text: $name)
            }
            HStack(alignment: .top, spacing: 10) {
                DarkFormField(label: "主机") {
                    UDTextField(placeholder: "host.example.com", text: $host,
                                errorMessage: hostError, monospaced: true)
                        .accessibilityValue(host.isEmpty ? "未填写" : host)
                        .onChange(of: host) { _, _ in hostTouched = true }
                }
                DarkFormField(label: "端口") {
                    UDTextField(placeholder: "22", text: $port,
                                errorMessage: portError, monospaced: true)
                        .accessibilityValue(port.isEmpty ? "未填写" : port)
                }
                .frame(width: 96)
            }
            DarkFormField(label: "用户名") {
                UDTextField(placeholder: "root", text: $username, monospaced: true)
            }
            DarkFormField(label: "认证方式") {
                UDSegmented(selection: $authMethod, options: [
                    (.password, "密码"), (.privateKey, "私钥"),
                ])
            }
            if authMethod == .password {
                DarkFormField(label: "密码") {
                    UDTextField(placeholder: "••••••••", text: $password, isSecure: true)
                }
            } else {
                DarkFormField(label: "密钥", hint: "从密钥管理器选择") {
                    KeySelectorView(
                        keys: allKeys, selected: selectedKey, open: $keyPickerOpen,
                        onPick: { keyID = $0; keyPickerOpen = false },
                        onManage: { openWindow(id: "keys") })
                }
            }
        }
    }

    private var groupSection: some View {
        DarkFormSection(title: "分组") {
            DarkFormField(label: "分组", hint: "可选") {
                UDTextField(placeholder: "例如：prod", text: $group)
            }
            if !existingGroups.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(existingGroups, id: \.self) { g in
                        UDSelectableGroupChip(label: g, selected: g == group) { group = g }
                    }
                }
            }
        }
    }

    /// 「仅 SFTP 连接」小节（设计稿 `new-server.jsx`）：与「跳板机」一致的开关样式。
    /// 关：提示默认开启终端会话；开：强调色说明卡，声明终端会话与命令执行均被禁用。
    private var sftpSection: some View {
        DarkFormSection(title: "仅 SFTP 连接", trailing: {
            UDToggle($sftpOnly)
        }) {
            if !sftpOnly {
                Text("默认开启终端会话，并可随时打开 SFTP 文件浏览。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UD.accent)
                        .padding(.top, 1)
                    Text("\(Text("仅 SFTP 文件传输").foregroundStyle(UD.text).fontWeight(.medium))。该主机将只能浏览与传输文件，\(Text("终端会话与命令执行均被禁用").foregroundStyle(UD.text3))。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(UD.accent.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(UD.accent.opacity(0.19), lineWidth: 1)
                )
            }
        }
    }

    private var jumpSection: some View {
        DarkFormSection(title: "跳板机", trailing: {
            UDToggle($useJumpHost)
        }) {
            if !useJumpHost {
                Text("如目标服务器在内网，可通过跳板机间接连接。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DarkFormField(label: "跳板机", hint: "只能从已有服务器中选择") {
                    JumpHostSelectorView(
                        hosts: availableJumps, selected: selectedJump, open: $jumpPickerOpen,
                        onPick: { jumpProfileID = $0; jumpPickerOpen = false })
                }
            }
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 10) {
            Text("密钥与口令仅保存在系统钥匙串")
                .font(.system(size: 11)).foregroundStyle(UD.text4)
            Spacer()
            UDButton(title: "取消", style: .secondary) { dismiss() }
            UDButton(title: "保存") { save() }
                .disabled(!isValid)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(UD.panel)
    }

    // MARK: - 校验

    private var isValid: Bool {
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty, hostError == nil, portError == nil else { return false }
        if authMethod == .privateKey, keyID == nil { return false }
        if useJumpHost, jumpProfileID == nil { return false }
        return true
    }

    /// 主机名 inline 校验：必填。仅在用户编辑过又清空时提示（避免开屏 / 编辑态即红）。
    private var hostError: String? {
        guard hostTouched else { return nil }
        return host.trimmingCharacters(in: .whitespaces).isEmpty ? "请填写主机地址" : nil
    }

    /// 端口 inline 校验：必须是 1–65535 的整数。空 / 非法均给出提示。
    private var portError: String? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let p = Int(trimmed) else { return "端口必须是数字" }
        guard (1...65535).contains(p) else { return "端口需在 1–65535 之间" }
        return nil
    }

    /// 已有的非空分组名，去重 + locale 排序。
    private var existingGroups: [String] {
        Set(allProfiles.compactMap { p -> String? in
            let g = p.group ?? ""
            return g.isEmpty ? nil : g
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - 载入 / 保存

    private func loadForEditing() {
        guard let editing else { return }
        name = editing.name
        host = editing.host
        port = String(editing.port)
        username = editing.username
        group = editing.group ?? ""
        authMethod = editing.authMethod
        keyID = editing.keyID
        sftpOnly = editing.sftpOnly
        password = (try? keychain.load(profileID: editing.id, kind: .password)) ?? ""
        if let jump = editing.jumpHost {
            useJumpHost = true
            jumpProfileID = jump.id
        }
    }

    private func save() {
        let isNew = editing == nil
        let profile = editing ?? ServerProfile()
        profile.name = name
        profile.host = host
        profile.port = Int(port) ?? 22
        profile.username = username
        if isNew {
            profile.sortOrder = ServerProfileStore(context: modelContext).nextSortOrder()
        }
        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.group = trimmedGroup.isEmpty ? nil : trimmedGroup
        if let g = profile.group {
            GroupStore(context: modelContext).ensure(name: g)
        }
        profile.authMethod = authMethod
        profile.sftpOnly = sftpOnly

        if authMethod == .password {
            try? keychain.save(password, profileID: profile.id, kind: .password)
            profile.keyID = nil
        } else {
            profile.keyID = keyID
            // 私钥正文不再按 profile.id 存（改由密钥库承载）；清掉可能存在的旧密码。
            try? keychain.delete(profileID: profile.id, kind: .password)
        }

        profile.jumpHost = useJumpHost ? availableJumps.first { $0.id == jumpProfileID } : nil

        if isNew { modelContext.insert(profile) }
        try? modelContext.save()
        dismiss()
    }
}
