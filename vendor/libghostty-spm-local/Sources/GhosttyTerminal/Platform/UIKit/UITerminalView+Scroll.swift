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
        // uTerm 本地补丁（配合 GhosttyKit 0023 的像素级平滑滚动）：视口位置的本地镜像。0023 让视口停在「第几行 + 往下多少像素」，
        // C 接口只报行号（滚动条回报，晚一帧）、不报那半行小数，所以 Swift 侧照引擎 `smoothScrollViewport` 的算法自己记一份：
        // `modelRow` = 视口首行行号，`modelFrac` = 首行顶边之上被滚出去的像素（0 ..< 行高，到顶 / 回到活动区时引擎清零）。
        // 发给引擎的位移一律是整数像素，两边都是整数运算，镜像不会和引擎差出小数。用它做三件事：
        // 到顶 / 到底的判定（行号到 0 不等于到顶，还差 `modelFrac` 像素）、停下时吸附整行、惯性落点取整行。
        // Ghostty 与 GhosttyKit 的点击、选区命中都按整数视口算，停在半行会差一行。
        var modelRow = 0
        var modelFrac = 0
        var modelValid = false
        var modelAtBottom = false
        /// 最近一次真给引擎发位移的时刻：滚动条回报要比它晚才作数（见 syncScrollModel / scrollbarReflectsLastSend）。
        var lastScrollSend: CFTimeInterval = 0
        /// 手指位移里不足一像素的零头，留到下一步。
        var dragCarry: CGFloat = 0
        /// 手指正拖着（began 之后、ended / cancelled 之前）。
        var panActive = false
        /// 「稍后吸附」的凭据：之后又有新的手势 / 惯性就作废。
        var settleToken = 0
        /// 这次自写路径的拖动开始时发过 drag-began 的 signpost 没有（触摸阶段 signpost 见 UTermScrollTrace）。
        // uTerm 本地补丁（回弹）：拖过顶 / 底时手指走了多少像素（未衰减），以及松手 / 惯性撞边后的弹簧状态。
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
                // uTerm 本地补丁：滚轮不吸附整行（一格可能不到半行，对齐会把它退回去），所以这里也不对齐。
                stopMomentumScrolling(settle: .none)
                momentumScroll.dragCarry = 0
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
            var pixels = TerminalScrollDistance.scrollPixels(
                for: translation,
                displayScale: resolvedDisplayScale(),
            )
            // uTerm 本地补丁：和手指拖动一样只发整数像素、记进视口位置的镜像（见 MomentumScrollState），
            // 之后手指再滚时镜像才对得上。滚轮没有回弹；引擎自己停在顶 / 底。
            if surface?.isMouseCaptured == true {
                momentumScroll.modelValid = false
            } else if pixels.y != 0 {
                let exact = pixels.y + momentumScroll.dragCarry
                pixels.y = exact.rounded()
                momentumScroll.dragCarry = exact - pixels.y
                if let extent = syncScrollModel() { applyToScrollModel(Int(pixels.y), extent, source: .wheel) }
                if pixels.x == 0, pixels.y == 0 { return }
            }
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
                UTermScrollTrace.signpostTouch(.dragBegan)
                // 接住惯性 / 回弹继续拖：不吸附（双指整行滚动除外，那条路径按整行算，先对齐）。
                stopMomentumScrolling(settle: momentumScroll.scrollsLocally ? .now : .none)
                if momentumScroll.bounceLink != nil { stopBounce(resetting: true) }
                momentumScroll.panActive = true
                momentumScroll.dragCarry = 0
                momentumScroll.settleToken += 1

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
                momentumScroll.panActive = false
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
                momentumScroll.panActive = false
                stopMomentumScrolling(settle: .none)
                // 被系统手势打断也要收尾：回弹弹回去，否则把停在半行的视口吸附回整行。
                if !releaseOverscroll(), surface?.isMouseCaptured != true { snapScrollToRow() }

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
                // 视口不是经平滑滚动动的：引擎不再认那半行小数，镜像下次用时照滚动条重来。
                momentumScroll.modelValid = false
                core.requestImmediateTick()
                return
            }
            var pixels = TerminalScrollDistance.scrollPixels(for: delta, displayScale: resolvedDisplayScale())
            // 这一步视口真正走了多少像素（给 trace 记）：撞边时发给引擎的比这多（见 absorbOverscroll）。
            var travelled = pixels.y
            if surface?.isMouseCaptured == true {
                // 程序抓了鼠标：位移按行报给程序，不滚视口，镜像不管这段。
                momentumScroll.modelValid = false
            } else if delta.y != 0 {
                // 只发整数像素，零头留到下一步：引擎那半行小数永远是整数，停下来吸附后正好是 0（见 MomentumScrollState）。
                let exact = pixels.y + momentumScroll.dragCarry
                let whole = exact.rounded()
                momentumScroll.dragCarry = exact - whole
                pixels.y = whole
                travelled = whole
                if whole != 0, let extent = syncScrollModel() {
                    let before = momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac
                    let forwarded = absorbOverscroll(Int(whole), momentum: momentum, extent: extent)
                    applyToScrollModel(forwarded, extent, source: .ownDrag)
                    pixels.y = CGFloat(forwarded)
                    travelled = CGFloat(before - (momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac))
                }
                // 这一步全进了回弹，或者还不够一像素：没有要发给引擎的。
                if pixels.x == 0, pixels.y == 0 { return }
            }
            let mods = TerminalScrollModifiers(precision: true, momentum: momentum)
            surface?.sendMouseScroll(x: Double(pixels.x), y: Double(pixels.y), mods: mods.rawValue)
            if momentum == .none, pixels.y != 0 {
                momentumScroll.lastDragTime = CACurrentMediaTime()
                momentumScroll.contentsAtLastDrag = UTermCommitWatch.contentsIdentity(of: self)
                UTermScrollTrace.record("drag", Double(travelled))
            }
            if let bar = core.bridge.scrollbar { UTermScrollTrace.record("row", Double(bar.offset)) }
            // uTerm 排查用（M16 第三轮）：每次发出的像素、视口行号、程序有没有抓鼠标（抓了就按行报给程序，不会平滑）。
            TerminalDebugLog.log(
                .input,
                "uterm-scroll px=\(String(format: "%.1f", pixels.y)) momentum=\(momentum) model=\(momentumScroll.modelRow)+\(momentumScroll.modelFrac)px bar=\(core.bridge.scrollbar.map { "\($0.offset)/\($0.total)/\($0.len)" } ?? "-") captured=\(surface?.isMouseCaptured == true) inline=\(usesInlineTextSelection) local=\(momentumScroll.scrollsLocally)",
            )
        }

        // MARK: uTerm 本地补丁：视口位置的本地镜像

        /// 行高（物理像素）和视口首行最远能到第几行（= 回滚行数；没有回滚、备用屏是 0）。
        struct ScrollExtent {
            let cell: Int
            let maxRow: Int
            /// 一屏有多少行。
            let screenRows: Int
        }

        func scrollExtent() -> ScrollExtent? {
            guard let metrics = surface?.size(), metrics.cellHeightPixels > 0 else { return nil }
            let maxRow = core.bridge.scrollbar.map { $0.total > $0.len ? Int($0.total - $0.len) : 0 } ?? 0
            return ScrollExtent(cell: Int(metrics.cellHeightPixels), maxRow: maxRow, screenRows: max(1, Int(metrics.rows)))
        }

        /// 用镜像之前先和引擎对一下。
        ///
        /// 滚动条回报是渲染线程那一帧发的，要等主线程的下一次 tick 才到我们手里，比发出去的位移晚一帧上下，
        /// 所以连着发位移时信镜像、不信它（旧实现拿它判「到顶了没有」和清零头，行号刚到 0 就当到顶，引擎其实还差半行，
        /// 见 absorbOverscroll）。回报确实是「发完位移之后」的才以它的行号为准（见 scrollbarReflectsLastSend）：
        /// 别的途径也会动视口（新输出、打字回到底部、键盘翻页、双指整行滚动）。
        /// 小数照旧留着：引擎的规则是「行号没变小数就还作数」；在活动区（底部）引擎不留小数。
        ///
        /// `adoptingBar: false`：只刷新范围、跟底，行号一律信镜像。系统滚动的 didScroll 和对齐用它：那条路径上
        /// contentOffset 和镜像是一对，只在停稳时一起对到引擎上（systemScrollSyncFromEngine）；途中单改镜像的行号，
        /// 下一次 didScroll 就会把这个差当成手指位移发给引擎，画面跳几行再被拽回来。
        @discardableResult
        func syncScrollModel(adoptingBar: Bool = true) -> ScrollExtent? {
            guard let extent = scrollExtent() else { return nil }
            if let bar = core.bridge.scrollbar, extent.maxRow > 0 {
                if !momentumScroll.modelValid || (adoptingBar && scrollbarReflectsLastSend()) {
                    if !momentumScroll.modelValid { momentumScroll.modelFrac = 0 }
                    momentumScroll.modelRow = Int(bar.offset)
                    momentumScroll.modelAtBottom = bar.offset + bar.len >= bar.total
                    momentumScroll.modelValid = true
                }
            } else {
                momentumScroll.modelRow = 0
                momentumScroll.modelAtBottom = true
                momentumScroll.modelValid = true
            }
            // 跟着活动区走的时候来了新输出：回滚变长，底部跟着往下挪。
            if momentumScroll.modelAtBottom || momentumScroll.modelRow >= extent.maxRow {
                momentumScroll.modelRow = extent.maxRow
                momentumScroll.modelFrac = 0
                momentumScroll.modelAtBottom = true
            }
            // 行高变了（捏合改字号）之后小数可能超过一行，夹回去。
            momentumScroll.modelFrac = min(max(0, momentumScroll.modelFrac), extent.cell - 1)
            return extent
        }

        /// 手里这份滚动条回报反映的是不是我们最后一次发位移之后的视口。
        ///
        /// 光看「停手 0.1 s 以上」不够：回报在引擎的信箱里，要主线程 tick 才取出来。主线程卡住 0.1 s 以上（一次慢布局、
        /// 一次截图）再回来，手里还是卡住之前的旧行号，照它改镜像就错开一行，下一步位移跟着错（实机测到：
        /// 镜像 97 行、引擎 96 行）。所以还要两条里占一条：
        /// - 这份回报是在最后一次发位移 0.1 s 之后才处理的（渲染线程早就画过那一步了，它之前的回报同一次 tick 里都取完了）；
        /// - 主队列里没有排着的 tick（引擎发过的消息都处理完了）。整个 App 共用一个 ghostty app，别的标签在刷输出时
        ///   这一条常常不成立，那就等下一份回报走上一条。
        private func scrollbarReflectsLastSend() -> Bool {
            let sent = momentumScroll.lastScrollSend
            guard CACurrentMediaTime() - sent > 0.1 else { return false }
            if core.bridge.scrollbarStamp - sent > 0.1 { return true }
            return core.controller?.wakeupGate.isPending != true
        }

        /// 引擎 `smoothScrollViewport` 的镜像：往回滚方向滚 `pixels`（负 = 往活动区）。滚过顶 / 回到活动区，引擎停在边上、不留小数。
        /// 谁动的镜像（signpost `scroll-offset` 的第六个数）。
        enum ScrollModelSource: Int {
            case systemDidScroll = 1, ownDrag = 2, alignEngineOnly = 3, settleNow = 4, wheel = 5
        }

        func applyToScrollModel(_ pixels: Int, _ extent: ScrollExtent, source: ScrollModelSource) {
            guard pixels != 0 else { return }
            let limit = extent.maxRow * extent.cell
            let position = min(max(0, momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac - pixels), limit)
            momentumScroll.modelAtBottom = position >= limit
            momentumScroll.modelRow = momentumScroll.modelAtBottom ? extent.maxRow : position / extent.cell
            momentumScroll.modelFrac = momentumScroll.modelAtBottom ? 0 : position % extent.cell
            momentumScroll.lastScrollSend = CACurrentMediaTime()
            #if !targetEnvironment(macCatalyst)
                // 和 SwiftTerm 标签同款的 scroll-offset signpost：位置、在不在减速、手指按没按着。
                let driver = systemScroll.driver
                UTermScrollTrace.signpostScrollOffset(
                    px: Double(position),
                    decelerating: momentumScroll.displayLink != nil || driver?.isDecelerating == true || systemScroll.uikitMoving
                        || systemScroll.alignLink != nil,
                    tracking: momentumScroll.panActive || driver?.isTracking == true,
                    systemPhysics: systemScrollIsActive,
                    source: source.rawValue,
                    view: systemScroll.serial,
                )
            #endif
        }

        // MARK: uTerm 本地补丁：停下时吸附整行

        /// 离最近的整行差多少像素（正 = 往回滚方向补）；已经在整行上、或者不该吸附时为 nil。
        private func snapDistance() -> Int? {
            guard surface?.isMouseCaptured != true, let extent = syncScrollModel() else { return nil }
            let frac = momentumScroll.modelFrac
            guard frac != 0 else { return nil }
            return frac * 2 <= extent.cell ? frac : frac - extent.cell
        }

        /// 把半行补成整行：离哪边近往哪边走，同一条减速曲线 0.28 s 落定（起步每帧不到 2 px，不会「先停再挪」）。
        func snapScrollToRow() {
            guard !momentumScroll.scrollsLocally else { return }
            #if !targetEnvironment(macCatalyst)
                // 系统滚动那条路径：对齐也交给 UIScrollView 的动画。
                if systemScrollIsActive {
                    systemScrollAlign(animated: true)
                    return
                }
            #endif
            guard let delta = snapDistance() else { return }
            startGlide(total: CGFloat(delta), duration: 0.28)
        }

        /// 当场对齐整行、收掉回弹，不做动画：接下来要按整数视口算命中（选区、菜单、捏合）或者视图要离屏时用。
        func settleScrollNow() {
            momentumScroll.settleToken += 1
            if momentumScroll.overscrollRaw != 0 || momentumScroll.bounceLink != nil {
                momentumScroll.overscrollRaw = 0
                stopBounce(resetting: true)
            }
            #if !targetEnvironment(macCatalyst)
                systemScrollStop()
                if systemScrollIsActive {
                    systemScrollAlign(animated: false)
                    return
                }
            #endif
            guard let delta = snapDistance(), let extent = scrollExtent() else { return }
            surface?.sendMouseScroll(x: 0, y: Double(delta), mods: TerminalScrollModifiers(precision: true).rawValue)
            applyToScrollModel(delta, extent, source: .settleNow)
        }

        /// 惯性途中手指落下把它停住：先原地停着（和 UIScrollView 一样），0.12 s 后要是没接着拖（只是点一下），再吸附回整行。
        func settleScrollSoon() {
            momentumScroll.settleToken += 1
            let token = momentumScroll.settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, token == momentumScroll.settleToken, !momentumScroll.panActive,
                      momentumScroll.displayLink == nil, momentumScroll.overscrollRaw == 0,
                      momentumScroll.bounceLink == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    // 点停那一下刚停住滚动视图，「最近有 didScroll」不算在动，不然这次对齐就被拦掉了，停在半行或界外。
                    // 回弹途中被按住、没拖就松手：我们在按下时停住了 UIKit 的回弹，停在界外的那一段也要在这里拉回来。
                    if systemScrollBusy(countingRecentScroll: false, countingOutOfRange: false) { return }
                #endif
                snapScrollToRow()
            }
        }

        // MARK: uTerm 本地补丁：到顶 / 到底回弹（照 UIScrollView）

        /// UIScrollView 的橡皮筋公式：拖出 x，显示 (1 − 1 / (x·0.55 / d + 1))·d，d = 视图高度。
        private func rubberBand(_ raw: CGFloat) -> CGFloat {
            let d = max(1, bounds.height * resolvedDisplayScale())
            return (1 - 1 / (abs(raw) * 0.55 / d + 1)) * d * (raw < 0 ? -1 : 1)
        }

        /// 回弹由宿主平移图层完成（和 UIScrollView 移内容层同一个思路），不让渲染器为它出帧：有输出时渲染器同一帧还要重建格子，
        /// 走 0023 的 overscroll uniform 会跟着它的出帧节奏抖。露出来的那条是视图后面的终端底色。
        /// 平移量取整到物理像素：画面层平移半个像素会被重采样，回弹途中整屏字发虚、行与行的交界多出一条混色线。
        /// 系统滚动那条路径（+SystemScroll）越界时也用它显示 UIScrollView 的橡皮筋。
        func applyOverscroll(_ shown: CGFloat) {
            UTermScrollTrace.record("overscroll", Double(shown))
            let pixels = shown.rounded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = pixels == 0
                ? CATransform3DIdentity
                : CATransform3DMakeTranslation(0, pixels / resolvedDisplayScale(), 0)
            CATransaction.commit()
        }

        /// 这一步位移（整数像素，正 = 往回滚方向、内容下移）里有多少真去滚视口：返回要发给引擎的像素，其余进回弹。
        /// 在顶上还往下拉、在底下还往上推时进回弹；回弹中往回推先把回弹收回去。
        ///
        /// 「到头」按镜像里离顶 / 离底还剩多少像素算，不是看滚动条行号：行号到 0 时引擎多半还差半行（`modelFrac`），
        /// 那时就进回弹的话，真正的第一行永远拉不下来，松手后停在「第一行被切掉一截、底下多露半行」的位置上
        ///（user 截图里顶上那条细线就是被切剩的上一行）。
        func absorbOverscroll(_ pixels: Int, momentum: TerminalScrollModifiers.Momentum, extent: ScrollExtent) -> Int {
            var y = pixels
            let raw = momentumScroll.overscrollRaw
            if raw != 0 {
                let next = raw + CGFloat(y)
                if next != 0, (next > 0) == (raw > 0) {
                    momentumScroll.overscrollRaw = next
                    applyOverscroll(rubberBand(next))
                    return 0
                }
                momentumScroll.overscrollRaw = 0
                applyOverscroll(0)
                y = Int(next)
            }
            // 没有回滚可滚（内容不满一屏、备用屏）：不回弹，原样交给引擎。UIScrollView 内容不满时也不回弹；
            // 备用屏里引擎把滚动换成方向键发给程序（less、vim），吃掉就滚不动了。
            guard y != 0, extent.maxRow > 0 else { return y }
            let position = momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac
            let room = y > 0 ? position : extent.maxRow * extent.cell - position
            guard abs(y) > room else { return y }
            let over = y > 0 ? y - room : y + room
            if momentum == .changed {
                // 惯性撞边：剩下的速度变成一次回弹（先冲出去再弹回来），惯性到此为止。
                let velocity = momentumScroll.velocity.y * resolvedDisplayScale()
                stopMomentumScrolling(sendTerminalEndEvent: false, settle: .none)
                startBounce(from: 0, velocity: velocity)
            } else {
                momentumScroll.overscrollRaw = CGFloat(over)
                applyOverscroll(rubberBand(CGFloat(over)))
            }
            // 剩下的那段先让引擎走完，再多给一屏：引擎自己夹在边上并把小数清零，回弹期间它一定正好在顶 / 底。
            // 镜像和引擎差出几行的情况也在这里收掉：输出正涨着的时候，滚动条报的总行数比引擎晚一两帧，
            // 镜像以为到底了、引擎其实还差刚来的那几行。
            let extra = extent.cell * extent.screenRows
            return y > 0 ? room + extra : -(room + extra)
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
                // 回弹期间视口应当正好在顶 / 底；万一不是（镜像和引擎差了整行，停手后才对上），补一次吸附。
                if !momentumScroll.panActive { snapScrollToRow() }
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
               let extent = syncScrollModel() {
                let scale = resolvedDisplayScale()
                let cell = CGFloat(extent.cell)
                let v = velocity.y * scale                                   // px/s
                let projected = v / 1000 / CGFloat(-log(0.998))              // UIScrollView .normal 滑到停的距离（px）
                // 落点 = 现在离回滚顶部的像素 − 滑行距离，取最近的整行；滑过顶 / 底的由回弹接手（absorbOverscroll）。
                let position = CGFloat(momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac)
                var total = position - ((position - projected) / cell).rounded() * cell
                if total * v <= 0 { total += v > 0 ? cell : -cell }
                TerminalDebugLog.log(.input, "glide start v=\(Int(v))px/s projected=\(Int(projected)) total=\(Int(total))")
                // 三次缓出 p = total·(1 − (1 − t/D)³) 的初速度是 3·total/D，让它等于抬手速度。
                UTermScrollTrace.signpostGlideStart(velocity: Double(v), total: Double(total), duration: Double(3 * total / v))
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
            stopMomentumScrolling(sendTerminalEndEvent: false, settle: .none)
            momentumScroll.settleToken += 1
            momentumScroll.dragCarry = 0
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
            UTermScrollTrace.signpostGlideTick(target: target, cumulative: Double(momentumScroll.glideSent))
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

        /// 停掉惯性之后视口怎么收尾。
        enum ScrollSettle {
            /// 不管：紧接着还有位移（手指接着拖、另起一段惯性）。
            case none
            /// 先原地停着，稍后没人接手再吸附回整行（惯性途中手指落下）。
            case later
            /// 当场对齐整行并收掉回弹（要按整数视口算命中、视图离屏、进后台）。
            case now
        }

        /// 惯性途中手指落下（`touchesBegan` / 点按识别器收到触摸）：停住，稍后没接着拖再吸附。
        func stopMomentumForTouchDown() {
            #if !targetEnvironment(macCatalyst)
                systemScrollStop()
            #endif
            stopMomentumScrolling(settle: .later)
        }

        /// 默认 `.now`：调用方大多是「接下来要按格子算位置」或「视图不显示了」，惯性停在半行、回弹停在半路都不行。
        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true, settle: ScrollSettle = .now) {
            #if !targetEnvironment(macCatalyst)
                if settle != ScrollSettle.none { systemScrollStop() }
            #endif
            if momentumScroll.displayLink != nil {
                TerminalDebugLog.log(.input, "momentum stop")

                if sendTerminalEndEvent {
                    scrollTouchContent(by: .zero, momentum: .none)
                }

                momentumScroll.displayLink?.invalidate()
                momentumScroll.displayLink = nil
                momentumScroll.velocity = .zero
            }
            switch settle {
            case .none: break
            case .later: settleScrollSoon()
            case .now: settleScrollNow()
            }
        }
    }
#endif
