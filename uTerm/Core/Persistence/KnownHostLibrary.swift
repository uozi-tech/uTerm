import Foundation
import SwiftData

/// 已知主机指纹的写操作（两端共用：macOS「已知主机指纹」窗口、iOS `FingerprintsView`）。
///
/// 删掉一条后，下次连接这台主机会重新走 TOFU 首次信任确认（见 `HostKeyVerifier`）；
/// 记录经 SwiftData + CloudKit 同步，其他设备上也随之删除。本机记着的「这台同意过用旧算法」
/// （`LegacyAlgorithmConsent`）一起忘掉：下次连接就是第一次。
@MainActor
enum KnownHostLibrary {
    static func delete(_ host: KnownHost, in context: ModelContext,
                       legacyConsent: LegacyAlgorithmConsent = .shared) {
        legacyConsent.remove(host: host.host, port: host.port)
        context.delete(host)
        try? context.save()
    }
}
