import UDesignKit
import SwiftUI

/// 预览区底部状态条。Mode-aware：代码显示语言/编码/未保存；图片显示尺寸；空态显示就绪。
/// Spec 2A §2.9。
struct PreviewStatusRow: View {
    let model: FilePreviewModel

    var body: some View {
        HStack(spacing: 14) {
            if let buf = model.activeBuffer {
                Text(label(for: buf.kind))
                if case .code = buf.kind {
                    Text("UTF-8")
                    Text("LF")
                }
                if buf.isDirty {
                    HStack(spacing: 3) {
                        Circle().fill(UD.warning).frame(width: 6, height: 6)
                        Text("未保存")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("未保存"))
                }
                if case .image = buf.kind, buf.imageSize != .zero {
                    Text("\(Int(buf.imageSize.width))×\(Int(buf.imageSize.height))")
                }
                Spacer()
            } else {
                Text("就绪")
                Spacer()
                Text("\(model.recents.count) 个最近文件")
            }
        }
        .font(UD.mono(10.5))
        .foregroundStyle(UD.text3)
        .padding(.horizontal, 12)
        // 状态条在卡面上、紧贴正文下方，24 高、不铺底色；顶部 1pt 线与正文分开（两侧同为
        // 卡面色）。日间编辑器底与卡同为白，不画这条线时正文直接流进状态条（实机反馈）。
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private func label(for kind: FileKind) -> String {
        switch kind {
        case .code(let l):    return l.isEmpty ? "text" : l
        case .markdown:        return "markdown"
        case .image:           return "image"
        case .plainText:       return "text"
        }
    }
}
