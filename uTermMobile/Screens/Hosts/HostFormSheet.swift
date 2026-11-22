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

    /// 表单字段（校验与写回见 `HostDraft`）。新建默认密码认证。
    @State private var draft = HostDraft()
    @State private var passwordRevealed = false
    /// 打开表单时读到的值。保存时只写用户真改过的字段：表单开着期间 CloudKit / 局域网
    /// 同步可能改了这台主机的分组、密钥等，整份写回会悄悄把它们改回旧值。
    @State private var original: HostDraft?
    @FocusState private var passwordFocused: Bool

    private var isEdit: Bool { host != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MInsetGroup(header: String(localized: "连接", comment: "主机表单分组：连接参数")) {
                        formInput(String(localized: "名称"), String(localized: "例如：prod-web-01"), $draft.name, autocap: .sentences)
                        formInput(String(localized: "主机地址"), String(localized: "example.com 或 10.0.0.1"), $draft.host)
                        formInput(String(localized: "端口"), "22", $draft.port, keyboard: .numberPad, last: false)
                        formInput(String(localized: "用户名"), "root", $draft.username, last: true)
                    }

                    MInsetGroup(header: String(localized: "认证", comment: "主机表单分组：认证方式")) {
                        Picker("方式", selection: $draft.auth) {
                            Text("密码").tag(AuthMethod.password)
                            Text("SSH 密钥").tag(AuthMethod.privateKey)
                        }
                        .pickerStyle(.segmented)
                        .padding(12)

                        if draft.auth == .password {
                            MRowDivider()
                            HStack(spacing: 4) {
                                Text("密码").font(M.sans(15)).foregroundStyle(M.text)
                                Spacer()
                                Group {
                                    if passwordRevealed {
                                        TextField("••••••••", text: $draft.password)
                                    } else {
                                        SecureField("••••••••", text: $draft.password)
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
                                MInsetRow(label: String(localized: "未找到密钥"), sub: String(localized: "先在「设置 › SSH 密钥」中添加"), last: true)
                            } else {
                                ForEach(Array(keys.enumerated()), id: \.element.id) { idx, key in
                                    keyRow(key, last: idx == keys.count - 1)
                                }
                            }
                        }
                    }

                    MInsetGroup(header: String(localized: "选项", comment: "主机表单分组")) {
                        formInput(String(localized: "分组", comment: "主机所属分组"), String(localized: "如 prod / dev（可空）"), $draft.group, autocap: .never, last: false)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("仅 SFTP").font(M.sans(15)).foregroundStyle(M.text)
                                Text("禁用终端，只允许文件浏览").font(M.sans(12)).foregroundStyle(M.text3)
                            }
                            Spacer()
                            MSwitch(on: $draft.sftpOnly)
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
                    Button("保存") { save() }.disabled(!draft.isValid).fontWeight(.semibold)
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
        let selected = draft.keyID == key.id
        let check: AnyView? = selected ? AnyView(MIcon(name: "check", size: 15, color: accent)) : nil
        return MInsetRow(icon: "key", label: key.name, sub: key.typeLabel,
                  last: last, trailing: check, onTap: { draft.keyID = key.id })
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
        draft = HostDraft(from: host)
        original = draft
    }

    private func save() {
        // 只写改过的字段；主机在表单打开期间被同步删掉时什么都不写（返回 nil）。
        let saved = draft.save(original: original, to: host, context: context)
        if host == nil, let saved { onSaved?(saved) }
        dismiss()
    }
}
