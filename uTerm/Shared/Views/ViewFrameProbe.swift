import AppKit
import SwiftUI

/// Holds a weak reference to a view's backing `NSView` so a drag `.onDrag`
/// closure can read the view's current on-screen frame at drag start.
final class ViewFrameProbe {
    weak var view: NSView?

    @MainActor var screenFrame: CGRect? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }
}

/// Transparent background bridge that wires a view's `NSView` into a
/// `ViewFrameProbe` for on-demand screen-frame lookups.
struct ViewFrameReader: NSViewRepresentable {
    let probe: ViewFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.view = nsView
    }
}
