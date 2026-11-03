import USSHKit
import SwiftUI
import SwiftData

/// 生成新 SSH 密钥（设计稿 `KeyGen`）。纯 Swift 生成（`SSHKeyGenerator`），私钥明文存钥匙串
/// （`KeyStore`），公钥 + 元数据入库。生成的密钥不带口令——靠钥匙串加密保护。
struct KeyGenSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent

    @State private var name = ""
    @State private var kind: SSHKeyKind = .ed25519
    @State private var bits = 4096
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?
    /// 在途的生成任务：抽屉被取消 / 下滑关掉时取消它，生成完也不再落库。
    @State private var generation: Task<Void, Never>?

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("私钥保存在钥匙串，永不离开本机；公钥可一键复制到服务器。")
                        .font(M.sans(13)).foregroundStyle(M.text3).lineSpacing(2)

                    MField(label: "名称", hint: "在 uTerm 内引用") {
                        MInput(text: $name, placeholder: "例如：default")
                    }
                    MField(label: "类型") {
                        Picker("类型", selection: $kind) {
                            Text("ed25519（推荐）").tag(SSHKeyKind.ed25519)
                            Text("RSA").tag(SSHKeyKind.rsa)
                        }
                        .pickerStyle(.segmented)
                    }
                    if kind == .rsa {
                        MField(label: "位数") {
                            Picker("位数", selection: $bits) {
                                Text("2048").tag(2048)
                                Text("3072").tag(3072)
                                Text("4096").tag(4096)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    MField(label: "注释", hint: "附在公钥末尾，便于辨识") {
                        MInput(text: $comment, placeholder: "sz@laptop", mono: true)
                    }
                    if let error { Text(error).font(M.sans(12)).foregroundStyle(M.danger) }
                    MBtn(title: busy ? "生成中…" : "生成密钥", kind: .primary, full: true, disabled: !valid || busy) {
                        generate()
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .mReadableColumn()
            }
            .background(M.bg)
            .navigationTitle("生成新密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        // RSA-4096 要生成一到三秒，期间可以下滑或点「取消」：改前任务照样跑完、照样落库，
        // 结果是「取消了却多了一把钥匙」。
        .onDisappear { generation?.cancel() }
    }

    private func generate() {
        busy = true; error = nil
        let nm = name.trimmingCharacters(in: .whitespaces)
        let cm = comment.trimmingCharacters(in: .whitespaces)
        let kind = self.kind, bits = self.bits
        generation = Task {
            do {
                let gen = try await Task.detached(priority: .userInitiated) { () throws -> SSHKeyGenerator.GeneratedKey in
                    switch kind {
                    case .rsa: return try SSHKeyGenerator.generateRSA(bits: bits, comment: cm)
                    default:   return SSHKeyGenerator.generateEd25519(comment: cm)
                    }
                }.value
                guard !Task.isCancelled else { return }
                let key = SSHKey()
                key.name = nm
                key.type = kind
                key.bits = kind == .ed25519 ? 256 : bits
                key.comment = cm
                key.fingerprint = gen.fingerprint
                key.publicKey = gen.publicKey
                key.hasPassphrase = false
                // 先写钥匙串、成功了才插入模型：反过来的话钥匙串写失败时，已插入的空私钥
                // 记录会被下一次任意 save 一并落盘。
                try KeyStore().save(keyID: key.id, privateKey: gen.privateKeyText, passphrase: nil)
                context.insert(key)
                try? context.save()
                busy = false
                dismiss()
            } catch {
                busy = false
                self.error = "生成失败：\(error.localizedDescription)"
            }
        }
    }
}
