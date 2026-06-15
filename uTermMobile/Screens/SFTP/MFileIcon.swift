import SwiftUI

/// SFTP 文件图标（移植自 macOS `SFTPFileIcon`，逐路径对齐设计稿 `pages/workspace.jsx`
/// 的 `SftpFileIcon`，24×24 viewBox）：双色文件夹 / 白纸折角文档 + 语言角标 / 符号链接箭头。
/// `kind` 由共享的 `BrowserFileKind.from(name:isDirectory:isSymlink:)` 派生。
struct MFileIcon: View {
    let kind: BrowserFileKind
    var isUp: Bool = false
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            switch kind {
            case .folder:
                folder
            case .symlink:
                doc
                symlinkBadge
            case .file(_, let tag, let color):
                doc
                if let tag, let color {
                    tagLabel(tag, color)
                } else {
                    detailLines
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size / 24, y: y * size / 24) }
    private func w(_ width: CGFloat) -> CGFloat { width * size / 24 }

    // MARK: 文件夹
    private var folder: some View {
        ZStack {
            folderBack.fill(M.folder1)
            folderFront.fill(M.folder2)
            if isUp {
                folderArrow.stroke(M.folderArrow,
                    style: StrokeStyle(lineWidth: w(1.7), lineCap: .round, lineJoin: .round))
            }
        }
    }
    private var folderBack: Path {
        var path = Path()
        path.move(to: p(2.5, 7.4))
        path.addQuadCurve(to: p(4.05, 5.85), control: p(2.5, 5.85))
        path.addLine(to: p(8.95, 5.85))
        path.addLine(to: p(10.85, 7.9))
        path.addLine(to: p(20.45, 7.9))
        path.addQuadCurve(to: p(22, 9.45), control: p(22, 7.9))
        path.addLine(to: p(22, 18.15))
        path.addQuadCurve(to: p(20.45, 19.7), control: p(22, 19.7))
        path.addLine(to: p(4.05, 19.7))
        path.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))
        path.closeSubpath()
        return path
    }
    private var folderFront: Path {
        var path = Path()
        path.move(to: p(2.5, 10.7))
        path.addLine(to: p(21.55, 10.7))
        path.addLine(to: p(21.55, 18.15))
        path.addQuadCurve(to: p(20, 19.7), control: p(21.55, 19.7))
        path.addLine(to: p(4.05, 19.7))
        path.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))
        path.closeSubpath()
        return path
    }
    private var folderArrow: Path {
        var path = Path()
        path.move(to: p(12, 17.6)); path.addLine(to: p(12, 13.5))
        path.move(to: p(9.7, 15.4)); path.addLine(to: p(12, 13.1)); path.addLine(to: p(14.3, 15.4))
        return path
    }

    // MARK: 文档
    private var doc: some View {
        let stroke = StrokeStyle(lineWidth: w(1.1), lineJoin: .round)
        return ZStack {
            docBody.fill(M.docBg)
            docBody.stroke(M.docLine, style: stroke)
            docFold.fill(M.docFold)
            docFold.stroke(M.docLine, style: stroke)
        }
    }
    private var docBody: Path {
        var path = Path()
        path.move(to: p(6.4, 3))
        path.addLine(to: p(12.7, 3))
        path.addLine(to: p(18, 8.2))
        path.addLine(to: p(18, 20))
        path.addQuadCurve(to: p(17, 21), control: p(18, 21))
        path.addLine(to: p(6.4, 21))
        path.addQuadCurve(to: p(5.4, 20), control: p(5.4, 21))
        path.addLine(to: p(5.4, 4))
        path.addQuadCurve(to: p(6.4, 3), control: p(5.4, 3))
        path.closeSubpath()
        return path
    }
    private var docFold: Path {
        var path = Path()
        path.move(to: p(12.6, 3.05))
        path.addLine(to: p(12.6, 7.2))
        path.addQuadCurve(to: p(13.6, 8.2), control: p(12.6, 8.2))
        path.addLine(to: p(17.8, 8.2))
        path.closeSubpath()
        return path
    }

    // MARK: 叠加
    private var symlinkBadge: some View {
        let stroke = StrokeStyle(lineWidth: w(1.6), lineCap: .round, lineJoin: .round)
        var arc = Path()
        arc.move(to: p(9, 18.3)); arc.addLine(to: p(9, 16.1))
        arc.addQuadCurve(to: p(10.7, 14.4), control: p(9, 14.4))
        arc.addLine(to: p(13.3, 14.4))
        var head = Path()
        head.move(to: p(11.6, 12.6)); head.addLine(to: p(14.2, 14.4)); head.addLine(to: p(11.6, 16.2))
        return ZStack {
            arc.stroke(M.iconTeal, style: stroke)
            head.stroke(M.iconTeal, style: stroke)
        }
    }
    private func tagLabel(_ tag: String, _ color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: w(1.4)).fill(color)
                .frame(width: w(12), height: w(6.2))
            Text(tag)
                .font(.system(size: w(5), weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hexString: "#0C1320"))
        }
        .position(p(12, 15.5))
    }
    private var detailLines: some View {
        var path = Path()
        path.move(to: p(8.2, 12.6)); path.addLine(to: p(15.8, 12.6))
        path.move(to: p(8.2, 15.1)); path.addLine(to: p(15.8, 15.1))
        path.move(to: p(8.2, 17.6)); path.addLine(to: p(12.8, 17.6))
        return path.stroke(M.docDetail, style: StrokeStyle(lineWidth: w(1.2), lineCap: .round))
    }
}
