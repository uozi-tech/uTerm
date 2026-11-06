import Foundation
import SwiftData

/// 设置页各行尾的数量徽标（主机 / 密钥 / 分组 / 已知主机 / 端口转发规则 / 模型服务）。
///
/// 走 `context.fetchCount`：SQL 层的 `COUNT(*)`，不物化任何对象。改前是六个无谓词的
/// `@Query`，一进设置页就把整表取出来只为显示几个数字（连过几百台机器的库里
/// `KnownHost` 本身就上千行）。代价是没有自动订阅，调用方在出现时与
/// `ModelContext.didSave` 时重取。
nonisolated struct LibraryCounts: Equatable, Sendable {
    var hosts = 0
    var keys = 0
    var groups = 0
    var knownHosts = 0
    var forwards = 0
    var providers = 0

    @MainActor
    static func fetch(in context: ModelContext) -> LibraryCounts {
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        return LibraryCounts(hosts: count(ServerProfile.self),
                             keys: count(SSHKey.self),
                             groups: count(ServerGroup.self),
                             knownHosts: count(KnownHost.self),
                             forwards: count(ForwardingRule.self),
                             providers: count(AIProvider.self))
    }
}
