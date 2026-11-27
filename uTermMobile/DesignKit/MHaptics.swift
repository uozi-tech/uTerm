import UIKit

/// 全 App 共用的触感反馈。
///
/// 改前每个按钮 / 行的按压样式各自挂一个 `.sensoryFeedback`（每个视图实例一个反馈生成器、不预热），
/// 在按下那一拍同步触发；不少地方还是现场 `UIImpactFeedbackGenerator(...)` 不 prepare 就震。触感引擎
/// 闲几秒就睡，第一下要现唤醒，和按压动画、随之弹出的面板 / 转场的头一帧挤在同一拍里。这里：
/// - 每种力度只有一个生成器，震完顺手 `prepare()`，接下来几秒内再震不用再唤醒；
/// - 触发挪到下一轮主线程循环，不和这一拍的动画、转场抢时间（差一拍人感觉不到）。
@MainActor
enum MHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    /// 按钮、行按下：轻震。
    static func press(intensity: CGFloat = 0.7) { impact(light, intensity: intensity) }

    /// 长按触发、拖拽开始：中等。
    static func emphasis() { impact(medium, intensity: 1) }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        DispatchQueue.main.async {
            notification.notificationOccurred(type)
            notification.prepare()
        }
    }

    /// 马上要用（比如手指刚按下、还没松开）：先把引擎叫醒。
    static func prepare() { light.prepare() }

    private static func impact(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        DispatchQueue.main.async {
            generator.impactOccurred(intensity: intensity)
            generator.prepare()
        }
    }
}
