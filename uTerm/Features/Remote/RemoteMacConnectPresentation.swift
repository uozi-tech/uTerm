import Foundation

/// 连一台 Mac 时界面上的文字：配对码、邀请摘要、连接进度（两端共用，各端只管排版）。

extension RemotePairingInvitation {
    /// 收到邀请时的确认文字：配上之后能做什么、经不经中继、提醒只接受信任的人发来的。
    nonisolated var summary: String {
        #if os(macOS)
        guard let relay else {
            return String(localized: "配对后，这台 Mac 可以控制「\(macName)」。这张邀请没带中继，只能在同一局域网里连接。只接受你信任的人发来的邀请。")
        }
        return String(localized: "配对后，这台 Mac 可以控制「\(macName)」，并经它的中继「\(relay.name)」在外网连接。只接受你信任的人发来的邀请。")
        #else
        guard let relay else {
            return String(localized: "配对后，这台手机可以控制「\(macName)」。这张邀请没带中继，只能在同一局域网里连接。只接受你信任的人发来的邀请。")
        }
        return String(localized: "配对后，这台手机可以控制「\(macName)」，并经它的中继「\(relay.name)」在外网连接。只接受你信任的人发来的邀请。")
        #endif
    }
}

/// 还没连上时的一行进度：标题，加一行可选的细节（连到哪一步、上次失败的原因）。
nonisolated struct RemoteConnectProgress: Equatable, Sendable {
    var title: String
    var detail: String?
}

extension RemoteMacClient {
    /// 连接中、或失败后正在自动重试时的进度；连上了、等配对确认、失败停下了都是 nil（各有各的页面）。
    var connectProgress: RemoteConnectProgress? {
        switch state {
        case .idle, .connecting:
            return RemoteConnectProgress(title: String(localized: "正在连接 \(macName)…"), detail: connectStage?.progress)
        case .failed(let message) where isAutoRetrying:
            return RemoteConnectProgress(title: String(localized: "没连上 \(macName)，正在重试…"), detail: message)
        default:
            return nil
        }
    }
}
