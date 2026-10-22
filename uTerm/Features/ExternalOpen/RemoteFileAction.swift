import AppKit
import UDesignKit
import SwiftUI
import UniformTypeIdentifiers

/// 远端文件的四个动作——**全 app 只用这一套叫法、图标与先后顺序**（侧栏 / 独立 SFTP
/// 窗口右键、检视器、预览区「无法预览」页、预览标签右键、双击被拦的提示框）：
///
/// - 预览：在 uTerm 内置编辑器里看 / 改，⌘S 存回远端。只有工作区有（独立 SFTP 窗口没有编辑器）。
/// - 打开：用本机应用打开——数据库交给 uTable（远端直连），其余用记住的 / 系统默认应用，
///   **保存后自动上传**（`ExternalOpenCoordinator`）。
/// - 打开方式 ▸：同「打开」，但指定应用。
/// - 下载…：另存一份到本地，之后不再同步。
///
/// 文案用 `String(localized:)`，保证会被抽进 `Localizable.xcstrings`。
nonisolated enum RemoteFileAction: CaseIterable {
    case preview, open, openWith, download

    var title: String {
        switch self {
        case .preview:  String(localized: "预览")
        case .open:     String(localized: "打开")
        case .openWith: String(localized: "打开方式")
        case .download: String(localized: "下载…")
        }
    }

    var systemImage: String {
        switch self {
        case .preview:  "eye"
        case .open:     "arrow.up.forward.app"
        case .openWith: "square.grid.2x2"
        case .download: "arrow.down.circle"
        }
    }

    var help: String {
        switch self {
        case .preview:  String(localized: "在内置编辑器中查看和编辑，⌘S 保存回服务器")
        case .open:     String(localized: "用本机应用打开，保存后自动上传回服务器")
        case .openWith: String(localized: "选择用哪个应用打开，保存后自动上传回服务器")
        case .download: String(localized: "另存一份到本地，之后不再同步")
        }
    }
}

/// 「打开方式 ▸」里的一项。
struct OpenWithChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let route: ExternalOpenCoordinator.Route
    /// 应用图标（「其他…」没有）。
    let applicationURL: URL?
}

/// 「打开方式 ▸」的候选：uTable（数据库且本机 uTable 支持交接时）→ 系统默认应用 →
/// 记住的应用 → 其余能打开这类文件的应用（按名字排，最多 8 个）→「其他…」。
@MainActor
enum OpenWithChoices {
    static let maxOtherApplications = 8

    static func choices(forPath path: String,
                        preference: ExternalAppPreference = ExternalAppPreference()) -> [OpenWithChoice] {
        var result: [OpenWithChoice] = []
        if SQLiteFileDetector.isCandidate(path: path), UTableHandoff.isAvailable {
            result.append(OpenWithChoice(
                id: "utable", title: "uTable", route: .uTable,
                applicationURL: NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: UTableHandoff.bundleIdentifier)))
        }

        // 按应用路径和显示名双重去重：同一个应用常装在两处（/Applications 与
        // ~/Applications、App Store 版与官网版），菜单里出现两个同名项没法分辨。
        var seen = Set<String>()
        var seenNames = Set<String>()
        func isNew(_ app: URL) -> Bool {
            seen.insert(app.path).inserted && seenNames.insert(displayName(app)).inserted
        }
        let type = contentType(forPath: path)
        if let type, let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: type) {
            _ = isNew(defaultApp)
            result.append(OpenWithChoice(
                id: defaultApp.path,
                title: String(localized: "\(displayName(defaultApp))（默认）"),
                route: .application(defaultApp), applicationURL: defaultApp))
        }
        if let remembered = preference.application(forPath: path), isNew(remembered) {
            result.append(OpenWithChoice(
                id: remembered.path, title: displayName(remembered),
                route: .application(remembered), applicationURL: remembered))
        }
        if let type {
            let others = NSWorkspace.shared.urlsForApplications(toOpen: type)
                .sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
                .filter { isNew($0) }
                .prefix(maxOtherApplications)
            for app in others {
                result.append(OpenWithChoice(
                    id: app.path, title: displayName(app),
                    route: .application(app), applicationURL: app))
            }
        }
        result.append(OpenWithChoice(
            id: "other", title: String(localized: "其他…"),
            route: .chooseApplication, applicationURL: nil))
        return result
    }

    /// 「打开」会交给谁——给按钮下方的说明行用。
    static func openTargetDescription(forPath path: String,
                                      preference: ExternalAppPreference = ExternalAppPreference()) -> String {
        if SQLiteFileDetector.isCandidate(path: path), UTableHandoff.isAvailable {
            return String(localized: "将用 uTable 打开，改动由 uTable 自动保存回服务器")
        }
        if let remembered = preference.application(forPath: path) {
            return String(localized: "将用 \(displayName(remembered)) 打开，保存后自动上传回服务器")
        }
        if let type = contentType(forPath: path),
           let app = NSWorkspace.shared.urlForApplication(toOpen: type) {
            return String(localized: "将用 \(displayName(app)) 打开，保存后自动上传回服务器")
        }
        return String(localized: "将让你选择一个应用来打开，保存后自动上传回服务器")
    }

    static func contentType(forPath path: String) -> UTType? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    static func displayName(_ application: URL) -> String {
        let name = FileManager.default.displayName(atPath: application.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// 「打开方式」的菜单项（子菜单与下拉按钮共用）。候选在菜单展开时才算
/// （`Menu` 的内容惰性求值）。
private struct OpenWithMenuItems: View {
    let path: String
    let onChoose: (ExternalOpenCoordinator.Route) -> Void

    var body: some View {
        let choices = OpenWithChoices.choices(forPath: path)
        ForEach(choices) { choice in
            if choice.route == .chooseApplication { Divider() }
            Button {
                onChoose(choice.route)
            } label: {
                if let app = choice.applicationURL {
                    Label {
                        Text(verbatim: choice.title)
                    } icon: {
                        Image(nsImage: Self.icon(app))
                    }
                } else {
                    Text(verbatim: choice.title)
                }
            }
        }
    }

    private static func icon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// 「打开方式 ▸」子菜单（右键菜单里用）。
struct OpenWithMenu: View {
    let path: String
    let onChoose: (ExternalOpenCoordinator.Route) -> Void

    var body: some View {
        Menu {
            OpenWithMenuItems(path: path, onChoose: onChoose)
        } label: {
            Label(RemoteFileAction.openWith.title, systemImage: RemoteFileAction.openWith.systemImage)
        }
    }
}

/// 「打开方式」下拉按钮（与 `UDButton` 并排摆放时用）。
///
/// 系统 `Menu` 的按钮样式按 AppKit 控件尺寸画，比 `UDButton` 矮一截、底色也不同；
/// 这里隐藏系统外观，按 `UDButton(style: .secondary)` 的度量自绘标签：32 高、14 横向
/// 内边距、`UD.Radius.md` 圆角、`UD.control` 字体、`uw04` 底 / hover `panelHover`。
struct OpenWithMenuButton: View {
    let path: String
    let onChoose: (ExternalOpenCoordinator.Route) -> Void
    var height: CGFloat = 32
    @State private var hovering = false

    var body: some View {
        Menu {
            OpenWithMenuItems(path: path, onChoose: onChoose)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: RemoteFileAction.openWith.systemImage)
                Text(RemoteFileAction.openWith.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.leading, 2)
            }
            .font(UD.control)
            .foregroundStyle(hovering ? UD.text : UD.text2)
            .frame(height: height)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                    .fill(hovering ? UD.panelHover : UD.uw04)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// 预览区 / 预览标签右键这类手里没有 model 的地方，经 `.remoteFileCommand` 通知把动作
/// 交给所在窗口执行（`ExternalOpenWindowBinding` 接收，只在 key window 上生效）。
enum RemoteFileCommand {
    static let userInfoKey = "command"

    case open(path: String, route: ExternalOpenCoordinator.Route)
    case download(path: String, size: Int64?)

    @MainActor
    func post() {
        NotificationCenter.default.post(
            name: .remoteFileCommand, object: nil, userInfo: [Self.userInfoKey: self])
    }
}

/// 「下载…」：问保存位置，然后进 `FileBrowserModel` 的传输队列（状态栏 Dock 显示进度）。
/// 所有入口的下载都走这里，行为一致。
@MainActor
enum RemoteFileDownload {
    static func saveAs(remotePath: String, size: Int64?, using model: FileBrowserModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (remotePath as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await model.downloadWithProgress(remotePath: remotePath, size: size, to: url) }
    }
}
