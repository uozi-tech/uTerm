import SwiftUI
import WidgetKit

/// 组件扩展的入口：只有一个实时活动，没有桌面小组件。
@main
struct TerminalActivityBundle: WidgetBundle {
    var body: some Widget {
        TerminalActivityWidget()
    }
}
