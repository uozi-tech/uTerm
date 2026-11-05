import UDesignKit
import SwiftUI

/// 远程文件图标：双色文件夹（可带「返回上级」箭头）/ 白纸折角文档 + 语言角标 /
/// 符号链接转向箭头。macOS SFTP 窗口、工作区侧栏、传输 Dock 与 iOS 文件标签共用。
///
/// 自绘矢量，逐路径对齐设计稿 `pages/workspace.jsx` 的 `SftpFileIcon`（24×24 viewBox）：
/// 文件夹后/前片填 `UD.folder1/2`，箭头 `UD.folderArrow`；文档 `UD.docBg` 白纸 +
/// `UD.docLine` 描边 + `UD.docFold` 折角，带类型者叠彩色角标，否则画 `UD.docDetail`
/// 内文线，符号链接叠 `UD.iconTeal` 箭头。`kind` 由 `BrowserFileKind.from` 派生。
///
/// `size` = 图标边长（点），调用方必须显式给：macOS 列表 19、侧栏 16、传输 Dock 15，
/// iOS 26。所有坐标 / 线宽按 `size/24` 缩放，`.scaleEffect` 放大时描边按比例变粗。
///
/// ## 几何按 size 缓存
///
/// 一个文档图标要 4~6 条 `Path`（`docBody` 一条就有 9 段）。列表一屏几十行、滚动时
/// 反复求值，现建全是白建的。几何只取决于 `size`（实际只有寥寥几档），按 size 缓存一份。
struct RemoteFileIcon: View {
    let kind: BrowserFileKind
    var isUp: Bool = false
    let size: CGFloat

    init(kind: BrowserFileKind, isUp: Bool = false, size: CGFloat) {
        self.kind = kind
        self.isUp = isUp
        self.size = size
    }

    var body: some View {
        let g = RemoteFileIconGeometry.cached(size: size)
        return ZStack {
            switch kind {
            case .folder:
                folder(g)
            case .symlink:
                doc(g)
                symlinkBadge(g)
            case .file(_, let tag, let color):
                doc(g)
                if let tag, let color {
                    tagLabel(tag, color, g)
                } else {
                    g.detailLines.stroke(UD.docDetail, style: g.detailStroke)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: 文件夹（后片 folder1 + 前片 folder2 + 可选返回箭头）

    private func folder(_ g: RemoteFileIconGeometry) -> some View {
        ZStack {
            g.folderBack.fill(UD.folder1)
            g.folderFront.fill(UD.folder2)
            if isUp {
                g.folderArrow.stroke(UD.folderArrow, style: g.folderArrowStroke)
            }
        }
    }

    // MARK: 文档（白纸 + 折角）

    private func doc(_ g: RemoteFileIconGeometry) -> some View {
        ZStack {
            g.docBody.fill(UD.docBg)
            g.docBody.stroke(UD.docLine, style: g.docStroke)
            g.docFold.fill(UD.docFold)
            g.docFold.stroke(UD.docLine, style: g.docStroke)
        }
    }

    // MARK: 叠加（符号链接箭头 / 类型角标）

    private func symlinkBadge(_ g: RemoteFileIconGeometry) -> some View {
        ZStack {
            g.symlinkArc.stroke(UD.iconTeal, style: g.symlinkStroke)
            g.symlinkHead.stroke(UD.iconTeal, style: g.symlinkStroke)
        }
    }

    private func tagLabel(_ tag: String, _ color: Color, _ g: RemoteFileIconGeometry) -> some View {
        // 设计稿 rect x6 y12.4 w12 h6.2 rx1.4，文本居中 (12, 15.5)。
        ZStack {
            RoundedRectangle(cornerRadius: g.tagCorner).fill(color)
                .frame(width: g.tagSize.width, height: g.tagSize.height)
            Text(tag)
                .font(.system(size: g.tagFontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x0C1320))
        }
        .position(g.tagCenter)
    }
}

/// 一档 `size` 的全部几何。`RemoteFileIcon` 的行体只查缓存，不再现建 `Path`。
struct RemoteFileIconGeometry {
    let folderBack: Path
    let folderFront: Path
    let folderArrow: Path
    let docBody: Path
    let docFold: Path
    let symlinkArc: Path
    let symlinkHead: Path
    let detailLines: Path

    let folderArrowStroke: StrokeStyle
    let docStroke: StrokeStyle
    let symlinkStroke: StrokeStyle
    let detailStroke: StrokeStyle

    let tagCorner: CGFloat
    let tagSize: CGSize
    let tagFontSize: CGFloat
    let tagCenter: CGPoint

    /// 键是 `size`；实际只有寥寥几档，新档进来自动补。
    private static var cache: [CGFloat: RemoteFileIconGeometry] = [:]

    static func cached(size: CGFloat) -> RemoteFileIconGeometry {
        if let hit = cache[size] { return hit }
        let made = RemoteFileIconGeometry(size: size)
        cache[size] = made
        return made
    }

    private init(size: CGFloat) {
        // 24×24 viewBox → 点。
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size / 24, y: y * size / 24) }
        func w(_ width: CGFloat) -> CGFloat { width * size / 24 }

        var back = Path()
        back.move(to: p(2.5, 7.4))
        back.addQuadCurve(to: p(4.05, 5.85), control: p(2.5, 5.85))   // 左上圆角
        back.addLine(to: p(8.95, 5.85))                              // 顶边
        back.addLine(to: p(10.85, 7.9))                             // 标签斜边
        back.addLine(to: p(20.45, 7.9))
        back.addQuadCurve(to: p(22, 9.45), control: p(22, 7.9))      // 右上圆角
        back.addLine(to: p(22, 18.15))
        back.addQuadCurve(to: p(20.45, 19.7), control: p(22, 19.7))  // 右下圆角
        back.addLine(to: p(4.05, 19.7))
        back.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))  // 左下圆角
        back.closeSubpath()
        folderBack = back

        var front = Path()
        front.move(to: p(2.5, 10.7))
        front.addLine(to: p(21.55, 10.7))
        front.addLine(to: p(21.55, 18.15))
        front.addQuadCurve(to: p(20, 19.7), control: p(21.55, 19.7))
        front.addLine(to: p(4.05, 19.7))
        front.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))
        front.closeSubpath()
        folderFront = front

        var arrow = Path()
        arrow.move(to: p(12, 17.6)); arrow.addLine(to: p(12, 13.5))            // 竖杆
        arrow.move(to: p(9.7, 15.4)); arrow.addLine(to: p(12, 13.1)); arrow.addLine(to: p(14.3, 15.4))
        folderArrow = arrow

        var body = Path()
        body.move(to: p(6.4, 3))
        body.addLine(to: p(12.7, 3))                                 // 顶边
        body.addLine(to: p(18, 8.2))                                // 折角斜边
        body.addLine(to: p(18, 20))
        body.addQuadCurve(to: p(17, 21), control: p(18, 21))         // 右下圆角
        body.addLine(to: p(6.4, 21))
        body.addQuadCurve(to: p(5.4, 20), control: p(5.4, 21))       // 左下圆角
        body.addLine(to: p(5.4, 4))
        body.addQuadCurve(to: p(6.4, 3), control: p(5.4, 3))         // 左上圆角
        body.closeSubpath()
        docBody = body

        var fold = Path()
        fold.move(to: p(12.6, 3.05))
        fold.addLine(to: p(12.6, 7.2))
        fold.addQuadCurve(to: p(13.6, 8.2), control: p(12.6, 8.2))
        fold.addLine(to: p(17.8, 8.2))
        fold.closeSubpath()
        docFold = fold

        var arc = Path()
        arc.move(to: p(9, 18.3)); arc.addLine(to: p(9, 16.1))
        arc.addQuadCurve(to: p(10.7, 14.4), control: p(9, 14.4))
        arc.addLine(to: p(13.3, 14.4))
        symlinkArc = arc

        var head = Path()
        head.move(to: p(11.6, 12.6)); head.addLine(to: p(14.2, 14.4)); head.addLine(to: p(11.6, 16.2))
        symlinkHead = head

        var lines = Path()
        lines.move(to: p(8.2, 12.6)); lines.addLine(to: p(15.8, 12.6))
        lines.move(to: p(8.2, 15.1)); lines.addLine(to: p(15.8, 15.1))
        lines.move(to: p(8.2, 17.6)); lines.addLine(to: p(12.8, 17.6))
        detailLines = lines

        folderArrowStroke = StrokeStyle(lineWidth: w(1.7), lineCap: .round, lineJoin: .round)
        docStroke = StrokeStyle(lineWidth: w(1.1), lineJoin: .round)
        symlinkStroke = StrokeStyle(lineWidth: w(1.6), lineCap: .round, lineJoin: .round)
        detailStroke = StrokeStyle(lineWidth: w(1.2), lineCap: .round)

        tagCorner = w(1.4)
        tagSize = CGSize(width: w(12), height: w(6.2))
        tagFontSize = w(5)
        tagCenter = p(12, 15.5)
    }
}
