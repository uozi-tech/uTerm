import Foundation
import XCTest

/// `uTermMobile/` 的渲染形态 lint。
///
/// ## 为什么 iOS 只能靠文本 lint
///
/// iOS 端**没有测试 target**，而且这台机器上 Xcode 26.6 的 iOS 平台组件没装、
/// 模拟器 runtime 一个都没有（`xcrun simctl list runtimes` 空），
/// 连 `xcodebuild -destination 'generic/platform=iOS Simulator'` 都过不去
/// （详见 `docs/scroll-perf-findings.md` 的「uTermMobile」一节）。
/// 桌面那套 AppKit 探针夹具（`ProbeWindow` / `ProbeMetrics`）在 iOS 上 0% 可用。
///
/// 所以这里退到**纯文本扫描**：跑在 macOS 的 `uTermTests` 里，不建窗、不 import，
/// 但至少能让这一轮修掉的几种形态「不能悄悄再长出来」。
///
/// ## 判红 vs 只打印
///
/// 只有**能机器判准**的才判红。剩下的形态（懒栈、`@Query` 规模、行体 formatter）
/// 都有正当的例外——小规模档换懒栈反而更慢、主机列表就是要拿全表——
/// 机器分不出「该改」和「本来就对」，所以只列清单给人看。
final class MobileRenderLintTests: XCTestCase {

    // MARK: - 判红：整表 fetch 不许进渲染路径

    /// `uTermMobile/` 里的 `context.fetch(FetchDescriptor<…>())` 只允许用来
    /// **求下一个 `sortOrder`**（写入路径，一次性）。
    ///
    /// 这一轮修掉的 `KeysScreen.usedCount` 就是反例：它在 `MInsetRow` 的
    /// 行体里调 `context.fetch(FetchDescriptor<ServerProfile>())` ——
    /// **每渲染一行就把整张主机表取出来物化一遍**再 filter。
    /// 渲染路径要取数请用 `@Query`（有订阅）或 `context.fetchCount`（不物化）。
    ///
    /// 判据是「同一行里必须跟着 `.map(\.sortOrder).max()`」：这是那个写入路径
    /// 惯用法的指纹，别的用法一概亮红，要放行就得来改这条注释。
    func testNoWholeTableFetchOutsideSortOrderSeeding() throws {
        var offenders: [String] = []
        for file in try GestureChainLintTests.mobileFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("context.fetch("), !trimmed.hasPrefix("//"),
                      !trimmed.hasPrefix("///") else { continue }
                guard !line.contains("sortOrder") else { continue }
                offenders.append("\(Self.relative(file)):\(i + 1)  \(trimmed)")
            }
        }
        for o in offenders { print("[mobile-lint] 整表 fetch：\(o)") }
        XCTAssertTrue(offenders.isEmpty, """
            `uTermMobile/` 里有渲染路径上的整表 fetch（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            行体里 `context.fetch(FetchDescriptor<T>())` 会把整张表取出来**物化成模型对象**，
            而且是每行一次。要订阅用 `@Query`，只要个数用 `context.fetchCount`，
            要按行取派生量就在 body 里建一次字典往下传。
            """)
    }

    // MARK: - 提示：单击 + 长按挂在同一条链上

    /// SwiftUI 里 `.onTapGesture` 与 `.onLongPressGesture` 同链时，
    /// 「长按满时长触发一次、抬手时**再**派发一次 tap」是有可能的 ——
    /// 真发生了就是「长按一个目录：动作面板弹出来的同时目录也被打开了」。
    ///
    /// 这台机器上没有可用的 iOS 模拟器 runtime，没法把它证实或证伪，
    /// 所以不判红，只列清单；`SFTPScreen` 那一处已经加了**两种情况下都正确**的
    /// 时间戳守卫（长按刚触发过就吃掉紧随的 tap）。
    func testReportTapAndLongPressOnTheSameChain() throws {
        var hits: [String] = []
        for file in try GestureChainLintTests.mobileFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for chain in GestureChainLintTests.modifierChains(in: source) {
                let compact = chain.text.replacingOccurrences(of: " ", with: "")
                guard compact.contains(".onLongPressGesture"),
                      GestureChainLintTests.hasSingleTap(chain.text) else { continue }
                hits.append("\(Self.relative(file)):\(chain.line)")
            }
        }
        print("[mobile-lint] 单击 + 长按同链：\(hits.count) 处（仅提示）")
        for h in hits { print("[mobile-lint]   - \(h)") }
    }

    // MARK: - 提示：非 lazy 容器 + 每行一个 Button

    /// 桌面那轮量出来的主因是「密集网格里每行挂 `Button`」；
    /// 但同一轮的**反例**也很硬：小规模档把 `VStack` 换成 `LazyVStack` 反而更慢
    /// （见 `docs/scroll-perf-findings.md`）。所以这条**只列不判** ——
    /// 要换懒栈得先有读数，不能照着清单无脑改。
    func testReportNonLazyStackWithButtonRows() throws {
        var hits: [String] = []
        for file in try GestureChainLintTests.mobileFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                guard line.contains("VStack("), !line.contains("LazyVStack") else { continue }
                // 往下看 40 行：同一段里既有 `ForEach(` 又有 `Button` / `NavigationLink`。
                let window = lines[i..<min(i + 40, lines.count)].joined(separator: "\n")
                guard window.contains("ForEach("),
                      window.contains("Button") || window.contains("NavigationLink") else { continue }
                hits.append("\(Self.relative(file)):\(i + 1)  "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }
        print("[mobile-lint] 非 lazy VStack + ForEach 行体带 Button：\(hits.count) 处（仅提示）")
        for h in hits { print("[mobile-lint]   - \(h)") }
    }

    // MARK: - 提示：无界 @Query

    /// `@Query` 不带 `fetchLimit` 时会把整张表取出来物化。
    /// 正当的例外很多（主机列表本来就要全表），所以只列不判 ——
    /// 看的时候问一句「这张表的规模是不是等于用户的库」：
    /// `ChatSession`（聊天历史）/ `KnownHost`（指纹）会一直长，
    /// `ServerProfile` / `ServerGroup` 不会。
    func testReportUnboundedQueries() throws {
        var hits: [String] = []
        for file in try GestureChainLintTests.mobileFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 注释里提到 `@Query` 的不算（这一轮的改动注释里到处都是）。
                guard !trimmed.hasPrefix("//"), trimmed.contains("@Query"),
                      !trimmed.contains("fetchLimit"), !trimmed.contains("Queries.")
                else { continue }
                hits.append("\(Self.relative(file)):\(i + 1)  \(trimmed)")
            }
        }
        print("[mobile-lint] @Query 无 fetchLimit：\(hits.count) 处（仅提示）")
        for h in hits { print("[mobile-lint]   - \(h)") }
    }

    // MARK: - 提示：行体里现建 formatter

    /// `DateFormatter()` / `RelativeDateTimeFormatter()` /
    /// `ByteCountFormatter.string(fromByteCount:` 都是几十微秒级的构造开销，
    /// 摊到逐行调用就是掉帧。共享实例在 `MFormat`（iOS）/ `WelcomeFormat`（macOS）。
    ///
    /// `MFormat.swift` 自己当然要建——按文件名跳过。
    func testReportFormattersBuiltInline() throws {
        let needles = ["DateFormatter()", "RelativeDateTimeFormatter()",
                       "ByteCountFormatter()", "ByteCountFormatter.string("]
        var hits: [String] = []
        for file in try GestureChainLintTests.mobileFiles()
        where file.lastPathComponent != "MFormat.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), needles.contains(where: { trimmed.contains($0) })
                else { continue }
                hits.append("\(Self.relative(file)):\(i + 1)  \(trimmed)")
            }
        }
        print("[mobile-lint] 行体现建 formatter：\(hits.count) 处（仅提示）")
        for h in hits { print("[mobile-lint]   - \(h)") }
    }

    // MARK: - 工具

    private static func relative(_ url: URL) -> String {
        guard let r = url.path.range(of: "/uTermMobile/") else { return url.path }
        return String(url.path[r.lowerBound...].dropFirst())
    }
}
