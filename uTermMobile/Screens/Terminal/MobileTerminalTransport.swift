import Foundation
import SwiftData

/// 终端传输的注入口。
///
/// ## 为什么不新造一个 `TerminalTransport` 协议
///
/// 桌面侧早就有 `TerminalBackend`（`uTerm/Services/SSH/TerminalBackend.swift`），
/// 面正好是终端要的那五件事：`outputItems`（入站字节）、`exitStream`（会话结束）、
/// `connect()`、`write(_:)`、`resize(cols:rows:)`、`close()`，`SSHConnection` 是它
/// 的唯一实现，桌面 `TerminalSession` 已经依赖 `any TerminalBackend`。
/// 移动端 `MobileTerminalController` 是**唯一**直接 `new SSHConnection` 的地方——
/// 所以缺的不是协议，是**工厂**。再抽一个同形的 `TerminalTransport` 只会让两端
/// 各自维护一套同义词。
///
/// 于是这里只补工厂：控制器持有 `MobileTerminalTransportFactory`，默认 `.live`
/// 就是 `SSHAuthResolver` + `HostKeyVerifier` + `SSHConnection` 的组装（与 mac 共用
/// `SSHConnection.make`）。测试注入别的工厂即可拿到假后端。

/// 建一条终端传输所需的全部输入。
///
/// `ServerProfile` / `ModelContainer` / `HostKeyChallengeRelay` 都只在主 actor 上
/// 被摸到（`ServerProfile` 是 SwiftData `@Model`，非 `Sendable`），所以整个请求
/// 结构与工厂闭包一律标 `@MainActor`——跨 actor 的那一步由 `SSHConnection` 自己的
/// `ProfileSnapshot` 完成，与改动前一致。
@MainActor
struct MobileTerminalTransportRequest {
    let profile: ServerProfile
    let container: ModelContainer
    let relay: HostKeyChallengeRelay
}

/// 造终端后端的工厂。`MobileTerminalController` 的唯一后端来源。
///
/// 只会从认证材料解析那一步抛错（含跳板机凭据缺失），控制器把它包成
/// `.failed("认证材料解析失败：…")`。
///
/// `async`：生产实现要读钥匙串（每次 3~5 次 `SecItemCopyMatching`，有跳板机再翻倍），
/// 这段 IPC 放在并发线程池里做，不和连接中页的入场动画抢主线程。
@MainActor
struct MobileTerminalTransportFactory {
    let make: @MainActor (MobileTerminalTransportRequest) async throws -> any TerminalBackend

    init(make: @escaping @MainActor (MobileTerminalTransportRequest) async throws -> any TerminalBackend) {
        self.make = make
    }

    /// 生产实现：真 SSH。
    static let live = MobileTerminalTransportFactory(make: makeLive)

    /// 组装与 mac 进程内连接同一份（`SSHConnection.make`）：钥匙串读取离开主线程，跳板机凭据缺了直接报错。
    /// 首次连接 / 密钥变化时弹出信任确认；信任后由 verifier 写入 known-hosts。
    private static func makeLive(_ request: MobileTerminalTransportRequest) async throws -> any TerminalBackend {
        try await SSHConnection.make(profile: request.profile, container: request.container,
                                     approver: request.relay.makeApprover())
    }
}
