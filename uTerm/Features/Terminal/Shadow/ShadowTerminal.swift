// 影子终端只在链了 libghostty-vt 的 target 里编（本地包 `vendor/libghostty-spm-local` 的 `GhosttyVt` product）。
// 还没链它的 target（这条评估分支上的 Mac App）里整份文件是空的；Mac 接上 Ghostty、依赖了那个 product 之后自动编进来。
#if canImport(GhosttyVt)
import Foundation
import GhosttyVt

// 影子终端：libghostty-vt 的一个终端实例，和画面（GhosttyKit surface）吃同一份字节，同步解析、不经 ghostty 的 app mailbox。
// 两端共享（迁移计划 docs/ghostty-migration-plan.md §2）：凡是要「读终端内部状态」的功能都找它——快照（远控镜像、holder
// 检查点、surface 补齐 / 回前台回放）、读屏、光标与备用屏；OSC / 未知序列回调、kitty 键盘标志、整段回滚读文本是下一步
// 往这个类型上加的（见类型末尾的「扩展位」）。只依赖 Foundation 与 GhosttyVt，不碰 UIKit / AppKit / GhosttyKit。
//
// vt 的 C API 是 Ghostty `042b16b6` 时的版本（1.0 之前）：选项一次性传结构体、没有读画笔的接口，不能照官方 vt-1.0.0 的
// 文档写。头文件在 `build/ghostty-vt/ghostty-vt.xcframework/*/Headers/ghostty/vt/`。vt 必须和 GhosttyKit 是同一棵打过补丁的
// 源码树编的，影子和画面才一致（M4：576 个检查点 0 差异；前提是下面三条：默认开 mode 2027、resize 跟着 surface 的终端自己
// 报的尺寸、回滚上限两边设成同一个值）。

/// 一个影子终端。
///
/// **线程模型**：类型是 `nonisolated` + `@unchecked Sendable`，内部一把锁，所有方法在任何线程上都能调，彼此串行。
/// - `feed` 同步解析：返回时这批字节已经落进终端状态。谁喂都行，但**同一条字节流要由一个调用方按顺序喂**
///  （入站任务 / 输出泵）；锁只保证不撕裂，不替你排序。
/// - 读（`cursor`、`viewportText()`、`snapshot()`……）读到的是「已经喂完的那些字节」之后的状态，可以在主线程上读；
///   正在 `feed` 一大块时读的一方会等它喂完（解析约 500 MB/s，64 KiB 一片就是 0.1 ms 量级）。要喂大块又不想挡读的一方，
///   调用方自己切片。
/// - 回调（应答、以后的 OSC 回调）是在 `feed` 里、拿着锁同步调用的，发生在喂字节的那条线程上：回调里**不要再调本终端的
///   任何方法**（会死锁），要做事就把数据带走、换个地方做。
/// - `replay(fromSnapshot:)` 是静态的、只吃快照，不占任何影子的锁。
nonisolated final class ShadowTerminal: @unchecked Sendable {
    /// 建终端时定下、之后不变的配置。回滚的两个上限没有默认值，调用方必须写出来。
    nonisolated struct Options: Sendable {
        /// 回滚行数上限；nil = 只按字节限。按页裁，实际留下的行数会比它多或少几十到上百行。
        var scrollbackLines: Int?
        /// 回滚字节上限。必须显式给：vt 自己的默认值很小，只设行数时 1 万行只剩约 1 千行（M3 实测）。
        /// 要和 surface 的 `scrollback-limit-bytes` / `-lines` 设成同一个值，否则回放进 surface 的历史长度和它自己攒的不同。
        var scrollbackBytes: Int
        /// 半个转义序列 / 半个 UTF-8 字符最多记多少字节（快照要带上它，回放才能从任意字节处接上）。
        var continuationBytes = 1 << 20
        /// surface 的终端默认开 mode 2027（字素簇）、vt 默认关；不对齐的话 ZWJ / 国旗 / 肤色字符宽度不同，整行错位（M4）。
        var graphemeClusters = true
        /// 光标闪烁（mode 12）的初值，跟 surface 的配置走。只能设当前值，设不了 reset 默认值。
        var cursorBlink = true
        /// XTVERSION 的应答（`CSI > q`）。空 = vt 的默认「libghostty」。surface 答的是「ghostty <版本>」。
        var versionReport = ""

        init(scrollbackLines: Int?, scrollbackBytes: Int) {
            self.scrollbackLines = scrollbackLines
            self.scrollbackBytes = scrollbackBytes
        }
    }

    /// 光标：位置是活动区里的格子坐标（左上角 0,0）。
    nonisolated struct Cursor: Sendable, Equatable {
        var x: Int
        var y: Int
        /// 写满一行、下一个字符才折行的那个悬着的状态。
        var pendingWrap: Bool
        /// DECTCEM（`CSI ? 25 h/l`）。
        var visible: Bool
    }

    /// 快照 / 回放失败的原因（只用于日志与测试断言）。
    nonisolated enum SnapshotError: Error {
        case encode(Int32)
        case decode(Int32)
        case format(Int32)
    }

    private let lock = NSLock()
    private let handle: OpaquePointer
    private let options: Options
    private var cellWidth: UInt32 = 0
    private var cellHeight: UInt32 = 0
    /// 查询应答的出口（DA / DSR / 光标位置 / 颜色查询 / kitty 键盘查询……）。在 `feed` 里同步调用，别回调进本终端。
    private var replyHandler: (@Sendable (Data) -> Void)?
    /// 前台由 surface 应答，影子闭嘴；后台 surface 不吃字节，换影子答。
    private var repliesEnabled = false
    /// `CSI ? 996 n` 的应答；nil = 不答。
    private var darkAppearance: Bool?
    private let versionReportBytes: [UInt8]
    /// 累计喂进来的字节数。
    private var fedBytes = 0

    /// 建一个 `cols` × `rows` 的终端。mode 2027（字素簇）默认开，见 `Options.graphemeClusters`。
    init(cols: UInt16, rows: UInt16, options: Options) {
        var term: OpaquePointer?
        let result = ghostty_terminal_new(nil, &term, max(1, cols), max(1, rows))
        precondition(result == GHOSTTY_SUCCESS && term != nil, "ghostty_terminal_new 失败 \(result.rawValue)")
        handle = term!
        self.options = options
        versionReportBytes = Array(options.versionReport.utf8)
        Self.applyLimits(to: handle, options: options)
        if options.graphemeClusters {
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &mode)
        }
        var blink = GhosttyTerminalModeConfig(mode: ghostty_mode_new(12, false), value: options.cursorBlink)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE, &blink)
        installEffects()
    }

    deinit { ghostty_terminal_free(handle) }

    private static func applyLimits(to handle: OpaquePointer, options: Options) {
        var bytes = options.scrollbackBytes
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        if var lines = options.scrollbackLines {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        }
        var continuation = options.continuationBytes
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation)
    }

    // MARK: 喂字节、尺寸

    /// 同步解析一批字节。
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        fedBytes += data.count
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(handle, base, raw.count)
        }
    }

    /// 跟着 surface 的终端 resize（挂在 `InMemoryTerminalSession` 的 resize 回调上，M4 的前提：不按视图尺寸算）。
    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        guard cols > 0, rows > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if cellWidth > 0 { self.cellWidth = cellWidth }
        if cellHeight > 0 { self.cellHeight = cellHeight }
        var size = (cols: UInt16(0), rows: UInt16(0))
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &size.cols)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &size.rows)
        guard size.cols != cols || size.rows != rows else { return }
        _ = ghostty_terminal_resize(handle, cols, rows, self.cellWidth, self.cellHeight)
    }

    var size: (cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (Int(Self.cols(handle)), Int(Self.rows(handle)))
    }

    var totalFedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return fedBytes
    }

    /// 活动屏的总行数（含回滚）。
    var totalRows: Int {
        lock.lock()
        defer { lock.unlock() }
        var rows = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &rows)
        return rows
    }

    /// 两个屏的页常驻字节（不含 Kitty 图片）。
    var residentBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        var usage = GhosttyTerminalMemoryUsage()
        usage.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage) == GHOSTTY_SUCCESS else { return 0 }
        return usage.primary_resident_bytes + usage.alternate_resident_bytes
    }

    var title: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.string(handle, GHOSTTY_TERMINAL_DATA_TITLE)
    }

    var isOnAlternateScreen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isAlternate(handle)
    }

    /// 光标位置与状态。
    var cursor: Cursor {
        lock.lock()
        defer { lock.unlock() }
        let at = Self.cursor(handle)
        var pending = false, visible = true
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        return Cursor(x: Int(at.x), y: Int(at.y), pendingWrap: pending, visible: visible)
    }

    /// 视口文字：一行一段、行尾空白去掉，和 `InMemoryTerminalSession.readViewportText()` 同一种读法（每行单独一个选区，
    /// 软折行不并行）。
    func viewportText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.viewportLines(handle).joined(separator: "\n")
    }

    // MARK: 应答

    /// 查询应答从这里出去。`enabled` 为 false 时影子不答（前台由 surface 答，两边都答远端会收到两份）。
    func setReplyHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock()
        replyHandler = handler
        lock.unlock()
    }

    func setRepliesEnabled(_ enabled: Bool) {
        lock.lock()
        repliesEnabled = enabled
        lock.unlock()
    }

    /// 后台替 surface 答颜色查询（OSC 10 / 11 / 12、`CSI ? 996 n`）要知道当前配色。只设默认值，不算程序改过的颜色，
    /// 所以不会被带进回放流。
    func setDefaultColors(foreground: (UInt8, UInt8, UInt8), background: (UInt8, UInt8, UInt8),
                          cursor: (UInt8, UInt8, UInt8)?, dark: Bool) {
        lock.lock()
        defer { lock.unlock() }
        darkAppearance = dark
        var fg = GhosttyColorRgb(r: foreground.0, g: foreground.1, b: foreground.2)
        var bg = GhosttyColorRgb(r: background.0, g: background.1, b: background.2)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if let cursor {
            var color = GhosttyColorRgb(r: cursor.0, g: cursor.1, b: cursor.2)
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &color)
        }
    }

    private func installEffects() {
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, bytes, count in
            guard let userdata, let bytes, count > 0 else { return }
            let shadow = Unmanaged<ShadowTerminal>.fromOpaque(userdata).takeUnretainedValue()
            // 在 `feed` 里同步回调，锁已经在手上。
            guard shadow.repliesEnabled, let handler = shadow.replyHandler else { return }
            handler(Data(bytes: bytes, count: count))
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))

        // 和 surface（termio/stream_handler.zig）答的一样：VT220、彩色、剪贴板；DA2 `>1;10;0c`。
        let deviceAttributes: GhosttyTerminalDeviceAttributesFn = { _, _, out in
            guard let out else { return false }
            out.pointee.primary.conformance_level = 62
            withUnsafeMutableBytes(of: &out.pointee.primary.features) { raw in
                let features = raw.bindMemory(to: UInt16.self)
                features[0] = 22
                features[1] = 52
            }
            out.pointee.primary.num_features = 2
            out.pointee.secondary.device_type = 1
            out.pointee.secondary.firmware_version = 10
            out.pointee.secondary.rom_cartridge = 0
            out.pointee.tertiary.unit_id = 0
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                             unsafeBitCast(deviceAttributes, to: UnsafeRawPointer.self))

        let sizeReport: GhosttyTerminalSizeFn = { terminal, userdata, out in
            guard let terminal, let userdata, let out else { return false }
            let shadow = Unmanaged<ShadowTerminal>.fromOpaque(userdata).takeUnretainedValue()
            out.pointee.columns = ShadowTerminal.cols(terminal)
            out.pointee.rows = ShadowTerminal.rows(terminal)
            out.pointee.cell_width = shadow.cellWidth
            out.pointee.cell_height = shadow.cellHeight
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(sizeReport, to: UnsafeRawPointer.self))

        let colorScheme: GhosttyTerminalColorSchemeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let shadow = Unmanaged<ShadowTerminal>.fromOpaque(userdata).takeUnretainedValue()
            guard let dark = shadow.darkAppearance else { return false }
            out.pointee = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self))

        if !versionReportBytes.isEmpty {
            let version: GhosttyTerminalXtversionFn = { _, userdata in
                guard let userdata else { return GhosttyString(ptr: nil, len: 0) }
                let shadow = Unmanaged<ShadowTerminal>.fromOpaque(userdata).takeUnretainedValue()
                // 数组存在 let 属性里，终端活着它就在；回调返回前指针有效。
                return shadow.versionReportBytes.withUnsafeBufferPointer { GhosttyString(ptr: $0.baseAddress, len: $0.count) }
            }
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(version, to: UnsafeRawPointer.self))
        }
    }

    // MARK: 快照

    /// 二进制快照（`ghostty_snapshot_encode`）：两端同版本才能解；带回滚、两个屏、模式、没走完的半个序列。
    /// 17,430 行历史约 5 MB、编码约 1.5 ms（M5）。
    func snapshot() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try Self.encode(handle)
    }

    private static func encode(_ handle: OpaquePointer) throws -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let result = ghostty_snapshot_encode_alloc(handle, nil, &pointer, &length)
        guard result == GHOSTTY_SUCCESS, let pointer else { throw SnapshotError.encode(result.rawValue) }
        defer { ghostty_free(nil, pointer, length) }
        return Data(bytes: pointer, count: length)
    }

    /// 从二进制快照还原出一个新的影子终端（上限、默认模式按 `options` 重新设：它们是终端选项，不在快照里）。
    convenience init(snapshot: Data, options: Options) throws {
        let restored = try Self.decode(snapshot, continuationBytes: options.continuationBytes)
        self.init(adopting: restored, options: options)
    }

    private init(adopting handle: OpaquePointer, options: Options) {
        self.handle = handle
        self.options = options
        versionReportBytes = Array(options.versionReport.utf8)
        Self.applyLimits(to: handle, options: options)
        installEffects()
    }

    // MARK: 扩展位（下一步往这里加，别另起一个类型）
    //
    // - OSC / 未知序列回调（7501 程序状态、133 提示符、6973 起止行、9 / 777 通知）：vt 的入口是
    //   `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS` / `_SEMANTIC_PROMPT` / `_UNKNOWN_SEQUENCE`（要同时设 `_UNKNOWN_MAX_BYTES`）/
    //   `_DESKTOP_NOTIFICATION`，照 `installEffects()` 里的写法装：C 回调里用 userdata 取回 `self`，把参数拷成 Swift 值，
    //   交给一个 `@Sendable` 的处理闭包。回调在 `feed` 里拿着锁同步来，见类型注释的线程模型。
    // - kitty 键盘协议标志：`GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS`，加一个和 `cursor` 一样的只读属性。
    // - 整段回滚读文本：`viewportLines` 的做法换成整屏选区（`GHOSTTY_POINT_TAG_SCREEN`），或者 formatter 不带选区直接出 PLAIN。
    // - 从快照还原出来的终端（`init(snapshot:options:)`）不带应答 / 回调的处理闭包与默认颜色：它们是宿主的状态，不在快照里，
    //   还原后重新装。

    /// 解码要显式开「保留续接字节」：这个版本默认不留，停在半个序列里的终端解出来之后再拍快照会失败（M5）。
    private static func decode(_ snapshot: Data, continuationBytes: Int) throws -> OpaquePointer {
        try snapshot.withUnsafeBytes { raw -> OpaquePointer in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw SnapshotError.decode(-2) }
            var decoder: OpaquePointer?
            var result = ghostty_snapshot_decoder_new_buf(nil, &decoder, base, raw.count)
            guard result == GHOSTTY_SUCCESS, let decoder else { throw SnapshotError.decode(result.rawValue) }
            defer { ghostty_snapshot_decoder_free(decoder) }
            var limit = continuationBytes
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit)
            var retain = true
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain)
            var terminal: OpaquePointer?
            result = ghostty_snapshot_decoder_decode(decoder, &terminal)
            guard result == GHOSTTY_SUCCESS, let terminal else { throw SnapshotError.decode(result.rawValue) }
            return terminal
        }
    }

    // MARK: 快照 → 回放流

    /// 把二进制快照变成一段 VT 字节：灌进一个**刚复位**的终端（surface 吃不了二进制快照，只能吃 VT），那个终端就到了
    /// 拍快照时的状态，之后接着喂实时字节即可。开头自带复位（CAN + RIS + 清动态颜色），所以直接灌进用过的 surface 也行。
    ///
    /// 做法是 `Spikes/GhosttyVT/vtsnap.c`（在构建分支 `worktree-agent-a6bb31349ee21df46` 上）的「vt+」，M5 在 33,243 个
    /// 切点上核过（3 个不一致；真实语料灌进 surface 320/320 一致）：
    /// formatter 出 VT（软折行并回一行、全部附加状态）+ formatter 给不出的几样（标题、动态颜色、DECSC 存的光标、
    /// 备用屏底下的主屏）+ 没走完的半个序列。和 vtsnap 有两处不同，都是因为这里的接收端是带配色的 surface：
    /// - 调色板不整份发（formatter 的 `palette` 会把 256 色全用 OSC 4 写死，surface 的配色就被影子的默认调色板盖掉了），
    ///   只发程序改过的那几项；
    /// - OSC 10 / 11 / 12 只在程序改过时发（影子的默认前景 / 背景是为了答查询设的，发过去会变成 surface 上的「程序设的颜色」，
    ///   之后切深浅色不再跟着变）。
    ///
    /// 发出去之前先自查（vtsnap 的「vt*」）：把生成的流灌进一个临时终端，和源终端比视口文字、总行数、光标、在不在备用屏。
    /// 对不上就换成「不并软折行」的那一版（每行原样一行，位置不会错，代价是软折行标记丢了、之后改宽度这些行不再连着重排）。
    /// 已知会走到后备的情形：软折行的续行被擦空（formatter 并行时不会把空的续行真正建出来，接收端少一行、整屏错一行；
    /// 上游问题，见构建分支 `docs/ghostty-eval/vt-snapshot-and-build.md` 1.3）。shell 里敲了一条折行的长命令再删回去就是这样。
    ///
    /// 两个入口：`makeReplay()` 从活的影子直接出（回前台用，省一次整份解码）；`replay(fromSnapshot:)` 只吃快照
    ///（快照是别处来的：远控、检查点；也不占活的影子的锁）。两者生成的流相同。
    static func replayStream(fromSnapshot snapshot: Data, continuationBytes: Int = 1 << 20,
                             graphemeClusters: Bool = true) throws -> Data {
        try replay(fromSnapshot: snapshot, continuationBytes: continuationBytes, graphemeClusters: graphemeClusters).stream
    }

    /// 回放流连同它是怎么生成的。
    nonisolated struct Replay: Sendable {
        var stream: Data
        /// 软折行并回了一行（首选的那一版）。false = 自查没过，用了逐行的后备版。
        var unwrapped: Bool
        /// 最终发出去的这一版自查过了没有。
        var verified: Bool
        /// 中间那张二进制快照的字节数。
        var snapshotBytes: Int
        /// 各步用时（秒）：拍快照（只有 `makeReplay` 计）、生成流、自查。
        var encodeSeconds = 0.0
        var buildSeconds = 0.0
        var verifySeconds = 0.0
    }

    static func replay(fromSnapshot snapshot: Data, continuationBytes: Int = 1 << 20,
                       graphemeClusters: Bool = true) throws -> Replay {
        let source = try decode(snapshot, continuationBytes: continuationBytes)
        defer { ghostty_terminal_free(source) }
        return try replay(of: source, snapshot: snapshot, continuationBytes: continuationBytes, graphemeClusters: graphemeClusters)
    }

    /// 拍一张快照并从活的终端直接出回放流。全程拿着影子的锁（这段时间喂不进字节），所以流和「此刻」严格对应。
    /// 快照只给两个克隆用：读 DECSC 存的光标（只解到 READY，不带回滚，便宜），以及在备用屏上时还原主屏（整份解码）。
    func makeReplay() throws -> Replay {
        lock.lock()
        defer { lock.unlock() }
        let started = Self.now()
        let snapshot = try Self.encode(handle)
        let encoded = Self.now()
        var replay = try Self.replay(of: handle, snapshot: snapshot, continuationBytes: options.continuationBytes,
                                     graphemeClusters: options.graphemeClusters)
        replay.encodeSeconds = encoded - started
        return replay
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// `source` 是拍 `snapshot` 时的那个终端（或它的整份还原），只读它、不改它。
    private static func replay(of source: OpaquePointer, snapshot: Data, continuationBytes: Int,
                               graphemeClusters: Bool) throws -> Replay {
        let started = now()
        let preferred = try buildReplay(source, snapshot: snapshot, continuationBytes: continuationBytes, unwrap: true)
        let built = now()
        if reproduces(preferred, source, graphemeClusters: graphemeClusters) {
            return Replay(stream: preferred, unwrapped: true, verified: true, snapshotBytes: snapshot.count,
                          buildSeconds: built - started, verifySeconds: now() - built)
        }
        let fallback = try buildReplay(source, snapshot: snapshot, continuationBytes: continuationBytes, unwrap: false)
        let verified = reproduces(fallback, source, graphemeClusters: graphemeClusters)
        return Replay(stream: fallback, unwrapped: false, verified: verified, snapshotBytes: snapshot.count,
                      buildSeconds: built - started, verifySeconds: now() - built)
    }

    /// 只解到快照的 READY 标记：模式、光标、存的光标、当前屏都在，回滚不解（探针用完就扔，省掉整份历史）。
    private static func withReadyClone<T>(_ snapshot: Data, continuationBytes: Int,
                                          _ body: (OpaquePointer) throws -> T) throws -> T {
        try snapshot.withUnsafeBytes { raw -> T in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw SnapshotError.decode(-2) }
            var decoder: OpaquePointer?
            var result = ghostty_snapshot_decoder_new_buf(nil, &decoder, base, raw.count)
            guard result == GHOSTTY_SUCCESS, let decoder else { throw SnapshotError.decode(result.rawValue) }
            var limit = continuationBytes
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit)
            var retain = true
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain)
            var terminal: OpaquePointer?
            result = ghostty_snapshot_decoder_ready(decoder, &terminal)
            guard result == GHOSTTY_SUCCESS, let terminal else {
                ghostty_snapshot_decoder_free(decoder)
                throw SnapshotError.decode(result.rawValue)
            }
            // 解码器借着这个终端，先放解码器再放终端。
            defer {
                ghostty_snapshot_decoder_free(decoder)
                ghostty_terminal_free(terminal)
            }
            return try body(terminal)
        }
    }

    /// 把回放流灌进一个和接收端同样默认值的临时终端，看它是不是到了源终端的样子。回滚不设上限：这里核的是流本身，
    /// 接收端自己的上限裁掉多少历史是另一回事。
    private static func reproduces(_ stream: Data, _ source: OpaquePointer, graphemeClusters: Bool) -> Bool {
        var term: OpaquePointer?
        guard ghostty_terminal_new(nil, &term, cols(source), rows(source)) == GHOSTTY_SUCCESS, let scratch = term else { return false }
        defer { ghostty_terminal_free(scratch) }
        ghostty_terminal_set(scratch, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)   // NULL = 不限
        if graphemeClusters {
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
            ghostty_terminal_set(scratch, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &mode)
        }
        stream.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(scratch, base, raw.count)
        }
        var wantRows = 0, gotRows = 0
        ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &wantRows)
        ghostty_terminal_get(scratch, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &gotRows)
        guard wantRows == gotRows, isAlternate(source) == isAlternate(scratch) else { return false }
        let want = cursor(source), got = cursor(scratch)
        guard want.x == got.x, want.y == got.y else { return false }
        return viewportLines(source) == viewportLines(scratch)
    }

    private static func buildReplay(_ source: OpaquePointer, snapshot: Data, continuationBytes: Int, unwrap: Bool) throws -> Data {
        var out = Data()
        out.reserveCapacity(snapshot.count / 2 + 4096)
        // CAN 结束接收端手上没走完的序列，RIS 清屏、清回滚、模式回默认；OSC 110–112 清掉程序设过的前景 / 背景 / 光标色
        //（RIS 只复位调色板）。
        out.append(contentsOf: Array("\u{18}\u{1B}c\u{1B}]110\u{07}\u{1B}]111\u{07}\u{1B}]112\u{07}".utf8))

        let title = string(source, GHOSTTY_TERMINAL_DATA_TITLE)
        if !title.isEmpty {
            out.append(contentsOf: Array("\u{1B}]2;".utf8))
            out.append(contentsOf: Array(title.utf8))
            out.append(0x07)
        }
        appendColorOverride(&out, source, effective: GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
                            fallback: GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT, osc: 10)
        appendColorOverride(&out, source, effective: GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
                            fallback: GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT, osc: 11)
        appendColorOverride(&out, source, effective: GHOSTTY_TERMINAL_DATA_COLOR_CURSOR,
                            fallback: GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT, osc: 12)
        appendPaletteOverrides(&out, source)

        // DECSC 存的光标：没有读它的接口，让一个克隆 DECRC 一下，看光标和画笔落在哪，再在接收端 DECSC 回去。
        // 后面 formatter 的输出会把光标挪回真正的位置。（存的字符集 / origin 模式这条路拿不回来。）
        try withReadyClone(snapshot, continuationBytes: continuationBytes) { probe in
            write(probe, "\u{18}\u{1B}8")
            let saved = cursor(probe)
            // 读画笔：关插入模式、回左上角打一个字，读那一格的样式（1.0 之前的 API 没有画笔的 getter）。这些都不动画笔。
            write(probe, "\u{1B}[4l\u{1B}[1;1H")
            let at = cursor(probe)
            write(probe, "X")
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            ghostty_style_default(&style)
            var protected = false
            if var ref = gridRef(probe, x: at.x, y: UInt32(at.y)) {
                ghostty_grid_ref_style(&ref, &style)
                var cell = GhosttyCell()
                if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS {
                    ghostty_cell_get(cell, GHOSTTY_CELL_DATA_PROTECTED, &protected)
                }
            }
            out.append(contentsOf: Array("\u{1B}[\(saved.y + 1);\(saved.x + 1)H".utf8))
            appendSGR(&out, style)
            if protected { out.append(contentsOf: Array("\u{1B}[1\"q".utf8)) }
            out.append(contentsOf: Array("\u{1B}7\u{1B}[0m\u{1B}[H".utf8))
        }

        // 在备用屏上时 formatter 只看得到备用屏：先让一个克隆像程序退出时那样离开备用屏，把主屏（含回滚）发过去，再进备用屏。
        if isAlternate(source) {
            let (leave, enter): (String, String)
            if modeOn(source, 1049) { (leave, enter) = ("\u{1B}[?1049l", "\u{1B}[?1049h") }
            else if modeOn(source, 1047) { (leave, enter) = ("\u{1B}[?1047l", "\u{1B}[?1047h") }
            else { (leave, enter) = ("\u{1B}[?47l", "\u{1B}[?47h") }
            let primary = try decode(snapshot, continuationBytes: continuationBytes)
            defer { ghostty_terminal_free(primary) }
            write(primary, "\u{18}")
            write(primary, leave)
            let at = cursor(primary)
            try appendFormatted(&out, primary, unwrap: unwrap)
            // 滚动区域不分屏：主屏那段刚设过，备用屏那段要先写行再设，这里先清掉（DECSTBM 会把光标送回左上角，
            // 所以在 1049 存光标之前把主屏的光标放回去）。
            out.append(contentsOf: Array("\u{1B}[r\u{1B}[\(at.y + 1);\(at.x + 1)H".utf8))
            out.append(contentsOf: Array(enter.utf8))
        }
        try appendFormatted(&out, source, unwrap: unwrap)

        // 源终端解析到一半的那个序列 / 半个 UTF-8 字符。
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        if ghostty_terminal_continuation_alloc(source, nil, &pointer, &length) == GHOSTTY_SUCCESS, let pointer, length > 0 {
            out.append(pointer, count: length)
            ghostty_free(nil, pointer, length)
        }
        return out
    }

    /// formatter 的 VT 输出：活动屏（含回滚）、不去行尾空白、除调色板外的全部附加状态。`unwrap`：软折行并回一行。
    private static func appendFormatted(_ out: inout Data, _ terminal: OpaquePointer, unwrap: Bool) throws {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_VT
        options.unwrap = unwrap
        options.trim = false
        options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        options.extra.palette = false
        options.extra.modes = true
        options.extra.scrolling_region = true
        options.extra.tabstops = true
        options.extra.pwd = true
        options.extra.keyboard = true
        options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        options.extra.screen.cursor = true
        options.extra.screen.style = true
        options.extra.screen.hyperlink = true
        options.extra.screen.protection = true
        options.extra.screen.kitty_keyboard = true
        options.extra.screen.charsets = true
        options.selection = nil
        var formatter: OpaquePointer?
        var result = ghostty_formatter_terminal_new(nil, &formatter, terminal, options)
        guard result == GHOSTTY_SUCCESS, let formatter else { throw SnapshotError.format(result.rawValue) }
        defer { ghostty_formatter_free(formatter) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        result = ghostty_formatter_format_alloc(formatter, nil, &pointer, &length)
        guard result == GHOSTTY_SUCCESS else { throw SnapshotError.format(result.rawValue) }
        if let pointer, length > 0 {
            out.append(pointer, count: length)
            ghostty_free(nil, pointer, length)
        }
    }

    private static func appendColorOverride(_ out: inout Data, _ terminal: OpaquePointer,
                                            effective: GhosttyTerminalData, fallback: GhosttyTerminalData, osc: Int) {
        var color = GhosttyColorRgb()
        guard ghostty_terminal_get(terminal, effective, &color) == GHOSTTY_SUCCESS else { return }
        var base = GhosttyColorRgb()
        if ghostty_terminal_get(terminal, fallback, &base) == GHOSTTY_SUCCESS,
           base.r == color.r, base.g == color.g, base.b == color.b { return }
        out.append(contentsOf: Array(String(format: "\u{1B}]%d;rgb:%02x/%02x/%02x\u{07}", osc, color.r, color.g, color.b).utf8))
    }

    private static func appendPaletteOverrides(_ out: inout Data, _ terminal: OpaquePointer) {
        var current = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        var base = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &current) == GHOSTTY_SUCCESS,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &base) == GHOSTTY_SUCCESS else { return }
        for index in 0..<256 where current[index].r != base[index].r || current[index].g != base[index].g
            || current[index].b != base[index].b {
            let color = current[index]
            out.append(contentsOf: Array(String(format: "\u{1B}]4;%d;rgb:%02x/%02x/%02x\u{07}", index, color.r, color.g, color.b).utf8))
        }
    }

    /// 能重建一个 `GhosttyStyle` 的 SGR（给 DECSC 存的画笔用）。
    private static func appendSGR(_ out: inout Data, _ style: GhosttyStyle) {
        var text = "\u{1B}[0"
        let flags: [(Bool, Int)] = [(style.bold, 1), (style.italic, 3), (style.faint, 2), (style.blink, 5),
                                    (style.inverse, 7), (style.invisible, 8), (style.strikethrough, 9), (style.overline, 53)]
        for (on, code) in flags where on { text += ";\(code)" }
        if style.underline != 0 { text += ";4:\(style.underline)" }
        func color(_ base: Int, _ value: GhosttyStyleColor) {
            if value.tag == GHOSTTY_STYLE_COLOR_PALETTE {
                text += ";\(base):5:\(value.value.palette)"
            } else if value.tag == GHOSTTY_STYLE_COLOR_RGB {
                text += ";\(base):2::\(value.value.rgb.r):\(value.value.rgb.g):\(value.value.rgb.b)"
            }
        }
        color(38, style.fg_color)
        color(48, style.bg_color)
        color(58, style.underline_color)
        text += "m"
        out.append(contentsOf: Array(text.utf8))
    }

    // MARK: 读终端的小工具（调用方持锁，或终端是自己独占的克隆）

    private static func write(_ terminal: OpaquePointer, _ text: String) {
        let bytes = Array(text.utf8)
        ghostty_terminal_vt_write(terminal, bytes, bytes.count)
    }

    private static func cols(_ terminal: OpaquePointer) -> UInt16 {
        var value: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &value)
        return value
    }

    private static func rows(_ terminal: OpaquePointer) -> UInt16 {
        var value: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &value)
        return value
    }

    private static func cursor(_ terminal: OpaquePointer) -> (x: UInt16, y: UInt16) {
        var x: UInt16 = 0, y: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return (x, y)
    }

    private static func isAlternate(_ terminal: OpaquePointer) -> Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    private static func modeOn(_ terminal: OpaquePointer, _ value: UInt16) -> Bool {
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, false), value: false)
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS && mode.value
    }

    private static func string(_ terminal: OpaquePointer, _ key: GhosttyTerminalData) -> String {
        var value = GhosttyString(ptr: nil, len: 0)
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS, let pointer = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: value.len), as: UTF8.self)
    }

    private static func gridRef(_ terminal: OpaquePointer, x: UInt16, y: UInt32) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: x, y: y)
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    private static func viewportLines(_ terminal: OpaquePointer) -> [String] {
        let cols = cols(terminal), rows = rows(terminal)
        guard cols > 0 else { return [] }
        var lines: [String] = []
        lines.reserveCapacity(Int(rows))
        for y in 0..<UInt32(rows) {
            guard let start = gridRef(terminal, x: 0, y: y), let end = gridRef(terminal, x: cols - 1, y: y) else {
                lines.append("")
                continue
            }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = start
            selection.end = end
            selection.rectangle = false
            let line: String = withUnsafePointer(to: &selection) { selectionPointer in
                var options = GhosttyFormatterTerminalOptions()
                options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
                options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
                options.unwrap = false
                options.trim = true
                options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
                options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
                options.selection = selectionPointer
                var formatter: OpaquePointer?
                guard ghostty_formatter_terminal_new(nil, &formatter, terminal, options) == GHOSTTY_SUCCESS,
                      let formatter else { return "" }
                defer { ghostty_formatter_free(formatter) }
                var pointer: UnsafeMutablePointer<UInt8>?
                var length = 0
                guard ghostty_formatter_format_alloc(formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS,
                      let pointer, length > 0 else { return "" }
                defer { ghostty_free(nil, pointer, length) }
                return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
            }
            lines.append(Self.trimmingTrailingWhitespace(line))
        }
        return lines
    }

    static func trimmingTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let before = line.index(before: end)
            guard line[before] == " " || line[before] == "\n" || line[before] == "\r" else { break }
            end = before
        }
        return String(line[..<end])
    }
}
#endif
