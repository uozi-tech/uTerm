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
                    Text("私钥保存在钥匙串，开启 iCloud 钥匙串后会同步到你的其他设备；拷贝公钥后，把它添加到主机的 ~/.ssh/authorized_keys。")
                        .font(M.sans(13)).foregroundStyle(M.text3).lineSpacing(2)

                    MField(label: String(localized: "名称"), hint: String(localized: "在 uTerm 内引用")) {
                        MInput(text: $name, placeholder: String(localized: "例如：default"))
                    }
                    MField(label: String(localized: "类型")) {
                        Picker("类型", selection: $kind) {
                            Text("ed25519（推荐）").tag(SSHKeyKind.ed25519)
                            Text("RSA").tag(SSHKeyKind.rsa)
                        }
                        .pickerStyle(.segmented)
                    }
                    if kind == .rsa {
                        MField(label: String(localized: "位数", comment: "RSA 密钥位数")) {
                            Picker("位数", selection: $bits) {
                                Text("2048").tag(2048)
                                Text("3072").tag(3072)
                                Text("4096").tag(4096)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    MField(label: String(localized: "注释", comment: "SSH 公钥末尾的注释字段"), hint: String(localized: "附在公钥末尾，便于辨识")) {
                        MInput(text: $comment, placeholder: "sz@laptop", mono: true)
                    }
                    if let error { Text(error).font(M.sans(12)).foregroundStyle(M.danger) }
                    MBtn(title: busy ? String(localized: "生成中…") : String(localized: "生成密钥"), kind: .primary, full: true, disabled: !valid || busy) {
                        generate()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, MSheetMetrics.screenInset).padding(.vertical, 20)
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
        let name = self.name, comment = self.comment
        let kind = self.kind, bits = self.bits
        generation = Task {
            let result = await KeyGeneration.run(kind: kind, bits: bits, name: name, comment: comment)
            busy = false
            switch result {
            case .success(let key):
                context.insert(key)
                try? context.save()
                dismiss()
            case .failure(.cancelled):
                return
            case .failure(.failed(let message)):
                self.error = message
            }
        }
    }
}
