import Foundation

/// 远控标签断线后多久再试一次。
///
/// 以前一律「0.5 秒起、翻倍、封顶 5 秒」。Mac 睡一整晚、或者拔了网线时，每个远控标签每 5 秒就要完整建连一次
///（经中继发信令、先收集打洞地址），蜂窝射频的尾巴有十来秒，5 秒一次等于让它一直开着。
/// 直接把上限调大又会让 Mac 回来之后标签要等很久才接上，所以只在两个条件同时成立时才放长：
///
/// - **没人在看这个标签**（不是前台标签，或 App 在后台）。有人看着的标签始终 ≤ 5 秒，Mac 一回来就接上。
///   没人看的标签一被切到前台就立刻重试（`RemoteTerminalBackend.setWatched`），所以放长对人不可见。
/// - **已经连续断了一阵**（1 分钟以上）。Wi-Fi 切换、电梯里掉线这种几秒到几十秒的断线照旧按 5 秒重试。
///
/// 有 Mac 可能回来了的迹象时（局域网又找到它、中继报它上线、网络恢复、回到前台、同一台 Mac 的另一个标签已经
/// 连上）由 `RemoteRetryGate.kick()` 立即叫醒，不等退避走完——见 `RemoteMacClient`。
nonisolated enum RemoteReconnectPolicy {
    /// 第一次重试前等多久；之后每失败一次翻倍。
    static let firstDelay: Duration = .milliseconds(500)
    /// 有人看着、或者刚断不久时的上限（与以前一样）。
    static let shortCap: Duration = .seconds(5)
    /// 没人看、断了超过 `longOutage` 的上限。
    static let mediumCap: Duration = .seconds(30)
    /// 没人看、断了超过 `veryLongOutage` 的上限。
    static let longCap: Duration = .seconds(60)
    static let longOutage: Duration = .seconds(60)
    static let veryLongOutage: Duration = .seconds(300)

    /// 退避上限。`outage` = 这次断线到现在多久了。
    static func cap(outage: Duration, watched: Bool) -> Duration {
        guard !watched else { return shortCap }
        if outage >= veryLongOutage { return longCap }
        if outage >= longOutage { return mediumCap }
        return shortCap
    }

    /// 下一次重试前等多久。`failures` = 上次被叫醒（或断线）以来连续失败了几次。
    static func delay(failures: Int, outage: Duration, watched: Bool) -> Duration {
        let grown = firstDelay * (1 << min(max(failures, 0), 16))
        return min(grown, cap(outage: outage, watched: watched))
    }
}
