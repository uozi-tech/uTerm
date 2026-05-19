import SwiftUI

extension View {
    /// 把一个 `HostKeyChallengeRelay` 接成 host-key 征询 sheet。
    /// `PaneView` 与 `FileBrowserView` 共用 —— 两者此前各自实现了一份相同的
    /// `challengeBinding` + `.sheet(item:)` + `HostKeyPromptView`。
    func hostKeySheet(_ relay: HostKeyChallengeRelay) -> some View {
        sheet(item: Binding(
            get: { relay.pendingChallenge },
            set: { if $0 == nil { relay.resolve(false) } }
        )) { challenge in
            HostKeyPromptView(challenge: challenge) { relay.resolve($0) }
        }
    }
}
