// uTerm/Editor/Selection/LineNumberGutter.swift
import AppKit
import CodeEditTextView

/// 编辑器左侧行号列。
///
/// - 挂为 `TextView` 的子视图（`textView.addSubview`），与文档同步滚动。
/// - 宽度按 `layoutManager.lineCount` 位数自适应：1-99 行 40pt、100-999 行 48pt、
///   1000-9999 行 56pt。变宽时由 controller 调 `textView.edgeInsets.left` 让正文挪。
/// - 当前光标所在行号高亮满色，其他 40% 透明。
/// - 点击行号选中整行；拖动跨多行扩选。
///
/// 渲染走 `draw(_:rect:)` + `NSAttributedString` 直绘 —— 早期版本用 CATextLayer
/// 池子，但在 macOS 26 上 `CATextLayer.font` 拿 NSFont 偶发不渲染（NSFont/CTFont
/// 桥接坑）。可见行通常 ≤ 60 行，每次 scroll 重绘的成本远低于追踪 CATextLayer
/// 的复杂度。
@MainActor
final class LineNumberGutter: NSView {

    weak var textView: TextView?

    /// 当前 gutter 宽度。`recomputeWidth()` 可能修改它，controller 据此调整 edgeInsets。
    private(set) var gutterWidth: CGFloat = 40

    /// 当前光标所在行（0-based）。
    private var activeLineIndex: Int?

    /// 当前 mouseDown 时记录的起锚行号；mouseDragged 用来跨行扩选。
    private var dragAnchorLineIndex: Int?

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let rightPadding: CGFloat = 6
    /// 13pt 等宽数字字符约 7.8pt，按 10pt 留 buffer 防止系统字体替换时溢出。
    /// 配合 max(40, ...)：1 位 40 / 2 位 40 / 3 位 40 / 4 位 50 / 5 位 60。
    private let digitWidth: CGFloat = 10

    init(textView: TextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        _ = recomputeWidth()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 必须 true，否则 mouseDown 拿不到（事件穿透到下面的 textView）；
    /// 且让坐标系与 TextView 一致（TextView 也是 isFlipped = true）。
    override var isFlipped: Bool { true }

    // MARK: - Sizing

    /// 按当前 lineCount 重算宽度。返回宽度是否变化。
    @discardableResult
    func recomputeWidth() -> Bool {
        let count = textView?.layoutManager.lineCount ?? 1
        let digits = String(max(count, 1)).count
        let new = max(40, CGFloat(digits) * digitWidth + 10)
        let changed = new != gutterWidth
        gutterWidth = new
        if changed {
            var f = frame
            f.size.width = new
            frame = f
            needsDisplay = true
        }
        return changed
    }

    // MARK: - Updates

    /// 由外部 controller 在滚动 / 文本变化 / 选中变化时调，触发重绘。
    /// 全 view invalidate；draw(_:rect:) 内部 clip 到可视带，cost 仍然 O(visible)。
    func update(visibleRect _: CGRect, activeLineIndex: Int?) {
        self.activeLineIndex = activeLineIndex
        needsDisplay = true
    }

    /// 加入窗口时强制画一次 —— 否则 attach() 时 scrollView 可能还没 layout，
    /// 第一次 `update()` 拿到 .zero visibleRect，导致 setNeedsDisplay 失效。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }

        let visible = textView.enclosingScrollView?.documentVisibleRect ?? bounds

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: EditorTheme.synDefault.withAlphaComponent(0.4),
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: EditorTheme.synDefault,
        ]

        // linesStartingAt 内部 `storage.getLine(atPosition: minY)` 找 yPos==minY
        // 的 line —— 顶部时 documentVisibleRect.minY = -contentInsets.top（如 -8），
        // 第一行 yPos=0，找不到任何 line，iterator 返回 nil。clamp 到 0 才正确。
        let queryMinY = max(visible.minY, 0)
        let iterator = textView.layoutManager.linesStartingAt(queryMinY, until: visible.maxY)
        let labelWidth = gutterWidth - rightPadding

        for position in iterator {
            let label = "\(position.index + 1)"
            let attrs = (position.index == activeLineIndex) ? activeAttrs : baseAttrs
            let attr = NSAttributedString(string: label, attributes: attrs)
            let size = attr.size()                                     // 一次测量
            let x = max(0, labelWidth - size.width)
            let y = position.yPos + (position.height - size.height) / 2
            attr.draw(at: NSPoint(x: x, y: y))
        }
    }

    // MARK: - Click / Drag

    override func mouseDown(with event: NSEvent) {
        guard let textView else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        guard let pos = textView.layoutManager.textLineForPosition(p.y) else {
            super.mouseDown(with: event); return
        }
        dragAnchorLineIndex = pos.index
        // 单击行号选行：剥掉行尾的 \n / \r，让 collapse 时光标停在行末而不是下一行开头
        textView.selectionManager.setSelectedRange(trimmedLineRange(pos.range, in: textView))
        // setSelectedRange 内部已 post selectionChangedNotification，不要再补一次
    }

    override func mouseDragged(with event: NSEvent) {
        guard let textView, let anchor = dragAnchorLineIndex else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let pos = textView.layoutManager.textLineForPosition(p.y) else { return }
        let from = min(anchor, pos.index)
        let to = max(anchor, pos.index)
        guard let fromPos = textView.layoutManager.textLineForIndex(from),
              let toPos = textView.layoutManager.textLineForIndex(to) else { return }
        let location = fromPos.range.location
        let length = NSMaxRange(toPos.range) - location
        // 跨多行 drag：保留最后一行的 \n 是常规约定（VSCode/Xcode 一致）
        textView.selectionManager.setSelectedRange(NSRange(location: location, length: length))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorLineIndex = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键不该让 drag anchor 卡住——某些 mouseUp 不发的场景下用以清理状态
        dragAnchorLineIndex = nil
        super.rightMouseDown(with: event)
    }

    /// 把单行 range 末尾的换行字节剥掉（\n / \r）。最后一行无换行时返回原 range。
    private func trimmedLineRange(_ range: NSRange, in textView: TextView) -> NSRange {
        guard range.length > 0 else { return range }
        let ns = textView.string as NSString
        let lastIdx = range.location + range.length - 1
        guard lastIdx < ns.length else { return range }
        let c = ns.character(at: lastIdx)
        if c == 0x0A || c == 0x0D {
            return NSRange(location: range.location, length: range.length - 1)
        }
        return range
    }
}
