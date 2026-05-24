// uTerm/Editor/Find/FindReplaceBar.swift
import SwiftUI

/// 悬浮在 editor 右上角的工具栏。spec §4.3。
struct FindReplaceBar: View {
    @Bindable var controller: FindReplaceController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    controller.isReplaceShown.toggle()
                } label: {
                    Image(systemName: controller.isReplaceShown ? "chevron.down" : "chevron.right")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)

                queryField
                toggleStrip
                matchCounter
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            if controller.isReplaceShown {
                replaceRow
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.Palette.bgPanel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.Palette.borderStrong, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    private var queryField: some View {
        TextField("Search", text: $controller.query)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 3).fill(AppTheme.Palette.bgRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(controller.errorMessage == nil ? Color.clear : AppTheme.Palette.danger,
                            lineWidth: 1)
            )
            .help(controller.errorMessage ?? "")
            .onSubmit { controller.next() }
    }

    private var toggleStrip: some View {
        HStack(spacing: 2) {
            toggleButton(label: "Aa", isOn: controller.options.caseSensitive) {
                let o = controller.options
                controller.options = .init(caseSensitive: !o.caseSensitive, regex: o.regex, wholeWord: o.wholeWord)
            }
            toggleButton(label: ".*", isOn: controller.options.regex) {
                let o = controller.options
                controller.options = .init(caseSensitive: o.caseSensitive, regex: !o.regex, wholeWord: o.wholeWord)
            }
            toggleButton(label: "W", isOn: controller.options.wholeWord) {
                let o = controller.options
                controller.options = .init(caseSensitive: o.caseSensitive, regex: o.regex, wholeWord: !o.wholeWord)
            }
        }
    }

    private func toggleButton(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
                .foregroundStyle(isOn ? AppTheme.Palette.textPrimary : AppTheme.Palette.textMuted)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? AppTheme.Palette.accent.opacity(0.6) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var matchCounter: some View {
        Text(matchCounterText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(AppTheme.Palette.textMuted)
            .frame(minWidth: 60, alignment: .trailing)
    }

    private var matchCounterText: String {
        if controller.matches.isEmpty { return "No results" }
        return "\(controller.activeIndex + 1) / \(controller.matches.count)"
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 22)  // align with chevron column
            TextField("Replace", text: $controller.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 3).fill(AppTheme.Palette.bgRaised))
            Button {
                controller.replaceCurrent()
            } label: {
                Image(systemName: "arrow.turn.up.left").frame(width: 22, height: 18)
            }.buttonStyle(.plain).help("Replace")
            Button {
                controller.replaceAll()
            } label: {
                Image(systemName: "text.badge.checkmark").frame(width: 22, height: 18)
            }.buttonStyle(.plain).help("Replace All (⌘Enter)")
        }
    }
}

