import AppKit
import SwiftData
import SwiftUI
@testable import uTerm

/// 欢迎窗口（主机 / 快捷命令 / 我的 Mac）与主机表单。
@MainActor
extension UICatalog {
    static var welcome: [UICatalogEntry] {
        let src = "uTerm/Features/Welcome/Views/WelcomeView.swift"
        let size = CGSize(width: 1120, height: 720)
        return [
            UICatalogEntry("欢迎页/主机", source: src, symbol: "WelcomeView", size: size) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(WelcomeView(startupBehaviorGate: StartupBehaviorGate(),
                                                          initialSelection: s.host("prod-web-01").id)))
            },
            UICatalogEntry("欢迎页/主机 · 空态", source: "uTerm/Features/Welcome/Views/EmptyServersState.swift",
                           symbol: "EmptyServersState", size: size) { stage in
                let s = try stage.session(hosts: false)
                return UICatalogRender(s.wrap(WelcomeView(startupBehaviorGate: StartupBehaviorGate())))
            },
            UICatalogEntry("欢迎页/快捷命令", source: "uTerm/Features/Welcome/Views/QuickCommandList.swift",
                           symbol: "QuickCommandList", size: size) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(WelcomeView(startupBehaviorGate: StartupBehaviorGate(),
                                                          initialPane: .quickCommands)))
            },
            UICatalogEntry("欢迎页/我的 Mac", source: src, symbol: "WelcomePane", size: size) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(WelcomeView(startupBehaviorGate: StartupBehaviorGate(),
                                                          initialPane: .remoteMacs)))
            },
            UICatalogEntry("主机表单/新建", .sheet, source: "uTerm/Features/Welcome/Views/ServerFormView.swift",
                           symbol: "ServerFormView", size: CGSize(width: 620, height: 760)) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(ServerFormView(editing: nil)))
            },
            UICatalogEntry("主机表单/编辑 · 跳板机", .sheet, source: "uTerm/Features/Welcome/Views/ServerFormView.swift",
                           symbol: "ServerFormView", size: CGSize(width: 620, height: 760)) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(ServerFormView(editing: s.host("prod-db"))))
            },
        ]
    }
}
