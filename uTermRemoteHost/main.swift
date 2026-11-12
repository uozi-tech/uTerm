import AppKit

// uTerm 远程控制（远控进程）：包内的沙盒 LaunchAgent，由 `SMAppService` 注册、launchd 按需拉起（App 连它的 mach 服务时）。
// 持有被控端的全部网络与采集，App 更新、崩溃、被强制结束时已建立的远控连接不断。见 `RemoteHostAgentService`。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    // 上次在帘幕期间被结束：把帘幕静音的输出设备恢复回去（记录在本进程自己的设置里）。
    RemoteCurtainMute.shared.restoreLeftovers()
    RemoteHostAgentMain.start()
}
application.run()
