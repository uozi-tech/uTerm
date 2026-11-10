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
        // 发给引擎的位移一律是整数像素，两边都是整数运算，镜像不会和引擎差出小数。系统滚动那条路径（+SystemScroll）靠它
        // 把 UIScrollView 的 contentOffset 换成发给引擎的位移、判到顶 / 到底、停下时对齐整行（行号到 0 不等于到顶，
        // 还差 `modelFrac` 像素）。Ghostty 与 GhosttyKit 的点击、选区命中都按整数视口算，停在半行会差一行。
        var modelRow = 0
        var modelFrac = 0
        var modelValid = false
        var modelAtBottom = false
        /// 最近一次真给引擎发位移的时刻：滚动条回报要比它晚才作数（见 syncScrollModel / scrollbarReflectsLastSend）。
        var lastScrollSend: CFTimeInterval = 0
        /// 手指位移里不足一像素的零头，留到下一步。
        var dragCarry: CGFloat = 0
        /// 手指正拖着（began 之后、ended / cancelled 之前；系统滚动的拖动也记在这里）。
        var panActive = false
        /// 「稍后对齐」的凭据：之后又有新的手势 / 惯性就作废。
        var settleToken = 0
        // uTerm 本地补丁（抓鼠标的程序松手后的惯性）：这段按速度衰减的惯性，位移是不是按行报给程序的（起惯性那一刻定），
        // 以及它慢到多少 pt/s 就停（见 startMomentumScrolling）。
        var reportsToProgram = false
        var stopSpeed: CGFloat = 50
    }

    extension UITerminalView {
        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.session.reported == nil else { return }
            switch gesture.state {
            case .began:
                dismissTouchSelection(restoringViewport: false)
                // uTerm 本地补丁：滚轮不对齐整行（一格可能不到半行，对齐会把它退回去），所以这里也不对齐。
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
            // 之后手指再滚时镜像才对得上。滚轮不回弹，引擎自己停在顶 / 底。
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
                // 接住惯性继续拖：不对齐（双指整行滚动除外，那条路径按整行算，先对齐）。
                stopMomentumScrolling(settle: momentumScroll.scrollsLocally ? .now : .none)
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
                // uTerm 本地补丁：程序抓着鼠标（Claude 的全屏界面、tmux / vim 开 mouse）时松手也起惯性。上游加内联选区那次
                //（a667344）把「内联选区开着、程序抓着鼠标、单指」拦在了外面，没写原因；拦掉之后手指一离开屏幕就停。
                // 惯性途中手指落下由点按识别器那条路停（`gestureRecognizer(_:shouldReceive:)`），那一下不算点击。
                startMomentumScrolling(velocity: velocity)
                // 没起惯性（抬手时几乎不动）就当场对齐；起了惯性的等惯性停下再对齐。
                if momentumScroll.displayLink == nil, surface?.isMouseCaptured != true { snapScrollToRow() }

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                momentumScroll.panActive = false
                stopMomentumScrolling(settle: .none)
                // 被系统手势打断也要收尾：把停在半行的视口对齐回整行。
                if surface?.isMouseCaptured != true { snapScrollToRow() }

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
            if surface?.isMouseCaptured == true {
                // 程序抓了鼠标：位移按行报给程序，不滚视口，镜像不管这段。
                momentumScroll.modelValid = false
            } else if delta.y != 0 {
                // 只发整数像素，零头留到下一步：引擎那半行小数永远是整数（见 MomentumScrollState）。
                // 到顶 / 到底不拦：引擎自己停在边上（镜像照样夹住），备用屏里引擎把位移换成方向键发给程序。
                let exact = pixels.y + momentumScroll.dragCarry
                let whole = exact.rounded()
                momentumScroll.dragCarry = exact - whole
                pixels.y = whole
                if whole != 0, let extent = syncScrollModel() { applyToScrollModel(Int(whole), extent, source: .ownDrag) }
                // 还不够一像素：没有要发给引擎的。
                if pixels.x == 0, pixels.y == 0 { return }
            }
            let mods = TerminalScrollModifiers(precision: true, momentum: momentum)
            surface?.sendMouseScroll(x: Double(pixels.x), y: Double(pixels.y), mods: mods.rawValue)
            if momentum == .none, pixels.y != 0 { UTermScrollTrace.record("drag", Double(pixels.y)) }
            if let bar = core.bridge.scrollbar { UTermScrollTrace.record("row", Double(bar.offset)) }
            // uTerm 排查用：每次发出的像素、视口行号、程序有没有抓鼠标（抓了就按行报给程序，不会平滑）。
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
        /// 所以连着发位移时信镜像、不信它（拿它判「到顶了没有」的话，行号刚到 0 就当到顶，引擎其实还差半行）。
        /// 回报确实是「发完位移之后」的才以它的行号为准（见 scrollbarReflectsLastSend）：
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

        /// 谁动的镜像（signpost `scroll-offset` 的第六个数）：系统滚动的 didScroll、自写的拖动 / 惯性（不归系统滚动的那几种）、
        /// 对齐时只动引擎、当场对齐（只有 Catalyst 走得到）、滚轮。
        enum ScrollModelSource: Int {
            case systemDidScroll = 1, ownDrag = 2, alignEngineOnly = 3, settleNow = 4, wheel = 5
        }

        /// 引擎 `smoothScrollViewport` 的镜像：往回滚方向滚 `pixels`（负 = 往活动区）。滚过顶 / 回到活动区，引擎停在边上、不留小数。
        func applyToScrollModel(_ pixels: Int, _ extent: ScrollExtent, source: ScrollModelSource) {
            guard pixels != 0 else { return }
            let limit = extent.maxRow * extent.cell
            let position = min(max(0, momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac - pixels), limit)
            momentumScroll.modelAtBottom = position >= limit
            momentumScroll.modelRow = momentumScroll.modelAtBottom ? extent.maxRow : position / extent.cell
            momentumScroll.modelFrac = momentumScroll.modelAtBottom ? 0 : position % extent.cell
            momentumScroll.lastScrollSend = CACurrentMediaTime()
            #if !targetEnvironment(macCatalyst)
                // scroll-offset signpost：位置、在不在减速、手指按没按着。
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

        // MARK: uTerm 本地补丁：停下时对齐整行

        // 单指滚回滚区的手势、减速、回弹、落点都归系统的 UIScrollView（+SystemScroll），停在半行上的视口也由那条路径
        // 对齐（`systemScrollAlign`）。这里原来还有一套自写的滚动物理（到顶 / 到底的橡皮筋与弹簧、一次算好落点的惯性、
        // 拖动 → 惯性交接对齐上屏、自写的吸附动画），评估期攒下的，已经整套删掉：user 定的，单指滚动不需要自写物理。
        // 留在这个文件里的自写路径只有不归系统滚动的那几种：程序抓着鼠标、备用屏 / 没有回滚可滚（位移原样交给引擎，
        // 松手后按速度衰减，见 momentumScrollFrame）、双指的本地整行滚动、滚轮 / 触控板。

        /// 把停在半行上的视口缓动回整行（没有手指、没有惯性在动它的时候）。
        func snapScrollToRow() {
            guard !momentumScroll.scrollsLocally else { return }
            #if !targetEnvironment(macCatalyst)
                if systemScrollIsActive { systemScrollAlign(animated: true) }
            #endif
        }

        /// 当场对齐整行，不做动画：接下来要按整数视口算命中（选区、菜单、捏合）或者视图要离屏时用。
        func settleScrollNow() {
            momentumScroll.settleToken += 1
            #if targetEnvironment(macCatalyst)
                // Catalyst 没有系统滚动那条路径（也没有触摸滚动），只有滚轮 / 触控板会把视口留在半行上：直接让引擎补到整行。
                guard surface?.isMouseCaptured != true, let extent = syncScrollModel() else { return }
                let frac = momentumScroll.modelFrac
                guard frac != 0 else { return }
                let delta = frac * 2 <= extent.cell ? frac : frac - extent.cell
                surface?.sendMouseScroll(x: 0, y: Double(delta), mods: TerminalScrollModifiers(precision: true).rawValue)
                applyToScrollModel(delta, extent, source: .settleNow)
            #else
                systemScrollStop()
                if systemScrollIsActive { systemScrollAlign(animated: false) }
            #endif
        }

        /// 惯性途中手指落下把它停住：先原地停着（和 UIScrollView 一样），0.12 s 后要是没接着拖（只是点一下），再对齐回整行。
        func settleScrollSoon() {
            momentumScroll.settleToken += 1
            let token = momentumScroll.settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, token == momentumScroll.settleToken, !momentumScroll.panActive,
                      momentumScroll.displayLink == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    // 点停那一下刚停住滚动视图，「最近有 didScroll」不算在动，不然这次对齐就被拦掉了，停在半行或界外。
                    // 回弹途中被按住、没拖就松手：我们在按下时停住了 UIKit 的回弹，停在界外的那一段也要在这里拉回来。
                    if systemScrollBusy(countingRecentScroll: false, countingOutOfRange: false) { return }
                #endif
                snapScrollToRow()
            }
        }

        // MARK: 自写的惯性（按速度衰减）：只给不归系统滚动的那几种拖动

        /// 现在的位移是不是按行报给程序（程序抓着鼠标，且不是双指的本地整行滚动）。
        private var scrollReportsToProgram: Bool {
            !(usesInlineTextSelection && momentumScroll.scrollsLocally) && surface?.isMouseCaptured == true
        }

        func startMomentumScrolling(velocity: CGPoint) {
            var velocity = velocity
            var stopSpeed: CGFloat = 50
            // uTerm 本地补丁（抓鼠标的程序松手后的惯性）：位移交给引擎，引擎每攒够一格就给程序报一次滚轮，画面由程序自己
            // 一行一行地重画，和 Mac 触控板的惯性滚动是一回事。和别的惯性（备用屏、没有回滚、双指本地滚动）有三处不同：
            // - 滑得近：距离是 UIScrollView `.normal` 的 `UTermScrollTrace.programMomentumTravel` 倍（四分之一，见 momentumScrollFrame）。
            //   照 `.normal` 滑时 user 觉得太远：整行整行跳的画面跟不住眼睛，程序一次滚轮也可能不止滚一行；
            // - 只留主方向：横向那点速度攒够一格会被报成横向滚轮；
            // - 慢到两行相隔 0.15 s 以上就停：一行一跳的画面，收尾那几下零星的跳比早点停难看
            //  （按 50 pt/s 那条线，13 pt 的行高最后几行要隔 0.26 s 才跳一下）。抬手速度不到这条线的不起惯性。
            let reports = scrollReportsToProgram
            if reports {
                let vertical = abs(velocity.y) >= abs(velocity.x)
                if vertical { velocity.x = 0 } else { velocity.y = 0 }
                if let metrics = surface?.size() {
                    let cell = CGFloat(vertical ? metrics.cellHeightPixels : metrics.cellWidthPixels) / resolvedDisplayScale()
                    stopSpeed = max(stopSpeed, cell / 0.15)
                }
            }
            guard abs(velocity.x) > stopSpeed || abs(velocity.y) > stopSpeed else { return }

            momentumScroll.velocity = velocity
            momentumScroll.reportsToProgram = reports
            momentumScroll.stopSpeed = stopSpeed
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

        static var scrollFrameRateRange: CAFrameRateRange {
            CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            // uTerm 本地补丁：位移的去向途中变了（起的时候程序抓着鼠标，现在它放开了，比如退出了全屏界面；或者反过来），
            // 惯性到此为止。接着走的话，本来报给程序的速度会拿去滚视口（视口归 UIScrollView 管，这里再动它两边就对不上了），
            // 或者本来滚视口的速度变成一串滚轮报给刚起来的程序。
            if momentumScroll.reportsToProgram != scrollReportsToProgram {
                stopMomentumScrolling()
                return
            }
            let dt = link.targetTimestamp - link.timestamp
            // uTerm 本地补丁：减速按 UIScrollView 的 `.normal`（每毫秒 0.998），和系统滚动甩出去的距离、收尾一致。
            // 上游是每 1/60 s 0.92，摩擦大得多，甩一下就停。按帧时长缩放，60 / 120 Hz 一样远。
            // 报给程序的那种惯性再按 `programMomentumTravel` 缩短距离（距离和减速率成反比）。
            let travel = momentumScroll.reportsToProgram ? max(0.05, UTermScrollTrace.programMomentumTravel) : 1
            let decay = CGFloat(pow(0.998, dt * 1000 / travel))

            momentumScroll.velocity.x *= decay
            momentumScroll.velocity.y *= decay

            let deltaX = momentumScroll.velocity.x * dt
            let deltaY = momentumScroll.velocity.y * dt

            let stopSpeed = momentumScroll.stopSpeed
            if abs(momentumScroll.velocity.x) < stopSpeed, abs(momentumScroll.velocity.y) < stopSpeed {
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
            /// 先原地停着，稍后没人接手再对齐回整行（惯性途中手指落下）。
            case later
            /// 当场对齐整行（要按整数视口算命中、视图离屏、进后台）。
            case now
        }

        /// 惯性 / 系统减速途中手指落下（`touchesBegan` / 点按识别器收到触摸）：停住，稍后没接着拖再对齐。
        func stopMomentumForTouchDown() {
            #if !targetEnvironment(macCatalyst)
                systemScrollStop()
            #endif
            stopMomentumScrolling(settle: .later)
        }

        /// 默认 `.now`：调用方大多是「接下来要按格子算位置」或「视图不显示了」，视口停在半行不行。
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
