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
        HStack(spacing: 0) {
            sidebar.frame(width: 260)
            Rectangle().fill(UD.border).frame(width: 1)
            detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(UD.bg)
        .background(WorkspaceWindowAppearance())
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
                Button(action: startGenerating) {
                    Label("生成", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UD.text)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(UD.accent.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.accent.opacity(0.33), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: importKey) {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(UD.text2)
                        .padding(.horizontal, 10).frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
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
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        let filename = url.deletingPathExtension().lastPathComponent
        do {
            try finishImport(text: text, passphrase: nil, defaultName: filename)
        } catch PrivateKeyImportError.encryptedKeyNeedsPassphrase,
                PrivateKeyImportError.incorrectPassphrase {
            promptPassphraseAndImport(text: text, defaultName: filename)
        } catch {
            importErrorText = (error as? LocalizedError)?.errorDescription ?? "无法识别该私钥"
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
            importErrorText = (error as? LocalizedError)?.errorDescription ?? "口令错误或私钥无法解析"
        }
    }

    private func finishImport(text: String, passphrase: String?, defaultName: String) throws {
        let parsed = try PrivateKeyImporter.resolve(pem: text, passphrase: passphrase)
        let material: KeyImportInspector.Material
        do {
            material = try KeyImportInspector.inspect(rawText: text, parsed: parsed, comment: "")
        } catch {
            throw NSError(domain: "uTerm.keys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "密钥库目前只支持 ed25519 / RSA 密钥",
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
        let tint: Color = type == .ed25519 ? UD.accent : Color(hex: 0xFBBF24)
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(tint.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(tint.opacity(0.3), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "key.fill")
                .font(.system(size: size * 0.45)).foregroundStyle(tint))
    }
}
