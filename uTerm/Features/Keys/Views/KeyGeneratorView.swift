import UDesignKit
import SwiftUI
import USSHKit

/// 生成新密钥面板（设计稿 `keys.jsx` 的 `KeyGenerator`）。按已定方案**不设口令**
/// —— 生成的私钥明文存钟匙串（系统加密 + iCloud e2e）。生成在后台线程跑（RSA
/// 4096 约 1 秒），完成回主线程经 `onCreate` 落库。
struct KeyGeneratorView: View {
    let onCancel: () -> Void
    let onCreate: (SSHKey) -> Void

    @State private var name = ""
    @State private var type: SSHKeyKind = .ed25519
    @State private var rsaBits = 4096
    // 不用 `Host.current()`：它要做本机名解析，DNS 不通时会卡住主线程；而 `@State` 初值每次重建视图都会再算一遍。
    @State private var comment = NSUserName() + "@" + LANSyncCoordinator.localDeviceName()
    @State private var generating = false
    @State private var errorText: String?
    @State private var nameTouched = false

    private let keyStore = KeyStore()

    private enum KeyFamily: Hashable {
        case ed25519
        case rsa
        case ecdsa
    }

    private var familyBinding: Binding<KeyFamily> {
        Binding {
            switch type {
            case .ed25519: .ed25519
            case .rsa: .rsa
            case .ecdsaP256, .ecdsaP384, .ecdsaP521: .ecdsa
            }
        } set: { family in
            switch family {
            case .ed25519: type = .ed25519
            case .rsa: type = .rsa
            case .ecdsa: type = .ecdsaP256
            }
        }
    }

    private var isECDSA: Bool {
        switch type {
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: true
        case .ed25519, .rsa: false
        }
    }

    private var nameEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nameError: String? {
        (nameTouched && nameEmpty) ? "名称不能为空" : nil
    }

    private var canGenerate: Bool {
        !nameEmpty && !generating
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("生成新密钥").font(.system(size: 17, weight: .medium)).foregroundStyle(UD.text)
                    Text("私钥保存在钥匙串，永不离开本机；公钥可一键复制到服务器。")
                        .font(.system(size: 12)).foregroundStyle(UD.text3)
                }

                    DarkFormSection(title: "基础") {
                    DarkFormField(label: "名称", hint: "在 uTerm 内引用") {
                        UDTextField(placeholder: "例如：default", text: $name,
                                    errorMessage: nameError)
                            .accessibilityValue(nameError ?? "")
                            .onChange(of: name) { _, _ in nameTouched = true }
                    }
                    DarkFormField(label: "类型") {
                        UDSegmented(selection: familyBinding, options: [
                            (.ed25519, "ed25519（推荐）"), (.rsa, "RSA"), (.ecdsa, "ECDSA"),
                        ])
                    }
                    if isECDSA {
                        DarkFormField(label: "曲线") {
                            UDSegmented(selection: $type, options: [
                                (.ecdsaP256, "P-256"), (.ecdsaP384, "P-384"), (.ecdsaP521, "P-521"),
                            ])
                        }
                    }
                    if type == .rsa {
                        DarkFormField(label: "位数") {
                            UDSegmented(selection: $rsaBits, options: [
                                (2048, "2048"), (3072, "3072"), (4096, "4096"),
                            ])
                        }
                    }
                    DarkFormField(label: "注释", hint: "附在公钥末尾，便于辨识") {
                        UDTextField(placeholder: "", text: $comment, monospaced: true)
                    }
                }

                if let errorText {
                    Text(errorText).font(.system(size: 11.5)).foregroundStyle(UD.danger)
                }

                HStack(spacing: 10) {
                    Text(type == .rsa ? "生成约需 1 秒" : "立即生成")
                        .font(.system(size: 11)).foregroundStyle(UD.text4)
                    Spacer()
                    UDButton(title: "取消", style: .secondary, action: onCancel)
                    UDButton(title: generating ? "生成中…" : "生成密钥", action: generate)
                        .disabled(!canGenerate)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }

    private func generate() {
        generating = true
        errorText = nil
        let chosenType = type
        let bits = rsaBits
        let cmt = comment
        let nm = name

        Task {
            let result = await KeyGeneration.run(
                kind: chosenType, bits: bits, name: nm, comment: cmt, keyStore: keyStore)
            generating = false
            switch result {
            case .success(let key):
                onCreate(key)
            case .failure(.cancelled):
                return
            case .failure(.failed(let message)):
                errorText = message
            }
        }
    }
}
