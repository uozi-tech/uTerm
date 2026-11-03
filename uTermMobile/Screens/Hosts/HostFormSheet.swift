import SwiftUI
import SwiftData

/// 新建 / 编辑服务器表单（真实写入 SwiftData + 钥匙串）。
struct HostFormSheet: View {
    let host: ServerProfile?
    /// 新建成功后回调（用于「保存后自动连接」）；编辑不触发。
    var onSaved: ((ServerProfile) -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\SSHKey.createdAt, order: .reverse)]) private var keys: [SSHKey]

    @State private var name = ""
    @State private var hostAddr = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var auth: AuthMethod = .password
    @State private var password = ""
    @State private var passwordRevealed = false
    @State private var selectedKey: UUID?
    @State private var group = ""
    @State private var sftpOnly = false
    /// 打开表单时读到的值。保存时只写用户真改过的字段：表单开着期间 CloudKit / 局域网
    /// 同步可能改了这台主机的分组、密钥等，整份写回会悄悄把它们改回旧值。
    @State private var original: Draft?
    @FocusState private var passwordFocused: Bool

    /// 表单里可编辑的全部字段（已规范化：去首尾空白、端口转成数字）。
    private struct Draft: Equatable {
        var name, host, username, group, password: String
        var port: Int
        var auth: AuthMethod
        var keyID: UUID?
        var sftpOnly: Bool
    }

    private var draft: Draft {
        Draft(name: name.trimmingCharacters(in: .whitespaces),
              host: hostAddr.trimmingCharacters(in: .whitespaces),
              username: username.trimmingCharacters(in: .whitespaces),
              group: group.trimmingCharacters(in: .whitespaces),
              password: password,
              port: Int(port) ?? 22,
              auth: auth,
              keyID: auth == .privateKey ? selectedKey : nil,
              sftpOnly: sftpOnly)
    }

    private var isEdit: Bool { host != nil }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !hostAddr.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(port) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MInsetGroup(header: "连接") {
                        formInput("名称", "生产 Web 服务器", $name, autocap: .sentences)
                        formInput("主机地址", "example.com 或 10.0.0.1", $hostAddr)
                        formInput("端口", "22", $port, keyboard: .numberPad, last: false)
                        formInput("用户名", "root", $username, last: true)
                    }

                    MInsetGroup(header: "认证") {
                        Picker("方式", selection: $auth) {
                            Text("密码").tag(AuthMethod.password)
                            Text("SSH 密钥").tag(AuthMethod.privateKey)
                        }
                        .pickerStyle(.segmented)
                        .padding(12)

                        if auth == .password {
                            MRowDivider()
                            HStack(spacing: 4) {
                                Text("密码").font(M.sans(15)).foregroundStyle(M.text)
                                Spacer()
                                Group {
                                    if passwordRevealed {
                                        TextField("••••••••", text: $password)
                                    } else {
                                        SecureField("••••••••", text: $password)
                                    }
                                }
                                .font(M.mono(14)).multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($passwordFocused)
                                .frame(maxWidth: 180)

                                MRevealButton(revealed: passwordRevealed, action: togglePasswordReveal)
                            }
                            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 11)
                        } else {
                            MRowDivider()
                            if keys.isEmpty {
                                MInsetRow(label: "未找到密钥", sub: "请先在「设置 › 密钥」中添加", last: true)
                            } else {
                                ForEach(Array(keys.enumerated()), id: \.element.id) { idx, key in
                                    keyRow(key, last: idx == keys.count - 1)
                                }
                            }
                        }
                    }

                    MInsetGroup(header: "选项") {
                        formInput("分组", "如 prod / dev（可空）", $group, autocap: .never, last: false)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("仅 SFTP").font(M.sans(15)).foregroundStyle(M.text)
                                Text("禁用终端，只允许文件浏览").font(M.sans(12)).foregroundStyle(M.text3)
                            }
                            Spacer()
                            MSwitch(on: $sftpOnly)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
                .padding(.top, 8).padding(.bottom, 40)
                .mReadableColumn()
            }
            .background(M.canvas)
            .navigationTitle(isEdit ? "编辑主机" : "新建主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid).fontWeight(.semibold)
                }
            }
        }
        .onAppear(perform: load)
    }

    /// 掩码 ⇄ 明文。`SecureField` 与 `TextField` 是两个不同的 UIKit 视图，换一个必然丢焦点
    /// —— 原来在编辑就等这拍界面更新落地后把焦点还回去，键盘不收。
    private func togglePasswordReveal() {
        let wasFocused = passwordFocused
        passwordRevealed.toggle()
        guard wasFocused else { return }
        Task {
            await Task.yield()
            passwordFocused = true
        }
    }

    private func keyRow(_ key: SSHKey, last: Bool) -> some View {
        let selected = selectedKey == key.id
        let check: AnyView? = selected ? AnyView(MIcon(name: "check", size: 15, color: accent)) : nil
        return MInsetRow(icon: "key", label: key.name, sub: key.typeLabel,
                  last: last, trailing: check, onTap: { selectedKey = key.id })
    }

    @ViewBuilder
    private func formInput(_ label: String, _ placeholder: String, _ binding: Binding<String>,
                           keyboard: UIKeyboardType = .default,
                           autocap: TextInputAutocapitalization = .never,
                           last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(M.sans(15)).foregroundStyle(M.text).frame(width: 78, alignment: .leading)
                TextField(placeholder, text: binding)
                    .font(M.sans(15)).foregroundStyle(M.text)
                    .keyboardType(keyboard).textInputAutocapitalization(autocap)
                    .autocorrectionDisabled().multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if !last { MRowDivider() }
        }
    }

    private func load() {
        guard let host else { return }
        name = host.name; hostAddr = host.host; port = String(host.port)
        username = host.username; auth = host.authMethod
        selectedKey = host.keyID; group = host.group ?? ""; sftpOnly = host.sftpOnly
        password = (try? KeychainStore().load(profileID: host.id, kind: .password)) ?? ""
        original = draft
    }

    private func save() {
        // 表单开着期间这台主机被同步删掉了：不往已删除的模型上写。
        if let host, host.isDeleted || host.modelContext == nil {
            dismiss()
            return
        }
        let profile = host ?? ServerProfile()
        let new = draft
        // 新建时没有基准，所有字段都算「改过」。
        let old = host == nil ? nil : original
        if new.name != old?.name { profile.name = new.name }
        if new.host != old?.host { profile.host = new.host }
        if new.port != old?.port { profile.port = new.port }
        if new.username != old?.username { profile.username = new.username }
        if new.auth != old?.auth { profile.authMethod = new.auth }
        if new.keyID != old?.keyID || new.auth != old?.auth { profile.keyID = new.keyID }
        if new.group != old?.group { profile.group = new.group.isEmpty ? nil : new.group }
        if new.sftpOnly != old?.sftpOnly { profile.sftpOnly = new.sftpOnly }

        if host == nil {
            profile.sortOrder = ServerProfileStore(context: context).nextSortOrder()
            context.insert(profile)
        }
        try? context.save()

        // 钥匙串 save 是 delete + add 并会经 iCloud 钥匙串广播，没改就不写。
        if new.auth == .password, !new.password.isEmpty, new.password != old?.password {
            try? KeychainStore().save(new.password, profileID: profile.id, kind: .password)
        }
        if host == nil { onSaved?(profile) }
        dismiss()
    }
}
