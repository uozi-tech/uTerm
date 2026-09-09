import Foundation
import SwiftData

/// `ServerProfile` → `HostConnectionSpec` 的**唯一调用点**，外加一个测试 seam。
///
/// 为什么要这一层：真实的 `HostConnectionSpec.resolve` 要读钥匙串（`KeychainStore`），
/// 而 XCTest 进程里钥匙串常常拿不到（`errSecMissingEntitlement`），于是 handler 的
/// 单测会在「还没走到被测逻辑」的地方就失败。注入一个 override 之后，SFTP / 转发的
/// handler 测试可以完全不碰钥匙串。
///
/// 生产路径零开销：`override` 为 nil 时直接转调 `HostConnectionSpec.resolve`。
@MainActor
enum ControlHostSpecResolver {

    /// 仅测试用：替换主机 → 建连输入的解析。用完必须在 `tearDown` 里置回 nil。
    static var overrideForTesting: ((ServerProfile) throws -> HostConnectionSpec)?

    static func resolve(
        profile: ServerProfile,
        container: ModelContainer
    ) throws -> HostConnectionSpec {
        if let overrideForTesting {
            return try overrideForTesting(profile)
        }
        return try HostConnectionSpec.resolve(profile: profile, container: container)
    }
}
