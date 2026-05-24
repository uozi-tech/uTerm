// uTerm/Views/CodeBody.swift
import SwiftUI
import AppKit
import CodeEditTextView

// MARK: - CodeBody

/// 代码编辑器主体视图，包装 CodeEditTextViewRepresentable。
///
/// `language` 参数当前被忽略（Spec 2A 不含 Tree-sitter 语法高亮）。
/// CodeEditLanguages 已在 commit 50a17ff 中从依赖图剔出；language 参数保留
/// 以兼容后续 Spec 2B 接入 Tree-sitter 时的 API 一致性。
struct CodeBody: View {
    let buffer: FileBuffer
    /// 文件语言标识（如 "swift" / "go"）。当前阶段忽略，保留供 Spec 2B 使用。
    var language: String = ""

    var body: some View {
        CodeEditTextViewRepresentable(
            text: Binding(
                get: { buffer.text },
                set: { newValue in
                    if buffer.text != newValue {
                        buffer.text = newValue
                        buffer.isDirty = true
                    }
                }),
            buffer: buffer)
            .background(AppTheme.Palette.bgBase)
    }
}

// MARK: - CodeEditTextViewRepresentable

/// 把 CodeEditTextView 的 `TextView` 桥接到 SwiftUI。
///
/// - 无 Tree-sitter 语法高亮（Spec 2A）；纯等宽字体渲染。
/// - text 通过 @Binding 双向同步：用户编辑时回写 binding 并标记 `isDirty`。
struct CodeEditTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let buffer: FileBuffer

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, buffer: buffer)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor(AppTheme.Palette.bgBase)

        let textView = TextView(
            string: text,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: NSColor(AppTheme.Palette.textPrimary),
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: context.coordinator
        )
        // CodeEditTextView.TextView 没有 backgroundColor 属性；外层 NSScrollView
        // 的 backgroundColor 已经覆盖了整个区域。

        // 文本与容器边界留呼吸空间 —— 否则字符贴左/上边显得拥挤。
        // 横向用 CodeEditTextView 自带的 `edgeInsets`，纵向走 NSScrollView 的
        // contentInsets（滚动条仍在 ScrollView 边缘）。
        textView.edgeInsets = HorizontalEdgeInsets(left: 12, right: 12)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TextView else { return }
        // 仅在外部（非用户输入）驱动的文本变化时才同步，避免光标跳动
        if textView.string != text {
            context.coordinator.isUpdatingFromBinding = true
            textView.setText(text)
            context.coordinator.isUpdatingFromBinding = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TextViewDelegate {
        @Binding var text: String
        let buffer: FileBuffer
        /// 防止 updateNSView 触发的 setText 再次回写 binding，形成循环。
        var isUpdatingFromBinding = false
        weak var textView: TextView?

        init(text: Binding<String>, buffer: FileBuffer) {
            self._text = text
            self.buffer = buffer
        }

        // MARK: TextViewDelegate

        func textView(
            _ textView: TextView,
            didReplaceContentsIn range: NSRange,
            with string: String
        ) {
            guard !isUpdatingFromBinding else { return }
            let newText = textView.string
            text = newText
            buffer.text = newText
            buffer.isDirty = true
        }
    }
}
