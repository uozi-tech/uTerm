import Foundation
import Security

/// Reads and replaces the Keychain accounts represented by the full LAN snapshot.
/// Account names are generated only from local model identifiers; arbitrary remote
/// account names are never accepted during import.
nonisolated final class LANSyncSecretStore {
    nonisolated final class Transaction {
        private let keychain: KeychainStore
        private let backup: [String: String?]
        private var active = true

        init(keychain: KeychainStore, backup: [String: String?]) {
            self.keychain = keychain
            self.backup = backup
        }

        func commit() { active = false }

        func rollback() {
            guard active else { return }
            for (account, value) in backup {
                if let value { try? keychain.save(value, account: account) }
                else { try? keychain.delete(account: account) }
            }
            active = false
        }

    }

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func snapshot(profiles: [ServerProfile], keys: [SSHKey], providers: [AIProvider]) throws
        -> [LANSyncSecretRecord] {
        let accounts = Self.accounts(profiles: profiles, keys: keys, providers: providers)
        return try accounts.sorted().compactMap { account in
            guard let value = try load(account: account) else { return nil }
            return LANSyncSecretRecord(account: account, value: value)
        }
    }

    func beginReplace(_ records: [LANSyncSecretRecord], previousAccounts: Set<String>,
                      incomingAccounts: Set<String>) throws -> Transaction {
        let allowed = previousAccounts.union(incomingAccounts)
        guard records.allSatisfy({ allowed.contains($0.account) }) else {
            throw LANSyncTransportError.invalidMessage
        }
        guard Set(records.map(\.account)).count == records.count else {
            throw LANSyncTransportError.invalidMessage
        }
        let incoming = Dictionary(uniqueKeysWithValues: records.map { ($0.account, $0.value) })
        var backup: [String: String?] = [:]
        for account in allowed { backup[account] = try load(account: account) }
        do {
            for account in allowed {
                let current = backup[account] ?? nil
                // 只动真的变了的条目：`save` 是 delete + add，且每次都会经 iCloud 钥匙串
                // 广播一次；一百台主机就是几百次 IPC，绝大多数值其实没变。
                if let value = incoming[account] {
                    if value != current { try keychain.save(value, account: account) }
                } else if current != nil {
                    try keychain.delete(account: account)
                }
            }
        } catch let KeychainError.unexpectedStatus(status) where status == errSecMissingEntitlement {
#if DEBUG
            // Unsigned local builds cannot access an access-group Keychain. Keep the
            // model/protocol testable while preserving fail-closed behavior in release.
            return Transaction(keychain: keychain, backup: [:])
#else
            throw KeychainError.unexpectedStatus(status)
#endif
        } catch {
            let transaction = Transaction(keychain: keychain, backup: backup)
            transaction.rollback()
            throw error
        }
        return Transaction(keychain: keychain, backup: backup)
    }

    static func accounts(profiles: [ServerProfile], keys: [SSHKey], providers: [AIProvider]) -> Set<String> {
        accounts(profileIDs: profiles.map(\.id), keyIDs: keys.map(\.id),
                 providerIDs: providers.map(\.id), profileKeyIDs: profiles.compactMap(\.keyID))
    }

    static func accounts(profileIDs: [UUID], keyIDs: [UUID], providerIDs: [UUID],
                         profileKeyIDs: [UUID] = []) -> Set<String> {
        Set((profileIDs + profileKeyIDs + keyIDs).flatMap(profileAccounts)
            + providerIDs.map { $0.uuidString })
    }

    private static func profileAccounts(_ id: UUID) -> [String] {
        SecretKind.allCases.map { "\(id.uuidString)/\($0.rawValue)" }
    }

    private func load(account: String) throws -> String? {
        do {
            return try keychain.load(account: account)
        } catch let KeychainError.unexpectedStatus(status) where status == errSecMissingEntitlement {
#if DEBUG
            return nil
#else
            throw KeychainError.unexpectedStatus(status)
#endif
        }
    }
}

nonisolated private extension SecretKind {
    static var allCases: [SecretKind] { [.password, .passphrase, .privateKey] }
}
