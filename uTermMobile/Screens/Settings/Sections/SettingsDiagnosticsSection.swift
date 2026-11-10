import SwiftUI

/// 设置 › 诊断：日志等级（与 Mac 同步，共享的 `AppLogger` 在 iOS 上同样按它过滤）。
/// Debug 构建另有「布局诊断」开关。
struct SettingsDiagnosticsSection: View {
    @AppStorage(DefaultsKey.logLevel) private var logLevelRaw = LogLevel.info.rawValue

    private var logLevel: Binding<LogLevel> {
        $logLevelRaw.rawValue(LogLevel.self, default: .info)
    }

    var body: some View {
        MInsetGroup(header: "诊断", footer: LogLevel.settingsHint) {
            MInsetRow(icon: "diag", label: "日志等级", last: true,
                      trailing: AnyView(
                          MMenu {
                              ForEach(LogLevel.allCases) { level in
                                  Button(level.localizedLabel) { logLevel.wrappedValue = level }
                              }
                          } label: {
                              HStack(spacing: 4) {
                                  Text(logLevel.wrappedValue.localizedLabel)
                                      .font(M.sans(15)).foregroundStyle(M.text2)
                                  MIcon(name: "chev-down", size: 11, color: M.text4)
                              }
                          }))
        }
        #if DEBUG
        DebugLayoutDiagnosticsGroup()
        DebugGhosttyTrialGroup()
        #endif
    }
}

#if DEBUG
/// 仅 Debug 构建：布局诊断浮层开关（见 MLayoutDiagnostics）。
private struct DebugLayoutDiagnosticsGroup: View {
    @AppStorage(MLayoutDiagnostics.key) private var layoutDiagnostics = false

    var body: some View {
        MInsetGroup(header: "调试", footer: "在屏幕左下角显示安全区、状态栏保留区与终端视图几何，供截图排查布局。仅 Debug 构建可见。") {
            MInsetRow(label: "布局诊断", last: true,
                      trailing: AnyView(MSwitch(on: $layoutDiagnostics)))
        }
    }
}

/// 仅 Debug 构建、Ghostty 评估分支临时（不进 main）：新开的终端标签改用 GhosttyKit，给人比手感（测量门 M16）。
private struct DebugGhosttyTrialGroup: View {
    @AppStorage(DefaultsKey.debugGhosttyTrial) private var ghosttyTrial = false
    @AppStorage(DefaultsKey.debugGhosttyFreeRenderer) private var freeRenderer = false
    @AppStorage(DefaultsKey.debugGhosttyOwnScrollPhysics) private var ownScrollPhysics = false
    @AppStorage(DefaultsKey.debugGhosttyProgramMomentum) private var programMomentum = 50

    var body: some View {
        MInsetGroup(header: "引擎试用", footer: "打开后，之后新开的终端标签由 GhosttyKit 绘制（已开着的标签不变）。用来和 SwiftTerm 比滚动、选区、键盘的手感。「渲染不同步」是第六轮的做法（主线程不再跟着重画），关着是第五轮的做法，切换立即生效，用来比滚动时糊不糊。「自写滚动物理」是第九轮的拖动 / 惯性 / 回弹，关着（默认）单指滚动交给系统的 UIScrollView，下一次按下起生效。「全屏程序里的惯性」管 Claude 全屏界面这类抓着鼠标的程序：松手后接着滚多远，「远」和普通滚动一样远，「中」一半，「近」四分之一，立即生效。仅 Debug 构建可见。") {
            MInsetRow(label: "Ghostty 试用",
                      trailing: AnyView(MSwitch(on: $ghosttyTrial)))
            MInsetRow(label: "渲染不同步（第六轮）",
                      trailing: AnyView(MSwitch(on: $freeRenderer)))
            MInsetRow(label: "自写滚动物理（第九轮）",
                      trailing: AnyView(MSwitch(on: $ownScrollPhysics)))
            MInsetRow(label: "全屏程序里的惯性", last: true,
                      trailing: AnyView(MSegmented(items: [(25, "近"), (50, "中"), (100, "远")], selection: $programMomentum)
                          .frame(width: 150)))
        }
        .onChange(of: freeRenderer) { GhosttyTrial.applyRendererMode() }
        .onChange(of: ownScrollPhysics) { GhosttyTrial.applyRendererMode() }
        .onChange(of: programMomentum) { GhosttyTrial.applyRendererMode() }
    }
}
#endif
