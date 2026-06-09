import Foundation
import SwiftData

nonisolated protocol SSHConfigKeyStoring {
    func save(keyID: UUID, privateKey: String, passphrase: String?) throws
}

extension KeyStore: SSHConfigKeyStoring {}

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
    private let keyStore: any SSHConfigKeyStoring

    init(context: ModelContext, keyStore: any SSHConfigKeyStoring = KeyStore()) {
        self.context = context
        self.keyStore = keyStore
    }

    /// 纯函数：标记 existing。可单测（nonisolated static）。
    nonisolated static func plan(_ hosts: [ParsedSSHHost], existingNames: Set<String>) -> [ImportRow] {
        hosts.enumerated().map { idx, h in
            ImportRow(id: "\(idx)·\(h.alias)", host: h, existing: existingNames.contains(h.alias))
        }
    }

    struct Result: Equatable {
        var created = 0, updated = 0, keysImported = 0, keysLinked = 0, keysSkipped = 0
    }

    /// 对选中且非通配的行：建/更新 ServerProfile；IdentityFile 私钥（去重、无口令）导入密钥库。
    func run(rows: [ImportRow], selected: Set<String>, dir: URL) -> Result {
        var result = Result()
        var keyCache: [String: UUID] = [:]   // 已成功导入的真实路径 → SSHKey.id（去重）
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }

        let existing = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        let existingKeys = (try? context.fetch(FetchDescriptor<SSHKey>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
        let existingKeysByName = Dictionary(
            existingKeys.map { ($0.name, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var linkedExistingKeyIDs = Set<UUID>()
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

            if let keyID = existingKeyID(identityFiles: h.identityFiles, existingKeysByName: existingKeysByName) {
                profile.keyID = keyID
                profile.authMethod = .privateKey
                if linkedExistingKeyIDs.insert(keyID).inserted {
                    result.keysLinked += 1
                }
            } else if let keyID = importKey(
                identityFiles: h.identityFiles,
                dir: dir,
                result: &result,
                keyCache: &keyCache
            ) {
                profile.keyID = keyID
                profile.authMethod = .privateKey
            }
        }
        try? context.save()
        return result
    }

    private func existingKeyID(identityFiles: [String], existingKeysByName: [String: UUID]) -> UUID? {
        for identityFile in identityFiles {
            for name in SSHIdentityFileResolver.candidateKeyNames(for: identityFile) {
                if let keyID = existingKeysByName[name] { return keyID }
            }
        }
        return nil
    }

    /// 按 OpenSSH config 顺序尝试 IdentityFile。加密/不可读/不支持时继续尝试下一条；
    /// 全部失败才计一次跳过。
    private func importKey(identityFiles: [String], dir: URL, result: inout Result,
                           keyCache: inout [String: UUID]) -> UUID? {
        guard !identityFiles.isEmpty else { return nil }

        for identityFile in identityFiles {
            for url in SSHIdentityFileResolver.urls(for: identityFile, configDir: dir) {
                let cacheKey = url.standardizedFileURL.path
                if let cached = keyCache[cacheKey] { return cached }
                if let keyID = importKey(url: url, displayName: SSHIdentityFileResolver.displayName(for: identityFile),
                                         result: &result) {
                    keyCache[cacheKey] = keyID
                    return keyID
                }
            }
        }

        result.keysSkipped += 1
        return nil
    }

    /// 读私钥文件 → 解析 → 建 SSHKey + 钥匙串。加密/不可读/不支持 → 返回 nil。
    private func importKey(url: URL, displayName: String, result: inout Result) -> UUID? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        do {
            let parsed = try PrivateKeyImporter.resolve(pem: text, passphrase: nil)
            let material = try KeyImportInspector.inspect(rawText: text, parsed: parsed, comment: "")
            let key = SSHKey()
            key.name = displayName.isEmpty ? "imported-key" : displayName
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
            return nil
        }
    }
}

nonisolated enum SSHIdentityFileResolver {
    static func urls(for identityFile: String, configDir: URL,
                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let path = normalize(identityFile)
        guard !path.isEmpty else { return [] }

        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let normalizedURL = url.standardizedFileURL
            guard seen.insert(normalizedURL.path).inserted else { return }
            candidates.append(normalizedURL)
        }

        if path == "~" {
            append(homeDirectory)
        } else if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            append(homeDirectory.appendingPathComponent(suffix))
            appendSSHRelativeMapping(for: suffix, configDir: configDir, append: append)
        } else if path == "$HOME" {
            append(homeDirectory)
        } else if path.hasPrefix("$HOME/") {
            let suffix = String(path.dropFirst("$HOME/".count))
            append(homeDirectory.appendingPathComponent(suffix))
            appendSSHRelativeMapping(for: suffix, configDir: configDir, append: append)
        } else if path == "%d" {
            append(homeDirectory)
        } else if path.hasPrefix("%d/") {
            let suffix = String(path.dropFirst("%d/".count))
            append(homeDirectory.appendingPathComponent(suffix))
            appendSSHRelativeMapping(for: suffix, configDir: configDir, append: append)
        } else if path.hasPrefix("/") {
            append(URL(fileURLWithPath: path))
            if let relative = relativePathInsideSSHDirectory(path) {
                append(configDir.appendingPathComponent(relative))
            }
        } else {
            append(configDir.appendingPathComponent(path))
            append(homeDirectory.appendingPathComponent(path))
        }

        let basename = displayName(for: path)
        if !basename.isEmpty {
            append(configDir.appendingPathComponent(basename))
        }

        return candidates
    }

    static func displayName(for identityFile: String) -> String {
        let path = normalize(identityFile)
        let basename = (path as NSString).lastPathComponent
        return basename.isEmpty ? path : basename
    }

    static func candidateKeyNames(for identityFile: String) -> [String] {
        let displayName = displayName(for: identityFile)
        let withoutExtension = (displayName as NSString).deletingPathExtension
        var names: [String] = []
        for name in [displayName, withoutExtension] where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private static func normalize(_ identityFile: String) -> String {
        var text = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2,
           let first = text.first,
           let last = text.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            text.removeFirst()
            text.removeLast()
        }
        return text
    }

    private static func appendSSHRelativeMapping(for suffix: String, configDir: URL,
                                                 append: (URL) -> Void) {
        if let relative = relativePathInsideSSHDirectory(suffix) {
            append(configDir.appendingPathComponent(relative))
        }
    }

    private static func relativePathInsideSSHDirectory(_ path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.lastIndex(of: ".ssh"),
              index + 1 < components.count else { return nil }
        return components[(index + 1)...].joined(separator: "/")
    }
}
