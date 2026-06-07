import SwiftUI

/// 设置 · 关于 tab。
///
/// 布局：
/// - 居中：ULogo(96) + "uTerm" wordmark (`u` 主色 + `Term` accent) + 版本字符串
/// - 底部：版权（年份自动取当年）
///
/// 版本号读 Info.plist 的 CFBundleShortVersionString + CFBundleVersion；
/// **读不到不回退**——以 Info.plist 为唯一来源，缺字段拼空串（"v ()"）。
struct AboutSettingsView: View {
    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                ULogo(size: 96)
                VStack(spacing: 8) {
                    wordmark
                    Text(Self.versionString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(UD.text3)
                }
            }

            VStack {
                Spacer()
                Text(Self.copyrightString)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3.opacity(0.7))
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    /// "u"(主色) + "Term"(accent)，font-weight light, size 24, tracking -0.5。
    /// 用 AttributedString 分段着色，而非 `Text + Text`：后者的 `+` 在 macOS 26
    /// 弃用，而 `Text("\(...)")` 插值会把内容当成 LocalizedStringKey（污染
    /// xcstrings）。AttributedString 的 per-run 属性（这里是 foregroundColor）
    /// 优先级高于 view modifier，故 .font/.tracking 加在外层 Text 上即对两段统一生效。
    private var wordmark: Text {
        var attributed = AttributedString("u")
        attributed.foregroundColor = UD.text
        var term = AttributedString("Term")
        term.foregroundColor = UD.accent
        attributed.append(term)
        return Text(attributed)
            .font(.system(size: 24, weight: .light))
            .tracking(-0.5)
    }

    // ─── 静态/纯函数：拼装版本与版权字符串 ───────────────────
    // 接受 [String: Any]? / Date 入参以便测试，无回退（spec 决定）。

    static var versionString: String {
        versionString(from: Bundle.main.infoDictionary)
    }

    static func versionString(from info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "v\(short) (\(build))"
    }

    static var copyrightString: String {
        copyrightString(now: Date())
    }

    static func copyrightString(now: Date) -> String {
        let year = Calendar.current.component(.year, from: now)
        return "© \(year) 柚子星云科技（深圳）有限公司"
    }
}

#Preview {
    AboutSettingsView()
        .frame(width: 720, height: 480)
        .background(UD.bg)
}
