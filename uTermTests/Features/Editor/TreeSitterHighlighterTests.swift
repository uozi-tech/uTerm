// uTermTests/Editor/TreeSitterHighlighterTests.swift
import XCTest
import AppKit
import CodeEditTextView
import SwiftTreeSitter
import TreeSitterGo
@testable import uTerm

@MainActor
final class TreeSitterHighlighterTests: XCTestCase {

    private func sRGB(_ color: NSColor, _ appearance: NSAppearance.Name = .darkAqua) -> (Double, Double, Double) {
        var out: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            out = (Double(resolved.redComponent),
                   Double(resolved.greenComponent),
                   Double(resolved.blueComponent))
        }
        return out
    }

    private func near(_ lhs: (Double, Double, Double), _ rhs: (Double, Double, Double)) -> Bool {
        abs(lhs.0 - rhs.0) < 0.01 &&
        abs(lhs.1 - rhs.1) < 0.01 &&
        abs(lhs.2 - rhs.2) < 0.01
    }

    private func makeGoHighlighter() -> TreeSitterHighlighter {
        let lang = Language(language: tree_sitter_go())
        // Minimal inline query covering the tokens our assertions check.
        // debounceMs: 0 → synchronous reparse for test determinism.
        let query = """
        (comment) @comment
        ["func" "var" "const" "return" "if" "else" "for" "package" "import"] @keyword
        (int_literal) @number
        """
        return TreeSitterHighlighter(language: lang,
                                     highlightsQueryText: query,
                                     debounceMs: 0)
    }

    func test_go_simpleSnippet_yieldsKeywordAndNumber() {
        let h = makeGoHighlighter()
        var captured: [(NSRange, NSColor)] = []
        h.initialHighlight(text: "package main") { captured = $0 }
        XCTAssertFalse(captured.isEmpty, "Expected at least one highlight")
        XCTAssertTrue(captured.contains(where: { $0.1 == EditorTheme.synKeyword }),
                      "Expected a keyword color for 'package'")
    }

    func test_initialHighlight_returnsNonEmptyForKnownTokens() {
        let h = makeGoHighlighter()
        var captured: [(NSRange, NSColor)] = []
        h.initialHighlight(text: "func main() { var x = 1 }") { captured = $0 }
        XCTAssertFalse(captured.isEmpty)
    }

    func test_incrementalEdit_reusesTreeAndFindsComment() {
        let h = makeGoHighlighter()
        h.initialHighlight(text: "var x = 1") { _ in }
        var applied: [(NSRange, NSColor)] = []
        // Append " // hello" at the end — synchronous because debounceMs == 0
        h.didEdit(range: NSRange(location: 9, length: 0),
                  replacement: " // hello",
                  fullText: "var x = 1 // hello") { applied = $0 }
        XCTAssertTrue(applied.contains(where: { $0.1 == EditorTheme.synComment }),
                      "Expected comment color after incremental edit")
    }

    func test_dispose_cancelsDebounce() {
        let h = makeGoHighlighter()
        h.initialHighlight(text: "var x = 1") { _ in }
        // Should not crash
        h.dispose()
    }

    func test_emptyText_returnsNoHighlights() {
        let h = makeGoHighlighter()
        var captured: [(NSRange, NSColor)] = []
        h.initialHighlight(text: "") { captured = $0 }
        XCTAssertTrue(captured.isEmpty)
    }

    func test_registryGoQuery_yieldsHighlights() {
        guard let entry = GrammarRegistry.entry(for: "go") else {
            XCTFail("Expected Go grammar entry")
            return
        }
        let registryHighlighter = TreeSitterHighlighter(language: entry.language,
                                                        highlightsQueryText: entry.highlightsQueryText,
                                                        debounceMs: 0)
        var registryPairs: [(NSRange, NSColor)] = []
        registryHighlighter.initialHighlight(text: "func main() { return }") {
            registryPairs = $0
        }
        XCTAssertFalse(registryPairs.isEmpty)
    }

    func test_bindingDrivenTextReplacement_reappliesSyntaxHighlights() {
        let buffer = FileBuffer(remotePath: "/tmp/main.go", kind: .code(language: "go"))
        let controller = CodeEditorController()
        let scrollView = NSScrollView()
        let textView = TextView(
            string: "",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: EditorTheme.foreground,
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: controller
        )
        scrollView.documentView = textView
        controller.attach(textView: textView, scrollView: scrollView, buffer: buffer)

        controller.isUpdatingFromBinding = true
        textView.setText("func main() { return }")
        controller.isUpdatingFromBinding = false
        controller.ensureGutterAttached()

        let keywordRange = ("func main() { return }" as NSString).range(of: "func")
        let color = textView.textStorage?.attribute(.foregroundColor,
                                                    at: keywordRange.location,
                                                    effectiveRange: nil) as? NSColor
        XCTAssertNotNil(color)
        let actual = sRGB(color ?? .clear)
        let expected = sRGB(EditorTheme.synKeyword)
        XCTAssertTrue(near(actual, expected), "actual \(actual), expected keyword \(expected)")
    }

    func test_unsupportedDetectedCodeLanguage_usesFallbackHighlights() {
        let buffer = FileBuffer(remotePath: "/etc/nginx/nginx.conf", kind: .code(language: "nginx"))
        let controller = CodeEditorController()
        let scrollView = NSScrollView()
        let textView = TextView(
            string: "",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: EditorTheme.foreground,
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: controller
        )
        scrollView.documentView = textView
        controller.attach(textView: textView, scrollView: scrollView, buffer: buffer)

        let source = "server { listen 80; # enabled\n}"
        controller.isUpdatingFromBinding = true
        textView.setText(source)
        controller.isUpdatingFromBinding = false
        controller.ensureGutterAttached()

        let numberRange = (source as NSString).range(of: "80")
        let color = textView.textStorage?.attribute(.foregroundColor,
                                                    at: numberRange.location,
                                                    effectiveRange: nil) as? NSColor
        XCTAssertNotNil(color)
        let actual = sRGB(color ?? .clear)
        let expected = sRGB(EditorTheme.synNumber)
        XCTAssertTrue(near(actual, expected), "actual \(actual), expected number \(expected)")
    }

    // MARK: - Buffer switching (residual-highlighter regression)

    /// Build a controller already attached to `buffer` with `text` loaded,
    /// mirroring the makeNSView → attach → setText → ensureGutterAttached path.
    private func attachedController(for buffer: FileBuffer,
                                    text: String) -> (CodeEditorController, TextView) {
        let controller = CodeEditorController()
        let scrollView = NSScrollView()
        let textView = TextView(
            string: "",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: EditorTheme.foreground,
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: controller
        )
        scrollView.documentView = textView
        controller.attach(textView: textView, scrollView: scrollView, buffer: buffer)
        controller.isUpdatingFromBinding = true
        textView.setText(text)
        controller.isUpdatingFromBinding = false
        controller.ensureGutterAttached()
        return (controller, textView)
    }

    func test_switchingToAnotherCodeLanguage_dropsPreviousHighlighter() {
        // Previous file: Go (tree-sitter strategy).
        let goBuffer = FileBuffer(remotePath: "/tmp/main.go", kind: .code(language: "go"))
        let (controller, textView) = attachedController(for: goBuffer,
                                                        text: "func main() { return }")

        // Switch to an nginx file in the SAME coordinator. SwiftUI reuses the
        // coordinator for two .code buffers (no `.id` on the body), so the switch
        // arrives via updateNSView → rebind, not a fresh makeNSView/attach.
        let nginxBuffer = FileBuffer(remotePath: "/etc/nginx/nginx.conf",
                                     kind: .code(language: "nginx"))
        controller.rebind(to: nginxBuffer)
        let source = "server { listen 80; }"
        controller.isUpdatingFromBinding = true
        textView.setText(source)
        controller.isUpdatingFromBinding = false
        controller.ensureGutterAttached()

        // "server" is an nginx keyword but a bare identifier to the Go grammar; with the
        // stale Go highlighter still in effect it would stay foreground (the bug).
        let range = (source as NSString).range(of: "server")
        let color = textView.textStorage?.attribute(.foregroundColor,
                                                     at: range.location,
                                                     effectiveRange: nil) as? NSColor
        XCTAssertNotNil(color)
        let actual = sRGB(color ?? .clear)
        let expected = sRGB(EditorTheme.synKeyword)
        XCTAssertTrue(near(actual, expected),
                      "After switching Go→nginx, 'server' should use the nginx keyword color; got \(actual)")
    }

    func test_editAfterSwitch_writesToNewBufferNotPrevious() {
        let goBuffer = FileBuffer(remotePath: "/tmp/main.go", kind: .code(language: "go"))
        let (controller, textView) = attachedController(for: goBuffer,
                                                        text: "package main")

        let nginxBuffer = FileBuffer(remotePath: "/etc/nginx/nginx.conf",
                                     kind: .code(language: "nginx"))
        controller.rebind(to: nginxBuffer)
        controller.isUpdatingFromBinding = true
        textView.setText("server { }")
        controller.isUpdatingFromBinding = false
        // The editor reports a user edit through the delegate.
        controller.textView(textView,
                            didReplaceContentsIn: NSRange(location: 0, length: 0),
                            with: "server { }")

        XCTAssertEqual(nginxBuffer.text, "server { }",
                       "Edits after a switch must land in the active buffer")
        XCTAssertTrue(nginxBuffer.isDirty)
        XCTAssertEqual(goBuffer.text, "",
                       "The previously open buffer must not receive the new file's edits")
        XCTAssertFalse(goBuffer.isDirty)
    }
}
