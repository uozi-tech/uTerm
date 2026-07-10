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
    @State private var selectedKey: UUID?
    @State private var group = ""
    @State private var sftpOnly = false

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
                            Divider().overlay(M.divider)
                            HStack {
                                Text("密码").font(M.sans(15)).foregroundStyle(M.text)
                                Spacer()
                                SecureField("••••••••", text: $password)
                                    .font(M.mono(14)).multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 180)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                        } else {
                            Divider().overlay(M.divider)
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

    @ViewBuilder
    private func keyRow(_ key: SSHKey, last: Bool) -> some View {
        let selected = selectedKey == key.id
        let check: AnyView? = selected ? AnyView(MIcon(name: "check", size: 15, color: accent)) : nil
        MInsetRow(icon: "key", label: key.name, sub: key.typeLabel,
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
            if !last { Divider().overlay(M.divider).padding(.leading, 14) }
        }
    }

    private func load() {
        guard let host else { return }
        name = host.name; hostAddr = host.host; port = String(host.port)
        username = host.username; auth = host.authMethod
        selectedKey = host.keyID; group = host.group ?? ""; sftpOnly = host.sftpOnly
        password = (try? KeychainStore().load(profileID: host.id, kind: .password)) ?? ""
    }

    private func save() {
        let profile = host ?? ServerProfile()
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.host = hostAddr.trimmingCharacters(in: .whitespaces)
        profile.port = Int(port) ?? 22
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.authMethod = auth
        profile.keyID = auth == .privateKey ? selectedKey : nil
        let g = group.trimmingCharacters(in: .whitespaces)
        profile.group = g.isEmpty ? nil : g
        profile.sftpOnly = sftpOnly

        if host == nil {
            profile.sortOrder = ServerProfileStore(context: context).nextSortOrder()
            context.insert(profile)
        }
        try? context.save()

        if auth == .password, !password.isEmpty {
            try? KeychainStore().save(password, profileID: profile.id, kind: .password)
        }
        if host == nil { onSaved?(profile) }
        dismiss()
    }
}
