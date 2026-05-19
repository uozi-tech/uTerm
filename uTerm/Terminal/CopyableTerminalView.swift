import SwiftUI
import SwiftTerm
import AppKit

/// SwiftTerm's `TerminalView` never promotes itself to first responder when
/// clicked — its `mouseDown` only updates the selection. That means after the
/// user drag-selects text the terminal still doesn't hold keyboard focus, so
/// the Edit menu's Copy (`Cmd+C`) — which is dispatched down the responder
/// chain from the first responder — never reaches the terminal's `copy:`.
/// Claiming first responder on any click fixes `Cmd+C`; right-click copy
/// already works because that menu targets the terminal view directly.
final class CopyableTerminalView: SwiftTerm.TerminalView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }
}
