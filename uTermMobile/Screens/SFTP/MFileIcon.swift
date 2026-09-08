import SwiftUI

/// SFTP 文件图标（移植自 macOS `SFTPFileIcon`，逐路径对齐设计稿 `pages/workspace.jsx`
/// 的 `SftpFileIcon`，24×24 viewBox）：双色文件夹 / 白纸折角文档 + 语言角标 / 符号链接箭头。
/// `kind` 由共享的 `BrowserFileKind.from(name:isDirectory:isSymlink:)` 派生。
///
/// ## 几何按 size 缓存
///
/// 改前 `folderBack` / `docBody` / … 都是**计算属性**：每次求值都现建一条
/// `Path`（`docBody` 一条就有 9 个 `addLine` / `addQuadCurve`），一个文档图标
/// 一次求值要建 4~6 条。SFTP 一屏二十行、滚动时反复求值，全是白建的。
/// 几何只取决于 `size`（实际只有 26 这一档），按 size 缓存一份即可。
struct MFileIcon: View {
    let kind: BrowserFileKind
    var isUp: Bool = false
    var size: CGFloat = 26

    var body: some View {
        let g = MFileIconGeometry.cached(size: size)
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
                    g.detailLines.stroke(M.docDetail, style: g.detailStroke)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: 文件夹
    private func folder(_ g: MFileIconGeometry) -> some View {
        ZStack {
            g.folderBack.fill(M.folder1)
            g.folderFront.fill(M.folder2)
            if isUp {
                g.folderArrow.stroke(M.folderArrow, style: g.folderArrowStroke)
            }
        }
    }

    // MARK: 文档
    private func doc(_ g: MFileIconGeometry) -> some View {
        ZStack {
            g.docBody.fill(M.docBg)
            g.docBody.stroke(M.docLine, style: g.docStroke)
            g.docFold.fill(M.docFold)
            g.docFold.stroke(M.docLine, style: g.docStroke)
        }
    }

    // MARK: 叠加
    private func symlinkBadge(_ g: MFileIconGeometry) -> some View {
        ZStack {
            g.symlinkArc.stroke(M.iconTeal, style: g.symlinkStroke)
            g.symlinkHead.stroke(M.iconTeal, style: g.symlinkStroke)
        }
    }

    private func tagLabel(_ tag: String, _ color: Color, _ g: MFileIconGeometry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: g.tagCorner).fill(color)
                .frame(width: g.tagSize.width, height: g.tagSize.height)
            Text(tag)
                .font(.system(size: g.tagFontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hexString: "#0C1320"))
        }
        .position(g.tagCenter)
    }
}

/// 一档 `size` 的全部几何。`MFileIcon` 的行体只查缓存，不再现建 `Path`。
struct MFileIconGeometry {
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

    /// 实际只有 26 这一档，字典也就一条；键是 `size`，别的档进来自动补。
    private static var cache: [CGFloat: MFileIconGeometry] = [:]

    static func cached(size: CGFloat) -> MFileIconGeometry {
        if let hit = cache[size] { return hit }
        let made = MFileIconGeometry(size: size)
        cache[size] = made
        return made
    }

    private init(size: CGFloat) {
        // 与改前逐字一致的 24×24 viewBox 换算。
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size / 24, y: y * size / 24) }
        func w(_ width: CGFloat) -> CGFloat { width * size / 24 }

        var back = Path()
        back.move(to: p(2.5, 7.4))
        back.addQuadCurve(to: p(4.05, 5.85), control: p(2.5, 5.85))
        back.addLine(to: p(8.95, 5.85))
        back.addLine(to: p(10.85, 7.9))
        back.addLine(to: p(20.45, 7.9))
        back.addQuadCurve(to: p(22, 9.45), control: p(22, 7.9))
        back.addLine(to: p(22, 18.15))
        back.addQuadCurve(to: p(20.45, 19.7), control: p(22, 19.7))
        back.addLine(to: p(4.05, 19.7))
        back.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))
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
        arrow.move(to: p(12, 17.6)); arrow.addLine(to: p(12, 13.5))
        arrow.move(to: p(9.7, 15.4)); arrow.addLine(to: p(12, 13.1)); arrow.addLine(to: p(14.3, 15.4))
        folderArrow = arrow

        var body = Path()
        body.move(to: p(6.4, 3))
        body.addLine(to: p(12.7, 3))
        body.addLine(to: p(18, 8.2))
        body.addLine(to: p(18, 20))
        body.addQuadCurve(to: p(17, 21), control: p(18, 21))
        body.addLine(to: p(6.4, 21))
        body.addQuadCurve(to: p(5.4, 20), control: p(5.4, 21))
        body.addLine(to: p(5.4, 4))
        body.addQuadCurve(to: p(6.4, 3), control: p(5.4, 3))
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
