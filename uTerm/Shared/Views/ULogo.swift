import UDesignKit
import SwiftUI

/// uTerm 官方品牌 logo（设计稿 05 号 · 星空之上）。
///
/// 资产烘染自 `Resources/Logo/ULogoMark.svg`；accent 烘成品牌色 #3b82f6
/// 与 UI accent (`UD.accent`) 解耦。
///
/// 任意尺寸均从同一 PNG 缩放，@2x 提供 512×512 源像素，足以覆盖 ≤ 256pt 的
/// 显示场景。若未来需要超过 256pt，扩展 imageset 加更大图源即可。
struct ULogo: View {
    /// 显示尺寸（pt）。建议范围 16…256。
    var size: CGFloat = 32

    var body: some View {
        Image("ULogoMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("uTerm")
            .accessibilityAddTraits(.isImage)
    }
}

#Preview {
    HStack(spacing: 16) {
        ULogo(size: 16)
        ULogo(size: 32)
        ULogo(size: 64)
        ULogo(size: 96)
    }
    .padding()
    .background(Color.black)
}
