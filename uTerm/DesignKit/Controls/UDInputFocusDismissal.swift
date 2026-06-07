import AppKit
import SwiftUI

enum UDInputFocusDismissal {
    static func shouldDismissFocus(eventWindow: NSWindow?,
                                   inputWindow: NSWindow?,
                                   eventLocationInWindow: NSPoint,
                                   inputFrameInWindow: NSRect) -> Bool {
        guard let eventWindow,
              let inputWindow,
              eventWindow === inputWindow
        else { return false }

        return !inputFrameInWindow.contains(eventLocationInWindow)
    }
}

struct UDInputFocusDismissMonitor: NSViewRepresentable {
    var isFocused: FocusState<Bool>.Binding

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isFocused = isFocused.wrappedValue
        nsView.onDismiss = { isFocused.wrappedValue = false }
        nsView.updateMonitor()
    }

    final class MonitorView: NSView {
        var isFocused = false
        var onDismiss: () -> Void = {}
        private nonisolated(unsafe) var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        func updateMonitor() {
            if window != nil, isFocused {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    self?.handleMouseDown(event) ?? event
                }
            } else {
                removeMonitor()
            }
        }

        private func handleMouseDown(_ event: NSEvent) -> NSEvent {
            guard isFocused,
                  let inputWindow = window
            else { return event }

            let inputFrame = convert(bounds, to: nil)
            guard UDInputFocusDismissal.shouldDismissFocus(eventWindow: event.window,
                                                           inputWindow: inputWindow,
                                                           eventLocationInWindow: event.locationInWindow,
                                                           inputFrameInWindow: inputFrame)
            else { return event }

            onDismiss()
            return event
        }

        private nonisolated func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
