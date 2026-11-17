import Foundation
import GhosttyTerminal
import Observation

/// 终端回滚区的查找（两端共用）：查找栏的状态，以及它和引擎之间的往来。
///
/// 查找本身归 GhosttyKit：匹配在 surface 的搜索线程上跑（输出变了它自己重找），高亮由 surface 画。这里只做三件事：
/// - 把查找栏上的操作变成 surface 的绑定动作：`search:<关键词>`（空串 = 停）、`navigate_search:next` / `:previous`、
///   `end_search`；
/// - 收引擎报回来的事件（`TerminalSearchEvent`：要开查找栏、共几处、选中第几处）；
/// - surface 换了一个（iOS 藏久了放掉再重建、Mac 切走的标签放掉再切回）时把关键词重发一遍——旧 surface 的查找随它一起没了，
///   新 surface 回放进来的内容由搜索线程自己找到。
///
/// 事件按到达顺序照收、不和关键词配对：换了关键词之后，旧关键词的计数可能还会晚到一条，但引擎换关键词时会先报一次
/// 「未选中」，之后到的才是新的，按顺序收下来最后一条总是对的。计数从搜索线程来，比发出 `search:` 的那一刻晚一拍以上。
///
/// 关键词不满 `debounceBelowLength` 个字符时等 `debounceDelay` 再发（Ghostty 自己的 App 也这样）：一两个字符的匹配
/// 很多，每敲一个键就整份回滚重找一遍不划算。
@MainActor
@Observable
final class TerminalSearch {
    /// 查找栏开着。
    private(set) var isPresented = false
    /// 引擎报来的匹配总数；nil = 还不知道（刚改了关键词、没在找）。
    private(set) var total: Int?
    /// 选中的是第几处（从 0 数）；nil = 没有选中。
    private(set) var selected: Int?
    /// 每次要求把键盘焦点交给查找框（刚打开、开着时又按了 ⌘F）就加一。查找栏看着它挪焦点。
    private(set) var focusRequest = 0
    private var storedQuery = ""

    /// 查找框里的字。改了就（按 `debounceBelowLength` 的规则）让引擎换关键词重找。
    var query: String {
        get { storedQuery }
        set { setQuery(newValue, immediately: false) }
    }

    /// 在 surface 上执行一个绑定动作，返回做成了没有（没有 surface 时做不成）。平台接线（`TerminalSurfaceLink`）给。
    @ObservationIgnored var perform: (String) -> Bool = { _ in false }
    /// 引擎此刻在找的关键词；nil = 没发出去（没有 surface、或者 surface 换过还没重发）。
    @ObservationIgnored private var sentNeedle: String?
    @ObservationIgnored private var pendingSend: Task<Void, Never>?

    nonisolated static let debounceBelowLength = 3
    /// 短关键词等多久再发（测试里改短）。
    @ObservationIgnored var debounceDelay: Duration = .milliseconds(300)

    // MARK: 查找栏上的操作

    /// 打开查找栏并把焦点交给查找框。`needle` 不为空时换成它（「用所选内容查找」），否则接着找上次的关键词。
    func present(needle: String? = nil) {
        isPresented = true
        if let needle, !needle.isEmpty {
            setQuery(needle, immediately: true)
        } else if sentNeedle != storedQuery {
            send(storedQuery)
        }
        focusRequest &+= 1
    }

    /// 关掉查找栏：引擎停止查找、去掉高亮。关键词留着，下次打开接着用。
    func dismiss() {
        guard isPresented else { return }
        close()
        _ = perform("end_search")
    }

    /// 下一处。Ghostty 的「下一处」往回滚上方（更早的输出）走。等着发的关键词先发出去，免得跳的是旧关键词的匹配。
    func next() { navigate("next") }

    /// 上一处（往下、更新的输出）。
    func previous() { navigate("previous") }

    /// 用 surface 上的选区开始查找：引擎把选区的字报回来（`.started(needle:)`），没有选区时什么也不做。
    /// 有没有选区由平台先看（引擎这一步的返回值是宿主接没接那个回报，GhosttyKit 一律报「没接」，不能拿来判断）。
    func presentWithSelection() {
        _ = perform("search_selection")
    }

    private func close() {
        isPresented = false
        pendingSend?.cancel()
        pendingSend = nil
        sentNeedle = nil
        total = nil
        selected = nil
    }

    private func navigate(_ direction: String) {
        guard isPresented else {
            present()
            return
        }
        flushPendingSend()
        guard !storedQuery.isEmpty else { return }
        _ = perform("navigate_search:\(direction)")
    }

    // MARK: 引擎报来的

    func handle(_ event: TerminalSearchEvent) {
        switch event {
        case .started(let needle):
            present(needle: needle)
        case .ended:
            // 只有我们自己发 `end_search`（绑定表里没有这一条），这时栏已经关了；兜底：引擎说停了就关。
            if isPresented { close() }
        case .total(let value):
            guard isPresented else { return }
            total = value
        case .selected(let value):
            guard isPresented else { return }
            selected = value
        }
    }

    // MARK: surface 的生灭

    /// 新的 surface 建好了：它还没有查找，查找栏开着的话把关键词重发一遍。
    func surfaceAttached() {
        sentNeedle = nil
        guard isPresented else { return }
        pendingSend?.cancel()
        pendingSend = nil
        send(storedQuery)
    }

    /// surface 没了：查找跟着它没了，计数作废。
    func surfaceDetached() {
        sentNeedle = nil
        total = nil
        selected = nil
    }

    // MARK: 发关键词

    private func setQuery(_ text: String, immediately: Bool) {
        guard text != storedQuery || immediately else { return }
        storedQuery = text
        guard isPresented else { return }
        pendingSend?.cancel()
        pendingSend = nil
        if immediately || text.isEmpty || text.count >= Self.debounceBelowLength {
            send(text)
            return
        }
        pendingSend = Task { [weak self] in
            guard let delay = self?.debounceDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingSend = nil
            self.send(self.storedQuery)
        }
    }

    private func flushPendingSend() {
        guard pendingSend != nil else { return }
        pendingSend?.cancel()
        pendingSend = nil
        send(storedQuery)
    }

    private func send(_ text: String) {
        if text.isEmpty {
            // 空串 = 停止查找；引擎本来就没在找（没发过、或 surface 换过）就不用发。
            total = nil
            selected = nil
            if let sent = sentNeedle, !sent.isEmpty { _ = perform("search:") }
            sentNeedle = nil
            return
        }
        guard text != sentNeedle else { return }
        // 绑定动作按第一个冒号切开，冒号后面原样是关键词（含冒号、空格），不用转义。
        sentNeedle = perform("search:\(text)") ? text : nil
    }

    // MARK: 显示

    /// 计数：「3/12」「-/12」（有匹配、没选中）、「无结果」；还不知道或没在找时为 nil。
    var counterText: String? {
        guard !storedQuery.isEmpty, let total else { return nil }
        if total == 0 { return String(localized: "无结果") }
        guard let selected else { return "-/\(total)" }
        return "\(selected + 1)/\(total)"
    }
}
