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
                        .foregroundStyle(AppTheme.Palette.textMuted)
                }
            }

            VStack {
                Spacer()
                Text(Self.copyrightString)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Palette.textMuted.opacity(0.7))
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    /// "u" + accent "Term"，font-weight 300, size 24, tracking -0.5。
    /// 注意：Text 拼接必须用 .foregroundColor（返回 Text）；.foregroundStyle
    /// 返回 some View 不可拼接。.tracking 应用在拼接后的整体上才会传到两段。
    private var wordmark: Text {
        (Text("u")
            .font(.system(size: 24, weight: .light))
            .foregroundColor(AppTheme.Palette.textPrimary)
         + Text("Term")
            .font(.system(size: 24, weight: .light))
            .foregroundColor(AppTheme.Palette.accent))
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
        .background(AppTheme.Palette.bgBase)
}
