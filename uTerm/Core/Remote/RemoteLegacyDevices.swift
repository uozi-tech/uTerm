import Foundation

/// 退役的一对一确认（旧「我的设备」）留下的数据，启动时清掉。设备组（`RemoteGroupRoster`）换了 service，
/// 不读这些。旧版没发布过，只有测试设备上有，所以同步的那份整个 service 删掉（删除会经 iCloud 钥匙串同步到别的设备）。
nonisolated enum RemoteLegacyDevices {
    /// 旧名册（iCloud 钥匙串）。
    static let service = "com.uozi.uTerm.remote.devices"
    /// 旧的本机状态（和远控身份同一个 service）：确认过谁、承诺、认可的担保者、撤销进度。
    static let localAccounts = ["siblingApprovals", "siblingCommits", "siblingVouchers", "siblingRevocations"]

    /// 删一遍；本来就没有不算错，所以每次启动都调也无妨。
    static func retire(synced: any RemoteSyncedStorage, secrets: any RemoteSecretStorage) {
        try? synced.deleteAll()
        for account in localAccounts { try? secrets.delete(account) }
    }

    /// 启动时调：钥匙串删除可能慢（同步的那份要等 iCloud），放到后台线程。测试宿主里什么都不做：
    /// 它的存储本来就是内存里的（`RemoteLocalState`），这里再明说一次，免得以后有人换了默认存储。
    static func retireLocalLeftovers() {
        guard !RemoteLocalState.isIsolated else { return }
        DispatchQueue.global(qos: .utility).async {
            retire(synced: RemoteLocalState.syncedStorage(service: service), secrets: RemoteLocalState.secrets)
        }
    }
}
