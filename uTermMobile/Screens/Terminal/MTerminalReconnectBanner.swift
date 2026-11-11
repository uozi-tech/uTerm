import SwiftUI

/// 终端顶部的断线提示。画面还停在断线前，这时按键发不出去，不说的话看起来就像卡住了。
struct MTerminalReconnectBanner: View {
    let notice: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(notice)
                .font(.footnote)
                .foregroundStyle(M.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
