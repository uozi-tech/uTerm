import Foundation

/// 窗格上那条真彩提示的内容。
enum TrueColorOffer: Equatable {
    case available(rcFile: String)
    case enabled(rcFile: String)
    case failed(String)
}

extension TerminalSession {

    private static let dismissedHostsKey = "trueColorOfferDismissedHosts"

    /// 有 Agent 开始报告状态时查一次：只有 Agent 才明显受 256 色影响，普通 shell 不打扰。
    /// 一条连接只查一次，断开后重置（`resetTrueColorOffer`）。
    func checkTrueColorIfNeeded() {
        guard !trueColorChecked, let backend = backend as? any TerminalTrueColorConfiguring else { return }
        trueColorChecked = true
        guard !Self.isOfferDismissed(host: backend.trueColorHostKey) else { return }
        Task { [weak self] in
            // 查不到（受限 shell、网络设备）就当没这回事：这只是个增强提示。
            guard let status = try? await backend.trueColorStatus(),
                  case .canEnable(let rcFile) = status else { return }
            self?.trueColorOffer = .available(rcFile: rcFile)
        }
    }

    func enableTrueColor() {
        guard let backend = backend as? any TerminalTrueColorConfiguring else { return }
        Task { [weak self] in
            do {
                let rcFile = try await backend.enableTrueColor()
                self?.trueColorOffer = .enabled(rcFile: rcFile)
            } catch {
                self?.trueColorOffer = .failed(error.localizedDescription)
            }
        }
    }

    /// 用户选了「不再询问」：这台主机以后都不提示。
    func dismissTrueColorOfferForHost() {
        if let backend = backend as? any TerminalTrueColorConfiguring {
            var hosts = UserDefaults.standard.stringArray(forKey: Self.dismissedHostsKey) ?? []
            if !hosts.contains(backend.trueColorHostKey) { hosts.append(backend.trueColorHostKey) }
            UserDefaults.standard.set(hosts, forKey: Self.dismissedHostsKey)
        }
        trueColorOffer = nil
    }

    func closeTrueColorOffer() {
        trueColorOffer = nil
    }

    func resetTrueColorOffer() {
        trueColorChecked = false
        trueColorOffer = nil
    }

    private static func isOfferDismissed(host: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: dismissedHostsKey)?.contains(host) ?? false
    }
}
