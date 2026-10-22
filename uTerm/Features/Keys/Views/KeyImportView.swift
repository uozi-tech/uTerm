import UDesignKit
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import USSHKit

/// 导入密钥面板（与 `KeyGeneratorView` 同处右详情区）。私钥正文可以直接粘贴，
/// 也可以「从文件读取…」或把文件拖进编辑框——三条路最后都落到同一个编辑框里，
/// 用户导入前能看到、能改。加密私钥会露出口令框。
///
/// 解析在后台线程跑（带口令的 OpenSSH 容器要跑 bcrypt_pbkdf，可达数百毫秒），
/// 成功后私钥写钥匙串，经 `onCreate` 交回未插入的 `SSHKey` 由窗口落库。
struct KeyImportView: View {
    /// 已有密钥，用来拦重复导入（按指纹）。
    let existingKeys: [SSHKey]
    let onCancel: () -> Void
    let onCreate: (SSHKey) -> Void

    @State private var name = ""
    @State private var keyText = ""
    @State private var passphrase = ""
    /// 解析器明确要求口令时置位（`looksEncrypted` 判不出的格式兜底）。
    @State private var passphraseRequested = false
    @State private var importing = false
    @State private var errorText: String?
    @State private var dropTargeted = false

    private let keyStore = KeyStore()

    private var normalizedText: String { KeyPasteText.normalize(keyText) }

    private var showsPassphrase: Bool {
        passphraseRequested || KeyPasteText.looksEncrypted(normalizedText)
    }

    private var canImport: Bool { !normalizedText.isEmpty && !importing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入密钥").font(.system(size: 17, weight: .medium)).foregroundStyle(UD.text)
                    Text("粘贴私钥内容，或从文件读取。私钥保存在钥匙串，永不离开本机。")
                        .font(.system(size: 12)).foregroundStyle(UD.text3)
                }

                DarkFormSection(title: "基础") {
                    DarkFormField(label: "名称", hint: "留空则用文件名或 imported-key") {
                        UDTextField(placeholder: "例如：prod-deploy", text: $name)
                    }
                }

                DarkFormSection(title: "私钥") {
                    keyEditor
                    HStack(spacing: 6) {
                        Text("支持 OpenSSH / PEM / PKCS#8，也可把文件拖进上面的框")
                            .font(.system(size: 11)).foregroundStyle(UD.text4)
                        Spacer(minLength: 8)
                        UDButton(title: "粘贴", style: .ghost, systemImage: "doc.on.clipboard",
                                 height: 26, action: pasteFromClipboard)
                        UDButton(title: "从文件读取…", style: .ghost, systemImage: "folder",
                                 height: 26, action: chooseFile)
                    }
                    if showsPassphrase {
                        DarkFormField(label: "口令", hint: "此私钥已加密") {
                            UDTextField(placeholder: "私钥口令（不是服务器登录密码）", text: $passphrase,
                                        isSecure: true, revealable: true)
                        }
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11.5)).foregroundStyle(UD.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Spacer()
                    UDButton(title: "取消", style: .secondary, action: onCancel)
                    UDButton(title: importing ? "导入中…" : "导入密钥", isLoading: importing, action: runImport)
                        .disabled(!canImport)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
        .onChange(of: keyText) { _, _ in
            errorText = nil
            passphraseRequested = false
        }
    }

    // MARK: - 编辑框

    private var keyEditor: some View {
        ZStack(alignment: .topLeading) {
            // 占位用 .opacity 切显隐而非 `if` 增删（同 QuickCommandForm：避免 ZStack 内 TextEditor 占位残影）。
            Text("-----BEGIN OPENSSH PRIVATE KEY-----\n在此粘贴私钥内容…\n-----END OPENSSH PRIVATE KEY-----")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(UD.text4)
                .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 12))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(keyText.isEmpty ? 1 : 0)
            TextEditor(text: $keyText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(UD.text)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 8))
                .accessibilityLabel("私钥内容")
        }
        .frame(minHeight: 200, maxHeight: 300)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.inputBg))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(UD.accent, lineWidth: 2)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in load(fileAt: url) }
            }
            return true
        }
    }

    // MARK: - 来源

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            errorText = "剪贴板里没有文本"
            return
        }
        keyText = text
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择 SSH 私钥文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(fileAt: url)
    }

    private func load(fileAt url: URL) {
        do {
            keyText = try String(contentsOf: url, encoding: .utf8)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        } catch {
            errorText = KeyImportErrorMessage.message(
                for: NSError(domain: "uTerm.keys", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "无法读取私钥文件",
                    NSLocalizedFailureReasonErrorKey: "读取 \(url.lastPathComponent) 时失败：\(FriendlyError.describe(error))",
                    NSLocalizedRecoverySuggestionErrorKey: "请确认文件仍存在、当前用户有读取权限，并且它是文本格式的 SSH 私钥。",
                ]),
                fallback: "无法读取私钥文件"
            )
        }
    }

    // MARK: - 导入

    private func runImport() {
        let text = normalizedText
        guard !text.isEmpty else { return }
        if KeyPasteText.isPublicKeyLine(text) {
            errorText = "这是公钥（.pub），不是私钥。请粘贴 -----BEGIN … PRIVATE KEY----- 开头的私钥内容。"
            return
        }
        let pass: String? = passphrase.isEmpty ? nil : passphrase
        importing = true
        errorText = nil

        Task {
            do {
                let material = try await Task.detached(priority: .userInitiated) {
                    try Self.inspect(text: text, passphrase: pass)
                }.value
                importing = false
                if let dup = existingKeys.first(where: { $0.fingerprint == material.fingerprint }) {
                    errorText = "密钥库里已有这把密钥：「\(dup.name)」。"
                    return
                }
                let key = SSHKey()
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                key.name = trimmedName.isEmpty ? "imported-key" : trimmedName
                key.type = material.type
                key.bits = material.bits
                key.fingerprint = material.fingerprint
                key.publicKey = material.publicKey
                key.hasPassphrase = pass != nil
                try keyStore.save(keyID: key.id, privateKey: text, passphrase: pass)
                onCreate(key)
            } catch PrivateKeyImportError.encryptedKeyNeedsPassphrase {
                importing = false
                passphraseRequested = true
                errorText = "此私钥已加密，请填写口令后再导入。"
            } catch PrivateKeyImportError.incorrectPassphrase where pass == nil {
                importing = false
                passphraseRequested = true
                errorText = "此私钥已加密，请填写口令后再导入。"
            } catch {
                importing = false
                errorText = KeyImportErrorMessage.message(
                    for: error,
                    fallback: pass == nil ? "无法识别该私钥" : "口令错误或私钥无法解析")
            }
        }
    }

    /// 解析 + 生成公钥 / 指纹元数据。后台线程调用。
    private nonisolated static func inspect(text: String, passphrase: String?) throws -> KeyImportInspector.Material {
        let parsed = try SSHPrivateKeyParser.parse(pem: text, passphrase: passphrase)
        do {
            return try KeyImportInspector.inspect(rawText: text, parsed: parsed, comment: "")
        } catch {
            throw NSError(domain: "uTerm.keys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法加入密钥库",
                NSLocalizedFailureReasonErrorKey: "私钥解析成功，但无法生成密钥库所需的公钥或指纹元数据。",
                NSLocalizedRecoverySuggestionErrorKey: "请确认密钥算法为 RSA、Ed25519 或 ECDSA；如果仍失败，可用 ssh-keygen -y -f <key> 检查该私钥。",
            ])
        }
    }
}
