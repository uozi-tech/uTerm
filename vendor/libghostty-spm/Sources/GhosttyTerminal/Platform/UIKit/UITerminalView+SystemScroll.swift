//
//  UITerminalView+SystemScroll.swift
//  uTerm 本地补丁：单指滚动的手势和物理交给 UIScrollView。
//
//  按「真正上玻璃」量真手甩：自写手势时冻结几乎都在手指参与的时刻（按下停住、拖动、松手交接），惯性中段反而好。
//  自写的 UIPanGestureRecognizer 每次按下都要重新识别，交接那一拍还要等上一步画出来。
//  UIScrollView 在减速中被按住直接续上跟踪，松手的减速、到头的回弹、落点都是系统的。这里只借它这些：
//  一个藏在终端视图里、不画东西、不接触摸的 UIScrollView，把它的 panGestureRecognizer 挂到终端视图上，
//  contentOffset 的变化换成整数物理像素发给引擎（视口位置的镜像见 UITerminalView+Scroll.swift）。
//  双指整行滚动、选区拖动、备用屏 / 程序抓鼠标、没有回滚可滚的情况仍走自写的拖动（UITerminalView+Scroll.swift，
//  它们不需要到顶 / 到底的物理）。评估期那套自写的橡皮筋、弹簧回弹、落点惯性已经删掉，回滚区的滚动物理只有这一份。
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    /// 藏在终端视图里的 UIScrollView：只借手势识别器、减速、回弹和落点。
    final class UTermScrollDriverView: UIScrollView {
        /// 这一下单指拖动归不归它。不归时它的 pan 不开始，自写的 pan 接手。
        var shouldBeginPan: (() -> Bool)?

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer, let shouldBeginPan, !shouldBeginPan() { return false }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        /// 不接任何触摸：点按、长按、选区手柄都要落到终端视图自己的 touches 和识别器上。
        override func hitTest(_: CGPoint, with _: UIEvent?) -> UIView? { nil }
    }

    struct SystemScrollState {
        var driver: UTermScrollDriverView?
        /// 正在按引擎回写 contentOffset：didScroll 不要再把它发回引擎。
        var isSyncing = false
        /// 松手后 UIKit 在减速 / 回弹（didEndDragging(willDecelerate: true) 到 didEndDecelerating 之间）。
        /// 和 isDecelerating 是一回事，单独记一份是为了不全靠 UIKit 的标志（测试里伪造的减速也要算）。
        var uikitMoving = false
        /// 最近一次 didScroll 的时刻（uikitMoving 的兜底：很久没动又没收到结束回调，就当结束了）。
        var lastDidScroll: CFTimeInterval = 0
        /// 对齐到整行的动画。自己用 display link 一帧帧写 contentOffset，不用 setContentOffset(animated:)：
        /// UIKit 那个动画开始以后取消不掉（setContentOffset(同一个值, animated: false) 停不住它），手指再拖起来时
        /// 它和手指每帧各写一次 contentOffset，引擎被来回拽，画面每帧横跳一下（user 录到的「两条交错的序列」，
        /// 一条钉在对齐目标上）。自己的动画随时能停。
        var alignLink: CADisplayLink?
        var alignFrom: CGFloat = 0
        var alignTo: CGFloat = 0
        var alignStart: CFTimeInterval = 0
        /// 这个视图的编号（signpost 里区分是哪个终端视图发的）。
        var serial = 0
        /// 已经为哪一头的回弹给引擎多发过一屏（-1 顶、1 底、0 没有）。
        var healedEdge = 0
        /// 引擎坐标比滚动视图坐标多出的像素：引擎位置 = contentOffset（px）+ shift。
        /// 平时是 0。停在底部时手指还按着 / 还在回弹，来了新输出：引擎跟着活动区往下走，回滚变长；这时不能改 contentSize、
        /// 更不能挪 contentOffset（会和 UIKit 的跟踪、回弹抢），就让滚动视图的「底」继续代表引擎的底，差多少记在这里。
        /// 停下来之后一次性把 contentSize、contentOffset 对到引擎上，shift 归零。
        var shiftPx = 0
        /// 「稍后再对一次引擎」的凭据（见 systemScrollResyncSoon）。
        var resyncToken = 0
    }

    /// 给每个终端视图编个号（signpost 用）。
    @MainActor enum SystemScrollSerial {
        static var next = 0
    }

    /// 系统滚动的几何：滚动视图那边和引擎那边各自最远能滚到哪（物理像素）。
    struct SystemScrollGeometry {
        let scale: CGFloat
        let cell: Int
        let screenRows: Int
        let engineMax: Int
        let viewMax: CGFloat
        let shift: Int
    }

    extension UITerminalView: UIScrollViewDelegate {
        /// 系统滚动这条路径现在用不用得上：驱动器在、有回滚可滚、程序没抓鼠标。
        var systemScrollIsActive: Bool {
            guard systemScroll.driver != nil,
                  surface?.isMouseCaptured != true,
                  let bar = core.bridge.scrollbar, bar.total > bar.len else { return false }
            return true
        }

        /// 这一下单指拖动归系统滚动：上面那些，再加没有选区在拖。
        var systemPanWouldBegin: Bool {
            systemScrollIsActive && touchSelection.range == nil
        }

        /// UIScrollView 正在减速 / 回弹，或者我们的对齐动画在跑。
        var systemScrollInMotion: Bool {
            guard let driver = systemScroll.driver else { return false }
            return driver.isDecelerating || systemScroll.uikitMoving || systemScroll.alignLink != nil
        }

        /// 有人在动滚动视图：手指按着 / 拖着、减速、对齐动画，或者还停在界外（回弹没走完）。
        /// 这时我们一律不写 contentOffset、不起对齐，不然就是两个人同时拽它（user：「反复横跳」）。
        var systemScrollIsBusy: Bool { systemScrollBusy(countingRecentScroll: true) }

        /// `countingRecentScroll`：把「最近 50 ms 里有过 didScroll」也算在动。减速 / 对齐刚结束的那一下要对齐引擎，不算这一条。
        /// `countingOutOfRange`：停在界外算在动（回弹还没走完）。点停兜底要把界外拉回来，不算这一条。
        func systemScrollBusy(countingRecentScroll: Bool, countingOutOfRange: Bool = true) -> Bool {
            guard let driver = systemScroll.driver else { return false }
            if driver.isTracking || driver.isDragging || systemScrollInMotion || momentumScroll.panActive {
                return true
            }
            // 别人在动它（点状态栏回顶的动画之类，UIKit 不报 isDecelerating）：最近 50 ms 里有过 didScroll 就算在动。
            if countingRecentScroll, CACurrentMediaTime() - systemScroll.lastDidScroll < 0.05 { return true }
            guard countingOutOfRange else { return false }
            let offset = driver.contentOffset.y
            let maxOffset = max(0, driver.contentSize.height - driver.bounds.height)
            let unit = 1 / (window?.screen.scale ?? traitCollection.displayScale)
            return offset < -unit || offset > maxOffset + unit
        }

        func installSystemScrollDriver() {
            guard systemScroll.driver == nil else { return }
            let driver = UTermScrollDriverView(frame: bounds)
            driver.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            driver.backgroundColor = .clear
            driver.showsVerticalScrollIndicator = false
            driver.showsHorizontalScrollIndicator = false
            driver.contentInsetAdjustmentBehavior = .never
            driver.alwaysBounceVertical = false
            driver.alwaysBounceHorizontal = false
            driver.decelerationRate = .normal
            driver.delegate = self
            // 它不是内容，读屏和焦点都不该看到它。
            driver.isAccessibilityElement = false
            driver.accessibilityElementsHidden = true
            driver.panGestureRecognizer.maximumNumberOfTouches = 1
            driver.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            driver.shouldBeginPan = { [weak self] in self?.systemPanWouldBegin ?? false }
            insertSubview(driver, at: 0)
            addGestureRecognizer(driver.panGestureRecognizer)
            systemScroll.driver = driver
            SystemScrollSerial.next += 1
            systemScroll.serial = SystemScrollSerial.next
        }

        func systemScrollGeometry() -> SystemScrollGeometry? {
            guard let driver = systemScroll.driver, let extent = scrollExtent() else { return nil }
            let scale = resolvedDisplayScale()
            return SystemScrollGeometry(scale: scale, cell: extent.cell, screenRows: extent.screenRows,
                                        engineMax: extent.maxRow * extent.cell,
                                        viewMax: max(0, driver.contentSize.height - driver.bounds.height) * scale,
                                        shift: systemScroll.shiftPx)
        }

        /// 引擎那边变了（滚动条回报、行高、视图尺寸）：contentSize 跟上；没人在滚时 contentOffset 也对到引擎的位置上。
        /// 停在底部时新输出让底部往下挪，offset 跟着到底；向上翻着时引擎的行号不变，offset 不动，只是能滚的范围变长。
        func systemScrollSyncFromEngine(afterMotion: Bool = false) {
            guard let driver = systemScroll.driver, bounds.height > 0, let extent = scrollExtent() else { return }
            let scale = resolvedDisplayScale()
            let engineMax = extent.maxRow * extent.cell
            let size = CGSize(width: bounds.width, height: bounds.height + CGFloat(engineMax) / scale)
            if systemScrollBusy(countingRecentScroll: !afterMotion) {
                // 滚着的时候不碰 contentOffset（和跟踪、回弹、减速抢会抖）。回滚变长了：
                // - 引擎跟着底部走（停在底部来了输出）：contentSize 也不动，滚动视图的底继续代表引擎的底，差值记进 shift；
                // - 引擎停在回滚中间：它的行号不变，往下多出来的只是能滚的范围，放宽 contentSize 就行。
                let viewMax = Int((max(0, driver.contentSize.height - driver.bounds.height) * scale).rounded())
                if momentumScroll.modelAtBottom {
                    if systemScroll.shiftPx != engineMax - viewMax {
                        UTermScrollTrace.signpostScrollWrite(.shiftChange, from: Double(systemScroll.shiftPx), to: Double(engineMax - viewMax))
                    }
                    systemScroll.shiftPx = engineMax - viewMax
                } else if driver.contentSize.height < size.height {
                    let grown = size.height - CGFloat(systemScroll.shiftPx) / scale
                    UTermScrollTrace.signpostScrollWrite(.motionGrowSize, from: Double(driver.contentSize.height * scale), to: Double(grown * scale))
                    systemScroll.isSyncing = true
                    driver.contentSize = CGSize(width: size.width, height: grown)
                    systemScroll.isSyncing = false
                }
                return
            }
            syncScrollModel()
            let target = CGFloat(momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac) / scale
            systemScroll.isSyncing = true
            if driver.contentSize != size {
                UTermScrollTrace.signpostScrollWrite(.restSize, from: Double(driver.contentSize.height * scale), to: Double(size.height * scale))
                driver.contentSize = size
            }
            if abs(driver.contentOffset.y - target) > 0.001 || driver.contentOffset.x != 0 {
                UTermScrollTrace.signpostScrollWrite(.restOffset, from: Double(driver.contentOffset.y * scale), to: Double(target * scale))
                driver.contentOffset = CGPoint(x: 0, y: target)
            }
            systemScroll.isSyncing = false
            // didScroll 被 isSyncing 挡掉了，越界平移得自己归零，否则画面层会挂着上一次的回弹量。
            applyOverscroll(0)
            systemScroll.shiftPx = 0
            systemScroll.healedEdge = 0
        }

        /// 越界（UIScrollView 的橡皮筋）靠平移图层显示，和 UIScrollView 移内容层同一个思路，不让渲染器为它出帧：
        /// 有输出时渲染器同一帧还要重建格子，走 0023 的 overscroll uniform 会跟着它的出帧节奏抖。露出来的那条是视图后面的终端底色。
        /// 平移量取整到物理像素：画面层平移半个像素会被重采样，回弹途中整屏字发虚、行与行的交界多出一条混色线。
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

        /// 停住减速 / 回弹 / 对齐动画，原地不动。返回有没有停掉什么。
        @discardableResult
        func systemScrollStop() -> Bool {
            guard let driver = systemScroll.driver, systemScrollInMotion else { return false }
            systemScrollCancelAlign()
            if driver.isDecelerating || systemScroll.uikitMoving {
                let px = Double(driver.contentOffset.y * resolvedDisplayScale())
                UTermScrollTrace.signpostScrollWrite(.stopDecel, from: px, to: px)
                // 停 UIKit 的减速：设一次 contentOffset（非动画）就停。
                driver.setContentOffset(driver.contentOffset, animated: false)
            }
            systemScroll.uikitMoving = false
            return true
        }

        /// 停掉我们自己的对齐动画（停在当前帧的位置）。
        func systemScrollCancelAlign() {
            systemScroll.alignLink?.invalidate()
            systemScroll.alignLink = nil
        }

        /// 把 contentOffset 对到最近的整行上（引擎跟着 didScroll 走）。已经在整行上就什么也不做。
        func systemScrollAlign(animated: Bool) {
            guard let driver = systemScroll.driver, let g = systemScrollGeometry() else { return }
            // 手指按着 / 拖着：UIKit 的 pan 在写 contentOffset，这时再起对齐动画就是两个人同时拽（松手时会再对齐）。
            guard !driver.isTracking, !driver.isDragging, !momentumScroll.panActive else { return }
            // 行号信镜像：这里要是照滚动条回报改了镜像，对齐动画的第一帧就会把这个差发给引擎（跳过去再滑回来）。
            syncScrollModel(adoptingBar: false)
            let position = momentumScroll.modelRow * g.cell + momentumScroll.modelFrac
            let aligned = min(g.engineMax, Int((Double(position) / Double(g.cell)).rounded()) * g.cell)
            let targetPx = min(max(0, CGFloat(aligned - g.shift)), g.viewMax)
            let offsetPx = driver.contentOffset.y * g.scale
            guard aligned != position || abs(offsetPx - targetPx) > 0.5 else { return }
            // UIKit 把 contentOffset 取整到 1/UIScreen.scale pt。取整后和现在一样：滚动视图不会动、didScroll 不会来，
            // 那就直接把引擎对齐（误差不到半个物理像素，画面上看不出滚动视图没挪）。
            let unit = 1 / (window?.screen.scale ?? traitCollection.displayScale)
            let targetPt = targetPx / g.scale
            if abs((targetPt / unit).rounded() * unit - driver.contentOffset.y) < unit / 2 {
                if aligned != position, let extent = scrollExtent() {
                    UTermScrollTrace.signpostScrollWrite(.alignEngineOnly, from: Double(position), to: Double(aligned))
                    surface?.sendMouseScroll(x: 0, y: Double(position - aligned), mods: TerminalScrollModifiers(precision: true).rawValue)
                    applyToScrollModel(position - aligned, extent, source: .alignEngineOnly)
                }
                return
            }
            systemScrollCancelAlign()
            guard animated else {
                UTermScrollTrace.signpostScrollWrite(.alignImmediate, from: Double(offsetPx), to: Double(targetPx))
                driver.contentOffset = CGPoint(x: 0, y: targetPx / g.scale)
                return
            }
            UTermScrollTrace.signpostScrollWrite(.alignAnimated, from: Double(offsetPx), to: Double(targetPx))
            systemScroll.alignFrom = driver.contentOffset.y
            systemScroll.alignTo = targetPx / g.scale
            systemScroll.alignStart = 0
            let link = CADisplayLink(target: self, selector: #selector(systemScrollAlignFrame(_:)))
            link.preferredFrameRateRange = Self.scrollFrameRateRange
            link.add(to: .main, forMode: .common)
            systemScroll.alignLink = link
        }

        /// 对齐动画的一帧：三次缓出，0.25 s 落定，每帧直接写 contentOffset（didScroll 照常把位移发给引擎）。
        @objc func systemScrollAlignFrame(_ link: CADisplayLink) {
            guard let driver = systemScroll.driver, systemScroll.alignLink === link else { link.invalidate(); return }
            if systemScroll.alignStart == 0 { systemScroll.alignStart = link.timestamp }
            let u = min(1, CGFloat(link.targetTimestamp - systemScroll.alignStart) / 0.25)
            let eased = 1 - pow(1 - u, 3)
            driver.contentOffset = CGPoint(x: 0, y: systemScroll.alignFrom + (systemScroll.alignTo - systemScroll.alignFrom) * eased)
            if u >= 1 {
                systemScrollCancelAlign()
                UTermScrollTrace.signpostScrollPhase(5, Double(driver.contentOffset.y * resolvedDisplayScale()))
                systemScrollSettled()
            }
        }

        // MARK: UIScrollViewDelegate

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver, !systemScroll.isSyncing, let g = systemScrollGeometry(),
                  let extent = scrollExtent() else { return }
            systemScroll.lastDidScroll = CACurrentMediaTime()
            let offsetPx = scrollView.contentOffset.y * g.scale
            // 越界的部分是系统的橡皮筋，平移画面层显示（applyOverscroll）。越界按滚动视图自己的范围算。
            let over: CGFloat = offsetPx < 0 ? -offsetPx : (offsetPx > g.viewMax ? g.viewMax - offsetPx : 0)
            applyOverscroll(over)
            let inView = min(max(0, offsetPx), g.viewMax)
            // UIKit 把 contentOffset 取整到 1/UIScreen.scale pt（Duo 内屏 1/3 pt = 0.94 物理像素），差不到半个格子算在底上。
            let atViewBottom = offsetPx >= g.viewMax - 0.5
            // 滚动视图的底永远代表引擎的底（shift 见 SystemScrollState）。
            let target = atViewBottom ? g.engineMax : min(max(0, Int((inView).rounded()) + g.shift), g.engineMax)
            // 行号信镜像，不看滚动条回报：发给引擎的只能是 contentOffset 走过的那一段。镜像和 contentOffset 只在停稳时
            // 一起对到引擎上（systemScrollSyncFromEngine），这里单改镜像，差出来的几行会被当成位移发出去。
            syncScrollModel(adoptingBar: false)
            let position = momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac
            var delta = position - target
            // 进回弹那一下多给引擎一屏：它自己夹在顶 / 底上、小数清零，镜像偏了几行（输出正涨着）也在这里收掉。
            let edge = offsetPx <= 0 && target == 0 ? -1 : (atViewBottom && offsetPx >= g.viewMax ? 1 : 0)
            if edge != 0, systemScroll.healedEdge != edge {
                let before = delta
                delta += edge < 0 ? g.cell * g.screenRows : -(g.cell * g.screenRows)
                UTermScrollTrace.signpostScrollWrite(.edgeHeal, from: Double(before), to: Double(delta))
            }
            systemScroll.healedEdge = edge
            UTermScrollTrace.signpostDidScroll(offset: Double(offsetPx), over: Double(over), target: target, delta: delta,
                                               tracking: scrollView.isTracking, decelerating: scrollView.isDecelerating,
                                               animating: systemScroll.alignLink != nil)
            if delta != 0 {
                let moving = systemScrollInMotion
                let mods = TerminalScrollModifiers(precision: true, momentum: moving ? .changed : .none)
                surface?.sendMouseScroll(x: 0, y: Double(delta), mods: mods.rawValue)
                applyToScrollModel(delta, extent, source: .systemDidScroll)
                let travelled = position - (momentumScroll.modelRow * extent.cell + momentumScroll.modelFrac)
                UTermScrollTrace.record(moving ? "momentum" : "drag", Double(travelled))
                if let bar = core.bridge.scrollbar { UTermScrollTrace.record("row", Double(bar.offset)) }
            }
            TerminalDebugLog.log(
                .input,
                "uterm-sysscroll offset=\(String(format: "%.1f", offsetPx))px model=\(momentumScroll.modelRow)+\(momentumScroll.modelFrac)px over=\(String(format: "%.0f", over)) tracking=\(scrollView.isTracking) decel=\(scrollView.isDecelerating)",
            )
        }

        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver else { return }
            UTermScrollTrace.signpostTouch(.dragBegan)
            UTermScrollTrace.signpostScrollPhase(1, Double(scrollView.contentOffset.y * resolvedDisplayScale()))
            TerminalDebugLog.log(.input, "sysscroll drag began")
            // 自写路径的惯性（双指整行滚动的）要是还在跑，停掉；系统自己的减速它已经按住了。
            if momentumScroll.displayLink != nil { stopMomentumScrolling(settle: .none) }
            // 我们的对齐动画还在跑：停在原地，交给手指。UIKit 自己的减速它会自己停。
            if systemScroll.alignLink != nil {
                let px = Double(scrollView.contentOffset.y * resolvedDisplayScale())
                UTermScrollTrace.signpostScrollWrite(.stopDecel, from: px, to: px)
                systemScrollCancelAlign()
            }
            systemScroll.uikitMoving = false
            momentumScroll.panActive = true
            momentumScroll.settleToken += 1
            #if !targetEnvironment(macCatalyst)
                softwareKeyboard.tapCandidateArmed = false
            #endif
            if !usesInlineTextSelection { dismissTouchSelection(restoringViewport: false) }
        }

        /// 落点取整到行，交给系统减速。
        public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                              targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard scrollView === systemScroll.driver, let g = systemScrollGeometry() else { return }
            let proposed = targetContentOffset.pointee.y
            // 落点按引擎的行取整（滚动视图坐标 + shift = 引擎坐标），再换回滚动视图坐标。
            let enginePx = min(max(0, proposed * g.scale + CGFloat(g.shift)), CGFloat(g.engineMax))
            let alignedEngine = (enginePx / CGFloat(g.cell)).rounded() * CGFloat(g.cell)
            let aligned = min(max(0, alignedEngine - CGFloat(g.shift)), g.viewMax) / g.scale
            targetContentOffset.pointee.y = aligned
            UTermScrollTrace.signpostScrollPhase(2, Double(velocity.y * 1000 * g.scale), Double(aligned * g.scale))
            TerminalDebugLog.log(.input, "sysscroll drag ending v=\(String(format: "%.2f", velocity.y))pt/ms target=\(String(format: "%.2f", proposed))→\(String(format: "%.2f", aligned))pt")
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard scrollView === systemScroll.driver else { return }
            UTermScrollTrace.signpostScrollPhase(3, decelerate ? 1 : 0, Double(scrollView.contentOffset.y * resolvedDisplayScale()))
            momentumScroll.panActive = false
            if decelerate {
                systemScroll.uikitMoving = true
                systemScroll.lastDidScroll = CACurrentMediaTime()
                watchUIKitMotion()
            } else {
                // 没有减速（几乎没动就松手、或者落点就是现在的位置）：自己对齐。
                systemScrollAlign(animated: true)
                systemScrollResyncSoon()
            }
        }

        /// uikitMoving 的兜底：每 0.25 s 看一次，UIKit 不在减速、又 0.25 s 没 didScroll 了，就当减速结束（正常会先收到 didEndDecelerating）。
        private func watchUIKitMotion() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, systemScroll.uikitMoving, let driver = systemScroll.driver else { return }
                if driver.isDecelerating || CACurrentMediaTime() - systemScroll.lastDidScroll < 0.25 {
                    watchUIKitMotion()
                    return
                }
                UTermScrollTrace.signpostScrollWrite(.watchdog, from: 0, to: 0)
                systemScroll.uikitMoving = false
                systemScrollSettled()
            }
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver else { return }
            UTermScrollTrace.signpostScrollPhase(4, Double(scrollView.contentOffset.y * resolvedDisplayScale()))
            systemScroll.uikitMoving = false
            systemScrollSettled()
        }

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver else { return }
            // 我们不再用 setContentOffset(animated:)；scrollsToTop（点状态栏回顶）会走到这里。
            UTermScrollTrace.signpostScrollPhase(5, Double(scrollView.contentOffset.y * resolvedDisplayScale()))
            systemScroll.uikitMoving = false
            systemScrollSettled()
        }

        /// 手指抬起（没拖起来的那种：点一下、按住不动）。UIKit 在按下那一刻就把减速停在了原地（这正是「续上跟踪」的前提），
        /// 可之后没有任何代理回调告诉我们它停在了半行上；这里兜底，稍后没人接手就对回整行。
        func systemScrollTouchEnded() {
            guard systemScroll.driver != nil, !momentumScroll.panActive else { return }
            UTermScrollTrace.signpostScrollPhase(6)
            settleScrollSoon()
        }

        /// 减速 / 对齐动画结束：核一下还在不在整行上（途中来了输出、顶被裁都可能让落点偏掉），不在就再对一次。
        private func systemScrollSettled() {
            // 结束回调可能在手指已经又拖起来之后才来：这时什么也不做，松手那一下会再对齐。
            if let driver = systemScroll.driver, driver.isTracking || driver.isDragging || momentumScroll.panActive { return }
            systemScroll.healedEdge = 0
            systemScrollAlign(animated: true)
            if systemScroll.alignLink == nil { systemScrollSyncFromEngine(afterMotion: true) }
            systemScrollResyncSoon()
        }

        /// 滚动条回报变了。
        func systemScrollBarChanged() {
            let busy = systemScrollIsBusy
            systemScrollSyncFromEngine()
            // 这一次没法以回报为准（正滚着；或者刚发过位移，分不清它是哪一刻的）：停稳之后再对一次。
            if busy || CACurrentMediaTime() - momentumScroll.lastScrollSend <= 0.1 { systemScrollResyncSoon() }
        }

        /// 稍后（停稳了、回报也到齐了）再把镜像和 contentOffset 对到引擎上一次。
        ///
        /// 滚动途中镜像不看滚动条回报（见 syncScrollModel）。途中别的途径动了视口（回滚满了顶被裁、打字回到底部），
        /// 镜像和 contentOffset 就和引擎差着几行；停稳后要是不再有新的回报进来，就没人来对。这里补上这一次。
        /// 对的时候引擎不动，只改我们这边的两个数，画面不会跳。
        func systemScrollResyncSoon(retries: Int = 6) {
            systemScroll.resyncToken += 1
            let token = systemScroll.resyncToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, systemScroll.resyncToken == token else { return }
                // 还在滚：结束时会再约一次。
                guard !systemScrollIsBusy else { return }
                // 还有回报排着没处理（唤醒闸门全 App 共用，后台标签一直在输出时它常常占着）：这一次对不上，过一会儿再来，最多几次。
                if retries > 0, core.controller?.wakeupGate.isPending == true {
                    systemScrollResyncSoon(retries: retries - 1)
                    return
                }
                systemScrollSyncFromEngine()
            }
        }
    }
#endif
