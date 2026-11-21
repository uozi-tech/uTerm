import AppKit
import CoreImage
import SwiftData
import SwiftUI
import UDesignKit
@testable import uTerm

// 移植自 uTable 的界面画廊（uTable `72756fd`，`uTableTests/Support/UICatalog`）。
// 差别：uTerm 的测试宿主带沙盒，图写不到仓库里 —— 每张图同时挂成 XCTAttachment，
// `make gallery` 从 xcresult 里导出来再拼页；终端画面是 Ghostty 在渲染线程上画进 IOSurface 的，
// `cacheDisplay` 拍不到，渲染器单独把 surface 那一帧贴回去。

/// 界面画廊的**目录**：uTerm 每一个窗口 / 派生界面一条记录。
///
/// 记录 = 层级路径 ID（`欢迎页/主机`、`工作区/终端分屏`…）+ 构造闭包 + 渲染尺寸 +
/// 源码位置（文件 + 类型名；行号由 `scripts/ui-gallery.py` 现查）。
///
/// 渲染见 `UICatalogSnapshotTests`（设 `UI_GALLERY_OUT` 才跑），拼页见 `make gallery`。
/// 往这里加界面：在对应 `UICatalog+*.swift` 的数组里加一条即可。
struct UICatalogEntry {
    enum Kind: String { case window, sheet, popover, panel, component }

    /// 层级路径，`/` 分隔。画廊左侧的树按它建。
    let id: String
    let kind: Kind
    /// 仓库相对路径。
    let source: String
    /// 源码里的类型 / 函数名（脚本据此 grep 出行号）。
    let symbol: String
    let size: CGSize
    let note: String?
    /// 画面里有 Ghostty 终端：窗口要在屏上（透明）才有显示节拍出帧。
    let live: Bool
    let build: @MainActor (UICatalogStage) async throws -> UICatalogRender

    init(_ id: String, _ kind: Kind = .window, source: String, symbol: String,
         size: CGSize = UICatalogEntry.windowSize, note: String? = nil, live: Bool = false,
         build: @escaping @MainActor (UICatalogStage) async throws -> UICatalogRender) {
        self.id = id; self.kind = kind; self.source = source; self.symbol = symbol
        self.size = size; self.note = note; self.live = live; self.build = build
    }

    var fullWindow: Bool { kind == .window }

    static let windowSize = CGSize(width: 1280, height: 800)
}

/// 一条记录造出来的东西：要挂的视图 + 挂上之后要做的事。
struct UICatalogRender {
    var view: AnyView
    /// 挂载并定型之后调用；可以改模型、喂终端输出、等异步加载落地。
    var after: (@MainActor (NSView) async -> Void)?
    /// 截完图后调用（关会话等）。
    var cleanup: (@MainActor () async -> Void)?

    init(_ view: some View, after: (@MainActor (NSView) async -> Void)? = nil,
         cleanup: (@MainActor () async -> Void)? = nil) {
        self.view = AnyView(view); self.after = after; self.cleanup = cleanup
    }
}

/// 全部目录。新增分区文件后在这里登记。
@MainActor
enum UICatalog {
    static var all: [UICatalogEntry] {
        welcome + workspace + tools + settings
    }
}

// MARK: - 舞台：每次渲染一份干净的环境

/// 每条记录每个主题都重新搭一次：新的内存 SwiftData 容器、新的设置存储、新的环境对象。
@MainActor
final class UICatalogStage {
    /// 一份会话：内存容器 + App 根注入的那些环境对象 + 夹具主机。
    @MainActor
    final class Session {
        let container: ModelContainer
        let defaults: UserDefaults
        let forwarding = ForwardingCoordinator()
        let globalForwarding = GlobalForwardingModel()
        let launchRelay = HostKeyChallengeRelay()
        let control: ControlSettings
        let background: BackgroundServiceSettings
        let registry = TerminalSessionRegistry()
        let remoteMacs = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                            adoptsRelayAsDefault: false)
        let fileSharing: RemoteFileSharingStore
        var hosts: [String: ServerProfile] = [:]
        var groups: [String: ServerGroup] = [:]
        var commands: [QuickCommand] = []

        init(container: ModelContainer, defaults: UserDefaults) {
            self.container = container
            self.defaults = defaults
            control = ControlSettings(defaults: defaults)
            background = BackgroundServiceSettings(defaults: defaults)
            fileSharing = RemoteFileSharingStore(defaults: defaults)
        }

        var context: ModelContext { container.mainContext }

        /// 给任意视图注入 App 根上的环境。
        func wrap(_ view: some View) -> some View {
            view
                .modelContainer(container)
                .defaultAppStorage(defaults)
                .environment(forwarding)
                .environment(globalForwarding)
                .environment(launchRelay)
                .environment(control)
                .environment(background)
                .environment(registry)
                .environment(remoteMacs)
                .environment(fileSharing)
        }

        func host(_ name: String) -> ServerProfile { hosts[name]! }
    }

    /// 搭一份会话。`hosts: false` 时容器里一台主机都没有（欢迎页空态）。
    func session(hosts withHosts: Bool = true) throws -> Session {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(ModelRegistry.types), configurations: config)
        let suite = "ui-catalog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let s = Session(container: container, defaults: defaults)
        if withHosts { UICatalogFixtures.seed(s) }
        try? s.context.save()
        return s
    }
}

// MARK: - 窗口

/// 画廊专用的窗口。
///
/// - 默认摆在所有屏幕之下：看不见，`cacheDisplay` 照样出图。
/// - 有终端的记录（`live`）摆在屏上但完全透明、不吃鼠标：Ghostty 要显示节拍才出帧。
/// - **自称 key window**：非 key 窗口里 SwiftUI 的点按与焦点样式不生效，而测试宿主不该抢前台。
/// - 鼠标位置谎报在窗外，用户的真光标亮不起 hover。
final class UICatalogWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// 红绿灯按「主窗口」画彩色，不然是灰的。
    override var isMainWindow: Bool { true }
    /// 测试宿主不是前台 App，AppKit 把整个窗口画成「非活跃」外观（红绿灯灰、选中色变淡）。
    /// 截图要的是用户看到的活跃窗口：覆盖 AppKit 判断活跃外观的私有方法（同名选择子即可覆盖）。
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var mouseLocationOutsideOfEventStream: NSPoint { ProbeWindow.mouseBlindOrigin }

    @MainActor
    /// `trafficLights`：整窗记录带上系统红绿灯（真窗口是 closable / miniaturizable / resizable），
    /// 表单、弹层之类不带。
    static func make(size: CGSize, host: NSView, live: Bool, trafficLights: Bool) -> UICatalogWindow {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = live ? NSPoint(x: screen.minX, y: screen.minY) : NSPoint(x: screen.minX, y: -20_000)
        let window = UICatalogWindow(contentRect: NSRect(origin: origin, size: size),
                                     styleMask: trafficLights
                                         ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                                         : [.titled, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        if live {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.level = .floating
        }
        window.setFrameOrigin(origin)
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }
}

// MARK: - 渲染

@MainActor
enum UICatalogRenderer {
    struct Shot {
        let entry: UICatalogEntry
        var files: [String: String] = [:]   // theme → 文件名
        var error: String?
        var millis: Int = 0
    }

    static let themes: [(name: String, appearance: NSAppearance.Name, pref: AppearancePreference)] = [
        ("light", .aqua, .light), ("dark", .darkAqua, .dark),
    ]

    /// 文件名：层级 ID 里的分隔符换成 `__`。
    static func fileStem(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// 渲染一条记录的两个主题。`emit` 收到每张图的文件名与 PNG 数据（落盘 + 挂附件由调用方决定）。
    static func render(_ entry: UICatalogEntry, stage: UICatalogStage,
                       emit: (String, Data) -> Void) async -> Shot {
        var shot = Shot(entry: entry)
        let t0 = Date()
        for theme in themes {
            do {
                // 终端配色、UD 动态色都跟 App 的外观走：两路都设（同 AppAppearanceSync）。
                NSApp.appearance = NSAppearance(named: theme.appearance)
                let render = try await entry.build(stage)
                let size = entry.size
                let host = NSHostingView(rootView: AnyView(
                    render.view
                        .environment(\.colorScheme, theme.name == "dark" ? .dark : .light)
                        .frame(width: size.width, height: size.height)
                ))
                host.appearance = NSAppearance(named: theme.appearance)
                host.frame = NSRect(origin: .zero, size: size)
                let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
                let window = UICatalogWindow.make(size: size, host: host, live: entry.live,
                                                  trafficLights: entry.fullWindow)
                window.appearance = NSAppearance(named: theme.appearance)
                await settle(host, limit: .milliseconds(1500))
                if let after = render.after {
                    await after(host)
                    await settle(host, limit: .milliseconds(1500))
                }
                if entry.live { await waitForTerminalFrames(in: host) }
                try? await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let name = "\(fileStem(entry.id))--\(theme.name).png"
                let overlays = NSApp.windows.filter {
                    $0 !== window && $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0))
                        && !String(describing: type(of: $0)).contains("Probe")
                }
                if let png = snapshot(host, overlays: overlays, windowCorners: entry.fullWindow) {
                    emit(name, png)
                    shot.files[theme.name] = name
                } else {
                    shot.error = "cacheDisplay 没出图"
                }
                for w in overlays { w.orderOut(nil) }
                window.contentView = NSView()
                window.orderOut(nil)
                await render.cleanup?()
            } catch {
                shot.error = "\(error)"
            }
        }
        NSApp.appearance = nil
        shot.millis = Int(Date().timeIntervalSince(t0) * 1000)
        return shot
    }

    /// 等布局与异步加载落地：连续两轮布局后视图树不再变就算稳了，最多等 `limit`。
    static func settle(_ view: NSView, limit: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        var last = -1
        var stable = 0
        while clock.now < deadline {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
            let count = countViews(view)
            stable = count == last ? stable + 1 : 0
            last = count
            if stable >= 3 { return }
        }
    }

    private static func countViews(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + countViews($1) } }

    // MARK: 终端

    static func terminalViews(in root: NSView) -> [GhosttySurfaceView] {
        var out: [GhosttySurfaceView] = []
        func walk(_ v: NSView) {
            if let t = v as? GhosttySurfaceView { out.append(t); return }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil && $0.bounds.width > 4 }
    }

    /// 等每个终端至少出过一帧、且连续两次读到的画面一样（渲染线程出帧要时间）。
    static func waitForTerminalFrames(in host: NSView, timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [Int] = []
        while Date() < deadline {
            for v in terminalViews(in: host) { v.setSurfaceVisible(true) }
            try? await Task.sleep(for: .milliseconds(120))
            let sig = terminalViews(in: host).map { v -> Int in
                guard let s = GhosttyFrameWatch.currentSurface(of: v) else { return 0 }
                return IOSurfaceGetSeed(s).hashValue ^ IOSurfaceGetWidth(s)
            }
            if !sig.isEmpty, !sig.contains(0), sig == last { return }
            last = sig
        }
    }

    private static func surfaceImage(_ view: GhosttySurfaceView) -> CGImage? {
        guard let surface = GhosttyFrameWatch.currentSurface(of: view) else { return nil }
        let image = CIImage(ioSurface: surface)
        return CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(image, from: image.extent)
    }

    // MARK: 出图

    private static func snapshot(_ view: NSView, overlays: [NSWindow], windowCorners: Bool) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        // 离屏的 cacheDisplay 画 CALayer 投影和屏幕上的合成器不一样：模糊约大 1.7 倍、偏移方向反了而且偏小
        // （主按钮的柔光在画廊里比 App 里散得多，对着 App 真窗口量的）。拍的那一下按比例改回去，拍完还原。
        let env = ProcessInfo.processInfo.environment
        let radiusScale = env["UI_GALLERY_SHADOW_RADIUS"].flatMap(Double.init) ?? 0.6
        let offsetScale = env["UI_GALLERY_SHADOW_OFFSET"].flatMap(Double.init) ?? -1.6
        var shadowed: [(CALayer, CGFloat, CGSize)] = []
        func collectShadows(_ l: CALayer) {
            if l.shadowOpacity > 0 { shadowed.append((l, l.shadowRadius, l.shadowOffset)) }
            l.sublayers?.forEach(collectShadows)
        }
        if let layer = view.layer { collectShadows(layer) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, r, o) in shadowed {
            l.shadowRadius = r * radiusScale
            l.shadowOffset = CGSize(width: o.width * offsetScale, height: o.height * offsetScale)
        }
        CATransaction.commit()
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (l, r, o) in shadowed { l.shadowRadius = r; l.shadowOffset = o }
            CATransaction.commit()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let terminals = terminalViews(in: view)
        // 红绿灯不在宿主视图里（在窗口的标题栏视图上），单独拍了贴到同一位置。
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let lights: [NSButton] = buttonTypes.compactMap {
            guard let b = view.window?.standardWindowButton($0), !b.isHidden else { return nil }
            return b
        }
        var out = rep
        if (!overlays.isEmpty || !terminals.isEmpty || !lights.isEmpty),
           let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            canvas.size = view.bounds.size
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: canvas)
            NSGraphicsContext.current = ctx
            rep.draw(in: view.bounds)
            // Ghostty 的画面：surface 那一帧按视图在宿主里的位置贴回去。
            for t in terminals {
                guard let image = surfaceImage(t) else { continue }
                var rect = t.convert(t.bounds, to: view)
                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                ctx?.cgContext.saveGState()
                ctx?.cgContext.clip(to: rect)
                // surface 的像素尺寸可能比视图大一点（按整格取整）：左上对齐、按 backing scale 缩放。
                let scale = t.window?.backingScaleFactor ?? 2
                let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
                ctx?.cgContext.draw(image, in: CGRect(x: rect.minX, y: rect.maxY - h, width: w, height: h))
                ctx?.cgContext.restoreGState()
            }
            for b in lights {
                guard let r = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { continue }
                b.cacheDisplay(in: b.bounds, to: r)
                var rect = b.convert(b.bounds, to: view)
                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                r.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            if let window = view.window {
                let origin = window.convertToScreen(view.convert(view.bounds, to: nil)).origin
                for w in overlays {
                    guard let v = w.contentView?.superview ?? w.contentView,
                          let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: r)
                    let rect = NSRect(x: w.frame.minX - origin.x, y: w.frame.minY - origin.y,
                                      width: v.bounds.width, height: v.bounds.height)
                    r.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            out = canvas
        }
        if windowCorners, let rounded = roundedWindowCorners(out, size: view.bounds.size) { out = rounded }
        return out.representation(using: .png, properties: [:])
    }

    /// 整窗截图裁成系统窗口的 16pt 圆角，外面透明。
    private static func roundedWindowCorners(_ rep: NSBitmapImageRep, size: CGSize) -> NSBitmapImageRep? {
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 16, yRadius: 16).addClip()
        rep.draw(in: NSRect(origin: .zero, size: size))
        // 窗口边缘那一圈 0.5pt 细线（系统给窗口画的：浅色是淡黑、深色是淡白），截图里要有，摆到别处才像一个窗口。
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let edge = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25),
                                xRadius: 15.75, yRadius: 15.75)
        edge.lineWidth = 0.5
        (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)).setStroke()
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    // MARK: 清单

    static func manifest(_ shots: [Shot]) throws -> Data {
        let entries: [[String: Any]] = shots.map { s in
            var d: [String: Any] = [
                "id": s.entry.id, "kind": s.entry.kind.rawValue,
                "source": s.entry.source, "symbol": s.entry.symbol,
                "width": s.entry.size.width, "height": s.entry.size.height,
                "images": s.files, "millis": s.millis,
            ]
            if let note = s.entry.note { d["note"] = note }
            if let e = s.error { d["error"] = e }
            return d
        }
        let root: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "app": "uTerm",
            "entries": entries,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
