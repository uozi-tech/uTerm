import UDesignKit
import SwiftUI

/// DesignKit 组件画廊 —— Claude Design 交付包 `Components.html` 的 SwiftUI 复刻。
///
/// 把 `UD` 基础组件按家族（基础 token / Chrome / 控件 / 浮层 / 对话与状态）铺成
/// 可滚动画廊，顶部可切深 / 浅外观，供肉眼对照设计稿。纯展示，不接入任何业务。
struct DesignKitGallery: View {
    /// 内置外观初值（默认深色；离屏渲染时可指定）。
    var initialScheme: ColorScheme = .dark
    /// 是否包裹 `ScrollView`。离屏 `ImageRenderer` 不渲染 ScrollView 内容，
    /// 故渲染快照时传 `false`，让内容直接按理想尺寸铺开。
    var scrolls: Bool = true

    @State private var scheme: ColorScheme
    @State private var search = ""
    @State private var composer = ""
    @State private var segFont = "Monaco"
    @State private var segView = "split"
    @State private var sliderFont = 11.0
    @State private var sliderLine = 1.0
    @State private var toggleHotReload = true
    @State private var toggleOff = false

    init(initialScheme: ColorScheme = .dark, scrolls: Bool = true) {
        self.initialScheme = initialScheme
        self.scrolls = scrolls
        _scheme = State(initialValue: initialScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(UD.border)
            if scrolls {
                ScrollView { sections }
            } else {
                sections
            }
        }
        .background(UD.bg)
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
        .frame(minWidth: 900, minHeight: scrolls ? 700 : nil)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 40) {
            tokensSection
            chromeSection
            controlsSection
            formsSection
            overlaysSection
            commsSection
            brandSection
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 表单控件 · Forms
    private var formsSection: some View {
        Section(title: "表单控件 · Forms", subtitle: "分段控制 / 滑块 / 开关") {
            Group(label: "分段控制 Segmented") {
                VStack(alignment: .leading, spacing: 14) {
                    UDSegmented(selection: $segFont,
                                options: [("Menlo", "Menlo"), ("SF Mono", "SF Mono"), ("Monaco", "Monaco")])
                    UDSegmented(selection: $segView,
                                options: [("edit", "编辑"), ("split", "分屏"), ("preview", "预览")])
                }
            }
            Group(label: "滑块 Slider") {
                VStack(alignment: .leading, spacing: 18) {
                    UDSlider(value: $sliderFont, in: 10...20, step: 1, ticks: 11,
                             valueLabel: { "\(Int($0)) pt" }).frame(width: 320)
                    UDSlider(value: $sliderLine, in: 1.0...2.0, step: 0.05,
                             valueLabel: { String(format: "%.2f", $0) }).frame(width: 320)
                    UDSlider(value: .constant(24), in: 10...30, color: UD.success,
                             valueLabel: { "\(Int($0)) pt" }).frame(width: 320)
                }
            }
            Group(label: "开关 Toggle") {
                HStack(spacing: 40) {
                    UDToggle($toggleOff)
                    UDToggle($toggleHotReload)
                    UDToggle(.constant(false)).disabled(true)
                    HStack(spacing: 10) {
                        Text("热加载").font(UD.body).foregroundStyle(UD.text)
                        UDToggle($toggleHotReload)
                    }
                }
            }
        }
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 12) {
            ULogo(size: 24)
            Text("uTerm · DesignKit")
                .font(UD.h2)
                .foregroundStyle(UD.text)
            Spacer()
            UDSegmented(selection: $scheme, options: [
                (value: ColorScheme.dark, label: "深色"),
                (value: ColorScheme.light, label: "浅色"),
            ])
            .frame(width: 160)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(UD.panel)
    }

    // MARK: 基础 · Tokens
    private var tokensSection: some View {
        Section(title: "基础 · Tokens", subtitle: "颜色 / 字体 / 圆角 / 表面阴影") {
            Group(label: "表面 Surfaces") {
                swatchRow([("窗口 bg", UD.bg), ("面板 panel", UD.panel),
                           ("高亮 panelHi", UD.panelHi), ("悬停 hover", UD.panelHover),
                           ("画布 pageBg", UD.pageBg), ("终端 termBg", UD.termBg)])
            }
            Group(label: "文本 / 描边") {
                swatchRow([("text", UD.text), ("text2", UD.text2), ("text3", UD.text3),
                           ("text4", UD.text4), ("border", UD.border)])
            }
            Group(label: "强调 / 语义") {
                swatchRow([("accent", UD.accent), ("成功", UD.success), ("警告", UD.warning),
                           ("断开", UD.caution), ("错误", UD.danger), ("信息", UD.info)])
            }
            Group(label: "字体 Type") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接到主机 demo-server").font(UD.title).foregroundStyle(UD.text)
                    Text("快速开始 · 支持热加载与 SFTP").font(UD.h2).foregroundStyle(UD.text2)
                    Text("root@demo-server:~$ systemctl status nginx")
                        .font(UD.monoTerminal).foregroundStyle(UD.text2)
                }
            }
            Group(label: "圆角 · 阴影") {
                HStack(spacing: 18) {
                    ForEach([("md 8", UD.Radius.md), ("lg 10", UD.Radius.lg), ("xl 12", UD.Radius.xl)], id: \.0) { item in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: item.1)
                                .fill(UD.panelHi)
                                .frame(width: 60, height: 44)
                            Text(item.0).font(UD.monoKbd).foregroundStyle(UD.text3)
                        }
                    }
                    ForEach([("sm", UD.Shadow.sm), ("md", UD.Shadow.md), ("lg", UD.Shadow.lg), ("menu", UD.Shadow.menu)], id: \.0) { item in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: UD.Radius.lg)
                                .fill(UD.panel)
                                .frame(width: 60, height: 44)
                                .udShadow(item.1)
                            Text(item.0).font(UD.monoKbd).foregroundStyle(UD.text3)
                        }
                        .padding(.leading, 6)
                    }
                }
            }
        }
    }

    // MARK: 窗口外框 · Chrome
    private var chromeSection: some View {
        Section(title: "窗口外框 · Chrome", subtitle: "标题栏 / 工具栏 / 侧边栏 / 标签页") {
            Group(label: "红绿灯 · 状态徽章") {
                HStack(spacing: 40) {
                    UDTrafficLights()
                    UDTrafficLights(hovered: true)
                    UDStatusBadge(state: .connected)
                    UDStatusBadge(state: .connecting)
                    UDStatusBadge(state: .disconnected)
                    UDStatusBadge(state: .failed)
                }
            }
            Group(label: "工具栏 Toolbar") {
                UDToolbar.standard(text: $search, onNew: {})
                    .frame(width: 520)
                    .clipShape(RoundedRectangle(cornerRadius: UD.Radius.lg))
                    .overlay(RoundedRectangle(cornerRadius: UD.Radius.lg).strokeBorder(UD.border))
            }
            Group(label: "侧边栏 SidebarRow") {
                VStack(alignment: .leading, spacing: 2) {
                    UDSidebarSectionHeader("视图")
                    UDSidebarRow(systemImage: "square.grid.2x2", label: "所有主机", count: 12, selected: true)
                    UDSidebarRow(systemImage: "clock", label: "最近", count: 4)
                    UDSidebarRow(systemImage: "tag", label: "生产环境", count: 6)
                }
                .frame(width: 224)
            }
            Group(label: "标签页 Tabs") {
                VStack(alignment: .leading, spacing: 12) {
                    UDTabBar {
                        UDPreviewTab(name: "main.go", active: true)
                        UDPreviewTab(name: "README.md")
                        UDPreviewTab(name: "router.go", dirty: true)
                    }
                    UDTabBar {
                        UDTermTab(name: "demo-server", active: true)
                        UDTermTab(name: "api-prod-01")
                    }
                }
            }
        }
    }

    // MARK: 控件 · Controls
    private var controlsSection: some View {
        Section(title: "控件 · Controls", subtitle: "按钮 / 输入框 / 徽章 · Chip · Kbd / 进度") {
            Group(label: "按钮 Button") {
                HStack(spacing: 14) {
                    UDButton(title: "新建主机", style: .primary, systemImage: "plus") {}
                    UDButton(title: "取消", style: .secondary) {}
                    UDButton(title: "了解更多", style: .ghost) {}
                    UDButton(title: "删除", style: .danger) {}
                    UDIconButton(systemImage: "plus") {}
                }
            }
            Group(label: "输入框 Input") {
                HStack(alignment: .top, spacing: 20) {
                    UDTextFieldDemo(label: "主机地址", placeholder: "输入主机地址")
                    UDTextField(label: "主机地址", placeholder: "输入主机地址",
                                text: .constant("root@203.0.113.10"), errorMessage: "无法解析该地址")
                        .frame(width: 240)
                    UDTextFieldDemo(label: "密码", placeholder: "••••••••",
                                    isSecure: true, revealable: true)
                }
            }
            Group(label: "徽章 / Chip / Kbd") {
                HStack(spacing: 28) {
                    UDGroupChip("生产环境")
                    UDCountBadge(12)
                    UDCountBadge(4, accent: true)
                    UDHostDot(color: UD.accent, pulse: true)
                    UDHostDot(color: UD.success, pulse: true)
                    UDKbd("⌘K")
                    UDKeyCombo(["⌘", "⇧", "N"])
                }
            }
            Group(label: "进度 Progress") {
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 12) {
                        UDLinearBar(progress: 0.24)
                        UDLinearBar(progress: 0.62)
                        UDLinearBar(progress: 1.0, color: UD.success)
                        UDIndeterminateBar()
                    }
                    HStack(spacing: 16) {
                        UDRing(progress: 0.30)
                        UDRing(progress: 0.68)
                        UDRing(progress: 0.92, color: UD.success)
                    }
                }
                HStack(spacing: 16) {
                    UDTransferRow(name: "banner.png", progress: 0.72, direction: .up)
                    UDTransferRow(name: "backup-2026.tar.gz", progress: 0.38, direction: .down)
                }
            }
        }
    }

    // MARK: 浮层 · Overlays
    private var overlaysSection: some View {
        Section(title: "浮层 · Overlays", subtitle: "下拉 / 会话 / 指标卡 / 菜单栏") {
            HStack(alignment: .top, spacing: 28) {
                UDSessionsDropdown()
                VStack(spacing: 22) {
                    UDMenu(width: 184, head: "模型", items: [
                        UDMenuItem(label: "claude-sonnet", dotColor: UD.accent, active: true),
                        UDMenuItem(label: "claude-opus", dotColor: UD.accentViolet),
                        UDMenuItem(label: "claude-haiku", dotColor: UD.success),
                    ])
                    UDMenu(width: 184, items: [
                        UDMenuItem(label: "在终端打开", kbd: "↩"),
                        UDMenuItem(label: "拷贝路径", kbd: "⌘C"),
                        .divider(),
                        UDMenuItem(label: "删除", kbd: "⌫", danger: true),
                    ])
                }
                UDMenubarPanel()
            }
            HStack(alignment: .top, spacing: 28) {
                UDMetricsPopover(title: "CPU 与负载",
                                 summary: "CPU 64.0% · 负载 0.42 / 0.51 / 0.48",
                                 color: UD.mCPU, samples: Self.sparkSamples,
                                 cores: [64, 42, 88, 12], showsPointer: true)
                UDMetricsPopover(title: "内存负载",
                                 summary: "1.2 GB / 4.0 GB · 30.0%",
                                 color: UD.mMem, samples: Self.sparkSamples)
            }
            Group(label: "命令面板 · Command Palette") {
                CommandPaletteGalleryDemo()
            }
        }
    }

    // MARK: 对话与状态 · Comms
    private var commsSection: some View {
        Section(title: "对话与状态 · Agent · Footer", subtitle: "对话气泡 / 工具调用 / 输入区 / 遥测状态栏") {
            HStack(alignment: .top, spacing: 28) {
                UDChatMessage(role: .user) {
                    Text("为什么 nginx 偶尔会 502？日志里看不出明显规律。")
                }
                UDChatMessage(role: .assistant) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("先看 worker 进程数与 upstream 配置：")
                        UDCodeChip("nginx -T | grep -E \"worker|upstream\"")
                    }
                }
                UDComposer(text: $composer, width: 300) { UDModelPill("claude-sonnet") }
            }
            Group(label: "工具调用 ToolCall · Cursor 风格审批卡片") {
                VStack(alignment: .leading, spacing: 0) {
                    UDToolCall(
                        command: "grep ' 502 ' /var/log/nginx/access.log | awk '{print $4}' | cut -d: -f2 | sort | uniq -c",
                        status: .done(output: "     2 09\n     3 10\n    47 14\n    51 15\n     4 16")
                    )
                    UDToolCall(
                        label: "运行命令 · 需要确认",
                        command: "for i in $(seq 1 20); do curl -s -o /dev/null -w \"%{http_code} %{time_total}\\n\" http://127.0.0.1:8080/health; done",
                        status: .pending
                    )
                }
                .frame(width: 300)
            }
            Group(label: "遥测状态栏 StatusBar") {
                UDStatusBar()
                    .frame(width: 760)
                    .clipShape(RoundedRectangle(cornerRadius: UD.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: UD.Radius.md).strokeBorder(UD.border))
            }
        }
    }

    // MARK: 品牌 · Brand
    private var brandSection: some View {
        Section(title: "品牌 · Brand", subtitle: "文字标识 / 开屏「星空之上 · 昼夜」（splash.jsx）") {
            Group(label: "文字标识 Wordmark") {
                BrandChip { UDWordmark(size: 46) }
            }
            Group(label: "开屏 Splash · 星空之上 · 昼夜（随外观切换）") {
                HStack(alignment: .top, spacing: 18) {
                    SplashCard(label: "夜") { UDSplash().environment(\.colorScheme, .dark) }
                    SplashCard(label: "昼") { UDSplash().environment(\.colorScheme, .light) }
                }
            }
        }
    }

    // 确定性折线样本（避免在视图体里用随机 / 时间）。
    private static let sparkSamples: [Double] = [
        55, 58, 52, 60, 64, 61, 57, 63, 70, 66, 62, 59, 65, 72, 68, 64, 58, 55, 61, 67,
        63, 60, 66, 71, 64, 58, 54, 60, 66, 62, 57, 63, 69, 65, 60, 56, 62, 68, 64, 60,
    ]
}

// MARK: - 画廊脚手架（仅本文件用）

private struct Section<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(UD.font(15, weight: .semibold)).foregroundStyle(UD.text)
                Text(subtitle).font(UD.caption).foregroundStyle(UD.text3)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Group<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label.uppercased())
                .font(UD.monoKbd)
                .tracking(1.2)
                .foregroundStyle(UD.text4)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UD.Radius.lg).fill(UD.panel))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.lg).strokeBorder(UD.border))
    }
}

private extension DesignKitGallery {
    func swatchRow(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .fill(item.1)
                        .frame(width: 84, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: UD.Radius.md).strokeBorder(UD.border))
                    Text(item.0).font(UD.font(11, weight: .medium)).foregroundStyle(UD.text2)
                }
            }
        }
    }
}

private struct CommandPaletteGalleryDemo: View {
    @State private var query = ""

    private var sections: [CommandPaletteSection] {
        groupCommandPalette([
            CommandPaletteItem(id: "h1", kind: .host, title: "demo-server",
                               detail: "root@203.0.113.10", hint: "连接") {},
            CommandPaletteItem(id: "h2", kind: .host, title: "api-prod-01",
                               detail: "deploy@10.0.4.18", hint: "连接") {},
            CommandPaletteItem(id: "c1", kind: .command, title: "新建主机…",
                               detail: "新建一台主机", hint: "⌘N") {},
            CommandPaletteItem(id: "f1", kind: .file, title: "main.go",
                               detail: "~/src/main.go", hint: "打开") {},
            CommandPaletteItem(id: "s1", kind: .setting, title: "设置 · 终端",
                               detail: "字体、颜色、行距", hint: "↵") {},
        ])
    }

    var body: some View {
        UDCommandPalette(query: $query, sections: sections,
                         selectedID: sections.first?.items.first?.id)
    }
}

/// 品牌元素演示底：文字标识默认近白（恒暗场景用），浅色画廊下也垫一块夜空底。
private struct BrandChip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 22)
            .frame(height: 88)
            .background(RoundedRectangle(cornerRadius: UD.Radius.lg)
                .fill(UD.ColorSpec.hex(0x101012).color()))
    }
}

/// 开屏方向缩放预览卡：按 iPhone 逻辑尺寸 390×844 渲染再整体缩放。
private struct SplashCard<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    private let scale: CGFloat = 0.34

    var body: some View {
        VStack(spacing: 8) {
            content
                .frame(width: 390, height: 844)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 390 * scale, height: 844 * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(UD.border))
            Text(label).font(UD.caption).foregroundStyle(UD.text3)
        }
    }
}

/// 输入框带 @State 绑定的演示包装。
private struct UDTextFieldDemo: View {
    let label: String
    let placeholder: String
    var isSecure = false
    var revealable = false
    @State private var text = ""

    var body: some View {
        UDTextField(label: label, placeholder: placeholder, text: $text,
                    isSecure: isSecure, revealable: revealable)
            .frame(width: 240)
    }
}

#Preview {
    DesignKitGallery()
}
