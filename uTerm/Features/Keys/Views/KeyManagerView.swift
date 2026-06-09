import SwiftUI
import SwiftData
import AppKit

/// 密钥管理窗口（设计稿 `keys.jsx`）。集中式 SSH 密钥库：左列表 + 右详情，
/// 顶部可生成 / 导入。独立 `Window`，外观随全局主题。
///
/// 私钥正文走 `KeyStore`（钟匙串）；模型 `SSHKey` 只存可公开元数据。「使用此
/// 密钥的主机」从 `ServerProfile.keyID == key.id` 实时派生。
struct KeyManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKey.createdAt, order: .reverse) private var keys: [SSHKey]
    @Query private var profiles: [ServerProfile]

    @State private var selectedID: UUID?
    @State private var generating = false
    @State private var pendingDelete: SSHKey?
    @State private var importErrorText: String?

    private let keyStore = KeyStore()

    private var selected: SSHKey? { keys.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            KeysTitleBar()
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
                Rectangle().fill(UD.border).frame(width: 1)
                detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        // 自绘扁平 chrome：透明系统标题栏 + full-size content + 不透明 #101012 底，
        // 让位红绿灯由 KeysTitleBar 顶部预留。取代 WorkspaceWindowAppearance（保留系统
        // 暗夜标题栏）——后者正是「chrome 还是系统默认暗夜配色」的来源。
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "密钥管理"))
        .overlay { deleteConfirmOverlay }
        .alert("导入失败", isPresented: Binding(
            get: { importErrorText != nil },
            set: { if !$0 { importErrorText = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorText ?? "")
        }
        .onAppear { if selectedID == nil { selectedID = keys.first?.id } }
    }

    // MARK: - 左列表

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                UDButton(title: "生成", systemImage: "plus", action: startGenerating)
                UDButton(
                    title: "导入",
                    style: .secondary,
                    systemImage: "square.and.arrow.down",
                    action: importKey
                )
            }
            .padding(10)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }

            if keys.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(keys) { key in
                            KeyRow(key: key,
                                   hostCount: hostCount(for: key),
                                   selected: key.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = key.id; generating = false }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAddTraits(key.id == selectedID ? .isSelected : [])
                                .accessibilityLabel("\(key.name)，\(key.typeLabel)，\(hostCount(for: key)) 台主机")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("\(keys.count) 把密钥").foregroundStyle(UD.text4)
                Spacer()
                Label("钥匙串", systemImage: "lock.fill").foregroundStyle(UD.text4)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
        }
    }

    private var emptyList: some View {
        VStack(spacing: 6) {
            Text("还没有密钥").font(.system(size: 12)).foregroundStyle(UD.text4)
            Text("点击「生成」创建第一把密钥").font(.system(size: 11)).foregroundStyle(UD.text4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 12)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundStyle(UD.border))
        .padding(12)
    }

    // MARK: - 右详情 / 生成

    @ViewBuilder
    private var detailPane: some View {
        if generating {
            KeyGeneratorView(
                onCancel: { generating = false },
                onCreate: { created in
                    modelContext.insert(created)
                    try? modelContext.save()
                    selectedID = created.id
                    generating = false
                })
        } else if let key = selected {
            KeyDetailView(
                key: key,
                usedByNames: usedByNames(for: key),
                onRename: { newName in key.name = newName; try? modelContext.save() },
                onDelete: { pendingDelete = key })
            .id(key.id)
        } else {
            Text("选择一把密钥")
                .font(.system(size: 13)).foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 删除确认覆盖层

    @ViewBuilder
    private var deleteConfirmOverlay: some View {
        if let key = pendingDelete {
            KeyDeleteConfirm(
                key: key,
                hostCount: hostCount(for: key),
                onCancel: { pendingDelete = nil },
                onConfirm: {
                    deleteKey(key)
                    pendingDelete = nil
                })
        }
    }

    // MARK: - 派生

    private func profilesUsing(_ key: SSHKey) -> [ServerProfile] {
        profiles.filter { $0.keyID == key.id }
    }
    private func hostCount(for key: SSHKey) -> Int { profilesUsing(key).count }
    private func usedByNames(for key: SSHKey) -> [String] {
        profilesUsing(key).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - 动作

    private func startGenerating() {
        generating = true
        selectedID = nil
    }

    private func deleteKey(_ key: SSHKey) {
        keyStore.delete(keyID: key.id)
        // 解绑引用此密钥的服务器（连接时会回退/报缺密钥）。
        for p in profilesUsing(key) { p.keyID = nil }
        if selectedID == key.id { selectedID = nil }
        modelContext.delete(key)
        try? modelContext.save()
        selectedID = keys.first(where: { $0.id != key.id })?.id
    }

    /// 选文件 → 校验（必要时索口令）→ 落库。
    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 SSH 私钥文件"
        guard panel.runModal() == .OK else { return }
        guard let url = panel.url else { return }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            importErrorText = KeyImportErrorMessage.message(
                for: NSError(domain: "uTerm.keys", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "无法读取私钥文件",
                    NSLocalizedFailureReasonErrorKey: "读取 \(url.lastPathComponent) 时失败：\((error as NSError).localizedDescription)",
                    NSLocalizedRecoverySuggestionErrorKey: "请确认文件仍存在、当前用户有读取权限，并且它是文本格式的 SSH 私钥。",
                ]),
                fallback: "无法读取私钥文件"
            )
            return
        }

        let filename = url.deletingPathExtension().lastPathComponent
        do {
            try finishImport(text: text, passphrase: nil, defaultName: filename)
        } catch PrivateKeyImportError.encryptedKeyNeedsPassphrase,
                PrivateKeyImportError.incorrectPassphrase {
            promptPassphraseAndImport(text: text, defaultName: filename)
        } catch {
            importErrorText = KeyImportErrorMessage.message(for: error, fallback: "无法识别该私钥")
        }
    }

    private func promptPassphraseAndImport(text: String, defaultName: String) {
        let alert = NSAlert()
        alert.messageText = "私钥已加密"
        alert.informativeText = "请输入此私钥的口令以导入。"
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try finishImport(text: text, passphrase: field.stringValue, defaultName: defaultName)
        } catch {
            importErrorText = KeyImportErrorMessage.message(for: error, fallback: "口令错误或私钥无法解析")
        }
    }

    private func finishImport(text: String, passphrase: String?, defaultName: String) throws {
        let parsed = try PrivateKeyImporter.resolve(pem: text, passphrase: passphrase)
        let material: KeyImportInspector.Material
        do {
            material = try KeyImportInspector.inspect(rawText: text, parsed: parsed, comment: "")
        } catch {
            throw NSError(domain: "uTerm.keys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法加入密钥库",
                NSLocalizedFailureReasonErrorKey: "私钥解析成功，但无法生成密钥库所需的公钥或指纹元数据。",
                NSLocalizedRecoverySuggestionErrorKey: "请确认密钥算法为 RSA、Ed25519 或 ECDSA；如果仍失败，可用 ssh-keygen -y -f <key> 检查该私钥。",
            ])
        }
        let key = SSHKey()
        key.name = defaultName.isEmpty ? "imported-key" : defaultName
        key.type = material.type
        key.bits = material.bits
        key.fingerprint = material.fingerprint
        key.publicKey = material.publicKey
        key.hasPassphrase = (passphrase?.isEmpty == false)
        try keyStore.save(keyID: key.id, privateKey: text, passphrase: passphrase)
        modelContext.insert(key)
        try? modelContext.save()
        selectedID = key.id
        generating = false
    }
}

// MARK: - 列表行

private struct KeyRow: View {
    let key: SSHKey
    let hostCount: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            KeyAvatar(type: key.type, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selected ? UD.text : UD.text2)
                        .lineLimit(1)
                    if key.hasPassphrase {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(UD.text4)
                    }
                }
                Text("\(key.typeLabel) · \(hostCount) 主机")
                    .font(UD.mono(11)).foregroundStyle(UD.text4).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? UD.rowSelected : Color.clear))
        .padding(.horizontal, 6)
    }
}

private struct KeyAvatar: View {
    let type: SSHKeyKind
    let size: CGFloat

    var body: some View {
        let tint: Color = switch type {
        case .ed25519: UD.accent
        case .rsa: Color(hex: 0xFBBF24)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: Color(hex: 0x34D399)
        }
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(tint.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(tint.opacity(0.3), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "key.fill")
                .font(.system(size: size * 0.45)).foregroundStyle(tint))
    }
}

/// 密钥管理窗口自绘扁平标题栏（对齐工作区 / SFTP 的自绘 chrome）：左侧让位窗口红绿灯
/// （~68pt），居中钥匙图标 + "密钥管理"。40px 扁平 UD.panel 条 + 底部 1px 描边。
/// 替代 macOS 系统标题栏 —— 后者在暗夜下是更浅的系统灰，盖在设计稿 #101012 之上。
private struct KeysTitleBar: View {
    var body: some View {
        ZStack {
            HStack(spacing: 9) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.accent)
                Text("密钥管理")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: 68)   // 让位窗口红绿灯
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}
