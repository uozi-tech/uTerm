// uTerm/Editor/CodeEditorView.swift
import SwiftUI
import AppKit
import CodeEditTextView

/// SwiftUI 入口。包了 CodeEditorController 持有的 TextView。
struct CodeEditorView: View {
    let buffer: FileBuffer
    var language: String = ""
    /// 用户主动打开 / 切换文件时的焦点请求（FilePreviewModel 发起）。
    var focusRequest: EditorFocusRequest? = nil
    @State private var findController: FindReplaceController?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CodeEditorViewRepresentable(buffer: buffer, language: language,
                                        focusRequest: focusRequest,
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

// MARK: - TextView 子类：上屏前修 caret

/// 只为拿一个「layout 之后、绘制之前」的钩子。
///
/// caret（`CursorView`）的 frame 由包在 `layout()` → `updateSelectionViews()` 里
/// 重设：宽度是写死的 1pt，高度是整行行高（这里 1.4 倍）。这条路径不只跟着选中变化跑
/// —— `setSelectedRange` 只在 range 真变了才发 `selectionChangedNotification`，而
/// `scrollToVisible`、`prepareContent`、`setTextStorage` 都会各自触发它。只订阅选中
/// 变化补不全。
///
/// `layout()` 在包的 extension 里声明成 `public` 而非 `open`，包外 override 不了；
/// `viewWillDraw()` 是 NSView 自己的方法，没被包动过，可以 override，且正好在
/// layout 跑完、像素落地之前 —— 改子视图 frame 的最后时机。
private final class EditorTextView: TextView {
    var onWillDraw: (() -> Void)?

    override func viewWillDraw() {
        super.viewWillDraw()
        onWillDraw?()
    }
}

// MARK: - NSViewRepresentable

private struct CodeEditorViewRepresentable: NSViewRepresentable {
    let buffer: FileBuffer
    let language: String
    let focusRequest: EditorFocusRequest?
    @Binding var findController: FindReplaceController?

    private var editorFont: NSFont {
        EditorTheme.textFont()
    }

    func makeCoordinator() -> CodeEditorController {
        CodeEditorController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // 编辑器 wrapLines=false（VSCode 默认不折行），超长行必须能横向滚动 ——
        // 关掉横向 scroller 会让超长内容（如 authorized_keys 单行公钥）直接
        // overflow 且无法查看。autohides=true：内容不超宽时滚动条不出现。
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = EditorTheme.background

        let textView = EditorTextView(
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
        // 顶部 contentInset 会在文档 y=0 之上留一条谁都画不到的空带（selection / active-line /
        // gutter 全在文档坐标系里，y >= 0），全选时露成一条空白 padding；它还会让
        // TextView.visibleRect 把 minY 上移，visibleTextRange 因此漏掉顶部那条半可见行，
        // 那一行有行号却没有选中底色。VSCode 的 editor.padding.top 默认同样为 0。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.documentView = textView
        scrollView.identifier = .utermPreviewRegion   // ⌘W 焦点判定标记

        context.coordinator.attach(textView: textView, scrollView: scrollView, buffer: buffer)
        textView.onWillDraw = { [weak coordinator = context.coordinator] in
            coordinator?.normalizeEditorCursors()
        }

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
            }, requestSave: {
                context.coordinator.requestSaveCurrentBuffer()
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
        if bufferChanged || coordinator.needsBindingTextUpdate(for: buffer) {
            coordinator.isUpdatingFromBinding = true
            textView.setText(buffer.text)
            coordinator.isUpdatingFromBinding = false
            coordinator.didRenderBindingText(for: buffer)
            // setText 把 textView 所有 subview 都 removeFromSuperview 了（CodeEditTextView
            // setTextStorage 的副作用）—— 把 gutter 重新挂回 + 刷宽度/行号 + 重高亮。
            coordinator.ensureGutterAttached()
        }

        // 用户主动打开 / 切换文件（FilePreviewModel 焦点请求代数变了）→ 把键盘焦点
        // 交给编辑器正文，⌘A/⌘C 等编辑菜单快捷键立即作用于文件内容，而不是留在
        // 文件树 / 终端等旧焦点上。按 bufferID 匹配：分屏下只有目标 buffer 的编辑器接手。
        if let focusRequest, focusRequest.generation != coordinator.handledFocusGeneration {
            coordinator.handledFocusGeneration = focusRequest.generation
            if focusRequest.bufferID == buffer.id {
                coordinator.focusTextView()
            }
        }
    }
}
