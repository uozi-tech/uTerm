import SwiftUI

extension View {
    /// 把一个 `HostKeyChallengeRelay` 接成 host-key 征询 sheet。
    /// `PaneView` 与 `FileBrowserView` 共用 —— 两者此前各自实现了一份相同的
    /// `challengeBinding` + `.sheet(item:)` + `HostKeyPromptView`。
    func hostKeySheet(_ relay: HostKeyChallengeRelay) -> some View {
        modifier(HostKeySheetModifier(relay: relay))
    }
}

private struct HostKeySheetModifier: ViewModifier {
    let relay: HostKeyChallengeRelay
    /// 弹层此刻显示的是哪一问。按钮答完后队首换成下一问，SwiftUI 晚到的「关掉了」回调不能落到下一问上。
    @State private var shown: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { relay.pendingChallenge },
                set: { new in
                    // 不是按钮关的（宿主视图卸下、切走标签）：按「没人回答」结束这一问，不当成用户拒绝。
                    if new == nil, let shown { relay.dismiss(shown) }
                }
            )) { challenge in
                HostKeyPromptView(challenge: challenge) { relay.resolve($0, for: challenge.id, byUser: true) }
                    .onAppear { shown = challenge.id }
            }
            .onAppear { relay.presenterAppeared() }
            .onDisappear { relay.presenterDisappeared() }
    }
}
