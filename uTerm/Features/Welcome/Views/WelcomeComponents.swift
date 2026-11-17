import UDesignKit
// uTerm/Views/WelcomeComponents.swift
import SwiftUI

/// 欢迎页（设计稿 Variant A）共享的小组件。
/// 列表行 `ServerRow` 与详情面板 `HostDetailPanel` 复用这里的 `KbdChip`，避免重复实现。
/// 相对时间（「上次连接」/ 行尾时间）走 `UTermFormat.relative`。

/// 键位提示小胶囊（设计稿 Kbd）。等宽、软底，浅深自适应。
struct KbdChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(UD.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(UD.fillSoft)
            )
    }
}

/// 详情面板底部的动作按钮（主机详情、「我的 Mac」详情共用）。
///
/// 主操作：accent 实心 + 白字 + 内嵌键帽 + 柔光，40 高；次操作：软底 + `KbdChip`，38 高。
/// 都铺满所在列宽。不可用时整体压暗（plain 按钮自己不变灰）。
struct DetailActionButton: View {
    /// `LocalizedStringKey`：调用处的字面量照常进文案目录。
    let title: LocalizedStringKey
    var systemImage: String? = nil
    /// 键位提示（「↵」「⌘↵」）；nil 不显示。只是提示，快捷键由调用方挂 `.keyboardShortcut`。
    var shortcutHint: String? = nil
    var prominent = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            if prominent { primaryLabel } else { secondaryLabel }
        }
        .buttonStyle(.udPlain)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var primaryLabel: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
            }
            Text(title).font(.system(size: 13.5, weight: .medium))
            if let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.18)))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9).fill(UD.accent))
        .shadow(color: UD.accent.opacity(isEnabled ? 0.45 : 0), radius: 10, y: 5)
    }

    private var secondaryLabel: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).foregroundStyle(UD.text2)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
            if let shortcutHint { KbdChip(text: shortcutHint) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 9).fill(UD.fillSoft))
        .contentShape(Rectangle())
    }
}

/// 详情面板里的一格元信息：小号标签 + 一行值（主机详情、「我的 Mac」详情共用）。
struct DetailMetaCell: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .tracking(0.5)
                .foregroundStyle(UD.text3)
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }
}
