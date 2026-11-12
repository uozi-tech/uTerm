import Foundation
import SwiftData

/// 中继配置的落点。生产里是 `RemoteHostServer`，测试换成内存替身。
@MainActor
protocol ControlRelayManaging: AnyObject {
    /// 钥匙串里当前的中继配置。
    func loadRelayConfig() -> RemoteRelayConfig?
    /// 存进钥匙串；开着公网接入时顺带换到新中继上。保存失败返回 false。
    func importRelayConfig(_ config: RemoteRelayConfig) -> Bool
    /// 公网接入开着（这台 Mac 在维持中继注册）。
    var isRelayLinkActive: Bool { get }
    var isRelayRegistered: Bool { get }
    var relayUpdates: RemoteRelayUpdateMonitor { get }
    /// relayID → 装着它的主机。
    var relayManagedHosts: RemoteRelayManagedHosts { get }
}

extension RemoteHostServer: ControlRelayManaging {
    var isRelayLinkActive: Bool { relayState != nil }
    var isRelayRegistered: Bool { relayState == .registered }
    var relayManagedHosts: RemoteRelayManagedHosts { RemoteRelayManagedHosts() }
}

/// 中继组：`relay-import` / `relay-check`。
///
/// 硬约束：**成员密钥不出应用**。`relay-import` 由 uTerm 自己经 SFTP 读服务器上的设备配置、
/// 直接存进钥匙串，响应里只有名字、地址、relayID——客户端（以及背后的 Agent）一个字节的密钥也拿不到。
extension ControlHandler {

    func handleRelay(_ request: ControlRequest, _ deps: Dependencies) async throws -> ControlResponse {
        guard let relay = deps.relay else {
            throw ControlFailure(code: .app_not_ready, message: "远程控制服务还没有启动")
        }
        switch request.action {
        case .relayImport:
            return try await importRelay(request, deps, relay: relay)
        case .relayCheck:
            return try await checkRelay(request, deps, relay: relay)
        default:
            throw ControlFailure(code: .invalid_request, message: "动作 \(request.action.rawValue) 不属于中继组")
        }
    }

    // MARK: - relay-import

    private func importRelay(_ request: ControlRequest, _ deps: Dependencies,
                             relay: any ControlRelayManaging) async throws -> ControlResponse {
        let needle = (request.host ?? "").trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            throw ControlFailure(code: .invalid_request, message: "relay-import 需要 --host：装着中继的那台已保存主机")
        }
        let profile = try resolveHost(needle)
        let path = Self.relayConfigPath(request.path)
        let spec = try HostConnectionSpec.resolve(profile: profile, container: deps.modelContainer)

        let data: Data
        do {
            data = try await deps.pool.withSFTP(for: spec) { sftp in
                do {
                    return try await sftp.download(remotePath: path, maximumBytes: RemoteRelayRelease.clientConfigMaxBytes)
                } catch {
                    let code = ControlFilePayloadBuilder.errorCode(for: error)
                    throw ControlFailure(code: code, message: Self.readFailureMessage(code: code, path: path, host: profile.name,
                                                                                      detail: ControlFilePayloadBuilder.errorDetail(for: error)))
                }
            }
        } catch let failure as ControlFailure {
            throw failure
        } catch let busy as SFTPChannelsBusyError {
            throw ControlFailure(code: .server_busy, message: busy.message(host: profile.name))
        } catch {
            return connectFailureResponse(error, id: request.id, profile: profile)
        }

        guard let config = RemoteRelayConfig(importing: data) else {
            throw ControlFailure(code: .relay_config_invalid,
                                 message: "\(profile.name):\(path) 不是 uterm-relay 的设备配置。用安装脚本的 client-config 重新生成。")
        }
        if let existing = relay.loadRelayConfig(), existing.relayID != config.relayID, request.force != true {
            throw ControlFailure(code: .relay_exists,
                                 message: "uTerm 已经导入了另一台中继「\(existing.name)」（\(existing.endpointDescription)）。问过用户确定要换，再加 --replace。")
        }
        guard relay.importRelayConfig(config) else {
            throw ControlFailure(code: .operation_failed, message: "保存中继配置到钥匙串失败")
        }
        relay.relayManagedHosts.set(profile.id, for: config.relayID)
        return .success(
            id: request.id,
            message: "已导入中继「\(config.name)」（\(config.endpointDescription)），由主机 \(profile.name) 管理。接着运行 relay check 测试连通。",
            relay: relayInfo(config, relay: relay, deps: deps)
        )
    }

    /// 缺省读安装脚本写的位置。`~/` 开头的去掉：SFTP 的相对路径本来就从主目录起算。
    static func relayConfigPath(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return RemoteRelayRelease.clientConfigPath }
        if trimmed.hasPrefix("~/") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }

    private static func readFailureMessage(code: ControlErrorCode, path: String, host: String, detail: String) -> String {
        switch code {
        case .file_not_found:
            return "\(host) 上没有 \(path)。中继装好了吗？安装脚本的 install（或装过以后的 client-config）会以当前 SSH 用户写这个文件。"
        case .permission_denied:
            return "\(host) 上的 \(path) 读不了（权限不够）。它应该属于 SSH 登录用户；用安装脚本的 client-config 重新生成。"
        case .file_too_large:
            return "\(host) 上的 \(path) 太大，不是中继的设备配置"
        default:
            return "读取 \(host):\(path) 失败：\(detail)"
        }
    }

    // MARK: - relay-check

    private func checkRelay(_ request: ControlRequest, _ deps: Dependencies,
                            relay: any ControlRelayManaging) async throws -> ControlResponse {
        guard let config = relay.loadRelayConfig() else {
            throw ControlFailure(code: .relay_not_configured,
                                 message: "uTerm 还没有导入中继。先在装好中继的主机上跑 relay import --host <主机>。")
        }
        let result = await RemoteRelayCheck.run(config: config)
        if result.tcp == .ok {
            relay.relayUpdates.noteRunning(result.serverVersion)
        }
        await relay.relayUpdates.refresh()
        var info = relayInfo(config, relay: relay, deps: deps)
        info.check = result
        let message = Self.checkSummary(result)
        if result.isUsable {
            return .success(id: request.id, message: message, relay: info)
        }
        return ControlResponse(id: request.id, ok: false, code: ControlErrorCode.relay_unreachable.rawValue,
                               message: message, relay: info)
    }

    static func checkSummary(_ result: RemoteRelayCheckResult) -> String {
        func mark(_ outcome: RemoteRelayCheckResult.Outcome) -> String {
            switch outcome {
            case .ok: return "通"
            case .failed: return "不通"
            case .skipped: return "未测"
            }
        }
        var line = "TCP \(mark(result.tcp)) · 认证 \(mark(result.auth)) · UDP \(mark(result.udp))"
        if let rtt = result.rttMs { line += " · 往返 \(rtt) ms" }
        if let version = result.serverVersion { line += " · 中继 \(version)" }
        guard !result.problems.isEmpty else { return line }
        return ([line] + result.problems).joined(separator: "\n")
    }

    private func relayInfo(_ config: RemoteRelayConfig, relay: any ControlRelayManaging,
                           deps: Dependencies) -> ControlRelayInfo {
        let managed = relay.relayManagedHosts.host(for: config.relayID)
        let hostName = managed.flatMap { id in sortedProfiles(deps).first { $0.id == id }?.name }
        let updates = relay.relayUpdates
        return ControlRelayInfo(
            name: config.name,
            endpoint: config.endpointDescription,
            relayID: config.relayID,
            managedHost: hostName,
            internetEnabled: relay.isRelayLinkActive,
            registered: relay.isRelayRegistered,
            latestVersion: updates.latestVersion,
            updateAvailable: updates.runningVersion == nil ? nil : updates.updateAvailable,
            check: nil
        )
    }
}
