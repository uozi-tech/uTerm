import UDesignKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - 为什么有这个文件
//
// SwiftUI 的常驻动画（`.repeatForever`）会把整个 `NSHostingView` / `UIHostingController`
// 钉在「每帧重跑 render + display list diff」的状态，代价跟**整棵视图树**的大小成正比，
// 而不是跟动画元素的大小成正比。更糟的是它**不看窗口可不可见** —— 窗口在别的 Space、
// app 被隐藏，照样满帧跑。
//
// 2026-09-20 实测（uTerm 1.16.4，2304×1296 @ **120Hz**）：欢迎页里两个 `.repeatForever`
// 呼吸点（选中行 + 详情面板表头）让 app **空载吃 30%+ CPU**、把 WindowServer 顶到
// **61%**，且当时一个窗口都不在可见 Space 上。`sample` 里主线程约 2/3 时间在
// `NSHostingView.layout` → `ViewGraphRootValueUpdater.render` → `DisplayList.ViewUpdater.update`
// → 把一屏 `Text` 全部重新栅格化 → `CATransaction::commit` → `requestUpdate(after:)`
// 的闭环里打转。打开「减弱动态效果」CPU 立刻归零，闭环确认。
//
// （顺带澄清一个当时的错误猜测：文本每帧重栅格化**不是**动态颜色导致的。UD 的颜色
// token 绝大多数是 `static let`，每帧拿到同一实例，`==` 成立。真正的机制是
// `CGDrawingLayer` —— SwiftUI 把未提升成独立 layer 的内容拍平进的那张共享绘制层，
// 动画每帧产出新 display list，这张拍平层里只要有一处变了就整张重画，同层文字陪葬。）
//
// 本文件把这类「永远在动的小装饰」下沉到 Core Animation：插值发生在渲染服务器，
// 主线程每帧 **0 开销**；合成的也只是一个小 layer，而不是重传整窗 backing store；
// 窗口不可见时系统根本不合成它。
//
// 四个图元覆盖了全仓所有常驻动画：
//   `PulseDot`     呼吸状态点（圆点 + 光晕）
//   `BlinkingBar`  闪烁光标（流式输出尾随）
//   `SpinningArc`  旋转弧（连接中转圈）
//   `ShimmerSweep` 流光（Agent「思考中」文字）

// MARK: - 图元 1：呼吸状态点

/// 带呼吸光晕的状态圆点。光晕由 Core Animation 驱动。
///
/// 参数默认值 = 原 `UDHostDot` 的光晕（核心 Ø8 / 光晕 Ø12 / 0.9↔1.1 / 2.4s 往复）。
/// `peakOpacity` 取的是原 SwiftUI 实现里两层 `.opacity()` **相乘后**的实际峰值
/// （如 HostDot 的 `0.18 × 0.18 = 0.0324`），视觉逐参数等价。
struct PulseDot: View {
    /// 圆点与光晕的颜色（同色，光晕靠 `peakOpacity` 压淡）。
    var color: Color = UD.accentDefault
    /// 实心核心点直径。
    var coreSize: CGFloat = 8
    /// 光晕静止直径（动画在此基础上做 `scale`）。
    var haloSize: CGFloat = 12
    /// 光晕缩放区间：从 `lowerBound` 动到 `upperBound`。
    var scale: ClosedRange<CGFloat> = 0.9...1.1
    /// 光晕不透明度峰值，动画从它衰减到 0。
    var peakOpacity: Double = 0.0324
    /// 单程时长。
    var duration: TimeInterval = 2.4
    /// true = 往复呼吸；false = 单向扩散后瞬回（雷达 ping）。
    var autoreverses: Bool = true
    /// 是否呼吸。false 时**根本不创建**那层平台视图，零成本。
    var pulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Reduce Motion：整层撤掉（与原 SwiftUI 实现一致），不是停在某一帧。
            if pulse && !reduceMotion {
                CAMotionShape(
                    color: color,
                    content: .fill(cornerRadius: nil),
                    motion: CAMotion(
                        opacity: .init(from: peakOpacity, to: 0),
                        // 公开参数仍用 `ClosedRange`：光晕天然由小放大，读起来直观。
                        scale: .init(from: scale.lowerBound, to: scale.upperBound),
                        duration: duration,
                        autoreverses: autoreverses,
                        timing: autoreverses ? .easeInEaseOut : .easeOut
                    )
                )
                .frame(width: haloSize, height: haloSize)
                .allowsHitTesting(false)
            }
            Circle()
                .fill(color)
                .frame(width: coreSize, height: coreSize)
        }
        // 外框按核心点算，光晕溢出不占位（与原实现一致：`.frame` 不裁剪）。
        .frame(width: coreSize, height: coreSize)
    }
}

// MARK: - 图元 2：闪烁光标

/// 流式输出尾随的闪烁光标。整条在 `1 ↔ minOpacity` 之间往复。
///
/// Reduce Motion 时常显（不闪），与原 SwiftUI 实现一致。
struct BlinkingBar: View {
    var color: Color = UD.accentDefault
    var width: CGFloat = 4
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 1
    /// 暗态不透明度。
    var minOpacity: Double = 0.15
    var duration: TimeInterval = 0.55

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius).fill(color)
            } else {
                CAMotionShape(
                    color: color,
                    content: .fill(cornerRadius: cornerRadius),
                    motion: CAMotion(
                        opacity: .init(from: 1, to: minOpacity),
                        duration: duration,
                        autoreverses: true,
                        timing: .easeInEaseOut
                    )
                )
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - 图元 3：旋转弧

/// 「连接中」转圈：一段描边圆弧绕中心匀速旋转。
///
/// Reduce Motion 时静置（弧还在，只是不转），与原 SwiftUI 实现一致。
struct SpinningArc: View {
    var color: Color = UD.accentDefault
    var size: CGFloat = 88
    var lineWidth: CGFloat = 3
    /// 弧长占整圈的比例。
    var trim: CGFloat = 0.25
    /// 转一整圈的时长。
    var duration: TimeInterval = 1.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CAMotionShape(
            color: color,
            content: .arc(trim: trim, lineWidth: lineWidth),
            motion: reduceMotion
                ? nil
                : CAMotion(spins: true, duration: duration, autoreverses: false, timing: .linear)
        )
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

// MARK: - 底层：一个 CAShapeLayer + 一段无限循环动画

/// 图元内容。`Equatable` 用于判断要不要重画 path。
enum CAMotionContent: Equatable {
    /// 填充形状。`cornerRadius` 为 nil 时取短边一半（圆 / 胶囊）。
    case fill(cornerRadius: CGFloat?)
    /// 描边圆弧。`trim` 为弧长占整圈的比例。
    case arc(trim: CGFloat, lineWidth: CGFloat)
}

/// 一对「从 → 到」的动画端点。
///
/// 不用 `ClosedRange` —— 它要求 `lowerBound <= upperBound`，而动画端点经常是**反向**的
/// （不透明度 0.3 → 0）。用 `ClosedRange` 写会在构造时直接
/// `Fatal error: Range requires lowerBound <= upperBound`。
struct CAMotionRamp<Value: Equatable>: Equatable {
    var from: Value
    var to: Value
}

/// 一段无限循环动画。`Equatable` 用于「参数没变就不重启动画」—— 否则每次
/// `updateNSView`（父视图任意重绘都会触发）都把动画从头播一遍，看起来像卡顿。
struct CAMotion: Equatable {
    /// 不透明度端点。nil = 不动不透明度。
    var opacity: CAMotionRamp<Double>?
    /// 缩放端点。nil = 不缩放。
    var scale: CAMotionRamp<CGFloat>?
    /// 是否绕中心匀速转整圈。
    var spins: Bool
    var duration: TimeInterval
    var autoreverses: Bool
    var timing: CAMediaTimingFunctionName

    init(opacity: CAMotionRamp<Double>? = nil,
         scale: CAMotionRamp<CGFloat>? = nil,
         spins: Bool = false,
         duration: TimeInterval,
         autoreverses: Bool,
         timing: CAMediaTimingFunctionName) {
        self.opacity = opacity
        self.scale = scale
        self.spins = spins
        self.duration = duration
        self.autoreverses = autoreverses
        self.timing = timing
    }
}

#if canImport(AppKit)
typealias CAMotionBaseView = NSView
#elseif canImport(UIKit)
typealias CAMotionBaseView = UIView
#endif

/// 承载图元的平台视图。只做三件事：按 bounds 画 path、上色、挂动画。
final class CAMotionView: CAMotionBaseView {
    private static let animationKey = "uterm.camotion"

    private let shape = CAShapeLayer()
    private var content: CAMotionContent?
    private var motion: CAMotion??      // 外层 nil = 还没配过；内层 nil = 明确不要动画
    private var resolved: CGColor?

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        #if canImport(AppKit)
        wantsLayer = true
        layer?.masksToBounds = false
        #else
        isUserInteractionEnabled = false
        layer.masksToBounds = false
        #endif
        // 基线全透明：可见度由动画的 fromValue 给；动画一旦被摘掉就自然隐身，
        // 不会在屏幕上留下一个突兀的静止色块。有 opacity 动画时才这样，
        // 纯旋转（无 opacity 动画）的图元在 configure 里会被拨回 1。
        shape.opacity = 0
        platformLayer.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CAMotionView 不从 nib 加载") }

    private var platformLayer: CALayer {
        #if canImport(AppKit)
        return layer!
        #else
        return layer
        #endif
    }

    #if canImport(AppKit)
    override func layout() {
        super.layout()
        syncGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 视图重新入树时 CA 可能已经把动画摘了（layer 离开 layer tree 会丢动画），补挂一次。
        if window != nil { restartAnimation() }
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        syncGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartAnimation() }
    }
    #endif

    func configure(content: CAMotionContent, motion: CAMotion?, color: CGColor) {
        if self.content != content {
            self.content = content
            syncGeometry()
        }
        if resolved != color {
            resolved = color
            applyColor()
        }
        // `motion` 是 `CAMotion??`：只有真的变了才重启动画。
        if self.motion == nil || self.motion! != motion {
            self.motion = .some(motion)
            // 无 opacity 动画的图元（纯旋转）需要自己把基线不透明度拨回来。
            withoutImplicitAnimations { shape.opacity = motion?.opacity == nil ? 1 : 0 }
            restartAnimation()
        }
    }

    /// 几何变更必须关隐式动画，否则 AppKit / UIKit 会给 path、frame 补一段淡入，
    /// 跟我们自己的循环动画打架。
    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func syncGeometry() {
        guard let content, bounds.width > 0, bounds.height > 0 else { return }
        withoutImplicitAnimations {
            shape.frame = bounds
            switch content {
            case .fill(let cornerRadius):
                let radius = cornerRadius ?? min(bounds.width, bounds.height) / 2
                shape.path = CGPath(roundedRect: bounds, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil)
                shape.fillColor = resolved
                shape.strokeColor = nil
                shape.lineWidth = 0
            case .arc(let trim, let lineWidth):
                // 描边按线宽内缩半线宽，弧才不会被 bounds 切掉外沿。
                let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                shape.path = CGPath(ellipseIn: rect, transform: nil)
                shape.fillColor = nil
                shape.strokeColor = resolved
                shape.lineWidth = lineWidth
                shape.lineCap = .round
                shape.strokeStart = 0
                shape.strokeEnd = trim
            }
        }
    }

    private func applyColor() {
        guard let content else { return }
        withoutImplicitAnimations {
            switch content {
            case .fill:  shape.fillColor = resolved
            case .arc:   shape.strokeColor = resolved
            }
        }
    }

    private func restartAnimation() {
        shape.removeAnimation(forKey: Self.animationKey)
        guard let motion = motion ?? nil else { return }

        var animations: [CABasicAnimation] = []
        if let opacity = motion.opacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity.from
            fade.toValue = opacity.to
            animations.append(fade)
        }
        if let scale = motion.scale {
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = scale.from
            zoom.toValue = scale.to
            animations.append(zoom)
        }
        if motion.spins {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            animations.append(spin)
        }
        guard !animations.isEmpty else { return }

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = motion.duration
        group.autoreverses = motion.autoreverses
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: motion.timing)
        // 无限循环本来跑不完；写上是防 CA 在某些时机（窗口重建等）提前收尾后
        // 把属性弹回 model 值。
        group.isRemovedOnCompletion = false
        shape.add(group, forKey: Self.animationKey)
    }
}

/// SwiftUI ↔ 平台视图的薄壳。颜色在 `context.environment` 里解析，
/// 所以深 / 浅切换（`\.colorScheme` 变化）会自动触发 `update` 重新上色。
private struct CAMotionShape {
    let color: Color
    let content: CAMotionContent
    let motion: CAMotion?

    func resolvedColor(_ environment: EnvironmentValues) -> CGColor {
        let c = color.resolve(in: environment)
        return CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                       blue: CGFloat(c.blue), alpha: CGFloat(c.opacity))
    }
}

#if canImport(AppKit)
extension CAMotionShape: NSViewRepresentable {
    func makeNSView(context: Context) -> CAMotionView { CAMotionView(frame: .zero) }

    func updateNSView(_ view: CAMotionView, context: Context) {
        view.configure(content: content, motion: motion,
                       color: resolvedColor(context.environment))
    }
}
#elseif canImport(UIKit)
extension CAMotionShape: UIViewRepresentable {
    func makeUIView(context: Context) -> CAMotionView {
        let view = CAMotionView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: CAMotionView, context: Context) {
        view.configure(content: content, motion: motion,
                       color: resolvedColor(context.environment))
    }
}
#endif

// MARK: - 图元 4：流光

/// 一道从左扫到右的高光带，扫完停顿 `pause` 再来。用 `.mask` 裁成文字形状，就是
/// 「思考中」那种流光文字。渐变的 `locations` 由 CA 插值，主线程每帧零开销。
///
/// Reduce Motion 时不画（底下的文字本身照常显示）。
struct ShimmerSweep: View {
    var color: Color
    var duration: TimeInterval = 1.4
    var pause: TimeInterval = 0.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            ShimmerLayer(color: color, duration: duration, pause: pause)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

final class ShimmerView: CAMotionBaseView {
    private static let animationKey = "uterm.shimmer"

    private let gradient = CAGradientLayer()
    private var color: CGColor?
    private var timing: (duration: TimeInterval, pause: TimeInterval)?

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        #if canImport(AppKit)
        wantsLayer = true
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #endif
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        // 静止时整条在可见区外（左边），动画被摘掉也不会留下一块亮斑。
        gradient.locations = [-0.6, -0.3, 0]
        platformLayer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ShimmerView 不从 nib 加载") }

    private var platformLayer: CALayer {
        #if canImport(AppKit)
        return layer!
        #else
        return layer
        #endif
    }

    #if canImport(AppKit)
    override func layout() {
        super.layout()
        syncFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartAnimation() }
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        syncFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartAnimation() }
    }
    #endif

    func configure(color: CGColor, duration: TimeInterval, pause: TimeInterval) {
        if self.color != color {
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = [color.copy(alpha: 0) ?? color, color, color.copy(alpha: 0) ?? color]
            CATransaction.commit()
        }
        if timing == nil || timing! != (duration, pause) {
            timing = (duration, pause)
            restartAnimation()
        }
    }

    private func syncFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    private func restartAnimation() {
        gradient.removeAnimation(forKey: Self.animationKey)
        guard let timing else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.6, -0.3, 0]
        sweep.toValue = [1, 1.3, 1.6]
        sweep.duration = timing.duration
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 停顿靠「组比扫一遍长」实现：扫完后停在可见区外，等组的剩余时长。
        let group = CAAnimationGroup()
        group.animations = [sweep]
        group.duration = timing.duration + timing.pause
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        gradient.add(group, forKey: Self.animationKey)
    }
}

private struct ShimmerLayer {
    let color: Color
    let duration: TimeInterval
    let pause: TimeInterval

    func resolvedColor(_ environment: EnvironmentValues) -> CGColor {
        let c = color.resolve(in: environment)
        return CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                       blue: CGFloat(c.blue), alpha: CGFloat(c.opacity))
    }
}

#if canImport(AppKit)
extension ShimmerLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerView { ShimmerView(frame: .zero) }

    func updateNSView(_ view: ShimmerView, context: Context) {
        view.configure(color: resolvedColor(context.environment), duration: duration, pause: pause)
    }
}
#elseif canImport(UIKit)
extension ShimmerLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> ShimmerView { ShimmerView(frame: .zero) }

    func updateUIView(_ view: ShimmerView, context: Context) {
        view.configure(color: resolvedColor(context.environment), duration: duration, pause: pause)
    }
}
#endif
