import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 导入已有 SSH 私钥（对应 macOS `KeyImportView`）。私钥正文可以直接粘贴，也可以
/// 「从文件导入」（文件 App / iCloud 云盘）——两条路都落到同一个编辑框，导入前能看到、能改。
/// 加密私钥会露出口令框。解析、查重、写钥匙串走两端共用的 `KeyImport`。
struct KeyImportSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent
    @Query private var keys: [SSHKey]

    @State private var name = ""
    @State private var keyText = ""
    @State private var passphrase = ""
    /// 解析器明确要求口令时置位（`looksEncrypted` 判不出的格式兜底）。
    @State private var passphraseRequested = false
    @State private var importing = false
    @State private var error: String?
    @State private var choosingFile = false
    /// 在途的导入任务：抽屉关掉时取消，解析完也不再落库。
    @State private var task: Task<Void, Never>?

    private var normalizedText: String { KeyPasteText.normalize(keyText) }

    private var showsPassphrase: Bool {
        passphraseRequested || KeyPasteText.looksEncrypted(normalizedText)
    }

    private var canImport: Bool { !normalizedText.isEmpty && !importing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("粘贴私钥内容，或从文件导入。私钥保存在钥匙串，开启 iCloud 钥匙串后会同步到你的其他设备。")
                        .font(M.sans(13)).foregroundStyle(M.text3).lineSpacing(2)

                    MField(label: "名称", hint: "留空则用文件名或 imported-key") {
                        MInput(text: $name, placeholder: "例如：prod-deploy")
                    }

                    MField(label: "私钥", hint: "支持 OpenSSH / PEM / PKCS#8") {
                        VStack(alignment: .leading, spacing: 10) {
                            MTextArea(text: $keyText,
                                      placeholder: "-----BEGIN OPENSSH PRIVATE KEY-----\n在此粘贴私钥内容…\n-----END OPENSSH PRIVATE KEY-----",
                                      minHeight: 180)
                                .accessibilityLabel("私钥内容")
                            HStack(spacing: 10) {
                                // 系统 `PasteButton`：用户点它即视为授权，不弹「允许粘贴」询问；
                                // 自己读 `UIPasteboard.general.string` 每次都会弹。
                                PasteButton(payloadType: String.self) { strings in
                                    guard let text = strings.first, !text.isEmpty else { return }
                                    Task { @MainActor in keyText = text }
                                }
                                // 它只认系统按钮样式，旁边的按钮也用同一套 bordered 样式，两颗才等高同形。
                                Button { choosingFile = true } label: {
                                    Label("从文件导入", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                                Spacer(minLength: 0)
                            }
                            // PasteButton 不认 .large，两颗都停在默认尺寸才等高。
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.roundedRectangle(radius: 9))
                            .tint(accent)
                        }
                    }

                    if showsPassphrase {
                        MField(label: "口令", hint: "此私钥已加密") {
                            MInput(text: $passphrase, placeholder: "私钥口令（不是主机登录密码）",
                                   secure: true, revealable: true)
                        }
                    }

                    if let error {
                        Text(error).font(M.sans(12)).foregroundStyle(M.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    MBtn(title: importing ? "导入中…" : "导入密钥", kind: .primary, full: true,
                         disabled: !canImport, action: runImport)
                        .padding(.top, 4)
                }
                .padding(.horizontal, MSheetMetrics.screenInset).padding(.vertical, 20)
                .mReadableColumn()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(M.bg)
            .navigationTitle("导入密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { load(fileAt: url) }
            case .failure(let err): error = KeyImport.fileReadMessage(fileName: "所选文件", error: err)
            }
        }
        .onChange(of: keyText) { _, _ in
            error = nil
            passphraseRequested = false
        }
        // 编辑框里有内容时不让下滑关抽屉：一不小心就丢掉刚粘贴 / 敲进去的私钥。要走点「取消」。
        .interactiveDismissDisabled(!keyText.isEmpty || importing)
        .onDisappear { task?.cancel() }
    }

    // MARK: - 来源

    private func load(fileAt url: URL) {
        // 文件 App 交来的是沙盒外的 URL，读之前要申请安全作用域访问。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            keyText = try String(contentsOf: url, encoding: .utf8)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        } catch {
            self.error = KeyImport.fileReadMessage(fileName: url.lastPathComponent, error: error)
        }
    }

    // MARK: - 导入

    private func runImport() {
        let text = normalizedText
        guard !text.isEmpty else { return }
        importing = true
        error = nil
        task = Task {
            let result = await KeyImport.run(
                normalizedText: text, name: name, passphrase: passphrase, existingKeys: keys)
            importing = false
            switch result {
            case .success(let key):
                // 解析期间抽屉被关掉：钥匙串已写入，撤掉，免得留下没有记录的孤儿私钥。
                guard !Task.isCancelled else {
                    KeyStore().delete(keyID: key.id)
                    return
                }
                context.insert(key)
                try? context.save()
                dismiss()
            case .failure(let failure):
                if case .needsPassphrase = failure { passphraseRequested = true }
                error = failure.message
            }
        }
    }
}
