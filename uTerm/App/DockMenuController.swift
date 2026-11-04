import AppKit
import SwiftData
import SwiftUI

/// Dock 右键菜单里的自定义项：新建本机终端 + 最近连接。系统把它们排在窗口列表下方。
@MainActor
final class DockMenuController: NSObject {
    struct Server: Equatable {
        let id: UUID
        let title: String
    }

    private let isLocked: @MainActor () -> Bool
    private let recentServers: @MainActor () -> [Server]
    private let onNewLocalShell: @MainActor () -> Void
    private let onOpenServer: @MainActor (UUID) -> Void

    init(
        isLocked: @escaping @MainActor () -> Bool,
        recentServers: @escaping @MainActor () -> [Server],
        onNewLocalShell: @escaping @MainActor () -> Void,
        onOpenServer: @escaping @MainActor (UUID) -> Void
    ) {
        self.isLocked = isLocked
        self.recentServers = recentServers
        self.onNewLocalShell = onNewLocalShell
        self.onOpenServer = onOpenServer
    }

    /// 应用锁定时不给任何自定义项：Dock 菜单在锁屏遮罩之外，主机名不能从这里露出来。
    func makeMenu() -> NSMenu? {
        guard !isLocked() else { return nil }
        let menu = NSMenu()
        let newShell = NSMenuItem(
            title: String(localized: "新建本机终端"),
            action: #selector(newLocalShell),
            keyEquivalent: "")
        newShell.target = self
        menu.addItem(newShell)

        let servers = recentServers()
        guard !servers.isEmpty else { return menu }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "最近连接"), action: nil, keyEquivalent: ""))
        for server in servers {
            let item = NSMenuItem(title: server.title, action: #selector(openServer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = server.id
            menu.addItem(item)
        }
        return menu
    }

    /// 最近连接过的主机，新的在前。
    static func recentServers(in context: ModelContext, limit: Int = 5) -> [Server] {
        var descriptor = FetchDescriptor<ServerProfile>(
            predicate: #Predicate { $0.lastConnectedAt != nil },
            sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let profiles = (try? context.fetch(descriptor)) ?? []
        return profiles.map { profile in
            Server(
                id: profile.id,
                title: ServerChromeTitle.serverTitle(
                    serverName: profile.name.isEmpty ? profile.host : profile.name,
                    groupName: profile.group))
        }
    }

    @objc private func newLocalShell() {
        onNewLocalShell()
    }

    @objc private func openServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onOpenServer(id)
    }
}

/// 「连接这台主机」：更新最近连接时间，再按主机类型开窗口。
@MainActor
enum ServerWindowOpener {
    static func connect(_ profile: ServerProfile, context: ModelContext, openWindow: OpenWindowAction) {
        connect(profile, context: context,
                openSFTP: { openWindow(value: $0) },
                openWorkspace: { openWindow(value: $0) })
    }

    /// `OpenWindowAction` 只有 SwiftUI 环境能给，单测走这个。
    static func connect(_ profile: ServerProfile, context: ModelContext,
                        openSFTP: (SFTPWindowID) -> Void, openWorkspace: (WorkspaceWindowID) -> Void) {
        profile.lastConnectedAt = Date()
        try? context.save()
        // 「仅 SFTP」主机禁用终端会话：任何连接入口都改开 SFTP 浏览。
        if profile.sftpOnly {
            openSFTP(SFTPWindowID(id: UUID(), serverID: profile.id))
        } else {
            openWorkspace(WorkspaceWindowID(serverID: profile.id))
        }
    }
}
