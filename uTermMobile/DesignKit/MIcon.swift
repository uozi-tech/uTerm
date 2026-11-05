import SwiftUI

/// 设计稿（`m-kit` 的 `Ico` / `shared` 的 `Glyph` / `TabIcon`）里自绘 SVG 图标到
/// SF Symbol 的近似映射。集中一处，屏幕侧只用语义名引用。
enum MGlyph {
    static func symbol(_ name: String) -> String {
        switch name {
        case "spark":      return "sparkles"
        case "parallel":   return "arrow.left.arrow.right"
        case "bolt":       return "bolt.fill"
        case "key":        return "key.fill"
        case "shield":     return "checkmark.shield"
        case "warn":       return "exclamationmark.triangle"
        case "folder-tag": return "folder"
        case "tag":        return "tag"
        case "search":     return "magnifyingglass"
        case "cmd":        return "command"
        case "run":        return "play.fill"
        case "rerun":      return "arrow.clockwise"
        case "trash":      return "trash"
        case "plus":       return "plus"
        case "check":      return "checkmark"
        case "x":          return "xmark"
        case "chev":       return "chevron.right"
        case "chev-down":  return "chevron.down"
        case "back":       return "chevron.left"
        case "copy":       return "doc.on.doc"
        case "download":   return "arrow.down.to.line"
        case "upload":     return "arrow.up.to.line"
        case "import":     return "square.and.arrow.down"
        case "edit":       return "pencil"
        case "term":       return "terminal"
        case "server":     return "server.rack"
        case "lock":       return "lock.fill"
        case "faceid":     return "faceid"
        case "touchid":    return "touchid"
        case "gear":       return "gearshape"
        case "ellipsis":   return "ellipsis"
        case "forward":    return "arrow.left.arrow.right"
        case "info":       return "info.circle"
        case "sort":       return "arrow.up.arrow.down"
        case "split":      return "rectangle.split.2x1"
        case "send":       return "paperplane.fill"
        case "grid":       return "square.grid.2x2"
        case "folder":     return "folder"
        case "refresh":    return "arrow.clockwise"
        case "host":       return "server.rack"
        case "mac":        return "laptopcomputer"
        case "display":    return "display"
        case "keyboard":   return "keyboard"
        case "file":       return "doc"
        case "link":       return "link"
        case "globe":      return "globe"
        case "clock":      return "clock"
        case "person":     return "person"
        case "eye":        return "eye"
        case "eye-off":    return "eye.slash"
        default:           return "circle"
        }
    }
}

/// 设计稿矢量图标的原生等价：SF Symbol + 统一线宽观感。
struct MIcon: View {
    let name: String
    var size: CGFloat = 18
    var color: Color = M.text
    var weight: Font.Weight = .medium

    var body: some View {
        Image(systemName: MGlyph.symbol(name))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
    }
}
