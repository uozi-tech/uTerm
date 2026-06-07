import AppKit
import CodeEditTextView

nonisolated enum IndentGuideLayout {
    static let defaultTabWidth = 4

    static func leadingIndentColumns(in line: String,
                                     tabWidth: Int = defaultTabWidth) -> [Int] {
        guard tabWidth > 0 else { return [] }

        var visualColumn = 0
        var columns: [Int] = []

        for character in line {
            switch character {
            case " ":
                visualColumn += 1
                if visualColumn.isMultiple(of: tabWidth) {
                    columns.append(visualColumn)
                }
            case "\t":
                let nextStop = ((visualColumn / tabWidth) + 1) * tabWidth
                visualColumn = nextStop
                columns.append(nextStop)
            default:
                return columns
            }
        }

        return columns
    }
}

/// VSCode-style indentation guides for the code editor.
///
/// The layer is attached to `TextView` so it scrolls in document coordinates just
/// like `ActiveLineOverlay` and the line-number gutter. Only visible lines are
/// inspected on each refresh.
@MainActor
final class IndentGuideOverlay {
    private weak var textView: TextView?
    private let guideLayer = CAShapeLayer()
    private let activeGuideLayer = CAShapeLayer()
    private let tabWidth: Int

    init(textView: TextView, tabWidth: Int = IndentGuideLayout.defaultTabWidth) {
        self.textView = textView
        self.tabWidth = tabWidth

        configure(guideLayer)
        configure(activeGuideLayer)
        activeGuideLayer.zPosition = -0.45
        guideLayer.zPosition = -0.5
        textView.layer?.insertSublayer(guideLayer, at: 0)
        textView.layer?.insertSublayer(activeGuideLayer, above: guideLayer)
        applyStrokeColors()
    }

    func update(visibleRect: CGRect, activeLineIndex: Int?) {
        guard let textView else {
            clear()
            return
        }

        guideLayer.frame = textView.bounds
        activeGuideLayer.frame = textView.bounds

        let guidePath = CGMutablePath()
        let activePath = CGMutablePath()
        let text = textView.string as NSString
        let charWidth = Self.characterAdvance(in: textView)
        let contentLeft = textView.layoutManager.edgeInsets.left
        let queryMinY = max(visibleRect.minY, 0)
        let queryMaxY = max(visibleRect.maxY, 0)
        let iterator = textView.layoutManager.linesStartingAt(queryMinY, until: queryMaxY)

        for position in iterator {
            let line = lineString(in: text, range: position.range)
            let columns = IndentGuideLayout.leadingIndentColumns(in: line, tabWidth: tabWidth)
            guard !columns.isEmpty else { continue }

            let minY = max(position.yPos, visibleRect.minY)
            let maxY = min(position.yPos + position.height, visibleRect.maxY)
            guard maxY > minY else { continue }

            for column in columns {
                let x = floor(contentLeft + CGFloat(column) * charWidth) + 0.5
                let path = (position.index == activeLineIndex && column == columns.last)
                    ? activePath
                    : guidePath
                path.move(to: CGPoint(x: x, y: minY))
                path.addLine(to: CGPoint(x: x, y: maxY))
            }
        }

        guideLayer.path = guidePath
        activeGuideLayer.path = activePath
        applyStrokeColors()
    }

    func clear() {
        guideLayer.path = nil
        activeGuideLayer.path = nil
    }

    func removeFromTextView() {
        guideLayer.removeFromSuperlayer()
        activeGuideLayer.removeFromSuperlayer()
    }

    private func configure(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineWidth = 1
        layer.lineCap = .butt
        layer.allowsEdgeAntialiasing = false
    }

    private func applyStrokeColors() {
        guard let textView else { return }
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            guideLayer.strokeColor = EditorTheme.synDefault.withAlphaComponent(0.18).cgColor
            activeGuideLayer.strokeColor = EditorTheme.synDefault.withAlphaComponent(0.42).cgColor
        }
    }

    private func lineString(in text: NSString, range: NSRange) -> String {
        guard range.location < text.length else { return "" }
        let length = min(range.length, text.length - range.location)
        return text.substring(with: NSRange(location: range.location, length: length))
    }

    private static func characterAdvance(in textView: TextView) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textView.font,
            .kern: textView.kern,
        ]
        let width = (" " as NSString).size(withAttributes: attrs).width
        return max(width, 1)
    }
}
