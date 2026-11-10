//
//  AppTerminalView+SmoothScroll.swift
//  uTerm 本地补丁（上游没有这个文件）
//
//  配合 GhosttyKit 0023 的逐像素平滑滚动：触控板停手后把视口吸附回整行。
//
//  0023 让精确滚动（触控板）按像素滚，视口可以停在「第几行 + 往下多少像素」。Ghostty 的点击、选区命中都按整数视口算，
//  停在半行会差一行；字也停在被切了一截的位置上。iOS 那边在 `UITerminalView+Scroll.swift` 里做了同样的事，
//  这里是 AppKit 的对应物，规则照搬、只留 Mac 用得上的那部分（没有回弹，惯性是系统发来的滚动事件）。
//
//  C 接口只报行号（滚动条回报，晚一帧）、不报那半行小数，所以照引擎 `smoothScrollViewport` 的算法自己记一份镜像：
//  发给引擎的位移一律是整数像素，两边都是整数运算，镜像不会和引擎差出小数。
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    /// 触控板平滑滚动的状态（uTerm 本地补丁）。
    struct SmoothScrollState {
        /// 视口位置的镜像：首行行号、首行顶边之上滚出去的像素（0 ..< 行高；到顶 / 回到活动区时引擎清零）。
        var modelRow = 0
        var modelFrac = 0
        var modelValid = false
        var modelAtBottom = false
        /// 最近一次真给引擎发位移的时刻：滚动条回报要比它晚才作数。
        var lastSend: CFTimeInterval = 0
        /// 位移里不足一像素的零头，留到下一个事件。
        var carry: CGFloat = 0
        /// 「稍后吸附」的凭据：之后又来了滚动事件就作废。
        var settleToken = 0
        /// 吸附动画：要走的总像素、已发出的、起点时刻。
        var snapTimer: Timer?
        var snapTotal = 0
        var snapSent = 0
        var snapStart: CFTimeInterval = 0
    }

    extension AppTerminalView {
        /// 行高（物理像素）和视口首行最远能到第几行（= 回滚行数；没有回滚、备用屏是 0）。
        struct SmoothScrollExtent {
            let cell: Int
            let maxRow: Int
        }

        func smoothScrollExtent() -> SmoothScrollExtent? {
            guard let metrics = surface?.size(), metrics.cellHeightPixels > 0 else { return nil }
            let maxRow = core.bridge.scrollbar.map { $0.total > $0.len ? Int($0.total - $0.len) : 0 } ?? 0
            return SmoothScrollExtent(cell: Int(metrics.cellHeightPixels), maxRow: maxRow)
        }

        /// 滚轮 / 触控板事件的入口（`scrollWheel(with:)` 调）。
        ///
        /// 精确位移乘上屏幕倍率再给引擎：引擎按物理像素算，上游这里原样传 pt，2x 屏上内容只走手指的一半。
        /// 程序抓着鼠标、没有回滚可滚（含备用屏）、鼠标滚轮：不归平滑滚动，位移原样交给引擎
        ///（按行报给程序 / 换成方向键 / 整行滚），镜像作废。
        func handleScrollWheel(_ event: NSEvent) {
            let mods = TerminalScrollModifiers(
                precision: event.hasPreciseScrollingDeltas,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase),
            )
            let scale = event.hasPreciseScrollingDeltas ? CGFloat(currentScaleFactor()) : 1
            guard event.hasPreciseScrollingDeltas, !isMouseCaptured,
                  let extent = smoothScrollExtent(), extent.maxRow > 0
            else {
                cancelScrollSettle()
                smoothScroll.modelValid = false
                smoothScroll.carry = 0
                surface?.sendMouseScroll(
                    x: event.scrollingDeltaX * scale,
                    y: event.scrollingDeltaY * scale,
                    mods: mods.rawValue,
                )
                return
            }

            cancelScrollSettle()
            // 只发整数像素，零头留到下一个事件。普通屏上横向滚动没有意义，不发。
            let exact = event.scrollingDeltaY * scale + smoothScroll.carry
            let whole = exact.rounded()
            smoothScroll.carry = exact - whole
            if whole != 0 {
                syncSmoothScrollModel(extent)
                applyToSmoothScrollModel(Int(whole), extent)
                surface?.sendMouseScroll(x: 0, y: Double(whole), mods: mods.rawValue)
            }

            // 收尾：惯性走完当场吸附；手指抬起后稍等一下，系统接着发惯性的话会把这次作废。
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                settleScrollSoon(after: 0)
            } else if event.phase == .ended || event.phase == .cancelled {
                settleScrollSoon(after: 0.08)
            }
        }

        /// 用镜像之前先和引擎对一下（规则同 iOS 的 `syncScrollModel`）。
        ///
        /// 滚动条回报是渲染线程那一帧发的，要等主线程的下一次 tick 才到手，比发出去的位移晚一帧上下，所以连着发位移时
        /// 信镜像、不信它；回报确实是「发完位移之后」的才以它的行号为准（别的途径也会动视口：新输出、打字回到底部、
        /// 键盘翻页）。行号被别的途径改了，引擎就不再认那半行小数，镜像跟着清零。
        private func syncSmoothScrollModel(_ extent: SmoothScrollExtent) {
            if let bar = core.bridge.scrollbar {
                if !smoothScroll.modelValid || scrollbarReflectsLastScrollSend() {
                    let row = Int(bar.offset)
                    if !smoothScroll.modelValid || row != smoothScroll.modelRow { smoothScroll.modelFrac = 0 }
                    smoothScroll.modelRow = row
                    smoothScroll.modelAtBottom = bar.offset + bar.len >= bar.total
                    smoothScroll.modelValid = true
                }
            } else {
                smoothScroll.modelRow = 0
                smoothScroll.modelFrac = 0
                smoothScroll.modelAtBottom = true
                smoothScroll.modelValid = true
            }
            // 跟着活动区走的时候来了新输出：回滚变长，底部跟着往下挪。
            if smoothScroll.modelAtBottom || smoothScroll.modelRow >= extent.maxRow {
                smoothScroll.modelRow = extent.maxRow
                smoothScroll.modelFrac = 0
                smoothScroll.modelAtBottom = true
            }
            // 行高变了（改字号）之后小数可能超过一行，夹回去。
            smoothScroll.modelFrac = min(max(0, smoothScroll.modelFrac), extent.cell - 1)
        }

        /// 手里这份滚动条回报反映的是不是最后一次发位移之后的视口（同 iOS 的 `scrollbarReflectsLastSend`）。
        private func scrollbarReflectsLastScrollSend() -> Bool {
            let sent = smoothScroll.lastSend
            guard CACurrentMediaTime() - sent > 0.1 else { return false }
            if core.bridge.scrollbarStamp - sent > 0.1 { return true }
            return core.controller?.wakeupGate.isPending != true
        }

        /// 引擎 `smoothScrollViewport` 的镜像：往回滚方向滚 `pixels`（负 = 往活动区）。滚过顶 / 回到活动区，引擎停在边上、不留小数。
        private func applyToSmoothScrollModel(_ pixels: Int, _ extent: SmoothScrollExtent) {
            guard pixels != 0 else { return }
            let limit = extent.maxRow * extent.cell
            let position = min(max(0, smoothScroll.modelRow * extent.cell + smoothScroll.modelFrac - pixels), limit)
            smoothScroll.modelAtBottom = position >= limit
            smoothScroll.modelRow = smoothScroll.modelAtBottom ? extent.maxRow : position / extent.cell
            smoothScroll.modelFrac = smoothScroll.modelAtBottom ? 0 : position % extent.cell
            smoothScroll.lastSend = CACurrentMediaTime()
        }

        // MARK: 停下时吸附整行

        func cancelScrollSettle() {
            smoothScroll.settleToken += 1
            smoothScroll.snapTimer?.invalidate()
            smoothScroll.snapTimer = nil
        }

        private func settleScrollSoon(after delay: TimeInterval) {
            smoothScroll.settleToken += 1
            let token = smoothScroll.settleToken
            guard delay > 0 else { snapScrollToRow(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, token == smoothScroll.settleToken else { return }
                snapScrollToRow()
            }
        }

        /// 把半行补成整行：离哪边近往哪边走，三次缓出 0.18 s 落定，每一步只发整像素。
        func snapScrollToRow() {
            smoothScroll.snapTimer?.invalidate()
            smoothScroll.snapTimer = nil
            guard !isMouseCaptured, let extent = smoothScrollExtent(), extent.maxRow > 0 else { return }
            syncSmoothScrollModel(extent)
            let frac = smoothScroll.modelFrac
            guard frac != 0 else { return }
            smoothScroll.snapTotal = frac * 2 <= extent.cell ? frac : frac - extent.cell
            smoothScroll.snapSent = 0
            smoothScroll.snapStart = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapScrollTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            smoothScroll.snapTimer = timer
        }

        private func snapScrollTick() {
            guard let extent = smoothScrollExtent() else { cancelScrollSettle(); return }
            let total = smoothScroll.snapTotal
            let u = min(1, (CACurrentMediaTime() - smoothScroll.snapStart) / 0.18)
            let target = u >= 1 ? total : Int((Double(total) * (1 - pow(1 - u, 3))).rounded())
            let delta = target - smoothScroll.snapSent
            if delta != 0 {
                smoothScroll.snapSent = target
                applyToSmoothScrollModel(delta, extent)
                surface?.sendMouseScroll(x: 0, y: Double(delta), mods: TerminalScrollModifiers(precision: true).rawValue)
            }
            if u >= 1 {
                smoothScroll.snapTimer?.invalidate()
                smoothScroll.snapTimer = nil
            }
        }
    }

    public extension AppTerminalView {
        /// uTerm 测试用：滚动镜像的快照。
        struct UTermScrollState: Equatable, Sendable {
            /// 视口首行行号、首行顶边之上滚出去的像素。
            public let row: Int
            public let fractionPixels: Int
            public let isSnapping: Bool
            /// 没有吸附在跑，视口在整行上。
            public var isAtRest: Bool { fractionPixels == 0 && !isSnapping }
        }

        var uTermScrollState: UTermScrollState {
            UTermScrollState(row: smoothScroll.modelRow, fractionPixels: smoothScroll.modelFrac,
                             isSnapping: smoothScroll.snapTimer != nil)
        }

        /// uTerm 测试用：引擎最近一次报的滚动条行号（视口首行）；还没报过时为 nil。
        var uTermScrollbarOffset: Int? { core.bridge.scrollbar.map { Int($0.offset) } }

        /// uTerm 测试用：Ghostty 报的一个格子的物理像素尺寸；还没有 surface 时为 nil。
        var uTermCellPixels: CGSize? {
            guard let metrics = surface?.size(), metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
            return CGSize(width: Int(metrics.cellWidthPixels), height: Int(metrics.cellHeightPixels))
        }
    }
#endif
