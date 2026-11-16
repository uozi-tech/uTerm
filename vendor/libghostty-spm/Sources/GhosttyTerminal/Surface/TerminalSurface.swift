//
//  TerminalSurface.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Thread-safe wrapper around `ghostty_surface_t`.
///
/// All access must happen on the main actor. The surface should be freed
/// explicitly via ``free()`` before the wrapper is deallocated; `deinit`
/// includes a safety net but relying on it is discouraged.
@MainActor
public final class TerminalSurface {
    private var surface: ghostty_surface_t?
    private var hasBeenFreed = false
    /// Told about every font-size action this surface performed, whichever
    /// path it came by: a host's binding action, a pinch, Cmd+=/-/0 on a
    /// hardware keyboard, a host's `sendKey`. Ghostty cannot report the
    /// resulting size, so the coordinator keeps it (`TerminalFontSize`).
    var onFontSizeAction: ((TerminalFontSizeAction) -> Void)?
    /// uTerm 本地补丁：程序收不收没有绑定接的 ⌘（super）组合（宿主读影子终端：开了 kitty 键盘协议才收）。返回 false 时
    /// 这类按键不交给引擎——legacy 模式下 Ghostty 会把 ⌘↑ 编成 `CSI 1;9A`、⌘↩ 编成 `CSI 27;9;13~`，shell 不认，只会在命令行里
    /// 留下「;9A」这类残渣；带 ⌘ 的字母键本来就编不出字节。绑定（⌘← / ⌘→ / ⌘⌫ / ⌘C …）照常。nil = 照发（上游行为）。
    /// 由 `TerminalSurfaceCoordinator.sendsCommandChords` 设。
    var sendsCommandChords: (() -> Bool)?
    /// 按下时丢掉的键码：它们的重复、抬起也丢，成对。
    private var droppedCommandKeycodes: Set<UInt32> = []
    /// A precision scroll went to the surface: `y`, positive toward the
    /// scrollback. Every one goes through here, a host's included, so the
    /// view can bring a viewport left between rows back to a row
    /// (`TerminalSmoothScrollSettler`).
    var onPrecisionScroll: ((Double) -> Void)?

    init(_ surface: ghostty_surface_t) {
        self.surface = surface
    }

    var rawValue: ghostty_surface_t? {
        surface
    }

    // MARK: - Input

    @discardableResult
    func sendKeyEvent(_ event: ghostty_input_key_s) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface key ignored: missing surface")
            return false
        }
        if dropsCommandChord(event, on: s) {
            TerminalDebugLog.log(.input, "surface key dropped: unbound command chord keycode=\(event.keycode)")
            return true
        }
        // Asked before the key goes in: the binding check reads the
        // surface's keybind state, which performing the key can move on.
        let fontSizeAction = fontSizeAction(forKey: event)
        let result = ghostty_surface_key(s, event)
        TerminalDebugLog.log(
            .input,
            "surface key action=\(TerminalDebugLog.describe(event.action)) keycode=\(event.keycode) mods=0x\(String(event.mods.rawValue, radix: 16)) consumed=0x\(String(event.consumed_mods.rawValue, radix: 16)) text=\(terminalKeyText(event)) composing=\(event.composing) result=\(result)",
        )
        if result, let fontSizeAction {
            onFontSizeAction?(fontSizeAction)
        }
        return result
    }

    /// uTerm 本地补丁：见 `sendsCommandChords`。两端所有按键路径（硬件键盘、IME 收字、宿主的 `sendKey`）都经这里。
    private func dropsCommandChord(_ event: ghostty_input_key_s, on surface: ghostty_surface_t) -> Bool {
        if event.action == GHOSTTY_ACTION_RELEASE {
            return droppedCommandKeycodes.remove(event.keycode) != nil
        }
        if event.action == GHOSTTY_ACTION_REPEAT, droppedCommandKeycodes.contains(event.keycode) { return true }
        droppedCommandKeycodes.remove(event.keycode)
        guard let sendsCommandChords,
              event.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0,
              !Self.modifierKeycodes.contains(event.keycode),
              !sendsCommandChords()
        else { return false }
        var flags = ghostty_binding_flags_e(rawValue: 0)
        guard !ghostty_surface_key_is_binding(surface, event, &flags) else { return false }
        droppedCommandKeycodes.insert(event.keycode)
        return true
    }

    /// 修饰键本身（按下 ⌘ 那一下也带着 super）：照常交给引擎，它靠这些更新修饰键状态（⌘ 悬停链接等）。
    /// macOS 虚拟键码；iOS 的硬件键也先换成这套（`TerminalHardwareKeyRouter.appKitKeyCodeForUIKit`）。
    private static let modifierKeycodes: Set<UInt32> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]

    /// Pastes text into the surface. This is the text path: ghostty treats
    /// it as a paste, wrapping it in bracketed-paste markers for a program
    /// that asked for them. Keystrokes go through ``sendKey(_:)``.
    @discardableResult
    public func paste(text: String) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface text ignored: missing surface")
            return false
        }
        TerminalDebugLog.log(
            .input,
            "surface text=\(TerminalDebugLog.describe(text))",
        )
        text.withCString { cStr in
            ghostty_surface_text(s, cStr, UInt(text.utf8.count))
        }
        return true
    }

    /// Pastes text the way a clipboard paste goes: paste protection reads it
    /// first, and text it flags as unsafe — a newline for a program without
    /// bracketed paste — reaches the host as a
    /// ``TerminalClipboardConfirmationRequest`` and lands only if allowed.
    /// For text the user has not read, such as a drop. ``paste(text:)``
    /// sends without asking.
    @discardableResult
    public func pasteWithProtection(text: String) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface protected paste ignored: missing surface")
            return false
        }
        TerminalDebugLog.log(
            .input,
            "surface protected paste text=\(TerminalDebugLog.describe(text))",
        )
        text.withCString { cStr in
            ghostty_surface_paste_text(s, cStr, UInt(text.utf8.count))
        }
        return true
    }

    @discardableResult
    public func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: TerminalInputModifiers = [],
    ) -> Bool {
        sendMouseButton(state: state, button: button, mods: modifiers.ghosttyMods)
    }

    @discardableResult
    public func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e,
    ) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface mouse button ignored: missing surface")
            return false
        }
        let result = ghostty_surface_mouse_button(s, state, button, mods)
        TerminalDebugLog.log(
            .input,
            "surface mouseButton state=\(TerminalDebugLog.describe(state)) button=\(button.rawValue) mods=0x\(String(mods.rawValue, radix: 16)) result=\(result)",
        )
        return result
    }

    public func sendMousePos(
        x: Double,
        y: Double,
        modifiers: TerminalInputModifiers = [],
    ) {
        sendMousePos(x: x, y: y, mods: modifiers.ghosttyMods)
    }

    public func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface mouse position ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface mousePos x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) mods=0x\(String(mods.rawValue, radix: 16))",
        )
        ghostty_surface_mouse_pos(s, x, y, mods)
    }

    public func sendMouseScroll(
        x: Double,
        y: Double,
        mods: TerminalScrollModifiers = TerminalScrollModifiers(precision: true),
    ) {
        sendMouseScroll(x: x, y: y, mods: mods.rawValue)
    }

    func sendMouseScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface scroll ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface scroll x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) mods=0x\(String(mods, radix: 16))",
        )
        ghostty_surface_mouse_scroll(s, x, y, mods)
        if TerminalScrollModifiers(rawValue: mods).precision, y != 0 {
            onPrecisionScroll?(y)
        }
    }

    /// Whether the application currently owns the mouse (DEC 1000/1002/1003).
    /// Host UI (copy menu, context menu) must not steal a click while this
    /// is true. Ghostty still owns reporting vs local selection for events
    /// that reach the surface.
    public var isMouseCaptured: Bool {
        guard let s = surface else { return false }
        return ghostty_surface_mouse_captured(s)
    }

    func preedit(_ text: String) {
        guard let s = surface else {
            TerminalDebugLog.log(.ime, "surface preedit ignored: missing surface")
            return
        }
        TerminalDebugLog.log(.ime, "surface preedit=\(TerminalDebugLog.describe(text))")
        text.withCString { cStr in
            ghostty_surface_preedit(s, cStr, UInt(text.utf8.count))
        }
    }

    /// uTerm 本地补丁：清掉 Ghostty 自己的选区。C 接口没有清选区的函数，binding action 里也没有；能清它的入口里
    /// 唯一不往程序发东西、不碰鼠标状态的是 preedit：`preeditCallback` 收到非空的预编辑文字时按
    /// `selection-clear-on-typing`（默认开）清选区，而零宽字符（U+200B）算不出格子，不会真的留下预编辑。
    /// 副作用是同时清掉正在显示的预编辑，所以有输入法组字时（`composing`）不动。没有选区时什么都不做。
    /// 返回清没清。引擎下次重编时可以换成正经的 C 接口（见 libghostty-spm 的 UTERM-PATCHES.md）。
    @discardableResult
    func clearSelectionWithoutInput(composing: Bool) -> Bool {
        guard !composing, let s = surface, ghostty_surface_has_selection(s) else { return false }
        let zeroWidth = "\u{200B}"
        zeroWidth.withCString { cStr in
            ghostty_surface_preedit(s, cStr, UInt(zeroWidth.utf8.count))
        }
        return !ghostty_surface_has_selection(s)
    }

    /// uTerm 本地补丁：Ghostty 自己的选区里只剩空白（选中的内容被擦掉了）。没有选区时 false。
    func selectionIsBlank() -> Bool {
        guard let s = surface, ghostty_surface_has_selection(s), let text = readSelection() else { return false }
        return text.allSatisfy(\.isWhitespace)
    }

    // MARK: - Actions

    /// Invoke a named Ghostty binding action.
    ///
    /// Action names use the same syntax as Ghostty's `keybind` configuration,
    /// such as `copy_to_clipboard` or `scroll_page_lines:-3`.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.actions, "binding action ignored: missing surface")
            return false
        }
        let result = action.withCString { cStr in
            ghostty_surface_binding_action(s, cStr, UInt(action.utf8.count))
        }
        TerminalDebugLog.log(
            .actions,
            "binding action=\(TerminalDebugLog.describe(action)) result=\(result)",
        )
        if result, let fontSizeAction = TerminalFontSizeAction(bindingAction: action) {
            onFontSizeAction?(fontSizeAction)
        }
        return result
    }

    /// Jump the viewport by a number of shell prompts.
    ///
    /// Negative offsets move toward older prompts and positive offsets move
    /// toward newer prompts. This requires prompt markers from Ghostty shell
    /// integration, or equivalent OSC 133 markers from a host-managed backend.
    @discardableResult
    public func jumpToPrompt(by offset: Int16) -> Bool {
        performBindingAction("jump_to_prompt:\(offset)")
    }

    /// Reveal an absolute scrollback row, where zero is the first row.
    @discardableResult
    public func scrollToRow(_ row: UInt) -> Bool {
        performBindingAction("scroll_to_row:\(row)")
    }

    // MARK: - Rendering

    func draw() {
        guard let s = surface else { return }
        TerminalDebugLog.log(.render, "surface draw")
        ghostty_surface_draw(s)
    }

    #if os(macOS)
        /// uTerm 本地补丁：把视图所在的显示器报给引擎。渲染器按它绑定 CVDisplayLink；link 当初没建成（建 surface 时
        /// 没有活动显示器）的话，这次调用就是它重试的机会（见 AppTerminalView+DisplayID.swift）。
        func setDisplayID(_ id: UInt32) {
            guard let s = surface else { return }
            ghostty_surface_set_display_id(s, id)
        }
    #endif

    func refresh() {
        guard let s = surface else { return }
        TerminalDebugLog.log(.render, "surface refresh")
        ghostty_surface_refresh(s)
    }

    func setSize(width: UInt32, height: UInt32) {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface setSize ignored: missing surface")
            return
        }
        TerminalDebugLog.log(.metrics, "surface setSize \(width)x\(height)")
        ghostty_surface_set_size(s, width, height)
    }

    func setContentScale(x: Double, y: Double) {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface contentScale ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .metrics,
            "surface contentScale x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y))",
        )
        ghostty_surface_set_content_scale(s, x, y)
    }

    // MARK: - State

    func setFocus(_ focused: Bool) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface focus=\(focused)")
        ghostty_surface_set_focus(s, focused)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface colorScheme=\(scheme.rawValue)")
        ghostty_surface_set_color_scheme(s, scheme)
    }

    func setOcclusion(_ visible: Bool) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface occlusion visible=\(visible)")
        ghostty_surface_set_occlusion(s, visible)
    }

    // MARK: - Size Query

    func size() -> TerminalGridMetrics? {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface size query ignored: missing surface")
            return nil
        }
        let metrics = TerminalGridMetrics(ghostty_surface_size(s))
        TerminalDebugLog.log(.metrics, "surface size \(metrics.debugSummary)")
        return metrics
    }

    // MARK: - Selection

    struct SelectionResult {
        let text: String
        let offsetStart: UInt32
        let offsetLength: UInt32
        /// The selection's top-left cell in view points: the viewport's
        /// top-left when the selection starts above it, negative when none
        /// of it is on screen.
        var topLeftX: Double = -1
    }

    public func hasSelection() -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface selection query ignored: missing surface")
            return false
        }
        let result = ghostty_surface_has_selection(s)
        TerminalDebugLog.log(.input, "surface hasSelection=\(result)")
        return result
    }

    public func readSelection() -> String? {
        readSelectionResult()?.text
    }

    func readSelectionResult() -> SelectionResult? {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface readSelection ignored: missing surface")
            return nil
        }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &out) else {
            TerminalDebugLog.log(.input, "surface readSelection returned false")
            return nil
        }
        defer { ghostty_surface_free_text(s, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            TerminalDebugLog.log(.input, "surface readSelection empty")
            return SelectionResult(
                text: "",
                offsetStart: out.offset_start,
                offsetLength: out.offset_len,
            )
        }

        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        TerminalDebugLog.log(
            .input,
            "surface readSelection bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text)) offset=\(out.offset_start)+\(out.offset_len)",
        )
        return SelectionResult(
            text: text,
            offsetStart: out.offset_start,
            offsetLength: out.offset_len,
            topLeftX: out.tl_px_x,
        )
    }

    // MARK: - IME

    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        if let s = surface {
            ghostty_surface_ime_point(s, &x, &y, &w, &h)
        }
        TerminalDebugLog.log(
            .ime,
            "surface imePoint x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) width=\(String(format: "%.2f", w)) height=\(String(format: "%.2f", h))",
        )
        return (x, y, w, h)
    }

    // MARK: - Quicklook Word (Apple-only)

    #if canImport(UIKit) || canImport(AppKit)
        struct QuicklookWordResult {
            let word: String
            /// Linear cell index of the word's first cell in the viewport grid
            /// (`row * columns + column`); the grid position to use.
            let offsetStart: UInt32
            let offsetLength: UInt32
            // tl_px_x / tl_px_y are reported in host points (view coordinates),
            // not surface pixels. Ghostty's embedded API receives mouse_pos in
            // points and stores the cursor position * contentScale internally,
            // then divides by contentScale when reporting selection coordinates
            // back. Despite the name, tl_px_y is the row's text baseline plus
            // the top window padding, not the cell top, and tl_px_x includes
            // the left padding — dividing them by the cell size does not give
            // the grid position.
            let pointX: Double
            let pointY: Double
        }

        func quicklookWord() -> QuicklookWordResult? {
            guard let s = surface else {
                TerminalDebugLog.log(.input, "surface quicklookWord ignored: missing surface")
                return nil
            }
            var out = ghostty_text_s()
            guard ghostty_surface_quicklook_word(s, &out) else {
                TerminalDebugLog.log(.input, "surface quicklookWord returned false")
                return nil
            }
            defer { ghostty_surface_free_text(s, &out) }

            let word: String
            if let textPtr = out.text, out.text_len > 0 {
                let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
                    .map { UInt8(bitPattern: $0) }
                word = String(decoding: bytes, as: UTF8.self)
            } else {
                word = ""
            }
            TerminalDebugLog.log(
                .input,
                "surface quicklookWord word=\(TerminalDebugLog.describe(word)) offset=\(out.offset_start)+\(out.offset_len) pointX=\(String(format: "%.2f", out.tl_px_x)) pointY=\(String(format: "%.2f", out.tl_px_y))",
            )
            return QuicklookWordResult(
                word: word,
                offsetStart: out.offset_start,
                offsetLength: out.offset_len,
                pointX: out.tl_px_x,
                pointY: out.tl_px_y,
            )
        }

        func selectionContainsQuicklookWord() -> Bool {
            guard let selected = readSelectionResult(),
                  let word = quicklookWord(),
                  !word.word.isEmpty,
                  word.offsetLength > 0
            else { return false }

            let selectionStart = UInt64(selected.offsetStart)
            let selectionEnd = selectionStart + UInt64(selected.offsetLength)
            let wordStart = UInt64(word.offsetStart)
            let wordEnd = wordStart + UInt64(word.offsetLength)
            let contains = wordStart >= selectionStart && wordEnd <= selectionEnd
            TerminalDebugLog.log(
                .input,
                "surface selectionContainsQuicklookWord=\(contains) selection=\(selected.offsetStart)+\(selected.offsetLength) word=\(word.offsetStart)+\(word.offsetLength)",
            )
            return contains
        }
    #endif

    // MARK: - Process

    /// PID of the pty's foreground process group (`tcgetpgrp(pty)`). When the
    /// user runs a program in the pty this is that program's pid, so hosts can
    /// correlate a surface with an external process list. Ghostty returns 0
    /// when the surface has no process yet — surfaced here as nil.
    ///
    /// Always nil on the pinned Ghostty 1.3.1, for every backend: that release
    /// predates upstream's process-info API, and the shipped
    /// `ghostty_surface_foreground_pid` is a stub from
    /// `Patches/ghostty/0002-host-managed-io.patch` that reports 0.
    var foregroundPid: pid_t? {
        guard let s = surface else { return nil }
        let pid = ghostty_surface_foreground_pid(s)
        return pid == 0 ? nil : pid_t(pid)
    }

    /// Name of the pty's controlling tty (e.g. `/dev/ttys004`), or nil when the
    /// surface has no process yet. Useful as a cross-check for ``foregroundPid``.
    ///
    /// Always nil on the pinned Ghostty 1.3.1, for every backend: the shipped
    /// `ghostty_surface_tty_name` is a stub that returns the empty string, for
    /// the same reason ``foregroundPid`` is nil there.
    var ttyName: String? {
        guard let s = surface else { return nil }
        let str = ghostty_surface_tty_name(s)
        defer { ghostty_string_free(str) }
        guard let ptr = str.ptr, str.len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(str.len)),
            as: UTF8.self,
        )
    }

    // MARK: - Lifecycle

    func free() {
        guard !hasBeenFreed, let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface free")
        hasBeenFreed = true
        surface = nil
        ghostty_surface_free(s)
    }

    deinit {
        // Surface should be freed explicitly via free() before deinit.
        // The deinit safety net is intentionally removed because
        // Swift 6 strict concurrency prevents accessing @MainActor
        // state from nonisolated deinit.
    }
}

private func terminalKeyText(_ event: ghostty_input_key_s) -> String {
    guard let text = event.text else { return "nil" }
    return TerminalDebugLog.describe(String(cString: text))
}
