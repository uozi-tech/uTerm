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
        // 分区方案 v3：状态条在卡面上、紧贴凹槽下方 —— 不铺底色、不画上分隔线，24 高。
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
