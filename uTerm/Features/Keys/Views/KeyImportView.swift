import UDesignKit
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 导入密钥面板（与 `KeyGeneratorView` 同处右详情区）。私钥正文可以直接粘贴，
/// 也可以「从文件读取…」或把文件拖进编辑框——三条路最后都落到同一个编辑框里，
/// 用户导入前能看到、能改。加密私钥会露出口令框。
///
/// 解析、查重、写钥匙串都在两端共用的 `KeyImport` 里，成功后经 `onCreate` 交回
/// 未插入的 `SSHKey` 由窗口落库。
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
                    Text("粘贴私钥内容，或从文件读取。私钥保存在钥匙串，开启 iCloud 钥匙串后会同步到你的其他设备。")
                        .font(.system(size: 12)).foregroundStyle(UD.text3)
                }

                DarkFormSection(title: String(localized: "基础", comment: "表单分组：基础信息")) {
                    DarkFormField(label: String(localized: "名称"), hint: String(localized: "留空则用文件名或 imported-key")) {
                        UDTextField(placeholder: String(localized: "例如：prod-deploy"), text: $name)
                    }
                }

                DarkFormSection(title: String(localized: "私钥")) {
                    keyEditor
                    HStack(spacing: 6) {
                        Text("支持 OpenSSH / PEM / PKCS#8，也可把文件拖进上面的框")
                            .font(.system(size: 11)).foregroundStyle(UD.text4)
                        Spacer(minLength: 8)
                        UDButton(title: String(localized: "粘贴"), style: .ghost, systemImage: "doc.on.clipboard",
                                 height: 26, action: pasteFromClipboard)
                        UDButton(title: String(localized: "从文件读取…"), style: .ghost, systemImage: "folder",
                                 height: 26, action: chooseFile)
                    }
                    if showsPassphrase {
                        DarkFormField(label: String(localized: "口令", comment: "私钥口令"), hint: String(localized: "此私钥已加密")) {
                            UDTextField(placeholder: String(localized: "私钥口令（不是主机登录密码）"), text: $passphrase,
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
                    UDButton(title: String(localized: "取消"), style: .secondary, action: onCancel)
                    UDButton(title: importing ? String(localized: "导入中…") : String(localized: "导入密钥"), isLoading: importing, action: runImport)
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
            errorText = String(localized: "剪贴板里没有文本")
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
        panel.message = String(localized: "选择 SSH 私钥文件")
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
            errorText = KeyImport.fileReadMessage(fileName: url.lastPathComponent, error: error)
        }
    }

    // MARK: - 导入

    private func runImport() {
        let text = normalizedText
        guard !text.isEmpty else { return }
        importing = true
        errorText = nil

        Task {
            let result = await KeyImport.run(
                normalizedText: text, name: name, passphrase: passphrase, existingKeys: existingKeys)
            importing = false
            switch result {
            case .success(let key):
                onCreate(key)
            case .failure(let failure):
                if case .needsPassphrase = failure { passphraseRequested = true }
                errorText = failure.message
            }
        }
    }
}
