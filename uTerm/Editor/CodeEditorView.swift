// uTerm/Editor/CodeEditorView.swift
import SwiftUI
import AppKit
import CodeEditTextView

/// SwiftUI 入口。包了 CodeEditorController 持有的 TextView。
struct CodeEditorView: View {
    let buffer: FileBuffer
    var language: String = ""
    @State private var findController: FindReplaceController?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CodeEditorViewRepresentable(buffer: buffer, language: language,
                                        findController: $findController)
                .background(Color(nsColor: EditorTheme.background))
            if let fc = findController {
                FindReplaceBar(controller: fc) {
                    findController = nil
                }
                .padding(.top, 8).padding(.trailing, 14)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - NSViewRepresentable

private struct CodeEditorViewRepresentable: NSViewRepresentable {
    let buffer: FileBuffer
    let language: String
    @Binding var findController: FindReplaceController?
    @AppStorage("terminalFontName") private var fontName: String = TerminalSettings.defaultFontName
    @AppStorage("terminalFontSize") private var fontSize: Double = TerminalSettings.defaultFontSize

    private var editorFont: NSFont {
        EditorTheme.textFont(fontName: fontName, fontSize: CGFloat(fontSize))
    }

    func makeCoordinator() -> CodeEditorController {
        CodeEditorController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = EditorTheme.background

        let textView = TextView(
            string: buffer.text,
            font: editorFont,
            textColor: EditorTheme.foreground,
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: context.coordinator
        )
        textView.edgeInsets = HorizontalEdgeInsets(left: 12, right: 12)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        scrollView.documentView = textView

        context.coordinator.attach(textView: textView, scrollView: scrollView, buffer: buffer)

        // Install a local event monitor for find/replace key shortcuts.
        // We filter to events where this textView's window is key and textView is first responder,
        // so the monitor doesn't steal from other windows.
        let findBinding = $findController
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard
                let window = textView.window,
                event.window === window,
                window.firstResponder === textView
            else { return event }

            let handled = context.coordinator.handleKeyEvent(event, openFind: { showReplace in
                let fc = context.coordinator.openFindController(showReplace: showReplace)
                DispatchQueue.main.async { findBinding.wrappedValue = fc }
            }, closeFind: {
                DispatchQueue.main.async {
                    context.coordinator.dismissFindController()
                    findBinding.wrappedValue = nil
                }
            })
            return handled ? nil : event
        }
        context.coordinator.keyEventMonitor = monitor

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TextView else { return }
        let coordinator = context.coordinator
        let targetFont = editorFont
        if textView.font != targetFont {
            textView.font = targetFont
            // TextView.font 只改 typingAttributes（影响后续输入），已加载文本的
            // .font 属性不会变 —— 必须显式把字体 attr 铺回整段 textStorage，否则
            // 换字体后正文不重渲染。
            if let storage = textView.textStorage {
                let fullRange = NSRange(location: 0, length: storage.length)
                storage.addAttribute(.font, value: targetFont, range: fullRange)
                textView.layoutManager.invalidateLayoutForRange(fullRange)
            }
            coordinator.ensureGutterAttached()
        }
        // SwiftUI 复用同一 coordinator 跨同 kind 文件（body 无 `.id(buffer.id)`），切文件
        // 只会进到这里而非 makeNSView/attach。先随新 buffer 重选高亮策略 + 重绑 buffer
        // 引用，否则新文件沿用上个文件的 grammar 上色（残留高亮），且编辑写回旧 FileBuffer。
        let bufferChanged = coordinator.rebind(to: buffer)
        if bufferChanged || textView.string != buffer.text {
            coordinator.isUpdatingFromBinding = true
            textView.setText(buffer.text)
            coordinator.isUpdatingFromBinding = false
            // setText 把 textView 所有 subview 都 removeFromSuperview 了（CodeEditTextView
            // setTextStorage 的副作用）—— 把 gutter 重新挂回 + 刷宽度/行号 + 重高亮。
            coordinator.ensureGutterAttached()
        }
    }
}
