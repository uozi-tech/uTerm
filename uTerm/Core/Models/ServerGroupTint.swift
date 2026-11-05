import SwiftUI

/// 组名 → 组色（`ServerGroup.colorHex`）的映射，iOS 与 macOS 的主机列表共用。
/// 无组 / 组不在表里时返回 nil（调用方回退强调色或中性）。
///
/// **用法**：在 body 里用 `colors(for:)` 一趟把分组表解析成字典，行体只做
/// `color(for:colors:)` 一次查表。别回到「每行拿 hex 字典再解析一遍十六进制」——
/// 那是 O(行 × 组) 的，2000 台档的欢迎页列表与 iOS 主机页都吃过这个亏。
enum ServerGroupTint {
    /// 一趟把 `ServerGroup` 表解析成「组名 → Color」，供整屏共用。同名组取第一个。
    static func colors(for groups: [ServerGroup]) -> [String: Color] {
        var out: [String: Color] = [:]
        out.reserveCapacity(groups.count)
        for group in groups where out[group.name] == nil {
            out[group.name] = color(hex: group.colorHex)
        }
        return out
    }

    /// 查表：`colors(for:)` 的结果 + 组名 → 组色（无组 / 无色 → nil）。
    nonisolated static func color(for groupName: String?, colors: [String: Color]) -> Color? {
        guard let groupName, !groupName.isEmpty else { return nil }
        return colors[groupName]
    }

    /// 单个色板 hex → Color（"#RRGGBB" / "RRGGBB"，非法输入回退中性灰 #9aa7b5，见 `groupHexRGB`）。
    nonisolated static func color(hex: String) -> Color {
        let rgb = groupHexRGB(hex)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
