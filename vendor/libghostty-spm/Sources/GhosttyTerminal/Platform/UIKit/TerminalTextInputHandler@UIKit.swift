//
//  TerminalTextInputHandler@UIKit.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    @MainActor
    final class TerminalTextInputHandler {
        private weak var view: UITerminalView?
        private var markedTextState = TerminalMarkedTextState()
        /// uTerm 本地补丁：上屏后系统还可能改写的那段字（听写），见 `TerminalCommittedTail`。
        private var committedTail = TerminalCommittedTail()
        /// 正在把这一段的改写发给终端：这期间经过 `sendInputKeyEvent` 的按键是我们自己发的，不清这一段。
        private var isApplyingCommittedEdit = false

        var hasMarkedText: Bool {
            markedTextState.hasMarkedText
        }

        // Positions the UITextInput document holds before the marked text.
        //
        // The software keyboard's held Delete stops the moment the caret is
        // at the start of the document: before every repeat, UIKit's
        // `handleAutoDeleteWithExecutionContext:` asks
        // `-[UIResponder _selectionAtDocumentStart]` — `compare(
        // selectedTextRange.start, beginningOfDocument) == .orderedSame` —
        // and clears the repeat timer when it says yes. A terminal's
        // document is only ever the composition, empty at a prompt, so the
        // caret was always at its start and a held Delete sent exactly one
        // backspace. One position of anchor ahead of the composition keeps
        // the caret off the start; it carries no text, so what the keyboard
        // reads as context is unchanged. Catalyst has no software keyboard
        // and keeps the plain document.
        //
        // uTerm 本地补丁：留着已上屏的一段（听写）时不要占位——那段字已经让光标离开了开头，
        // 而占位没有字，`text(in:)` 读出来比范围短一格，UIKit 往前扩大范围找上一版时位置会差一格。
        #if targetEnvironment(macCatalyst)
            private static let documentAnchorLength = 0
        #else
            private static let documentAnchorLength = 1
        #endif

        /// The UITextInput document. Every `TerminalTextPosition` the view
        /// hands UIKit is a position in it.
        var document: TerminalInputDocument {
            TerminalInputDocument(
                anchorLength: committedTail.isEmpty ? Self.documentAnchorLength : 0,
                committedLength: committedTail.length,
                markedLength: markedTextState.documentLength,
            )
        }

        init(view: UITerminalView) {
            self.view = view
            TerminalDictationInput.startObserving()
        }

        // MARK: - Text Input

        func insertText(
            _ text: String,
            applyingStickyModifiers: Bool = false,
        ) {
            guard let view else { return }
            let isHypothesis = TerminalDictationInput.claimHypothesis()
            let startsCommittedText = !hasMarkedText && committedTail.isEmpty && isHypothesis
            let shouldNotifySelectionChange = shouldNotifySelectionChange || startsCommittedText

            TerminalDebugLog.log(
                .input,
                "insertText text=\(TerminalDebugLog.describe(text)) marked=\(hasMarkedText) dictation=\(startsCommittedText)",
            )

            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            markedTextState.clear()
            view.surface?.preedit("")
            #if !targetEnvironment(macCatalyst)
                if applyingStickyModifiers {
                    _ = view.handleStickyCommittedText(text)
                } else {
                    sendCommittedText(text, startingTail: startsCommittedText)
                }
            #else
                sendCommittedText(text, startingTail: startsCommittedText)
            #endif
            view.refreshInputAccessoryContent()

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
        }

        /// Deliver keyboard text the way a hardware keystroke does: on a key
        /// event that carries the text, so ghostty's key encoder writes the
        /// bytes.
        ///
        /// `ghostty_surface_text` is documented as "treated like a paste" —
        /// it lands in `completeClipboardPaste`, so with bracketed paste
        /// (mode 2004) active every software-keyboard character reaches the
        /// shell wrapped in `ESC[200~ … ESC[201~`. zsh renders a pasted
        /// region with `zle_highlight`'s `paste:standout`, which is why the
        /// character just typed shows up reverse-video until the next edit
        /// redraws the line. AppKit never hits this because typed text rides
        /// its `keyDown` event, and the bundled sample app never hits it
        /// because its simulated shell has no bracketed paste at all.
        ///
        /// The keycode is deliberately out of the AppKit virtual-keycode
        /// table, so ghostty resolves the physical key to `.unidentified`
        /// and encodes from the text alone. Both of ghostty's encoders
        /// handle that: the legacy one writes unmodified printable text
        /// directly, and the Kitty one treats an unmapped key carrying UTF-8
        /// as a pure text event — the same shape IME commits already had.
        ///
        /// Real pastes (the accessory's Paste button, the edit menu's
        /// `paste(_:)`) keep using `paste(text:)`, where the bracketed-paste
        /// markers belong. Text with newlines is routed there too: whatever
        /// produced it, a shell must not see those lines as Return presses.
        private func sendTypedText(_ text: String) {
            guard let view, !text.isEmpty else { return }

            guard !text.contains(where: \.isNewline) else {
                TerminalDebugLog.log(
                    .input,
                    "typed text has newlines, sending as paste bytes=\(text.utf8.count)",
                )
                view.paste(text: text)
                return
            }

            var event = ghostty_input_key_s()
            event.action = GHOSTTY_ACTION_PRESS
            event.mods = ghostty_input_mods_e(rawValue: 0)
            event.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            event.keycode = 0xFFFF
            event.composing = false
            event.unshifted_codepoint = text.unicodeScalars.first.map(\.value) ?? 0

            text.withCString { ptr in
                event.text = ptr
                view.sendInputKeyEvent(event)
            }
        }

        /// 上屏一段字。留着听写那一段时接在它后面（UIKit 下一版结果要连同它一起找）；没留着就和以前一样直接发。
        /// `startingTail`：这是听写的第一版（UIKit 在光标处插入时走 `insertText`，见 `TerminalDictationInput`），从它开始记。
        private func sendCommittedText(_ text: String, startingTail: Bool = false) {
            guard !committedTail.isEmpty || startingTail else {
                sendTypedText(text)
                return
            }
            applyCommittedEdit { sendTypedText(text) }
            if text.contains(where: \.isNewline) {
                // 带换行的走了粘贴，那一行已经交出去了。
                committedTail.clear()
            } else {
                committedTail.append(text)
            }
        }

        private func applyCommittedEdit(_ body: () -> Void) {
            let wasApplying = isApplyingCommittedEdit
            isApplyingCommittedEdit = true
            defer { isApplyingCommittedEdit = wasApplying }
            body()
        }

        /// uTerm 本地补丁：`replace(_:withText:)` 在没有组字时的实现。范围落在已上屏的那一段里就按范围改
        ///（退格 + 补字），落在那一段之后就是在光标处插入、并从这里开始记。
        func replaceCommittedText(in range: TerminalTextRange, with text: String) {
            guard let view else { return }
            _ = TerminalDictationInput.claimHypothesis()
            let tailRange = document.committedRange(of: NSRange(location: range.location, length: range.length))

            TerminalDebugLog.log(
                .input,
                "replace committed range=\(TerminalDebugLog.describe(tailRange)) tail=\(committedTail.length) text=\(TerminalDebugLog.describe(text))",
            )

            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)

            let edit = committedTail.replace(tailRange, with: text)
            applyCommittedEdit {
                for _ in 0 ..< edit.deletions {
                    view.sendBackspaceKey()
                }
                sendTypedText(edit.typed)
            }
            if edit.typed.contains(where: \.isNewline) {
                committedTail.clear()
            }
            view.refreshInputAccessoryContent()

            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        /// 不在组字时按了退格：留着那一段就跟着删掉最后一个字符，文档和终端那一行保持一致。
        func performBackspace(_ send: () -> Void) {
            guard let view, !committedTail.isEmpty else {
                send()
                return
            }
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)
            committedTail.removeLast()
            applyCommittedEdit(send)
            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        /// 终端那一行被别的输入改了（按键、粘贴、失焦）：清掉已上屏的那一段。
        /// 听写进行中清掉会让 UIKit 取消这次听写——用户确实做了别的事。
        func resetCommittedText() {
            guard !isApplyingCommittedEdit, !committedTail.isEmpty, let view else { return }
            TerminalDebugLog.log(.input, "reset committed tail=\(committedTail.length)")
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)
            committedTail.clear()
            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        func setMarkedText(_ text: String?, selectedRange: NSRange) {
            guard let view else { return }
            let shouldNotifySelectionChange = shouldNotifySelectionChange

            TerminalDebugLog.log(
                .ime,
                "setMarkedText text=\(TerminalDebugLog.describe(text)) selected=\(TerminalDebugLog.describe(selectedRange))",
            )

            #if !targetEnvironment(macCatalyst)
                if let text, !text.isEmpty {
                    if view.stickyModifiers.hasActiveModifiers {
                        view.inputDelegate?.textWillChange(view)
                        if shouldNotifySelectionChange {
                            view.inputDelegate?.selectionWillChange(view)
                        }

                        markedTextState.clear()
                        view.surface?.preedit("")
                        _ = view.handleStickyMarkedText(text)
                        view.refreshInputAccessoryContent()

                        if shouldNotifySelectionChange {
                            view.inputDelegate?.selectionDidChange(view)
                        }
                        view.inputDelegate?.textDidChange(view)
                        return
                    }
                }
            #endif

            view.dismissTouchSelection()
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)

            markedTextState.setMarkedText(text, selectedRange: selectedRange)

            if let text = markedTextState.text, !text.isEmpty {
                view.surface?.preedit(text)
            } else {
                view.surface?.preedit("")
            }
            view.refreshInputAccessoryContent()

            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        func unmarkText(
            applyingStickyModifiers: Bool = false,
        ) {
            guard let view else { return }
            let shouldNotifySelectionChange = shouldNotifySelectionChange
            let committedText = markedTextState.text

            TerminalDebugLog.log(
                .ime,
                "unmarkText committed=\(TerminalDebugLog.describe(committedText))",
            )

            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            markedTextState.clear()
            view.surface?.preedit("")
            if let committedText, !committedText.isEmpty {
                #if !targetEnvironment(macCatalyst)
                    if applyingStickyModifiers {
                        _ = view.handleStickyCommittedText(committedText)
                    } else {
                        sendCommittedText(committedText)
                    }
                #else
                    sendCommittedText(committedText)
                #endif
            }
            view.refreshInputAccessoryContent()

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
        }

        func markedTextRange() -> TerminalTextRange? {
            guard markedTextState.hasMarkedText else { return nil }
            return TerminalTextRange(
                location: document.position(ofMarkedOffset: markedTextState.markedRange.location),
                length: markedTextState.markedRange.length,
            )
        }

        func selectedTextRange() -> TerminalTextRange {
            TerminalTextRange(
                location: document.position(ofMarkedOffset: markedTextState.selectedRange.location),
                length: markedTextState.selectedRange.length,
            )
        }

        func setSelectedTextRange(_ range: UITextRange?) {
            let clampedRange = if let range = range as? TerminalTextRange {
                document.markedRange(of: NSRange(location: range.location, length: range.length))
            } else {
                NSRange(location: 0, length: 0)
            }
            guard markedTextState.selectedRange != clampedRange else { return }
            TerminalDebugLog.log(
                .ime,
                "setSelectedTextRange range=\(TerminalDebugLog.describe(clampedRange))",
            )
            notifySelectionWillChange()
            markedTextState.setMarkedText(markedTextState.text, selectedRange: clampedRange)
            notifySelectionDidChange()
        }

        func text(in range: TerminalTextRange) -> String? {
            let document = document
            guard range.location >= 0, range.length >= 0, range.location + range.length <= document.length else { return nil }
            let nsRange = NSRange(location: range.location, length: range.length)
            guard let marked = markedTextState.text(in: document.markedRange(of: nsRange)) else { return nil }
            return (committedTail.text(in: document.committedRange(of: nsRange)) ?? "") + marked
        }

        func deleteBackwardInMarkedText() -> Bool {
            guard let view else { return false }
            guard markedTextState.hasMarkedText else { return false }
            let shouldNotifySelectionChange = shouldNotifySelectionChange
            TerminalDebugLog.log(
                .ime,
                "deleteBackwardInMarkedText selected=\(TerminalDebugLog.describe(markedTextState.selectedRange))",
            )
            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            _ = markedTextState.deleteBackward()
            view.surface?.preedit(markedTextState.text ?? "")
            view.refreshInputAccessoryContent()

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
            return true
        }

        func notifyGeometryDidChange(reason: String) {
            guard let view else { return }
            TerminalDebugLog.log(
                .ime,
                "notifyGeometryDidChange reason=\(reason) selected=\(TerminalDebugLog.describe(markedTextState.selectedRange)) documentLength=\(markedTextState.documentLength) marked=\(hasMarkedText)",
            )
            view.inputDelegate?.selectionWillChange(view)
            view.inputDelegate?.selectionDidChange(view)
            if view.isFirstResponder {
                view.reloadInputViews()
            }
        }

        private var shouldNotifySelectionChange: Bool {
            hasMarkedText
                || !committedTail.isEmpty
                || markedTextState.selectedRange.location != 0
                || markedTextState.selectedRange.length != 0
        }

        private func notifySelectionWillChange() {
            if let view {
                view.inputDelegate?.selectionWillChange(view)
            }
        }

        private func notifySelectionDidChange() {
            if let view {
                view.inputDelegate?.selectionDidChange(view)
            }
        }
    }
#endif
