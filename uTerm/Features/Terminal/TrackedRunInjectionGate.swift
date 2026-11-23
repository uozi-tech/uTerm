import Foundation

/// 什么时候往远端 shell 里打命令。两端共用：Mac 的 `startTrackedRun`、iOS 与远控镜像的 `TerminalCommandTyping`。
nonisolated enum TrackedRunInjectionGate {
    /// 行编辑器一直没有信号（sh、bash 5.0 及以前不开括号粘贴，也没有 OSC 133）时，输出停这么久就当它在等输入。
    static let quietSeconds = 1.5
    /// 最多等这么久，到了照打。
    static let maxWaitSeconds = 6.0
    static let pollInterval: Duration = .milliseconds(50)

    /// - Parameters:
    ///   - lineEditorReady: 括号粘贴开着（zsh、bash 5.1+、fish 开始读一行时打开、跑命令前关掉），或者光标在 OSC 133 标的提示符里。
    ///   - sawOutput: 连上之后来过输出。
    ///   - quietFor: 离最后一次输出过了多久。
    ///   - waited: 一共等了多久。
    static func isReady(lineEditorReady: Bool, sawOutput: Bool, quietFor: Double, waited: Double) -> Bool {
        lineEditorReady || (sawOutput && quietFor >= quietSeconds) || waited >= maxWaitSeconds
    }

    /// 看着影子终端等远端的行编辑器起来（或等够上限）。`stillValid` 变成 false（断开了、换了一条连接）就不等了，返回 false。
    @MainActor
    static func waitForLineEditor(shadow: ShadowTerminal, stillValid: () -> Bool) async -> Bool {
        let started = ContinuousClock.now
        var lastBytes = shadow.totalFedBytes, lastChange = started
        let initialBytes = lastBytes
        while !Task.isCancelled, stillValid() {
            let now = ContinuousClock.now
            let bytes = shadow.totalFedBytes
            if bytes != lastBytes {
                lastBytes = bytes
                lastChange = now
            }
            if isReady(lineEditorReady: shadow.bracketedPasteMode || shadow.isCursorAtPrompt,
                       sawOutput: bytes != initialBytes,
                       quietFor: seconds(now - lastChange),
                       waited: seconds(now - started)) { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// 连上之后往 shell 里打一行命令，不跟踪输出、不改回显：iOS 的终端标签、远控镜像（Mac 控 Mac）上的
/// 「继续这个会话」用。等的规则和 Mac 的 `startTrackedRun` 是同一份（`TrackedRunInjectionGate`）：
/// 先等连上，再等行编辑器起来，再打命令和回车。
///
/// 远控镜像不能用 `startTrackedRun`：那条路要在本端改写回显，镜像的画面归被控的 Mac 管，改了两边就对不上，
/// Mac 自己的窗口里还会露出包装的 `printf`。
@MainActor
enum TerminalCommandTyping {
    /// 等连上的上限。首连可能要确认主机密钥，所以给得宽。
    static let connectTimeout: Duration = .seconds(30)

    /// - Parameters:
    ///   - generation: 这条连接的代次（输出泵的 `generation`）。等的中途换了连接就不打。
    ///   - send: 打进去（`command` 后面已经带了回车）。
    /// - Returns: 打没打进去。连不上、等的中途断了返回 false。
    @discardableResult
    static func type(_ command: String, shadow: ShadowTerminal, generation: () -> Int, isConnected: () -> Bool,
                     connectTimeout: Duration = connectTimeout, send: (String) async -> Void) async -> Bool {
        let deadline = ContinuousClock.now + connectTimeout
        while !isConnected() {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: TrackedRunInjectionGate.pollInterval)
        }
        let connection = generation()
        let ready = await TrackedRunInjectionGate.waitForLineEditor(shadow: shadow) {
            generation() == connection && isConnected()
        }
        guard ready else { return false }
        await send(command + "\r")
        return true
    }
}
