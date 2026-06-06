import Foundation
import SwiftData

/// 导入预览的一行。`existing` = 已有同名 ServerProfile。
nonisolated struct ImportRow: Identifiable, Equatable {
    let id: String          // = host.alias
    let host: ParsedSSHHost
    let existing: Bool
}

/// 把解析出的 host 映射成 ServerProfile，并导入 IdentityFile 私钥。
@MainActor
struct SSHConfigImporter {
    let context: ModelContext

    /// 纯函数：标记 existing。可单测（nonisolated static）。
    nonisolated static func plan(_ hosts: [ParsedSSHHost], existingNames: Set<String>) -> [ImportRow] {
        hosts.enumerated().map { idx, h in
            ImportRow(id: "\(idx)·\(h.alias)", host: h, existing: existingNames.contains(h.alias))
        }
    }

    private let keyStore = KeyStore()

    struct Result: Equatable {
        var created = 0, updated = 0, keysImported = 0, keysSkipped = 0
    }

    /// 对选中且非通配的行：建/更新 ServerProfile；IdentityFile 私钥（去重、无口令）导入密钥库。
    func run(rows: [ImportRow], selected: Set<String>, dir: URL) -> Result {
        var result = Result()
        var keyCache: [String: UUID] = [:]   // IdentityFile 基名 → SSHKey.id（去重）
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }

        let existing = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        for row in rows where selected.contains(row.id) && !row.host.isWildcard {
            let h = row.host
            let profile: ServerProfile
            if row.existing, let found = existing.first(where: { $0.name == h.alias }) {
                profile = found; result.updated += 1
            } else {
                profile = ServerProfile(); profile.name = h.alias
                context.insert(profile); result.created += 1
            }
            profile.host = h.hostName
            profile.username = h.user
            profile.port = h.port

            if let idf = h.identityFile {
                let base = (idf as NSString).lastPathComponent
                if let cached = keyCache[base] {
                    profile.keyID = cached
                    profile.authMethod = .privateKey
                } else if let keyID = importKey(basename: base, dir: dir, result: &result) {
                    keyCache[base] = keyID
                    profile.keyID = keyID
                    profile.authMethod = .privateKey
                }
            }
        }
        try? context.save()
        return result
    }

    /// 读 dir 下的私钥文件 → 解析 → 建 SSHKey + 钥匙串。加密/不可读/不支持 → 跳（返回 nil）。
    private func importKey(basename: String, dir: URL, result: inout Result) -> UUID? {
        let url = dir.appendingPathComponent(basename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            result.keysSkipped += 1; return nil
        }
        do {
            let parsed = try PrivateKeyImporter.resolve(pem: text, passphrase: nil)
            let material = try KeyImportInspector.inspect(rawText: text, parsed: parsed, comment: "")
            let key = SSHKey()
            key.name = basename.isEmpty ? "imported-key" : basename
            key.type = material.type
            key.bits = material.bits
            key.fingerprint = material.fingerprint
            key.publicKey = material.publicKey
            key.hasPassphrase = false
            try keyStore.save(keyID: key.id, privateKey: text, passphrase: nil)
            context.insert(key)
            result.keysImported += 1
            return key.id
        } catch {
            result.keysSkipped += 1; return nil
        }
    }
}
