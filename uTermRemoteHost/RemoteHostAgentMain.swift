import AppKit
import Foundation

/// 远控进程的装配：监听 mach 服务，正式环境的部件（真采集、真注入、包内的文件服务、配对审批框与被控指示条）。
@MainActor
enum RemoteHostAgentMain {
    private static var service: RemoteHostAgentService?
    private static var listener: NSXPCListener?
    private static var panels: [AnyObject] = []
    private static var activity: NSObjectProtocol?

    static func start() {
        // 常驻后台：不让系统按「没有窗口、没人用」把它挂起或自动结束（心跳被拖慢，中继就会把这台 Mac 摘掉）。
        ProcessInfo.processInfo.disableAutomaticTermination("uTerm 远程控制常驻")
        ProcessInfo.processInfo.disableSuddenTermination()
        let service = RemoteHostAgentService(environment: production())
        let listener = NSXPCListener(machServiceName: RemoteHostAgent.machServiceName)
        listener.delegate = service
        listener.resume()
        self.service = service
        self.listener = listener
        AppLogger.notice("远控进程已启动（pid \(ProcessInfo.processInfo.processIdentifier)）", category: RemoteLog.category)
    }

    private static func production() -> RemoteHostAgentService.Environment {
        RemoteHostAgentService.Environment(
            settingsDefaults: .standard,
            makeDesktopEnvironment: { settings in .live(settings: settings) },
            makeFileAccess: { settings in RemoteHostFileClient.access(settings: settings) },
            attachPanels: { server in
                panels = [RemotePairingPrompt(server: server), RemoteDesktopIndicator(server: server)]
            },
            clientRequirement: RemoteHostAgent.appRequirement,
            terminate: {
                // 交给 launchd：正常退出不会被 KeepAlive 拉起，App 下一次连接时按需启动（届时就是包里的新版本）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            })
    }
}
