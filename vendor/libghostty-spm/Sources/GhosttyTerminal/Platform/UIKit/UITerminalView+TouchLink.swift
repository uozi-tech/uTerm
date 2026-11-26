//
//  UITerminalView+TouchLink.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import Foundation
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        func touchLinkExists(at point: CGPoint) -> Bool {
            guard let surface else { return false }
            return hoveringLink(at: point, mods: linkMods(.super_, on: surface), on: surface) { $0.found }
        }

        /// uTerm 补丁：程序接管着鼠标（Claude Code、vim）时 Ghostty 只在按着 Shift 时认链接，⌘ 点会被当成鼠标事件报给
        /// 程序。这时把 ⌘ 报成 ⌘⇧：Ghostty 认链接前会去掉这个 Shift，点击也不报给程序（同 Mac 的 `linkMods`）。
        func linkMods(_ mods: TerminalInputModifiers, on surface: TerminalSurface) -> TerminalInputModifiers {
            guard mods.contains(.super_), !mods.contains(.shift), surface.isMouseCaptured else { return mods }
            return mods.union(.shift)
        }

        /// uTerm 补丁：手指轻点。宿主（`uTermTapOpensLink`）说这条链接开，就当 ⌘ 点打开它；程序接管着鼠标时也一样。
        /// 宿主没接时退回上游：只开没被接管时的 http(s) 网址。返回 true = 开了，这次点击不再交给终端。
        func openTappedLink(at point: CGPoint, on surface: TerminalSurface) -> Bool {
            guard let opens = uTermTapOpensLink else {
                return !surface.isMouseCaptured && openWebLink(at: point, on: surface)
            }
            let mods = linkMods(.super_, on: surface)
            return hoveringLink(at: point, mods: mods, on: surface) { link in
                guard let url = link.url, !url.isEmpty, opens(url) else { return false }
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
                return core.bridge.linkProbe?.opened == true
            }
        }

        /// A left click at `point` with `mods`. With Command alone it opens
        /// the link there, which Ghostty reports as `GHOSTTY_ACTION_OPEN_URL`.
        func sendCommandClick(at point: CGPoint, mods: TerminalInputModifiers, on surface: TerminalSurface) {
            let mods = linkMods(mods, on: surface)
            hoveringLink(at: point, mods: mods, on: surface) { _ in
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
            }
        }

        /// Command-clicks the http or https link at `point`, and says whether
        /// the host handled it.
        func openWebLink(at point: CGPoint, on surface: TerminalSurface) -> Bool {
            hoveringLink(at: point, mods: .super_, on: surface) { link in
                guard let url = link.url,
                      url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
                else { return false }
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
                return core.bridge.linkProbe?.opened == true
            }
        }

        /// Ghostty looks for a link only when the pointer reaches another
        /// cell (`link_point`), and its apprt drops a move of under a pixel,
        /// so the pointer comes in from off the view and leaves again.
        private func hoveringLink<Result>(
            at point: CGPoint,
            mods: TerminalInputModifiers,
            on surface: TerminalSurface,
            _ body: (TerminalLinkProbe) -> Result,
        ) -> Result {
            let sent = surfacePoint(point)
            surface.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
            core.bridge.linkProbe = TerminalLinkProbe()
            defer {
                surface.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
                core.bridge.linkProbe = nil
            }
            surface.sendMousePos(x: Double(sent.x), y: Double(sent.y), modifiers: mods)
            return body(core.bridge.linkProbe!)
        }
    }
#endif
