import Foundation

/// 端口转发组：`forward-list` / `forward-start` / `forward-stop`。
///
/// 硬约束：规则**只在界面里建**，CLI 只启停与查状态（协议里没有增删改字段）。
/// `forward-start` 走非交互 host-key 路径；端口冲突用 `PortConflictChecker` 判成
/// `port_in_use`，不要让 NIO 的 EADDRINUSE 冒成通用失败。
///
/// Wave 2 待填：三个动作的实现 + 规则解析（id / name，歧义回 `rule_ambiguous`）。
extension ControlHandler {

    func handleForward(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .forwardList:
            // Wave 2：fetch ForwardingRule × forwardingCoordinator.status/connectionIssue/
            // trafficSnapshot → [ControlForwardSnapshot]。
            throw ControlFailure.notImplemented("forward-list")
        case .forwardStart:
            // Wave 2：解析规则 → ensureSession(for:) → start(_:)。
            throw ControlFailure.notImplemented("forward-start")
        case .forwardStop:
            // Wave 2：解析规则 → forwardingCoordinator.stop(_:)。
            throw ControlFailure.notImplemented("forward-stop")
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于转发组"
            )
        }
    }
}
