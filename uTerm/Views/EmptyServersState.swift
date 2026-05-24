// uTerm/Views/EmptyServersState.swift
import SwiftUI

/// 还没有服务器时的空态：图标 + 提示 + Primary「新建服务器」按钮。
struct EmptyServersState: View {
    let onNewServer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppTheme.Palette.textMuted.opacity(0.4))
            Text("还没有服务器")
                .font(.callout)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text("添加一台开始使用 uTerm")
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textMuted)
            Button("＋ 新建服务器", action: onNewServer)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Palette.bgBase)
    }
}
