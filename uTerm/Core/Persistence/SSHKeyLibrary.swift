import Foundation
import SwiftData

/// 密钥库里「跨模型」的读写：删除一把密钥要连带清钥匙串、解绑引用它的主机；列表要知道每把密钥被几台主机用。
/// 两端（macOS `KeyManagerView`、iOS `KeysScreen` / `KeyDetailSheet`）共用这一处。
///
/// 钥匙串存取仍在 `KeyStore`（纯钥匙串、不碰模型）；这里持 `ModelContext`，管模型间的引用。
@MainActor
struct SSHKeyLibrary {
    let context: ModelContext
    var keyStore: KeyStore = KeyStore()

    /// 删除一把密钥：清掉它的钥匙串条目 → 引用它的主机 `keyID` 置空（连接时按缺密钥处理）→ 删行 → save。
    func delete(_ key: SSHKey) {
        let id = key.id
        keyStore.delete(keyID: id)
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        for profile in profiles where profile.keyID == id {
            profile.keyID = nil
        }
        context.delete(key)
        try? context.save()
    }

    /// `keyID → 使用它的主机数`，一趟建好给列表查表用。
    static func usageCounts(_ profiles: [ServerProfile]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for profile in profiles {
            guard let id = profile.keyID else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }

    /// 使用这把密钥的主机（保持传入顺序）。
    static func users(of key: SSHKey, in profiles: [ServerProfile]) -> [ServerProfile] {
        let id = key.id
        return profiles.filter { $0.keyID == id }
    }
}
