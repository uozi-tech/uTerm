import UDesignKit
import SwiftUI
import SwiftData
import Combine

/// 并行执行请求（命令广播到多台主机）。由命令详情发起，根视图以全屏覆盖呈现。
struct ParallelRunRequest: Identifiable {
    let id = UUID()
    let commandID: UUID
    let name: String
    let command: String
    let intent: String
    let aiAssisted: Bool
    let serverIDs: [UUID]
}

/// 造并行控制器所需的、只有视图取得到的东西（`@Query` 出的主机与 provider、SwiftData 上下文）。
/// 见 `ParallelRunView.makeController`。
@MainActor
struct ParallelRunSetup {
    let request: ParallelRunRequest
    /// 按 `request.serverIDs` 选中的主机（顺序与 serverIDs 一致）。
    let targets: [ServerProfile]
    let providers: [AIProvider]
    let context: ModelContext
}

/// 并行执行全屏视图（设计稿 `ParallelRun`）：Shell 网格 + AI 泳道两视图共用一次真实执行。
struct ParallelRunView: View {
    let request: ParallelRunRequest
    /// 控制器工厂。默认造真控制器（真实 SSH 执行器），**生产调用点不变**；
    /// 探针注入一个带假执行器的控制器，整屏就能在没有真机器的情况下挂起来量。
    let makeController: @MainActor (ParallelRunSetup) -> ParallelRunController
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var allHosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]

    @State private var controller: ParallelRunController?
    @State private var now = Date()
    /// 本屏可用宽度，判断要不要切成大屏布局（见 `wide`）。
    @State private var width: CGFloat = 0
    /// 大屏 Shell 当前在第几页。
    @State private var shellPage: Int? = 0
    /// 大屏 Shell 每页几台：输出区够高就 2×2 四台，矮（手机横屏）就一行两台，免得每格只露三四行。
    @State private var shellPerPage = 4
    /// 从 AI 泳道点「原始输出」跳过来时，要滚到的那一台（窄屏列表用）。
    @State private var revealLane: UUID?
    @State private var aiFilter: ParAIFilter = .all
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// - Parameters:
    ///   - makeController: 控制器工厂，默认造真控制器。
    ///   - controller: 直接给一个现成的控制器（**探针用**）。给了就跳过 `onAppear` 现造那一步，
    ///     首帧即内容（否则要先渲一帧 `ProgressView`，探针在那一帧里拿不到 `UIScrollView`）；
    ///     此时 `start()` 由调用方自己发。生产不传，走工厂。
    init(request: ParallelRunRequest,
         makeController: @escaping @MainActor (ParallelRunSetup) -> ParallelRunController
            = ParallelRunView.defaultController,
         controller: ParallelRunController? = nil,
         onClose: @escaping () -> Void) {
        self.request = request
        self.makeController = makeController
        self.onClose = onClose
        _controller = State(initialValue: controller)
    }

    /// 全屏覆盖层自带一层 `NavigationStack`。按液态玻璃的分层：**控件在导航层、输出在内容层**。
    /// - 顶栏（系统）：左关闭、右重新运行；标题 = 命令名，副标题 = 实时进度（完成数 / 失败数 / 用时）。
    /// - 底栏（系统）：Shell / AI 介入的系统分段控件；大屏 Shell 的页码点也在这里。
    /// - 内容：命令条 + 进度条 + 输出，全部是实底，不上玻璃。
    /// 系统栏不铺自定义底色，交给系统按玻璃强度 / 降低透明度 / 增强对比度自己适配。
    /// 改前是自绘页头（+ `mTopClearance` 手补顶边），iPhone Duo 上按钮不会随系统挪到侧边状态栏下方那一列；
    /// 再之前模式切换与状态栏都是内容里自绘的。
    var body: some View {
        NavigationStack {
            Group {
                if let c = controller {
                    content(c)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(M.surface)
                }
            }
            .navigationTitle(controller?.commandName ?? request.name)
            .mNavigationSubtitle(controller.map(subtitle))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ParPinnedBars())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MToolbarCloseButton(action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller?.rerun() } label: {
                        Image(systemName: MGlyph.symbol("rerun"))
                    }
                    .disabled(controller?.allDone != true)
                    .accessibilityLabel(Text("重新运行"))
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let c = controller {
                        if showsPageDots(c) {
                            modePicker(c)
                            Spacer()
                            pageDots(c)
                        } else {
                            Spacer()
                            modePicker(c)
                            Spacer()
                        }
                    }
                }
            }
        }
        .onAppear { if controller == nil { setup() } }
        .onReceive(ticker) { t in if controller?.allDone == false { now = t } }
    }

    private func setup() {
        let targets = request.serverIDs.compactMap { id in allHosts.first { $0.id == id } }
        let c = makeController(ParallelRunSetup(request: request, targets: targets,
                                                providers: providers, context: context))
        controller = c
        c.start()
    }

    /// 默认工厂：真 AI doctor + 真 SSH 执行器 + 真 `QuickCommandStore`（与加注入口之前逐行一致）。
    @MainActor
    static func defaultController(_ setup: ParallelRunSetup) -> ParallelRunController {
        ParallelRunController(
            commandID: setup.request.commandID, commandName: setup.request.name,
            command: setup.request.command, intent: setup.request.intent,
            aiAssisted: setup.request.aiAssisted,
            targets: setup.targets, doctor: ParallelDoctor.make(provider: setup.providers.first),
            store: QuickCommandStore(context: setup.context), container: setup.context.container)
    }

    // MARK: 组合

    /// 宽度够放两列就算「大屏」（iPad、iPhone Duo 展开、Pro Max 横屏）：Shell 换成每页 2×2 四台
    /// 横向翻页，AI 泳道排两列，顶部的模式切换 / 广播条 / 进度压成一行，把纵向空间留给输出。
    nonisolated static let wideThreshold: CGFloat = 700
    private var wide: Bool { width >= Self.wideThreshold }

    private func content(_ c: ParallelRunController) -> some View {
        VStack(spacing: 0) {
            commandStrip(c)
            if c.mode == .ai {
                aiBody(c)
            } else {
                shellBody(c)
            }
        }
        // 内容层 = 画布 + 卡片（`canvas` 浅灰 / 纯黑，每台一张 `card`），靠底色差分界、不描边。
        // 不走终端那类「整屏单面 + hairline」：这里是十几台并排比较，一台一张卡才分得清。
        .background(M.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
        // 整次运行落定时给一下触觉：全成功 = success，有失败 = warning。
        .sensoryFeedback(trigger: c.allDone) { _, done in
            done ? (c.failedCount > 0 ? .warning : .success) : nil
        }
    }

    /// 导航栏副标题：台数 + 实时进度。失败数与用时也在这里，不再另画一条底部状态栏。
    private func subtitle(_ c: ParallelRunController) -> String {
        let elapsed = (c.finishedAt ?? now).timeIntervalSince(c.startedAt)
        var parts = ["\(c.mode == .ai ? "AI" : "并行") · \(c.total) 台", "完成 \(c.doneCount)/\(c.total)"]
        if c.failedCount > 0 { parts.append("\(c.failedCount) 失败") }
        parts.append(UFormat.duration(seconds: max(0, elapsed)))
        return parts.joined(separator: " · ")
    }

    /// 底栏里的视图切换：系统分段控件（iOS 26 起自带玻璃滑块、VoiceOver 与动态字体）。
    private func modePicker(_ c: ParallelRunController) -> some View {
        Picker("视图", selection: Binding(get: { c.mode },
                                         set: { m in withAnimation(.snappy) { c.mode = m } })) {
            Text("Shell").tag(PMode.shell)
            Text("AI 介入").tag(PMode.ai)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
    }

    private func showsPageDots(_ c: ParallelRunController) -> Bool {
        wide && c.mode == .shell && c.states.count > shellPerPage
    }

    /// 命令条 + 进度条（内容层，实底）。窄屏上下两行，大屏并成一行。
    private func commandStrip(_ c: ParallelRunController) -> some View {
        let layout = wide
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return layout {
            commandChip(c)
            progressBar(c).frame(maxWidth: wide ? 180 : .infinity)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("完成 \(c.doneCount)/\(c.total)" + (c.failedCount > 0 ? "，\(c.failedCount) 台失败" : "")))
    }

    private func tint(_ c: ParallelRunController) -> Color { c.mode == .ai ? M.aiAccent : accent }

    private func commandChip(_ c: ParallelRunController) -> some View {
        HStack(spacing: 9) {
            MIcon(name: "parallel", size: 13, color: tint(c))
            if !c.broadcastIsIntent { Text("$").font(M.mono(13)).foregroundStyle(tint(c)) }
            Text(c.broadcastText).font(M.mono(13)).foregroundStyle(M.text2).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
    }

    private func progressBar(_ c: ParallelRunController) -> some View {
        ProgressView(value: Double(c.doneCount), total: Double(max(c.total, 1)))
            .progressViewStyle(.linear)
            .tint(c.failedCount > 0 ? M.caution : tint(c))
            .animation(.easeOut(duration: 0.35), value: c.doneCount)
    }

    // MARK: Shell

    @ViewBuilder
    private func shellBody(_ c: ParallelRunController) -> some View {
        if wide {
            shellGrid(c)
        } else {
            shellList(c)
        }
    }

    /// 窄屏：一列，逐台往下排，格高随输出。
    private func shellList(_ c: ParallelRunController) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.cardGap) {
                    ForEach(c.states) { s in
                        ParShellPane(state: s, accent: accent) { c.trustAndRetry(serverID: s.id) }
                            .id(s.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                guard let id = revealLane else { return }
                revealLane = nil
                // 推迟一拍：同步滚会落在懒栈还没量好那几格之前的旧位置上。
                Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    /// 大屏：每页 2×2 四台（矮屏一行两台）、横向翻页；每格定高，格内输出自己滚并贴底跟随。
    private func shellGrid(_ c: ParallelRunController) -> some View {
        let pages = Self.shellPages(count: c.states.count, perPage: shellPerPage)
        return GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { p in
                        shellPage(c, indices: pages[p])
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(p)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $shellPage)
            .scrollIndicators(.hidden)
        }
        .onGeometryChange(for: Int.self) { Self.shellPerPage(gridHeight: $0.size.height) } action: { perPage in
            // 换档时保住正在看的那一台所在的页。
            let firstVisible = (shellPage ?? 0) * shellPerPage
            shellPerPage = perPage
            shellPage = firstVisible / perPage
        }
    }

    /// 输出区高度 → 每页几台。两行时每格至少要露出 7~8 行输出才有意义。
    nonisolated static func shellPerPage(gridHeight: CGFloat) -> Int {
        gridHeight >= 300 ? 4 : 2
    }

    /// 一页里的格子：1 台占满，2 台左右各半，3~4 台两行两列（第 3 台时右下留空）。
    private func shellPage(_ c: ParallelRunController, indices: [Int]) -> some View {
        let columns = indices.count == 1 && shellPerPage == 4 ? 1 : 2
        let rows = stride(from: 0, to: indices.count, by: columns).map {
            Array(indices[$0..<min($0 + columns, indices.count)])
        }
        return VStack(spacing: Self.cardGap) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: Self.cardGap) {
                    ForEach(0..<columns, id: \.self) { col in
                        if col < rows[r].count, c.states.indices.contains(rows[r][col]) {
                            let s = c.states[rows[r][col]]
                            ParShellPane(state: s, accent: accent, fillsCell: true) {
                                c.trustAndRetry(serverID: s.id)
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// 卡片之间的缝。
    static let cardGap: CGFloat = 10

    /// 大屏 Shell 的分页：按原顺序每 `perPage` 台一页，返回每页的下标。
    nonisolated static func shellPages(count: Int, perPage: Int = 4) -> [[Int]] {
        guard count > 0, perPage > 0 else { return [] }
        return stride(from: 0, to: count, by: perPage).map { Array($0..<min($0 + perPage, count)) }
    }

    /// 状态栏中间的页码点：当前页拉长成胶囊，有失败台的页标红；点一下翻过去。
    private func pageDots(_ c: ParallelRunController) -> some View {
        let pages = Self.shellPages(count: c.states.count, perPage: shellPerPage)
        let current = shellPage ?? 0
        return HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { p in
                let failed = pages[p].contains { c.states.indices.contains($0) && c.states[$0].status == .failed }
                Capsule()
                    .fill(p == current ? accent : (failed ? M.danger : M.text4.opacity(0.5)))
                    .frame(width: p == current ? 16 : 6, height: 6)
                    .padding(.vertical, 8).padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { shellPage = p } }
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("第 \(current + 1) 页，共 \(pages.count) 页"))
    }

    // MARK: AI

    private func aiBody(_ c: ParallelRunController) -> some View {
        let visible = c.states.filter { aiFilter.includes($0.tone) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                aiOverview(c)
                if c.total > 1, !wide { filterBar(c) }
                if wide {
                    // `Grid` 而不是 `LazyVGrid`：懒网格按各自内容量高，同一行两张卡高矮不齐；
                    // `Grid` 的一行取最高那张，卡片再 `maxHeight: .infinity` 撑满，整行等高。
                    // 台数是几十量级、卡片很轻，不懒没关系。
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Self.pairs(visible), id: \.first?.id) { pair in
                            GridRow(alignment: .top) {
                                ForEach(pair) { s in lane(s, in: c) }
                                if pair.count == 1 {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                                }
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(visible) { s in lane(s, in: c) }
                    }
                }
                if visible.isEmpty {
                    Text("没有\(aiFilter.title)的服务器")
                        .font(M.sans(13)).foregroundStyle(M.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(16)
            .frame(maxWidth: wide ? 1180 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lane(_ s: PServerState, in c: ParallelRunController) -> some View {
        ParAILane(state: s, onShowOutput: { showOutput(of: s.id, in: c) }) {
            c.trustAndRetry(serverID: s.id)
        }
    }

    /// 宽屏两列：按原顺序两两成行。
    static func pairs<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    /// 顶部总览：进度环 + 成功 / 失败 / 进行中计数；全部落定后接 AI 汇总。
    /// 大屏（多半是横屏、纵向紧）压成一行：环 + 标题计数 + 右侧筛选，汇总另起一块。
    @ViewBuilder
    private func aiOverview(_ c: ParallelRunController) -> some View {
        if wide {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    progressRing(c, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        overviewTitle(c, size: 15)
                        overviewCounts(c)
                    }
                    Spacer(minLength: 12)
                    if c.total > 1 { filterBar(c).fixedSize(horizontal: true, vertical: false) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(M.card)
                .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
                synthesisBlock(c, cornerRadius: MRadius.list)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    progressRing(c, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        overviewTitle(c, size: 16)
                        overviewCounts(c)
                        if !c.allDone, c.aiAssisted {
                            Text("遇到报错会先自行诊断、换办法修复，处理不了的才交给你。")
                                .font(M.sans(12.5)).foregroundStyle(M.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                synthesisBlock(c, cornerRadius: MRadius.inner(of: MRadius.list, inset: 14))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
        }
    }

    private func progressRing(_ c: ParallelRunController, size: CGFloat) -> some View {
        let progress = c.total == 0 ? 0 : Double(c.doneCount) / Double(c.total)
        let ringTint: Color = c.failedCount > 0 ? M.danger : (c.allDone ? M.success : M.aiAccent)
        return ZStack {
            Circle().stroke(M.fillMed, lineWidth: 5)
            Circle().trim(from: 0, to: progress)
                .stroke(ringTint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(c.doneCount)/\(c.total)")
                .font(M.mono(size > 50 ? 11.5 : 10.5, weight: .semibold)).foregroundStyle(M.text)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.snappy, value: c.doneCount)
    }

    private func overviewTitle(_ c: ParallelRunController, size: CGFloat) -> some View {
        let title: String = !c.allDone
            ? "正在 \(c.total) 台服务器上执行"
            : (c.failedCount > 0 ? "已完成，\(c.failedCount) 台失败" : "全部 \(c.total) 台执行成功")
        return Text(title).font(M.sans(size, weight: .semibold)).foregroundStyle(M.text)
    }

    private func overviewCounts(_ c: ParallelRunController) -> some View {
        let running = c.total - c.doneCount
        return HStack(spacing: 12) {
            countLabel("checkmark.circle.fill", "成功 \(c.okCount)", M.success)
            if c.failedCount > 0 {
                countLabel("xmark.circle.fill", "失败 \(c.failedCount)", M.danger)
            }
            if running > 0 {
                countLabel("circle.dashed", "进行中 \(running)", M.aiAccent)
            }
        }
        .animation(.snappy, value: c.doneCount)
    }

    /// 全部落定后的 AI 汇总（汇总请求还没回来时显示「正在汇总」）。
    @ViewBuilder
    private func synthesisBlock(_ c: ParallelRunController, cornerRadius: CGFloat) -> some View {
        if c.allDone, c.aiAssisted {
            if c.synthesis.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在汇总各台结果…").font(M.sans(13)).foregroundStyle(M.text3)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        MIcon(name: "spark", size: 12, color: M.aiAccent)
                        Text("AI 汇总").font(M.sans(12.5, weight: .semibold)).foregroundStyle(M.aiAccent)
                    }
                    Text(c.synthesis).font(M.sans(14)).foregroundStyle(M.text).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(M.aiAccent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
    }

    private func countLabel(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(text).font(M.sans(12.5, weight: .medium)).foregroundStyle(M.text2)
                .contentTransition(.numericText())
        }
    }

    /// 按结果筛选：十几台时一眼只看失败的那几台。
    private func filterBar(_ c: ParallelRunController) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ParAIFilter.allCases, id: \.self) { f in
                    let n = c.states.filter { f.includes($0.tone) }.count
                    if f == .all || n > 0 || f == aiFilter {
                        let on = f == aiFilter
                        Button { withAnimation(.snappy) { aiFilter = f } } label: {
                            HStack(spacing: 5) {
                                Text(f.title).font(M.sans(13, weight: on ? .semibold : .medium))
                                Text("\(n)").font(M.mono(12)).opacity(0.8)
                            }
                            .foregroundStyle(on ? f.tint : M.text2)
                            .padding(.horizontal, 12).frame(height: 30)
                            // `button` 在画布（窄屏）与卡片（宽屏，芯片在总览卡里）上都成形。
                            .background(on ? f.tint.opacity(0.14) : M.button)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(MPressStyle())
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// AI 泳道「原始输出」：切回 Shell 并定位到这一台。
    private func showOutput(of id: UUID, in c: ParallelRunController) {
        if let index = c.states.firstIndex(where: { $0.id == id }) {
            shellPage = index / shellPerPage
        }
        revealLane = id
        c.mode = .shell
    }
}

/// iOS 27 起系统会随滚动把导航栏 / 底栏收起。这一页的进度在副标题、视图切换在底栏，
/// 收起就看不到了，所以两条都钉住。
private struct ParPinnedBars: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.toolbarMinimizationBehavior(.never, for: .navigationBar, .bottomBar)
        } else {
            content
        }
    }
}

/// AI 视图的结果筛选。
enum ParAIFilter: CaseIterable {
    case all, failed, running, ok

    var title: String {
        switch self {
        case .all: return "全部"
        case .failed: return "失败"
        case .running: return "进行中"
        case .ok: return "成功"
        }
    }

    var tint: Color {
        switch self {
        case .all: return M.text
        case .failed: return M.danger
        case .running: return M.aiAccent
        case .ok: return M.success
        }
    }

    func includes(_ tone: PTone) -> Bool {
        switch self {
        case .all: return true
        case .failed: return tone == .failed
        case .running: return tone == .running
        case .ok: return tone == .ok
        }
    }
}

// MARK: - Shell 窗格（逐台真实输出）

/// `internal` 而非 `private`：探针要单独挂一格来给「行数 / 台数各自涨多少」归因
/// （整屏读数分不出这两笔账）。可见性之外没有任何改动。
struct ParShellPane: View {
    let state: PServerState
    let accent: Color
    /// 大屏网格里的一格：高度由格子定，输出在格内自己滚、贴底跟随。
    /// 默认 false = 窄屏列表，格高随输出（与改前一致）。
    var fillsCell = false
    var onTrust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if fillsCell {
                // 格内贴底跟随：进格、来新行都滚到最后一行。`defaultScrollAnchor(.bottom)`
                // 在懒栈里实测不跟（内容高是估的），所以显式 scrollTo 底部哨兵。
                ScrollViewReader { proxy in
                    ScrollView {
                        lineStack
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { scrollToBottom(proxy) }
                    .onChange(of: state.lines.count) { scrollToBottom(proxy) }
                }
            } else {
                lineStack.frame(minHeight: 72, alignment: .topLeading)
            }
        }
        // 一台一张卡（画布上靠底色差成形，不描边）。状态只在卡头表达，不再铺彩色顶边：
        // 全部成功时满屏绿条反而把真正要看的失败淹掉。
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
    }

    private var failed: Bool { state.status == .failed }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.name).font(M.sans(13, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
            Text(state.endpointDisplay).font(M.mono(11)).foregroundStyle(M.text4).lineLimit(1)
            Spacer(minLength: 6)
            status
        }
        .padding(.horizontal, 12).frame(height: 36)
        // 失败的卡头铺淡红；其余与卡同底，只靠下面那条细线和输出分开。
        .background(failed ? M.danger.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    /// 卡头右侧的状态：运行中 = 脉冲点；成功 = 小绿勾 + 退出码（低调）；失败 = 红叉 + 红色退出码。
    @ViewBuilder
    private var status: some View {
        switch state.status {
        case .running:
            HStack(spacing: 6) {
                MDot(color: accent, pulse: true, size: 7)
                Text("运行中").font(M.mono(11)).foregroundStyle(M.text3)
            }
        case .succeeded:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(M.success)
                if let code = state.exitCode {
                    Text("退出码 \(code)").font(M.mono(11)).foregroundStyle(M.text4)
                }
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(M.danger)
                Text(state.exitCode.map { "退出码 \($0)" } ?? "失败")
                    .font(M.mono(11, weight: .medium)).foregroundStyle(M.danger)
            }
        }
    }

    // `LazyVStack` 而不是 `VStack`：一格就是一台的全部输出（自愈多步 × 200 行，
    // 极端档一格两万多 pt）。外层懒栈只保证「没进视野的**格**不建」，
    // 一旦某格进了视野，非懒的内层会把这一格的一千两百行**整批**建出来 ——
    // 实测（`ParallelRunProbeTests`，24 台 × 1200 行）翻到下一台那一跳
    // p50 316ms / max 367ms，是 16.67ms 预算的 19~22 倍；6 台 × 600 行也要 161ms。
    // 换成懒栈后只建视野内那几十行。
    private var lineStack: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(state.lines) { line in
                HStack(alignment: .top, spacing: 7) {
                    switch line.kind {
                    case .cmd: Text("$").foregroundStyle(accent)
                    case .err: Text("✕").foregroundStyle(M.danger)
                    case .ok: Text("✓").foregroundStyle(M.success)
                    case .out: Text(" ").foregroundStyle(.clear)
                    }
                    Text(line.text).foregroundStyle(lineColor(line.kind))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(M.mono(12.5))
            }
            if state.hostKeyUntrusted {
                MBtn(title: "信任并重试", icon: "shield", kind: .tinted, height: 36, action: onTrust)
                    .fixedSize().padding(.top, 8)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private static let bottomID = "par-shell-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // 推迟一拍：同步滚会落在新行布局之前的旧底部。
        Task { @MainActor in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private func lineColor(_ kind: PLine.Kind) -> Color {
        switch kind {
        case .cmd: return M.text
        case .err: return M.danger
        default: return M.text3
        }
    }
}

// MARK: - AI 泳道

/// 一台服务器的 AI 处理卡片：状态 + 正在做什么（运行中）/ 结论（落定后）+ 处理过程时间线。
///
/// `internal` 而非 `private`：探针要量「展开处理过程」这一下的成本，而 `open` 是
/// `@State`，外部点不到（SwiftUI 的 Button 在视图树里不是 `UIControl`，hitTest 也点不着）。
struct ParAILane: View {
    let state: PServerState
    /// 初始就展开「处理过程」。**默认 false = 现状**；只有探针会传 true，用来做展开前→后同轮对照。
    var initiallyOpen = false
    /// 「原始输出」：切到 Shell 看这一台的完整输出。nil 时不显示这个按钮。
    var onShowOutput: (() -> Void)?
    var onTrust: () -> Void
    @State private var open: Bool

    /// 运行中只露最近几步，落定后收进「处理过程」。
    private static let liveSteps = 3

    init(state: PServerState, initiallyOpen: Bool = false,
         onShowOutput: (() -> Void)? = nil, onTrust: @escaping () -> Void) {
        self.state = state
        self.initiallyOpen = initiallyOpen
        self.onShowOutput = onShowOutput
        self.onTrust = onTrust
        _open = State(initialValue: initiallyOpen)
    }

    private var resolved: Bool { state.tone != .running }
    private var stepCount: Int { state.agentSteps.isEmpty ? state.steps.count : state.agentSteps.count }
    private var tint: Color {
        switch state.tone {
        case .running: return M.aiAccent
        case .ok: return M.success
        case .failed: return M.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if resolved { resolvedBody } else { runningBody }
        }
        .padding(13)
        // `maxHeight: .infinity`：宽屏 `Grid` 一行里撑到与同行那张一样高；窄屏在 ScrollView 里
        // 高度不受限，等于按内容高，不受影响。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 白卡（画布上靠底色差成形，不描边）；失败的卡整张铺一层淡红，扫一眼就能找到。
        .background {
            ZStack {
                M.card
                if state.tone == .failed { M.danger.opacity(0.07) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
    }

    private var header: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.name).font(M.sans(14.5, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
                Text(state.endpointDisplay).font(M.mono(11)).foregroundStyle(M.text4).lineLimit(1)
            }
            Spacer(minLength: 6)
            if resolved, let ms = state.durationMs {
                Text(UFormat.duration(seconds: Double(ms) / 1000)).font(M.mono(11)).foregroundStyle(M.text4)
            }
            Text(state.laneStatusText)
                .font(M.sans(11.5, weight: .semibold)).foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.tone {
        case .running:
            ProgressView().controlSize(.small).tint(M.aiAccent)
        case .ok:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(M.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 19)).foregroundStyle(M.danger)
        }
    }

    /// 运行中：最近几步 + 这一刻在做什么。
    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !state.agentSteps.isEmpty {
                let hidden = state.agentSteps.count - Self.liveSteps
                if hidden > 0 {
                    Text("… 前面还有 \(hidden) 步").font(M.sans(11.5)).foregroundStyle(M.text4)
                }
                ParStepTimeline(steps: Array(state.agentSteps.suffix(Self.liveSteps)))
            }
            // 有一步正在跑时，时间线里那一行已经说明了在做什么；只在两步之间
            // （分析结果、重试模型请求、跑初始命令）补一行。
            if state.agentSteps.last?.state != .running {
                HStack(alignment: .top, spacing: 6) {
                    MIcon(name: "spark", size: 11, color: M.aiAccent).padding(.top, 2)
                    Text(state.activity ?? state.laneStatusText)
                        .font(M.sans(13)).foregroundStyle(M.text2).lineLimit(2)
                }
            }
        }
    }

    /// 落定后：结论 + 操作 + 可展开的完整处理过程。
    private var resolvedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 结论这一块吃掉卡片被撑高的那部分，按钮行于是贴在卡底，同一行两张卡的按钮对齐。
            VStack(alignment: .leading, spacing: 10) {
                summaryText
                if state.hostKeyUntrusted {
                    MBtn(title: "信任并重试", icon: "shield", kind: .tinted, height: 36, action: onTrust)
                        .fixedSize()
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            if stepCount > 0 || onShowOutput != nil || open {
                HStack(spacing: 8) {
                    if stepCount > 0 {
                        pill(icon: "chev", title: open ? "收起" : "处理过程 · \(stepCount) 步",
                             rotate: open) { withAnimation(.snappy) { open.toggle() } }
                    } else if open {
                        pill(icon: "chev", title: "收起", rotate: true) { withAnimation(.snappy) { open = false } }
                    }
                    if let onShowOutput {
                        pill(icon: "term", title: "原始输出", rotate: false, action: onShowOutput)
                    }
                }
            }
            if open, stepCount > 0 {
                if state.agentSteps.isEmpty {
                    legacySteps
                } else {
                    ParStepTimeline(steps: state.agentSteps)
                }
            }
        }
    }

    /// 结论默认只占一行、超出省略，十几张卡扫下来整齐；点结论或「处理过程」展开看全文。
    /// 不开 `textSelection`：可选中的文字每段都会建 UIKit 选择视图，视图数跟着展开的卡涨
    /// （`testAILaneExpansionCost` 抓到 +26），而复制结论用处不大（汇总卡在上面）。
    @ViewBuilder
    private var summaryText: some View {
        let text = Text(state.summary).font(M.sans(13.5)).foregroundStyle(M.text).lineSpacing(2)
        if open {
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            text.lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { open = true } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("展开完整结论"))
        }
    }

    private func pill(icon: String, title: String, rotate: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MIcon(name: icon, size: 11, color: M.text3, weight: .semibold)
                    .rotationEffect(.degrees(rotate ? 90 : 0))
                Text(title).font(M.sans(12)).foregroundStyle(M.text2)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(M.button)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }.buttonStyle(MPressStyle())
    }

    /// 只有纯文本步骤（旧记录 / 探针构造的数据）时的列表。
    private var legacySteps: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(state.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(i + 1)").font(M.mono(10.5)).foregroundStyle(M.aiAccent)
                        .frame(width: 18, height: 18).background(M.aiAccent.opacity(0.12)).clipShape(Circle())
                    Text(step).font(M.sans(13)).foregroundStyle(M.text3).lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// AI 处理过程时间线：每步一个结果图标 + 说明 + 命令；非 0 退出码在右侧标出。
struct ParStepTimeline: View {
    let steps: [PAgentStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 9) {
                    icon(step.state).frame(width: 16, height: 16).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        if let e = step.explanation, !e.isEmpty {
                            Text(e).font(M.sans(13)).foregroundStyle(M.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(step.command).font(M.mono(11.5)).foregroundStyle(M.text3).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    if let code = step.exitCode, code != 0 {
                        Text("退出码 \(code)").font(M.mono(10.5)).foregroundStyle(M.danger)
                    } else if step.state == .timedOut {
                        Text("超时").font(M.mono(10.5)).foregroundStyle(M.caution)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: PAgentStep.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(M.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(M.danger)
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 14)).foregroundStyle(M.caution)
        }
    }
}
