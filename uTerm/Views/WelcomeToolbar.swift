// uTerm/Views/WelcomeToolbar.swift
import SwiftUI

/// Welcome 顶部 toolbar：左搜索框 + 右「密钥」/「新建」按钮。
struct WelcomeToolbar: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var query: String
    let onNewServer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(UD.text3)
            TextField("搜索 name / host / group…", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(UD.text2)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(UD.text3)
            }
            Spacer(minLength: 12)
            UDButton(title: "密钥", style: .secondary, systemImage: "key") {
                openWindow(id: "keys")
            }
            UDButton(title: "新建", style: .primary, systemImage: "plus", action: onNewServer)
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(UD.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}
