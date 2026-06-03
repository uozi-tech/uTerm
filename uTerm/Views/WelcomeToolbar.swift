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
                .foregroundStyle(AppTheme.Palette.textMuted)
            TextField("搜索 name / host / group…", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Palette.textMuted)
            }
            Spacer(minLength: 12)
            Button { openWindow(id: "keys") } label: {
                Label("密钥", systemImage: "key")
                    .labelStyle(.titleAndIcon)
            }
            Button(action: onNewServer) {
                Label("新建", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.Palette.bgPanel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Palette.border).frame(height: 1)
        }
    }
}
