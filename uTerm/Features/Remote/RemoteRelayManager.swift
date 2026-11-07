import Foundation
import Observation
import SwiftData

/// 设置页里对中继的操作：测试连接、在装着它的主机上一键更新。
///
/// 更新只跑 OSS 上的安装脚本（`install.sh update`），换二进制、重启，起不来脚本自己会换回旧版。
/// 非 root 走 `sudo -n`；要密码时改开一个终端窗口跑同一条命令，让用户自己输。
@MainActor
@Observable
final class RemoteRelayManager {
    enum UpdatePhase: Equatable {
        case idle
        case running
        case finished(String)
        /// 要 sudo 密码，已经开了终端窗口。
        case openedTerminal
        case failed(String)
    }

    private(set) var updatePhase = UpdatePhase.idle
    private(set) var isChecking = false
    private(set) var lastCheck: RemoteRelayCheckResult?

    /// 测试连接。顺带把中继版本交给更新提醒。
    func check(_ config: RemoteRelayConfig, updates: RemoteRelayUpdateMonitor) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let result = await RemoteRelayCheck.run(config: config)
        lastCheck = result
        if result.tcp == .ok { updates.noteRunning(result.serverVersion) }
        await updates.refresh()
    }

    func update(_ config: RemoteRelayConfig, on profile: ServerProfile, container: ModelContainer,
                registry: TerminalSessionRegistry?, updates: RemoteRelayUpdateMonitor) async {
        guard updatePhase != .running else { return }
        updatePhase = .running
        let executor: SSHCommandExecutor
        do {
            executor = try WorkspaceCommandExecutorFactory.make(server: profile, container: container).executor
        } catch {
            updatePhase = .failed(FriendlyError.describe(error))
            return
        }
        let limits = SupervisedExec.interactiveLimits(for: executor)
        switch await SupervisedExec.run(RemoteRelayRelease.updateCommand, on: executor, limits: limits) {
        case .completed(let result):
            if result.exitCode == 0 {
                let summary = RemoteRelayRelease.summary(result.output)
                let version = summary["version"] ?? ""
                updatePhase = .finished(summary["updated"] == "no"
                                        ? String(localized: "已经是最新版本 \(version)")
                                        : String(localized: "已更新到 \(version)，中继已重启"))
                // 中继重启后这台 Mac 会自己重连注册；这里再测一次，马上刷新设置页上的版本。
                try? await Task.sleep(for: .seconds(1))
                await check(config, updates: updates)
            } else if RemoteRelayRelease.needsPassword(result.output) {
                openTerminal(profile: profile, registry: registry)
            } else {
                updatePhase = .failed(Self.tail(result.output))
            }
        case .failed(let failure):
            updatePhase = .failed(failure.text)
        case .stalled(let stalled):
            updatePhase = .failed(stalled.message(limits: limits))
        }
    }

    private func openTerminal(profile: ServerProfile, registry: TerminalSessionRegistry?) {
        guard let registry, let open = registry.openTerminalWindow, let windowID = open(profile.id) else {
            updatePhase = .failed(String(localized: "这台主机的 sudo 要密码。请在终端里运行：\n\(RemoteRelayRelease.interactiveUpdateCommand)"))
            return
        }
        updatePhase = .openedTerminal
        Task {
            guard let entry = await registry.waitForSession(inWindow: windowID, timeout: .seconds(20)),
                  let session = registry.session(for: entry.id) else { return }
            session.startTrackedRun(RemoteRelayRelease.interactiveUpdateCommand)
        }
    }

    /// 安装脚本出错时最后几行就是原因。
    private static func tail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
        return lines.isEmpty ? String(localized: "更新失败，没有输出") : lines
    }
}
