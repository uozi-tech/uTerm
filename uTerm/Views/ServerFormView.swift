import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 新建 / 编辑一台服务器的 sheet 表单。非密钥字段写入 `ServerProfile`；
/// 密码 / passphrase / 私钥内容写入 `KeychainStore`。
struct ServerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建；非 nil = 编辑现有 profile。
    let editing: ServerProfile?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var passphrase = ""
    @State private var privateKeyContent: String?
    @State private var privateKeyFilename = ""

    @State private var useJumpHost = false
    @State private var jumpName = ""
    @State private var jumpHostAddr = ""
    @State private var jumpPort = "22"
    @State private var jumpUsername = ""
    @State private var jumpAuthMethod: AuthMethod = .password
    @State private var jumpPassword = ""
    @State private var jumpPassphrase = ""
    @State private var jumpPrivateKeyContent: String?
    @State private var jumpPrivateKeyFilename = ""

    private let keychain = KeychainStore()

    var body: some View {
        VStack(spacing: 0) {
            Text(editing == nil ? "新建服务器" : "编辑服务器")
                .font(.headline).padding()
            Form {
                serverSection(
                    title: "目标服务器",
                    name: $name, host: $host, port: $port, username: $username,
                    authMethod: $authMethod, password: $password, passphrase: $passphrase,
                    keyContent: $privateKeyContent, keyFilename: $privateKeyFilename
                )
                Section("跳板机") {
                    Toggle("通过跳板机连接", isOn: $useJumpHost)
                    if useJumpHost {
                        serverFields(
                            name: $jumpName, host: $jumpHostAddr, port: $jumpPort,
                            username: $jumpUsername, authMethod: $jumpAuthMethod,
                            password: $jumpPassword, passphrase: $jumpPassphrase,
                            keyContent: $jumpPrivateKeyContent, keyFilename: $jumpPrivateKeyFilename
                        )
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: loadForEditing)
    }

    private var isValid: Bool {
        !name.isEmpty && !host.isEmpty && !username.isEmpty && Int(port) != nil
            && (!useJumpHost || (!jumpHostAddr.isEmpty && !jumpUsername.isEmpty && Int(jumpPort) != nil))
    }

    @ViewBuilder
    private func serverSection(
        title: String,
        name: Binding<String>, host: Binding<String>, port: Binding<String>,
        username: Binding<String>, authMethod: Binding<AuthMethod>,
        password: Binding<String>, passphrase: Binding<String>,
        keyContent: Binding<String?>, keyFilename: Binding<String>
    ) -> some View {
        Section(title) {
            serverFields(name: name, host: host, port: port, username: username,
                         authMethod: authMethod, password: password, passphrase: passphrase,
                         keyContent: keyContent, keyFilename: keyFilename)
        }
    }

    @ViewBuilder
    private func serverFields(
        name: Binding<String>, host: Binding<String>, port: Binding<String>,
        username: Binding<String>, authMethod: Binding<AuthMethod>,
        password: Binding<String>, passphrase: Binding<String>,
        keyContent: Binding<String?>, keyFilename: Binding<String>
    ) -> some View {
        TextField("名称", text: name)
        TextField("主机地址", text: host)
        TextField("端口", text: port)
        TextField("用户名", text: username)
        Picker("认证方式", selection: authMethod) {
            Text("密码").tag(AuthMethod.password)
            Text("私钥").tag(AuthMethod.privateKey)
        }
        if authMethod.wrappedValue == .password {
            SecureField("密码", text: password)
        } else {
            HStack {
                Text(keyFilename.wrappedValue.isEmpty ? "未选择私钥" : keyFilename.wrappedValue)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("选择私钥…") { pickPrivateKey(into: keyContent, filename: keyFilename) }
            }
            SecureField("私钥口令（可选）", text: passphrase)
        }
    }

    /// 选取私钥文件后立即读取内容到内存，不保留文件路径。
    private func pickPrivateKey(into content: Binding<String?>, filename: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data, .text, UTType.item]
        panel.message = "选择 SSH 私钥文件"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        content.wrappedValue = text
        filename.wrappedValue = url.lastPathComponent
    }

    private func loadForEditing() {
        guard let editing else { return }
        name = editing.name
        host = editing.host
        port = String(editing.port)
        username = editing.username
        authMethod = editing.authMethod
        password = (try? keychain.load(profileID: editing.id, kind: .password)) ?? ""
        passphrase = (try? keychain.load(profileID: editing.id, kind: .passphrase)) ?? ""
        privateKeyContent = try? keychain.load(profileID: editing.id, kind: .privateKey)
        if privateKeyContent != nil { privateKeyFilename = "（已保存的私钥）" }
        if let jump = editing.jumpHost {
            useJumpHost = true
            jumpName = jump.name
            jumpHostAddr = jump.host
            jumpPort = String(jump.port)
            jumpUsername = jump.username
            jumpAuthMethod = jump.authMethod
            jumpPassword = (try? keychain.load(profileID: jump.id, kind: .password)) ?? ""
            jumpPassphrase = (try? keychain.load(profileID: jump.id, kind: .passphrase)) ?? ""
            jumpPrivateKeyContent = try? keychain.load(profileID: jump.id, kind: .privateKey)
            if jumpPrivateKeyContent != nil { jumpPrivateKeyFilename = "（已保存的私钥）" }
        }
    }

    private func save() {
        let profile = editing ?? ServerProfile()
        profile.name = name
        profile.host = host
        profile.port = Int(port) ?? 22
        profile.username = username
        profile.authMethod = authMethod
        writeSecrets(for: profile, authMethod: authMethod,
                     password: password, passphrase: passphrase, key: privateKeyContent)

        if useJumpHost {
            let jump = profile.jumpHost ?? ServerProfile()
            jump.name = jumpName.isEmpty ? "\(name) 跳板机" : jumpName
            jump.host = jumpHostAddr
            jump.port = Int(jumpPort) ?? 22
            jump.username = jumpUsername
            jump.authMethod = jumpAuthMethod
            writeSecrets(for: jump, authMethod: jumpAuthMethod,
                         password: jumpPassword, passphrase: jumpPassphrase, key: jumpPrivateKeyContent)
            profile.jumpHost = jump
        } else {
            if let oldJump = editing?.jumpHost {
                try? keychain.delete(profileID: oldJump.id, kind: .password)
                try? keychain.delete(profileID: oldJump.id, kind: .passphrase)
                try? keychain.delete(profileID: oldJump.id, kind: .privateKey)
                modelContext.delete(oldJump)
            }
            profile.jumpHost = nil
        }

        if editing == nil { modelContext.insert(profile) }
        try? modelContext.save()
        dismiss()
    }

    private func writeSecrets(for profile: ServerProfile, authMethod: AuthMethod,
                              password: String, passphrase: String, key: String?) {
        if authMethod == .password {
            try? keychain.save(password, profileID: profile.id, kind: .password)
            try? keychain.delete(profileID: profile.id, kind: .privateKey)
            try? keychain.delete(profileID: profile.id, kind: .passphrase)
        } else {
            if let key { try? keychain.save(key, profileID: profile.id, kind: .privateKey) }
            if !passphrase.isEmpty {
                try? keychain.save(passphrase, profileID: profile.id, kind: .passphrase)
            } else {
                try? keychain.delete(profileID: profile.id, kind: .passphrase)
            }
            try? keychain.delete(profileID: profile.id, kind: .password)
        }
    }
}
