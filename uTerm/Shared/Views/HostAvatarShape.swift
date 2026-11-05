import SwiftUI

/// 主机头像色块的形状（两端共用）：圆角方块，右下角挖掉一个圆，给在线角标留镂空。
///
/// 用路径相减而不是 `.mask` + `.compositingGroup()`：后者每行多一次离屏合成，
/// 欢迎页列表可见行数十行、滚动期间逐帧都要付。镂空也不用「描一圈背景色」——
/// 列表行有选中 / 悬停叠底，描边色永远对不齐。
nonisolated struct HostAvatarShape: Shape {
    var cornerRadius: CGFloat
    /// 镂空圆的直径；0 = 不挖。
    var cutoutDiameter: CGFloat
    /// 镂空圆心相对右下角往外挪的距离（与角标的 offset 一致）。
    var cutoutOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let base = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        guard cutoutDiameter > 0 else { return base }
        let center = CGPoint(x: rect.maxX - cutoutDiameter / 2 + cutoutOffset,
                             y: rect.maxY - cutoutDiameter / 2 + cutoutOffset)
        let hole = Path(ellipseIn: CGRect(x: center.x - cutoutDiameter / 2,
                                          y: center.y - cutoutDiameter / 2,
                                          width: cutoutDiameter,
                                          height: cutoutDiameter))
        return base.subtracting(hole)
    }
}

/// 头像尺寸派生量（两端同一套比例，色块尺寸一变角标跟着缩放）。
nonisolated struct HostAvatarMetrics: Equatable, Sendable {
    let size: CGFloat
    /// 镂空环宽。
    let gap: CGFloat = 2

    var cornerRadius: CGFloat { (size * 0.27).rounded() }
    var badge: CGFloat { (size * 0.3).rounded() }
    /// 角标圆心落在色块右下角再往外挪一点。
    var badgeOffset: CGFloat { (badge * 0.3).rounded() }
    var cutoutDiameter: CGFloat { badge + gap * 2 }
    /// 镂空圆与角标同心：bottomTrailing 对齐后，镂空圆要比角标多挪一个环宽。
    var cutoutOffset: CGFloat { badgeOffset + gap }
}
