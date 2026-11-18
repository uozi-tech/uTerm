import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 远程桌面「只看一个窗口」在被控端要的三件事：列出能看的窗口、取一个窗口此刻在哪儿多大、把它提到最前。
///
/// 列窗口和取位置用 `CGWindowList`（窗口标题要屏幕录制授权，远程桌面本来就要）。提到最前要用辅助功能接口：
/// 授权和注入鼠标键盘是同一项，沙盒里另需 `mach-lookup` 的例外权限（`com.apple.axserver`，写在两份
/// entitlements 里；2026-11-17 探针：没有它时读窗口列表报 `-25204`）。没授权时提不动，流照开。
nonisolated enum RemoteDesktopWindows {
    /// 系统窗口表里的一行。
    struct Entry: Equatable, Sendable {
        var id: UInt32
        var pid: pid_t
        var app: String
        var title: String
        /// 全局坐标（左上角原点，点）。
        var bounds: CGRect
        var layer: Int
        var alpha: Double
    }

    /// 比这小的不列：工具条、浮层、状态栏弹出的小面板。
    static let minimumSize = CGSize(width: 160, height: 120)

    // MARK: - 列表

    /// 此刻在屏幕上的窗口，最前面的在前（系统给的顺序）。
    static func onScreenEntries() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap(entry(from:))
    }

    /// 能单独看的那些：普通层级、看得见、不太小。顺序不变。
    static func listable(_ entries: [Entry]) -> [RemoteDesktopWindowSummary] {
        entries.filter { entry in
            entry.layer == 0 && entry.alpha > 0.01
                && entry.bounds.width >= minimumSize.width && entry.bounds.height >= minimumSize.height
        }
        .map { entry in
            RemoteDesktopWindowSummary(id: entry.id, app: entry.app, title: entry.title,
                                       width: entry.bounds.width, height: entry.bounds.height)
        }
    }

    static func list() -> [RemoteDesktopWindowSummary] { listable(onScreenEntries()) }

    /// 一个窗口此刻的那一行；窗口没了返回 nil。
    static func entry(id: UInt32) -> Entry? {
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] else {
            return nil
        }
        return raw.compactMap(entry(from:)).first { $0.id == id }
    }

    /// 一个进程此刻在屏幕上的全部窗口，含菜单、浮层这些不是普通层级的，最上面的在前。
    static func windows(ofPID pid: pid_t) -> [Entry] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.compactMap(entry(from:))
    }

    private static func entry(from info: [String: Any]) -> Entry? {
        guard let number = info[kCGWindowNumber as String] as? NSNumber,
              let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
        return Entry(id: number.uint32Value, pid: pid.int32Value,
                     app: info[kCGWindowOwnerName as String] as? String ?? "",
                     title: info[kCGWindowName as String] as? String ?? "",
                     bounds: bounds,
                     layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                     alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }

    // MARK: - 采集目标

    /// 把窗口当成一块「显示器」交给采集与注入：`bounds` 是窗口此刻的位置，像素按它所在显示器的倍数算。
    static func target(id: UInt32) -> (display: RemoteDesktopDisplay, entry: Entry)? {
        guard let entry = entry(id: id), entry.bounds.width > 0, entry.bounds.height > 0 else { return nil }
        let displayID = display(containing: entry.bounds)
        let scale = pixelScale(of: displayID)
        let display = RemoteDesktopDisplay(id: displayID, bounds: entry.bounds,
                                           pixelWidth: Int((entry.bounds.width * scale).rounded()),
                                           pixelHeight: Int((entry.bounds.height * scale).rounded()),
                                           windowID: id)
        return (display, entry)
    }

    /// 窗口大半在哪块显示器上；一块都不沾（整个在屏幕外）算主显示器。
    static func display(containing bounds: CGRect) -> CGDirectDisplayID {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetDisplaysWithRect(bounds, UInt32(ids.count), &ids, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        return ids.prefix(Int(count)).max { first, second in
            area(CGDisplayBounds(first).intersection(bounds)) < area(CGDisplayBounds(second).intersection(bounds))
        } ?? CGMainDisplayID()
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// 这块显示器每个点几个像素（视网膜屏 2，普通外接屏 1）。
    static func pixelScale(of display: CGDirectDisplayID) -> CGFloat {
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0, let mode = CGDisplayCopyDisplayMode(display) else { return 1 }
        return max(1, (CGFloat(mode.pixelWidth) / bounds.width).rounded())
    }

    // MARK: - 提到最前

    /// 把窗口提到最前、它的 App 变成当前 App。点击只会落到最上面的窗口上；开流那一刻被同一个 App 的另一个窗口
    /// 整个盖住时按窗口的流还一帧都不出（2026-11-17 探针），所以开流前先提一次。同步等辅助功能接口，别在主线程上调。
    /// 沙盒里实测能提别的 App 的窗口（同一天，带 `com.apple.axserver` 例外的探针）。
    ///
    /// `activates` 为 false 时只把窗口提到它那个 App 的窗口堆最上面，不把 App 变成当前 App（2026-11-18 探针：
    /// 窗口会排到当前 App 的窗口后面、别的后台窗口前面，前台 App 不变）。
    @discardableResult
    static func raise(id: UInt32, activates: Bool = true) -> Bool {
        guard let entry = entry(id: id) else { return false }
        if entry.pid == ProcessInfo.processInfo.processIdentifier {
            // 本进程自己的窗口（服务跑在 uTerm 主程序里、看的正是 uTerm 的窗口）：对自己发辅助功能请求会在
            // 调用线程上直接操作窗口，不在主线程就被 AppKit 中断（2026-11-17 探针崩在这里）。改在主线程上直接提。
            DispatchQueue.main.async {
                if activates {
                    NSApp.window(withWindowNumber: Int(id))?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    NSApp.window(withWindowNumber: Int(id))?.orderFront(nil)
                }
            }
            return true
        }
        let app = AXUIElementCreateApplication(entry.pid)
        // 对方卡住时别跟着卡：默认要等 6 秒。
        AXUIElementSetMessagingTimeout(app, 1)
        var raw: CFTypeRef?
        let listed = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard listed == .success, let windows = raw as? [AXUIElement] else {
            AppLogger.notice("远程桌面：读不到 \(entry.app) 的窗口（辅助功能 \(listed.rawValue)），没法把窗口提到最前",
                             category: RemoteLog.category)
            return false
        }
        // 辅助功能接口不给窗口号，按位置和大小对上系统窗口表里的那一个。
        guard let window = windows.first(where: { frame(of: $0).map { matches($0, entry.bounds) } ?? false }) else {
            return false
        }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        if activates { AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
        return raised
    }

    /// 输入按进程投递（不占 Mac 的键鼠）时开流前用：同一个 App 有别的窗口叠在它上面才提，而且不激活 App。
    /// 被别的 App 盖住不用管——流照出、点击照到；只有被自家窗口整个盖住时流一帧都不出（见 `raise`）。
    static func surface(id: UInt32) {
        guard hasSiblingAbove(id: id, in: onScreenEntries()) else { return }
        raise(id: id, activates: false)
    }

    /// 纯规则：`entries` 是屏幕上的窗口（最上面的在前）。同一个进程有没有别的普通窗口叠在这个窗口上面。
    static func hasSiblingAbove(id: UInt32, in entries: [Entry]) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let target = entries[index]
        return entries[..<index].contains { other in
            other.pid == target.pid && other.layer == 0 && other.alpha > 0.01 && other.bounds.intersects(target.bounds)
        }
    }

    /// 走全局输入通道、只看一个窗口时，每次按下之前调：这个点上盖着别的 App 的窗口就先把要看的窗口提到最前，
    /// 等它真的排到上面（最多约 0.3 秒）。全局通道的点击只落到最上面的窗口上，不提就点到别人头上
    /// （2026-11-18 user 反馈）。同步等辅助功能接口，别在主线程上调。
    static func uncover(id: UInt32, at point: CGPoint) {
        guard let entry = entry(id: id), obstruction(to: entry.pid, at: point, in: onScreenEntries()) != nil else { return }
        AppLogger.info("远程桌面：要点的位置被别的 App 的窗口盖着，先把看的窗口提到最前", category: RemoteLog.category)
        guard raise(id: id) else { return }
        for _ in 0..<30 {
            usleep(10_000)
            if obstruction(to: entry.pid, at: point, in: onScreenEntries()) == nil { return }
        }
    }

    /// 纯规则：`entries` 是屏幕上的窗口（最上面的在前）。这个点上最上面的普通窗口是别的进程的就返回它。
    /// 别的进程不是普通层级的窗口不算（程序坞、菜单栏、各种工具铺满屏幕的透明浮层：提窗口也盖不过它们）。
    static func obstruction(to pid: pid_t, at point: CGPoint, in entries: [Entry]) -> Entry? {
        let top = entries.first { entry in
            entry.alpha > 0.01 && entry.bounds.contains(point) && (entry.layer == 0 || entry.pid == pid)
        }
        guard let top, top.pid != pid else { return nil }
        return top
    }

    /// 这个窗口的 App 此刻是不是当前 App（见 `RemoteDesktopStartRequest.windowKeepFront`）。窗口没了也算是。
    ///
    /// 只看 App 在不在最前，不看它在同一个 App 里是不是最上面的那个窗口：同一个 App 里盖在上面的常常是它自己
    /// 弹出来的面板、浮层，再去提主窗口会把这些东西顶掉。
    static func appIsFront(id: UInt32) -> Bool {
        guard let entry = entry(id: id) else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid
    }

    // MARK: - 改大小

    /// 比这小的尺寸不接受（主控端报错了、或画布还没量出来）。
    static let minimumFit = CGSize(width: 200, height: 150)

    /// 把窗口改成 `size`（点），左上角不动。返回改之前的位置；没改（本来就这么大、提不动、对方不让改）返回 nil。
    /// App 有最小窗口尺寸时得到的可能比要的大。同步等辅助功能接口，别在主线程上调。
    static func resize(id: UInt32, to size: CGSize) -> CGRect? {
        guard size.width >= minimumFit.width, size.height >= minimumFit.height, let entry = entry(id: id) else { return nil }
        let target = CGRect(origin: entry.bounds.origin, size: CGSize(width: size.width.rounded(), height: size.height.rounded()))
        guard !matches(entry.bounds, target) else { return nil }
        guard setFrame(target, of: entry, moves: false) else { return nil }
        settle(id: id, target: target)
        guard let after = self.entry(id: id), !matches(after.bounds, entry.bounds) else { return nil }
        return entry.bounds
    }

    /// 把窗口挪到 `frame`（换一块屏幕放，位置和大小一起改），等它停下来。挪不动返回 false。
    /// 同步等辅助功能接口，别在主线程上调。
    static func place(id: UInt32, frame: CGRect) -> Bool {
        guard let entry = entry(id: id) else { return false }
        guard setFrame(frame, of: entry, moves: true) else { return false }
        settle(id: id, target: frame)
        return true
    }

    /// 把窗口放回 `frame`（流结束时还原）。窗口没了就算了。
    static func restore(id: UInt32, frame: CGRect) {
        guard let entry = entry(id: id), !matches(entry.bounds, frame) else { return }
        _ = setFrame(frame, of: entry, moves: true)
    }

    private static func setFrame(_ frame: CGRect, of entry: Entry, moves: Bool) -> Bool {
        if entry.pid == ProcessInfo.processInfo.processIdentifier {
            // 本进程自己的窗口：同 `raise`，不走辅助功能，在主线程上直接改。全局坐标左上角原点 → AppKit 左下角原点。
            DispatchQueue.main.sync {
                guard let window = NSApp.window(withWindowNumber: Int(entry.id)) else { return }
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                window.setFrame(NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height),
                                display: true)
            }
            return true
        }
        let app = AXUIElementCreateApplication(entry.pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement],
              let window = windows.first(where: { self.frame(of: $0).map { matches($0, entry.bounds) } ?? false }) else {
            return false
        }
        var size = frame.size, origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return false }
        if moves { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue) }
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        // 跨显示器还原时，尺寸受窗口当时所在屏幕约束：挪过去之后再设一遍。
        if moves { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        return resized
    }

    /// 等窗口的大小停下来（有的 App 改大小带动画）：连着两次读到一样的就算停了，最多约 0.5 秒。
    /// 已经是要的大小就不等：多数 App 在辅助功能调用返回时已经改完，系统窗口表最多晚几毫秒，先快看几眼
    /// （原先每次至少睡 50 ms，转屏、弹键盘时都白等这一下）。
    private static func settle(id: UInt32, target: CGRect) {
        for _ in 0..<4 {
            if let now = entry(id: id)?.bounds, matches(now, target) { return }
            usleep(6_000)
        }
        var last = entry(id: id)?.bounds
        for _ in 0..<10 {
            usleep(50_000)
            let now = entry(id: id)?.bounds
            if now == last { return }
            last = now
        }
    }

    static func matches(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// 按窗口采集时，一帧画面对应屏幕上哪一块、占视频帧多大一部分。
///
/// 2026-11-17 探针（macOS 27.2.1）：按窗口开的流输出尺寸不变；窗口改大小、弹出的菜单伸出窗口时，系统把新的范围
/// 等比缩进同一帧、靠左上角放，每帧带着 `contentRect`（内容在帧里的位置，点）、`contentScale`（缩了多少）、
/// `scaleFactor`（每点几个像素）、`screenRect`（窗口在屏幕上的位置，不含伸出去的菜单）。
nonisolated struct RemoteDesktopFrameGeometry: Equatable, Sendable {
    /// 画面对应的范围（全局坐标，点）。
    var bounds: CGRect
    /// 内容占视频帧的比例（0…1，从左上角算）。
    var contentFraction: CGSize

    static func whole(_ bounds: CGRect) -> RemoteDesktopFrameGeometry {
        RemoteDesktopFrameGeometry(bounds: bounds, contentFraction: CGSize(width: 1, height: 1))
    }

    /// 由一帧附带的几何算出来。算不出（缺字段、尺寸为零）返回 nil。
    ///
    /// - Parameters:
    ///   - contentRect: 内容在帧里的位置（点，帧左上角为原点）。
    ///   - contentScale: 内容相对原大小缩了多少（1 = 没缩）。
    ///   - scaleFactor: 帧里每个点几个像素。
    ///   - screenRect: 窗口在屏幕上的位置（全局坐标，点）。
    ///   - frameSize: 帧的像素尺寸。
    static func make(contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat, screenRect: CGRect,
                     frameSize: CGSize) -> RemoteDesktopFrameGeometry? {
        guard contentRect.width > 0, contentRect.height > 0, contentScale > 0, scaleFactor > 0,
              frameSize.width > 0, frameSize.height > 0 else { return nil }
        let fraction = CGSize(width: min(1, contentRect.width * scaleFactor / frameSize.width),
                              height: min(1, contentRect.height * scaleFactor / frameSize.height))
        // 内容原本多大（点）：窗口，或窗口加上伸出去的菜单。
        let size = CGSize(width: contentRect.width / contentScale, height: contentRect.height / contentScale)
        // 范围比窗口大（菜单伸出去了）时系统不报并集在哪儿：菜单几乎都往右、往下伸，按左上角不动算。
        return RemoteDesktopFrameGeometry(bounds: CGRect(origin: screenRect.origin, size: size), contentFraction: fraction)
    }

    /// 和另一份差得够不够多、值得告诉主控端：位置随便动，尺寸差 1 点或占比差千分之二以上才算。
    func differsVisibly(from other: RemoteDesktopFrameGeometry) -> Bool {
        abs(bounds.width - other.bounds.width) >= 1 || abs(bounds.height - other.bounds.height) >= 1
            || abs(contentFraction.width - other.contentFraction.width) >= 0.002
            || abs(contentFraction.height - other.contentFraction.height) >= 0.002
    }

    var update: RemoteDesktopGeometryUpdate {
        RemoteDesktopGeometryUpdate(width: bounds.width, height: bounds.height,
                                    contentWidth: contentFraction.width, contentHeight: contentFraction.height)
    }
}
