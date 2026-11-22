import Foundation

/// 看远程桌面时的界面判定与文案（手机的 `RemoteDesktopScreen` 与 Mac 主控端的 `RemoteDesktopWindow` 共用）：
/// 帘幕按钮、状态遮罩、锁屏提示、解锁结果、读数行。两端只负责画（按钮样式、字号、布局）和把动作接到自己的
/// 处理上；什么时候显示什么、写什么字只在这里定。

// MARK: - 帘幕

extension RemoteDesktopScreenState {
    /// 帘幕按钮能不能用：锁着时没有意义；开帘幕要那台 Mac 允许远程解锁（与被控端 `canUnlockRemotely` 一致），
    /// 关帘幕不看这个开关——帘幕开着时开关被关掉，照样要能关掉帘幕。
    nonisolated func canToggleCurtain(supportsUnlock: Bool) -> Bool {
        supportsUnlock && !locked && (curtained || unlockAvailable)
    }
}

// MARK: - 状态遮罩

/// 盖在画面上的一层：转圈 / 标题 / 说明 / 按钮。
nonisolated struct RemoteDesktopNotice: Equatable {
    enum Action: Equatable {
        /// 「重试」：再开一次这一路画面。
        case retry
        /// 「重新连接」：流结束了，重新连上再开。
        case reconnect
        /// 「关闭」：离开这一页（手机；Mac 的窗口自己有关闭按钮，不给）。
        case close

        var title: String {
            switch self {
            case .retry: return String(localized: "重试")
            case .reconnect: return String(localized: "重新连接")
            case .close: return String(localized: "关闭")
            }
        }
    }

    var spinner: Bool
    var title: String
    var message: String?
    /// 半透明（画面还在底下，比如重连中）。
    var dim = false
    var actions: [Action] = []
}

/// 锁屏时显示什么。
nonisolated enum RemoteDesktopLockPrompt: Equatable {
    case none
    /// 那台 Mac 允许远程解锁：盖一层解锁入口（输密码 / 取出已存的密码，各端自己画）。
    case unlock
    /// 没开远程解锁：不挡画面（仍可直接在锁屏上输密码），只在底部提示一句。
    case caption(String)
}

@MainActor
extension RemoteDesktopSession {
    /// 按这一路画面的状态该盖什么；正常在放时为 nil。`showsClose`：失败 / 结束时给不给「关闭」。
    func notice(macName: String, showsClose: Bool) -> RemoteDesktopNotice? {
        let close: [RemoteDesktopNotice.Action] = showsClose ? [.close] : []
        // 同一个窗口换大小的那几百毫秒：留着上一张画面，什么都不盖（见 `isRetargeting`）。失败、结束、重试照常提示。
        if isRetargeting, retryReason == nil {
            switch state {
            case .idle, .connecting, .streaming: return nil
            case .reconnecting, .failed, .ended, .unsupported: break
            }
        }
        switch state {
        case .idle, .connecting:
            if let retryReason {
                return RemoteDesktopNotice(spinner: true, title: String(localized: "没打开，正在重试…"), message: retryReason)
            }
            return RemoteDesktopNotice(spinner: true, title: String(localized: "正在连接 \(macName) 的屏幕…"),
                                       message: progress)
        case .reconnecting:
            return RemoteDesktopNotice(spinner: true, title: String(localized: "连接已断开，正在重新连接…"),
                                       message: String(localized: "接上后画面会自动恢复"), dim: true)
        case .streaming where awaitingFirstFrame:
            return RemoteDesktopNotice(spinner: true, title: String(localized: "正在连接 \(macName) 的屏幕…"),
                                       message: progress, dim: true)
        case .streaming:
            return nil
        case .failed(let message):
            return RemoteDesktopNotice(spinner: false, title: String(localized: "无法打开屏幕"), message: message,
                                       actions: [.retry] + close)
        case .ended(let reason):
            return RemoteDesktopNotice(spinner: false, title: String(localized: "远程桌面已结束"), message: reason,
                                       actions: [.reconnect] + close)
        case .unsupported:
            return RemoteDesktopNotice(spinner: false, title: String(localized: "\(macName) 上的 uTerm 需要更新"),
                                       message: RemoteDesktopError.macTooOld.localizedDescription, actions: close)
        }
    }

    /// 正在放、但只能看时底部的一句说明（那台 Mac 没有「辅助功能」授权）。
    var controlCaption: String? {
        guard state == .streaming, !awaitingFirstFrame, !canControl else { return nil }
        return info?.controlNote
    }

    /// 锁屏提示。只在画面正在传时显示：流断了 / 结束了，锁屏状态是断开前最后一次推来的旧值，再叠一层会和
    /// 「已结束」的提示、「重新连接」按钮压在一起（真机截图），而且这时输密码也送不过去。
    func lockPrompt(macName: String) -> RemoteDesktopLockPrompt {
        guard case .streaming = state, supportsUnlock, screen.locked else { return .none }
        if screen.unlockAvailable { return .unlock }
        return .caption(String(localized: "\(macName) 已锁定。在它的「设置 › 远程控制」里打开「允许远程解锁」（并授予「辅助功能」权限）后，可以在这里解锁。"))
    }

    /// 屏上有系统验证框时显示什么。和锁屏提示一样只在画面正在传时显示；锁着时先解锁。
    func authPromptBanner(macName: String) -> RemoteDesktopAuthPromptBanner {
        guard case .streaming = state, supportsAuthPrompt, !screen.locked, let prompt = screen.authPrompt else {
            return .none
        }
        guard screen.unlockAvailable else {
            return .caption(String(localized: "\(macName) 在等验证身份。在它的「设置 › 远程控制」里打开「允许远程解锁」（并授予「辅助功能」权限）后，可以在这里替它填入登录密码。"))
        }
        return .actionable(prompt: prompt, title: prompt.kind.bannerTitle(macName: macName),
                           message: String(localized: "指纹没法远程按。可以让它改用登录密码，或取消这个请求。"))
    }

    /// 顶栏名字后面的一行状态。`controlling`：正常可控时写什么（手机写「触控板模式」，Mac 窗口不写字）。
    func statusText(controlling: String?) -> String? {
        switch state {
        case .streaming:
            let mode = canControl ? controlling : String(localized: "仅查看")
            guard screen.curtained else { return mode }
            return [mode, String(localized: "帘幕已开")].compactMap(\.self).joined(separator: " · ")
        case .idle, .connecting: return String(localized: "正在连接…")
        case .reconnecting: return String(localized: "正在重新连接…")
        case .failed: return String(localized: "连接失败")
        case .ended: return String(localized: "已结束")
        case .unsupported: return String(localized: "Mac 上的 uTerm 版本过旧")
        }
    }

    /// 读数：延迟放最前（最先要看的是「点一下多久见到结果」），其余是排查用的分项，开着声音时接上声音缓冲。
    var statItems: [RemoteDesktopStat] {
        RemoteDesktopStat.items(latency: latency, video: stats, audio: isAudioOn ? audioStats : nil)
    }

    /// 要多大的画面：按本机屏幕的像素（长边、短边，与方向无关），至少 1080p——放大看细节时还有余量。
    nonisolated static func requestedSize(longPixels: Int, shortPixels: Int) -> (width: Int, height: Int) {
        (max(longPixels, 1920), max(shortPixels, 1080))
    }
}

// MARK: - 读数

/// 读数里的一项：小标题、数值、单位各自分开，两端按自己的版式画（数值亮、标题和单位暗），不再拼成一整串。
nonisolated struct RemoteDesktopStat: Equatable, Identifiable, Sendable {
    enum Kind: Sendable { case latency, frameRate, bitrate, decode, audio }

    /// 数值要不要变色提醒。
    enum Level: Sendable {
        case normal
        /// 能用，但已经感觉得到（黄）。
        case warning
        /// 明显拖慢操作（红）。
        case poor
    }

    var kind: Kind
    var label: String
    var value: String
    var unit: String
    /// 补充读数（延迟的 p95、声音缓冲的目标深度）：地方够才画。
    var detail: String?
    var level = Level.normal

    var id: Kind { kind }

    /// 延迟（画面往返的中位数）到这个数变黄 / 变红：100 ms 以内操作跟手，过了 200 ms 拖动和打字明显滞后。
    static let latencyWarningMillis = 100
    static let latencyPoorMillis = 200
    /// 解码一帧超过 60 Hz 的一帧时间，硬解就跟不上满帧率了。
    static let decodeWarningMillis = 1000.0 / 60

    /// 按当前读数排出各项。老 Mac 不报延迟、没开声音时，对应的项不出现。帧率与码率不变色：画面不动时
    /// 本来就只有几帧、几十 kbps，低不代表有问题。
    static func items(latency: RemoteDesktopLatency?, video: RemoteDesktopReceiverStats.Snapshot,
                      audio: RemoteAudioReceiver.Snapshot?) -> [RemoteDesktopStat] {
        var items: [RemoteDesktopStat] = []
        if let latency {
            let level: Level = latency.p50Millis >= latencyPoorMillis ? .poor
                : latency.p50Millis >= latencyWarningMillis ? .warning : .normal
            items.append(RemoteDesktopStat(kind: .latency, label: String(localized: "延迟"),
                                           value: String(latency.p50Millis), unit: "ms",
                                           detail: "p95 \(latency.p95Millis)", level: level))
        }
        items.append(RemoteDesktopStat(kind: .frameRate, label: String(localized: "帧率"),
                                       value: String(format: "%.0f", video.framesPerSecond), unit: "fps"))
        items.append(RemoteDesktopStat(kind: .bitrate, label: String(localized: "码率"),
                                       value: String(format: "%.1f", video.megabitsPerSecond), unit: "Mbps"))
        items.append(RemoteDesktopStat(kind: .decode, label: String(localized: "解码"),
                                       value: String(format: "%.1f", video.decodeMillis), unit: "ms",
                                       level: video.decodeMillis >= decodeWarningMillis ? .warning : .normal))
        if let audio {
            // 补洞是开声音以来的累计数，没补过就不占地方。
            var detail = String(localized: "目标 \(String(audio.targetMillis))")
            if audio.counters.concealed > 0 {
                detail += " · " + String(localized: "补洞 \(String(audio.counters.concealed))")
            }
            items.append(RemoteDesktopStat(kind: .audio, label: String(localized: "声音缓冲"),
                                           value: String(audio.bufferedMillis), unit: "ms", detail: detail))
        }
        return items
    }

    /// 读屏时念的一句。
    static func spokenText(_ items: [RemoteDesktopStat]) -> String {
        items.map { item in
            [item.label, item.value, item.unit, item.detail].compactMap(\.self).joined(separator: " ")
        }.joined(separator: String(localized: "，", comment: "读屏文字里各段之间的分隔符"))
    }
}

// MARK: - 验证框

/// Mac 屏上有验证框（Touch ID / 密码）时显示什么。
nonisolated enum RemoteDesktopAuthPromptBanner: Equatable {
    case none
    /// 能替它填密码或取消：标题、说明，按钮各端自己画。
    case actionable(prompt: RemoteDesktopAuthPrompt, title: String, message: String)
    /// 那台 Mac 没开远程解锁：不挡画面，只在底部提示一句。
    case caption(String)
}

extension RemoteDesktopAuthPrompt.Kind {
    nonisolated func bannerTitle(macName: String) -> String {
        switch self {
        case .authorization: return String(localized: "\(macName) 在请求管理员授权")
        case .localAuthentication: return String(localized: "\(macName) 上的 App 在请求验证身份")
        case .other: return String(localized: "\(macName) 在请求验证身份")
        }
    }
}

extension RemoteDesktopAuthPromptResult.Outcome {
    /// 没成时给用户看的原因；通过了 / 取消了为 nil。
    nonisolated var failureMessage: String? {
        switch self {
        case .accepted, .cancelled: return nil
        case .rejected: return String(localized: "密码不对，那个验证框还在，请重试。")
        case .gone: return String(localized: "那个验证框已经关了。")
        case .notFocused: return String(localized: "没能把验证框切到前台，密码没有输入（免得打进别的 App）。可以在画面上点一下那个框再试。")
        case .notAllowed: return String(localized: "Mac 当前不允许远程填写密码。")
        case .timedOut: return String(localized: "等不到结果，请看一下画面再试。")
        }
    }
}

// MARK: - 解锁结果

extension RemoteDesktopUnlockResult.Outcome {
    /// 解锁没成时给用户看的原因；成功（或本来就没锁）为 nil。
    nonisolated var failureMessage: String? {
        switch self {
        case .unlocked, .notLocked: return nil
        case .stillLocked: return String(localized: "输完密码 Mac 仍是锁着的：密码可能不对，也可能没输进锁屏，请重试。")
        case .inputBlocked: return String(localized: "Mac 上有截图等程序占着键盘，密码没有输入。请先让它退出再试。")
        case .timedOut: return String(localized: "解锁超时，请重试。")
        case .notAllowed: return String(localized: "Mac 当前不允许远程解锁。")
        }
    }
}
