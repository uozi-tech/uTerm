//
//  UITerminalView+Scroll.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// A pan recognizer fed by wheel and trackpad scroll events alone.
    ///
    /// A scroll event is neither a touch nor a pointer drag: it reaches a
    /// pan recognizer only through `allowedScrollTypesMask`, and the touch
    /// recognizers never see it. Refusing every other event here keeps a
    /// finger on the touch-scroll recognizer and a pointer drag on the
    /// selection one without the view's delegate having to tell them apart.
    final class TerminalScrollWheelGestureRecognizer: UIPanGestureRecognizer {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedScrollTypesMask = [.continuous, .discrete]
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func shouldReceive(_ event: UIEvent) -> Bool {
            event.type == .scroll
        }
    }

    /// Touch-scroll momentum state; behavior lives in +Interaction.
    struct MomentumScrollState {
        var displayLink: CADisplayLink?
        var velocity: CGPoint = .zero
        var scrollsLocally = false
        var localRow: CGFloat = 0
        // uTerm 本地补丁（吸附整行，配合 GhosttyKit 0023 的像素级平滑滚动）：手指 / 惯性喂给 surface 的
        // 精确滚动像素累计在这里，停下时补一段把视口落回整行。Ghostty 与 GhosttyKit 的点击、选区命中都按整数视口算，
        // 停在半行会差一行。C 接口不报小数行，只能在 Swift 侧自己记。
        var pixelResidue: CGFloat = 0
        var snapLink: CADisplayLink?
        var snapRemaining: CGFloat = 0
        // uTerm 本地补丁（回弹，用 0023 的 ghostty_surface_set_overscroll）：拖过顶 / 底时手指走了多少像素（未衰减），
        // 以及松手 / 惯性撞边后的弹簧状态。
        var overscrollRaw: CGFloat = 0
        var bounceLink: CADisplayLink?
        var bounceStart: CFTimeInterval = 0
        var bounceFrom: CGFloat = 0
        var bounceVelocity: CGFloat = 0
        // uTerm 本地补丁（落点取整的惯性）：一次滑行要走的总像素、指数速率（1/s）、起点时刻、已发出的整像素。
        var glideTotal: CGFloat = 0
        var glideDuration: CGFloat = 0
        var glideStart: CFTimeInterval = 0
        var glideSent: CGFloat = 0
        /// 最近一次手指拖动发出位移的时刻，和那一刻 Ghostty 画面层上挂着的 IOSurface（用来判断拖动那一步画出来没有）。
        var lastDragTime: CFTimeInterval = 0
        var contentsAtLastDrag: ObjectIdentifier?
    }

    extension UITerminalView {
        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.session.reported == nil else { return }
            switch gesture.state {
            case .began:
                dismissTouchSelection(restoringViewport: false)
                stopMomentumScrolling()
            case .changed, .ended:
                // `.ended` still carries whatever moved since the last
                // `.changed`.
                break
            default:
                return
            }

            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            TerminalDebugLog.log(
                .input,
                "scroll wheel translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))",
            )

            // Ghostty's scroll C API has no key mods. The last mouse_pos
            // carries them, so a wheel event can target the cell under the
            // pointer (tmux, vim). View points: Ghostty applies content_scale
            // to a position, unlike the scroll delta below.
            let point = pointer.lastLocation ?? gesture.location(in: self)
            sendPointerPosition(at: point, remember: pointer.lastLocation == nil)

            // Always precision: UIKit hands a discrete wheel notch to the pan
            // recognizer as a point translation, not a line count, and
            // ghostty's non-precision path reads the value as lines times
            // the scroll multiplier.
            let scrollMods = TerminalScrollModifiers(precision: true)
            let pixels = TerminalScrollDistance.scrollPixels(
                for: translation,
                displayScale: resolvedDisplayScale(),
            )
            surface?.sendMouseScroll(
                x: Double(pixels.x),
                y: Double(pixels.y),
                mods: scrollMods.rawValue,
            )
        }

        @objc func handleTouchScrollGesture(
            _ gesture: UIPanGestureRecognizer,
        ) {
            #if !targetEnvironment(macCatalyst)
                if usesInlineTextSelection {
                    if gesture.state == .began {
                        touchSelection.panUsesSelection = touchSelection.range != nil && gesture.numberOfTouches == 1
                        momentumScroll.scrollsLocally = gesture.numberOfTouches == 2
                        momentumScroll.localRow = CGFloat(touchViewportOffset)
                    }
                    if touchSelection.panUsesSelection {
                        handleTouchSelectionPan(gesture)
                        return
                    }
                }
            #endif
            switch gesture.state {
            case .began:
                guard pointer.session.reported == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                if !usesInlineTextSelection {
                    dismissTouchSelection(restoringViewport: false)
                }
                TerminalDebugLog.log(.input, "touch scroll began")
                stopMomentumScrolling()
                stopScrollSnap()
                if momentumScroll.bounceLink != nil { stopBounce(resetting: true) }

            case .changed:
                guard pointer.session.reported == nil else { return }
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll changed translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))",
                )

                if usesInlineTextSelection, !momentumScroll.scrollsLocally {
                    sendPointerPosition(at: gesture.location(in: self))
                }
                scrollTouchContent(by: translation, momentum: .none)

            case .ended:
                guard pointer.session.reported == nil else { return }
                let velocity = gesture.velocity(in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll ended velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
                )
                if releaseOverscroll() { return }
                if !usesInlineTextSelection || momentumScroll.scrollsLocally || surface?.isMouseCaptured != true {
                    startMomentumScrolling(velocity: velocity)
                }
                // 没起惯性（抬手时几乎不动）就当场吸附；起了惯性的等惯性停下再吸附。
                if momentumScroll.displayLink == nil, surface?.isMouseCaptured != true { snapScrollToRow() }

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                stopMomentumScrolling()
                _ = releaseOverscroll()

            default:
                break
            }
        }

        func scrollTouchContent(by delta: CGPoint, momentum: TerminalScrollModifiers.Momentum) {
            if usesInlineTextSelection, momentumScroll.scrollsLocally {
                guard let metrics = surface?.size(), let bar = core.bridge.scrollbar else { return }
                let cellHeight = CGFloat(metrics.cellHeightPixels) / resolvedDisplayScale()
                guard cellHeight > 0 else { return }
                momentumScroll.localRow = min(
                    max(0, CGFloat(bar.total) - CGFloat(bar.len)),
                    max(0, momentumScroll.localRow - delta.y / cellHeight),
                )
                _ = surface?.scrollToRow(UInt(momentumScroll.localRow.rounded()))
                core.requestImmediateTick()
                return
            }
            var pixels = TerminalScrollDistance.scrollPixels(for: delta, displayScale: resolvedDisplayScale())
            if pixels.y != 0, surface?.isMouseCaptured != true {
                guard let rest = absorbOverscroll(pixels.y, momentum: momentum) else { return }
                pixels.y = rest
            }
            let mods = TerminalScrollModifiers(precision: true, momentum: momentum)
            surface?.sendMouseScroll(x: Double(pixels.x), y: Double(pixels.y), mods: mods.rawValue)
            if momentum == .none, pixels.y != 0 {
                momentumScroll.lastDragTime = CACurrentMediaTime()
                momentumScroll.contentsAtLastDrag = UTermCommitWatch.contentsIdentity(of: self)
                UTermScrollTrace.record("drag", Double(pixels.y))
            }
            if let bar = core.bridge.scrollbar { UTermScrollTrace.record("row", Double(bar.offset)) }
            trackScrollResidue(pixels.y)
            // uTerm 排查用（M16 第三轮）：每次发出的像素、视口行号、程序有没有抓鼠标（抓了就按行报给程序，不会平滑）。
            TerminalDebugLog.log(
                .input,
                "uterm-scroll px=\(String(format: "%.1f", pixels.y)) momentum=\(momentum) residue=\(String(format: "%.1f", momentumScroll.pixelResidue)) bar=\(core.bridge.scrollbar.map { "\($0.offset)/\($0.total)/\($0.len)" } ?? "-") captured=\(surface?.isMouseCaptured == true) inline=\(usesInlineTextSelection) local=\(momentumScroll.scrollsLocally)",
            )
        }

        // MARK: uTerm 本地补丁：停下时吸附整行

        /// 视口在回滚两端（顶 / 活动区底部）且还往外推时 Ghostty 不留小数行，累计清零；其余时候按发出去的像素累计。
        func trackScrollResidue(_ pixels: CGFloat) {
            guard pixels != 0 else { return }
            guard let bar = core.bridge.scrollbar, bar.total > bar.len else {
                momentumScroll.pixelResidue = 0
                return
            }
            let atTop = bar.offset == 0 && pixels > 0
            let atBottom = bar.offset + bar.len >= bar.total && pixels < 0
            if atTop || atBottom {
                momentumScroll.pixelResidue = 0
                return
            }
            momentumScroll.pixelResidue += pixels
        }

        /// 把累计的小数行补成整行：离哪边近往哪边走，几帧缓动完成。
        func snapScrollToRow() {
            stopScrollSnap()
            guard !momentumScroll.scrollsLocally,
                  let metrics = surface?.size(), metrics.cellHeightPixels > 0 else { return }
            let cell = CGFloat(metrics.cellHeightPixels)
            var r = momentumScroll.pixelResidue.truncatingRemainder(dividingBy: cell)
            if r < 0 { r += cell }
            let delta = r < cell / 2 ? -r : cell - r
            guard abs(delta) >= 0.5 else { return }
            // 没有初速度的吸附：同一条减速曲线，0.28 s 落定（起步每帧不到 2 px，不会「先停再挪」）。
            startGlide(total: delta, duration: 0.28)
        }

        @objc func scrollSnapFrame(_: CADisplayLink) {
            let remaining = momentumScroll.snapRemaining
            // 每帧走剩下的 40%（120 Hz 下约 0.1 s 收敛），最后不到 1 像素一次补齐。
            let step = abs(remaining) < 1 ? remaining : remaining * 0.4
            momentumScroll.snapRemaining -= step
            UTermScrollTrace.record("snap", Double(step))
            let mods = TerminalScrollModifiers(precision: true, momentum: .none)
            surface?.sendMouseScroll(x: 0, y: Double(step), mods: mods.rawValue)
            if abs(momentumScroll.snapRemaining) < 0.01 { stopScrollSnap() }
        }

        func stopScrollSnap() {
            momentumScroll.snapLink?.invalidate()
            momentumScroll.snapLink = nil
            momentumScroll.snapRemaining = 0
        }

        // MARK: uTerm 本地补丁：到顶 / 到底回弹（照 UIScrollView）

        private var scrollAtTop: Bool {
            guard let bar = core.bridge.scrollbar else { return true }
            return bar.total <= bar.len || bar.offset == 0
        }

        private var scrollAtBottom: Bool {
            guard let bar = core.bridge.scrollbar else { return true }
            return bar.offset + bar.len >= bar.total
        }

        /// UIScrollView 的橡皮筋公式：拖出 x，显示 (1 − 1 / (x·0.55 / d + 1))·d，d = 视图高度。
        private func rubberBand(_ raw: CGFloat) -> CGFloat {
            let d = max(1, bounds.height * resolvedDisplayScale())
            return (1 - 1 / (abs(raw) * 0.55 / d + 1)) * d * (raw < 0 ? -1 : 1)
        }

        /// 回弹由宿主平移图层完成（和 UIScrollView 移内容层同一个思路），不让渲染器为它出帧：有输出时渲染器同一帧还要重建格子，
        /// 走 0023 的 overscroll uniform 会跟着它的出帧节奏抖。露出来的那条是视图后面的终端底色。
        private func applyOverscroll(_ shown: CGFloat) {
            UTermScrollTrace.record("overscroll", Double(shown))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = shown == 0
                ? CATransform3DIdentity
                : CATransform3DMakeTranslation(0, shown / resolvedDisplayScale(), 0)
            CATransaction.commit()
        }

        /// 这一步位移里有多少进了回弹：返回剩下要正常滚的像素，nil = 全被回弹吃掉了。
        /// 正 = 往回滚方向（内容下移）。在顶上还往下拉、在底下还往上推时进回弹；回弹中往回推先把回弹收回去。
        func absorbOverscroll(_ y: CGFloat, momentum: TerminalScrollModifiers.Momentum) -> CGFloat? {
            let raw = momentumScroll.overscrollRaw
            if raw != 0 {
                let next = raw + y
                if next != 0, (next > 0) == (raw > 0) {
                    momentumScroll.overscrollRaw = next
                    applyOverscroll(rubberBand(next))
                    return nil
                }
                momentumScroll.overscrollRaw = 0
                applyOverscroll(0)
                return next == 0 ? nil : next
            }
            let pushingPastTop = y > 0 && scrollAtTop
            let pushingPastBottom = y < 0 && scrollAtBottom
            guard pushingPastTop || pushingPastBottom else { return y }
            if momentum == .changed {
                // 惯性撞边：剩下的速度变成一次回弹（先冲出去再弹回来），惯性到此为止。
                let velocity = momentumScroll.velocity.y * resolvedDisplayScale()
                stopMomentumScrolling(sendTerminalEndEvent: false)
                startBounce(from: 0, velocity: velocity)
                return nil
            }
            momentumScroll.overscrollRaw = y
            applyOverscroll(rubberBand(y))
            return nil
        }

        /// 松手时还在回弹里：弹回去，不起惯性。返回是否接管了。
        func releaseOverscroll() -> Bool {
            guard momentumScroll.overscrollRaw != 0 else { return false }
            let shown = rubberBand(momentumScroll.overscrollRaw)
            momentumScroll.overscrollRaw = 0
            startBounce(from: shown, velocity: 0)
            return true
        }

        /// 临界阻尼弹簧回到 0：x(t) = (x0 + (v0 + ω·x0)·t)·e^(−ω·t)，ω = 12/s（约 0.45 s 停稳，和 UIScrollView 回弹的观感相近）。
        func startBounce(from shown: CGFloat, velocity: CGFloat) {
            stopBounce(resetting: false)
            momentumScroll.bounceFrom = shown
            momentumScroll.bounceVelocity = velocity
            momentumScroll.bounceStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(bounceFrame(_:)))
            link.preferredFrameRateRange = Self.scrollFrameRateRange
            link.add(to: .main, forMode: .common)
            momentumScroll.bounceLink = link
        }

        @objc func bounceFrame(_ link: CADisplayLink) {
            let omega: CGFloat = 12
            let t = CGFloat(link.targetTimestamp - momentumScroll.bounceStart)
            let x0 = momentumScroll.bounceFrom, v0 = momentumScroll.bounceVelocity
            var x = (x0 + (v0 + omega * x0) * t) * exp(-omega * t)
            // 冲出去的那段也按橡皮筋衰减，甩得再快也冲不出半屏。
            if x0 == 0 { x = rubberBand(x) }
            if t > 0.25, abs(x) < 0.5 {
                stopBounce(resetting: true)
                return
            }
            applyOverscroll(x)
        }

        func stopBounce(resetting: Bool) {
            momentumScroll.bounceLink?.invalidate()
            momentumScroll.bounceLink = nil
            if resetting { applyOverscroll(0) }
        }

        func startMomentumScrolling(velocity: CGPoint) {
            guard abs(velocity.x) > 50 || abs(velocity.y) > 50 else { return }
            // uTerm 本地补丁：普通滚动（程序没抓鼠标、不是双指本地滚动）改成「先算落点再滑」，照 UIScrollView 的
            // targetContentOffset：按 `.normal` 减速率算出能滑多远，取整到最近的整行，再用一条指数曲线正好停在那一行上，
            // 速度一路连续降到 0，不再惯性停下后另起一段吸附。
            if abs(velocity.y) > 50, !momentumScroll.scrollsLocally, surface?.isMouseCaptured != true,
               let metrics = surface?.size(), metrics.cellHeightPixels > 0 {
                let scale = resolvedDisplayScale()
                let cell = CGFloat(metrics.cellHeightPixels)
                let v = velocity.y * scale                                   // px/s
                let projected = v / 1000 / CGFloat(-log(0.998))              // UIScrollView .normal 滑到停的距离（px）
                var r = momentumScroll.pixelResidue.truncatingRemainder(dividingBy: cell)
                if r < 0 { r += cell }
                var total = ((r + projected) / cell).rounded() * cell - r
                if total * v <= 0 { total += v > 0 ? cell : -cell }
                TerminalDebugLog.log(.input, "glide start v=\(Int(v))px/s projected=\(Int(projected)) total=\(Int(total))")
                // 三次缓出 p = total·(1 − (1 − t/D)³) 的初速度是 3·total/D，让它等于抬手速度。
                startGlide(total: total, duration: 3 * total / v)
                return
            }

            momentumScroll.velocity = velocity
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
            )

            scrollTouchContent(by: .zero, momentum: .began)

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:)),
            )
            // uTerm 本地补丁：惯性按屏幕最高刷新率走。不设的话这个 link 在 ProMotion 上只有 60 Hz（真机日志：
            // 惯性每 16.7 ms 一步、每步 70 px 上下），渲染是 120 Hz，同一个位置连画两帧，看起来就是一格一格地跳。
            link.preferredFrameRateRange = Self.scrollFrameRateRange
            link.add(to: .main, forMode: .common)
            momentumScroll.displayLink = link
        }

        /// 沿三次缓出 p(t) = total·(1 − (1 − t/D)³) 滑完 `total` 像素：速度连续降到 0、正好在 D 秒时落在 total 上。
        /// 不用纯指数衰减：那样最后几个像素要拖上一两秒、每隔几帧才挪 1 px，看着就是收尾卡（第四轮真机读数）。
        /// 每帧只发整像素（零头留到下一帧），慢下来时文字不会停在子像素位置上闪。
        func startGlide(total: CGFloat, duration: CGFloat) {
            stopMomentumScrolling(sendTerminalEndEvent: false)
            stopScrollSnap()
            momentumScroll.glideTotal = total
            momentumScroll.glideDuration = min(max(duration, 0.12), 3.0)
            // 起点在第一次回调时按那一帧的 timestamp 定（见 glideFrame），这样第一帧正好走一帧的量。按调用时刻算的话，
            // 第一次回调的 targetTimestamp 离调用时刻差不多两帧，第一帧一下走两帧的量（上屏实测：…18, 52, 24, 24…）。
            momentumScroll.glideStart = 0
            momentumScroll.glideSent = 0
            momentumScroll.velocity = .zero
            scrollTouchContent(by: .zero, momentum: .began)
            let link = CADisplayLink(target: self, selector: #selector(glideFrame(_:)))
            link.preferredFrameRateRange = Self.scrollFrameRateRange
            link.add(to: .main, forMode: .common)
            momentumScroll.displayLink = link
        }

        @objc func glideFrame(_ link: CADisplayLink) {
            if momentumScroll.glideStart == 0 {
                startGlideTimeline(link)
                if momentumScroll.glideStart != link.timestamp { return }
            }
            advanceGlide(link, target: link.targetTimestamp)
        }

        /// 定惯性的起点。正常情况起点 = 这一帧的 timestamp，第一帧正好走一帧的量。
        ///
        /// 交接那一帧要防「一帧走两步」：惯性回调在它这一拍的 vsync（timestamp）之前约 1 ms 就来，手指最后一下拖动若刚
        /// 发生在它前面一点，拖动那一步还没画上画面层。它要是在 vsync 之后才上画面层，就和惯性第一步同一拍上屏（上屏实测：
        /// 交接那一拍 43 = 18 + 25 px、117 = 18 + 99 px，前一拍不动）。所以拖动还没上画面层时，这一帧先不走（起点挪到下一帧），
        /// 等它画上来：赶在 vsync 之前画上来的，说明它落在这一拍，惯性第一步立刻补上（落在下一拍），不空一帧；
        /// 赶不上的，它自己占下一拍，惯性从再下一拍起走。
        func startGlideTimeline(_ link: CADisplayLink) {
            // 拖动后画面层没换过 IOSurface = 拖动那一步还没画上来。拖动才过去不到 1 ms 时，即使换过也是更早那一帧
            //（Ghostty 画一帧要 1.5 ms 上下），一样当作还没画上来，等下一次换。
            let sinceDrag = CACurrentMediaTime() - momentumScroll.lastDragTime
            let current = UTermCommitWatch.contentsIdentity(of: self)
            let dragPending = sinceDrag < 2 * link.duration && momentumScroll.contentsAtLastDrag != nil
                && (current == momentumScroll.contentsAtLastDrag || sinceDrag < 0.001)
            let baseline = current
            guard dragPending else {
                momentumScroll.glideStart = link.timestamp
                UTermScrollTrace.record("glide-first", 0)
                return
            }
            momentumScroll.glideStart = link.targetTimestamp
            UTermScrollTrace.record("glide-first", 1)
            let vsync = link.timestamp, target = link.targetTimestamp
            UTermCommitWatch.onContentsChange(of: self, from: baseline, within: 2 * link.duration) { [weak self] committedAt in
                guard let self, committedAt < vsync, self.momentumScroll.displayLink === link,
                      self.momentumScroll.glideSent == 0 else { return }
                self.momentumScroll.glideStart = vsync
                UTermScrollTrace.record("glide-first", 2)
                self.advanceGlide(link, target: target)
            }
        }

        /// 把惯性推进到 `target` 这一拍该在的位置（只发整像素，零头留到下一帧）。
        func advanceGlide(_ link: CADisplayLink, target: CFTimeInterval) {
            let callbackMark = UTermScrollTrace.mark()
            defer { UTermScrollTrace.span("glide-cb", since: callbackMark) }
            let total = momentumScroll.glideTotal, duration = momentumScroll.glideDuration
            let u = min(1, CGFloat(target - momentumScroll.glideStart) / duration)
            let rest = pow(1 - u, 3)
            let position = u >= 1 ? total : total * (1 - rest)
            let delta = position.rounded() - momentumScroll.glideSent
            UTermScrollTrace.record("glide-target", target)
            if UTermCommitWatch.isWanted {
                UTermCommitWatch.watch(self)
                TerminalDebugLog.log(.input, "uterm-glide t=\(String(format: "%.5f", CACurrentMediaTime())) target=\(String(format: "%.5f", target)) sent=\(Int(delta))")
            }
            // 撞边转回弹要用当前速度（pt/s）：v = 3·total/D·(1 − u)²。
            momentumScroll.velocity = CGPoint(x: 0, y: 3 * total / duration * pow(1 - u, 2) / resolvedDisplayScale())
            if delta != 0 {
                momentumScroll.glideSent += delta
                UTermScrollTrace.record("momentum", Double(delta))
                let sendMark = UTermScrollTrace.mark()
                scrollTouchContent(by: CGPoint(x: 0, y: delta / resolvedDisplayScale()), momentum: .changed)
                UTermScrollTrace.span("glide-send", since: sendMark)
            }
            // 撞边时 scrollTouchContent 已经把 link 停了、交给回弹。
            if u >= 1, momentumScroll.displayLink === link { stopMomentumScrolling() }
        }

        static var scrollFrameRateRange: CAFrameRateRange {
            CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp
            // uTerm 本地补丁：减速按 UIScrollView 的 `.normal`（每毫秒 0.998），和 SwiftTerm 标签（UIScrollView）
            // 甩出去的距离、收尾一致。上游是每 1/60 s 0.92，摩擦大得多，甩一下就停。按帧时长缩放，60 / 120 Hz 一样远。
            let decay = CGFloat(pow(0.998, dt * 1000))

            momentumScroll.velocity.x *= decay
            momentumScroll.velocity.y *= decay

            let deltaX = momentumScroll.velocity.x * dt
            let deltaY = momentumScroll.velocity.y * dt

            if abs(momentumScroll.velocity.x) < 50, abs(momentumScroll.velocity.y) < 50 {
                stopMomentumScrolling()
                if surface?.isMouseCaptured != true { snapScrollToRow() }
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumScroll.velocity.x))x\(String(format: "%.2f", momentumScroll.velocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))",
            )

            UTermScrollTrace.record("momentum", Double(deltaY * resolvedDisplayScale()))
            scrollTouchContent(by: CGPoint(x: deltaX, y: deltaY), momentum: .changed)
        }

        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true) {
            guard momentumScroll.displayLink != nil else { return }
            TerminalDebugLog.log(.input, "momentum stop")

            if sendTerminalEndEvent {
                scrollTouchContent(by: .zero, momentum: .none)
            }

            momentumScroll.displayLink?.invalidate()
            momentumScroll.displayLink = nil
            momentumScroll.velocity = .zero
        }
    }
#endif
