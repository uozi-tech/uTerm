import AgentKit
import AppKit
import SwiftData
import SwiftUI
import UPaneTree
@testable import uTerm

/// 工作区窗口（文件树 | 预览 + 终端 | Agent）。终端是真的 Ghostty surface，后端是 `MockBackend`，
/// 挂上、尺寸停稳之后喂一段写好的输出。
@MainActor
extension UICatalog {
    static var workspace: [UICatalogEntry] {
        let src = "uTerm/Features/Workspace/Views/WorkspaceWindowView.swift"
        return [
            UICatalogEntry("工作区/终端", source: src, symbol: "WorkspaceWindowView", live: true) { stage in
                try await workspaceRender(stage, .init(scripts: [UICatalogTerminalScripts.nginx], inspector: false,
                                                       recentFiles: UICatalogFiles.recents, previewRatio: 0.42))
            },
            // 纯终端窗口（「在终端中打开」）：没有文件侧栏和预览区，只有标签、分屏和状态栏。
            UICatalogEntry("终端窗口/分屏", source: "uTerm/Features/Terminal/Views/TerminalWindowView.swift",
                           symbol: "TerminalWindowView", live: true) { stage in
                try await workspaceRender(stage, .init(scripts: [UICatalogTerminalScripts.claudeCode(cols: 81, rows: 51),
                                                                 UICatalogTerminalScripts.memory],
                                                       split: .horizontal, inspector: false, terminalWindow: true))
            },
            // 手机「窗口模式」看到的就是这个窗口：Mac 把它调成手机画布的大小（iPhone Duo 横握 951×669 点）。
            // iOS 的官网截图（PromoGalleryTests）拿这张图当远程桌面送来的画面。
            UICatalogEntry("终端窗口/手机窗口模式", source: "uTerm/Features/Terminal/Views/TerminalWindowView.swift",
                           symbol: "TerminalWindowView", size: CGSize(width: 951, height: 669), live: true) { stage in
                try await workspaceRender(stage, .init(scripts: [UICatalogTerminalScripts.claudeCode(cols: 120, rows: 41)],
                                                       inspector: false, terminalWindow: true))
            },
            // App Store 截图用的 13 英寸 iPad 竖握画布（1032×1376 点）。竖屏放不下 Claude Code 的录制（按录制时的
            // 行列数排版），用写好的 shell 输出。iPhone 竖握没有这一张：440 点比终端窗口的最小宽度还窄，Mac 调不过去。
            UICatalogEntry("终端窗口/iPad 窗口模式", source: "uTerm/Features/Terminal/Views/TerminalWindowView.swift",
                           symbol: "TerminalWindowView", size: CGSize(width: 1032, height: 1376), live: true) { stage in
                try await workspaceRender(stage, .init(scripts: [UICatalogTerminalScripts.nginx, UICatalogTerminalScripts.memory],
                                                       split: .vertical, inspector: false, terminalWindow: true))
            },
            UICatalogEntry("工作区/文件预览与终端", source: src, symbol: "WorkspaceWindowView", live: true) { stage in
                try await workspaceRender(stage, .init(scripts: [UICatalogTerminalScripts.nginx], inspector: false,
                                                       openFile: "/etc/nginx/nginx.conf", previewRatio: 0.62))
            },
            UICatalogEntry("工作区/AI 助手", source: src, symbol: "WorkspaceWindowView", live: true) { stage in
                try await workspaceRender(stage, .init(scripts: [UICatalogTerminalScripts.disk], inspector: true,
                                                       recentFiles: UICatalogFiles.recents, previewRatio: 0.42, chat: true))
            },
        ]
    }

    struct WorkspaceSetup {
        var host = "prod-web-01"
        var scripts: [String]
        var split: SplitDirection?
        var inspector: Bool
        var sidebar = true
        var openFile: String?
        /// 先打开再关掉这些文件：预览区空着时显示的「最近打开」就有内容（走真的打开流程）。
        var recentFiles: [String] = []
        /// 预览区占中央列的比例（App 默认 0.667）。
        var previewRatio = 0.667
        var chat = false
        /// 渲染成独立终端窗口（`TerminalWindowView`）而不是工作区窗口。
        var terminalWindow = false
    }

    static func workspaceRender(_ stage: UICatalogStage, _ setup: WorkspaceSetup) async throws -> UICatalogRender {
        let s = try stage.session()
        let server = s.host(setup.host)
        let sftp = MockSFTP(tree: UICatalogFiles.tree)
        for (path, text) in UICatalogFiles.blobs {
            try? await sftp.write(path, data: Data(text.utf8))
        }
        let files = FileBrowserModel(testProvider: sftp, startPath: "/etc/nginx", resolvesOwnerNames: false)
        await files.load("/etc/nginx")
        let ws = WorkspaceModel(windowID: nil, fileBrowserModel: files)
        ws.bindDefaultServer(id: server.id, title: server.name)
        ws.openServer(profileID: server.id, title: server.name)
        if let split = setup.split { ws.splitActiveGroup(direction: split) }
        ws.uiState.rightInspectorPresented = setup.inspector
        ws.uiState.leftSidebarVisibility = setup.sidebar ? .all : .detailOnly
        ws.uiState.sidebarWidth = 248
        ws.uiState.inspectorWidth = 380
        ws.uiState.previewTerminalRatio = setup.previewRatio

        // 每个终端标签接一个假后端（已连上）：视图出现时的 `connect(profile:)` 看到已连接就不再真去连。
        let panes = ws.terminalGroups.allTabs.map(\.payload).filter { $0.fileBuffer == nil }
        for pane in panes {
            pane.session.attentionSink = { _ in }
            await pane.session.connect(using: MockBackend())
        }

        if setup.chat {
            let provider = AIProvider(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com",
                                      model: "claude-sonnet-5-5")
            s.context.insert(provider)
            s.defaults.set(provider.id.uuidString, forKey: DefaultsKey.activeProviderID)
            let session = UICatalogChat.diskSession()
            s.context.insert(session)
            try? s.context.save()
            ws.assistantModel.providers = [provider]
            ws.assistantModel.activeProviderID = provider.id
            ws.assistantModel.load(session)
        }

        let view: AnyView = setup.terminalWindow
            ? AnyView(s.wrap(TerminalWindowView(windowID: TerminalWindowID(id: UUID(), serverID: server.id),
                                                catalogModel: ws)))
            : AnyView(s.wrap(WorkspaceWindowView(windowID: WorkspaceWindowID(id: UUID(), serverID: server.id),
                                                 catalogModel: ws)))
        return UICatalogRender(view, after: { _ in
            // 状态栏的遥测：真解析器吃两拍写好的输出（CPU% 要两拍差分）。
            for sample in UICatalogTelemetry.samples {
                await sftp.setExecOutput(sample)
                await ws.telemetryModel.tick()
            }
            for path in setup.recentFiles {
                await ws.filePreviewModel.open(path: path, fileSize: nil, mtime: UICatalogFixtures.now)
                if let tab = ws.filePreviewModel.activeTabID { ws.filePreviewModel.closeTab(tab) }
            }
            if let path = setup.openFile {
                await ws.filePreviewModel.open(path: path, fileSize: nil, mtime: UICatalogFixtures.now)
            }
            // 尺寸停稳之后再喂：影子终端按真实列数排版，不会按默认 80 列折行。
            try? await Task.sleep(for: .milliseconds(400))
            for (pane, script) in zip(panes, setup.scripts) {
                pane.session.feedOutput(text: script)
                let size = pane.session.currentProcessSize
                print("[ui-gallery] term-size \(size.cols)x\(size.rows)")
            }
            try? await Task.sleep(for: .milliseconds(300))
        }, cleanup: {
            ws.dispose()
        })
    }
}

// MARK: - 终端里的内容

/// 只用来定位测试包（`Bundle(for:)`）。
final class UICatalogRecordingAnchor {}

/// 写好的终端输出（带 ANSI 颜色）。只用常见命令的真实输出格式。
enum UICatalogTerminalScripts {
    private static let e = "\u{1B}["
    private static func prompt(_ host: String = "prod-web-01", _ dir: String = "~") -> String {
        "\(e)1;32mdeploy@\(host)\(e)0m:\(e)1;34m\(dir)\(e)0m$ "
    }

    static let nginx: String = {
        var s = "Last login: Fri Nov 20 21:14:07 2026 from 10.0.0.2\r\n"
        s += prompt() + "uptime\r\n"
        s += " 21:30:12 up 4 days,  3:12,  1 user,  load average: 0.42, 0.37, 0.31\r\n"
        s += prompt() + "systemctl status nginx --no-pager | head -6\r\n"
        s += "\(e)1;32m●\(e)0m nginx.service - A high performance web server and a reverse proxy server\r\n"
        s += "     Loaded: loaded (/lib/systemd/system/nginx.service; \(e)1;32menabled\(e)0m; preset: \(e)1;32menabled\(e)0m)\r\n"
        s += "     Active: \(e)1;32mactive (running)\(e)0m since Mon 2026-11-16 18:17:44 UTC; 4 days ago\r\n"
        s += "       Docs: man:nginx(8)\r\n"
        s += "   Main PID: 1123 (nginx)\r\n"
        s += "      Tasks: 5 (limit: 9387)\r\n"
        s += prompt() + "docker ps --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}'\r\n"
        s += "NAMES     IMAGE                  STATUS\r\n"
        s += "api       registry.example.com/api:2.14.0     Up 4 days (healthy)\r\n"
        s += "worker    registry.example.com/worker:2.14.0  Up 4 days (healthy)\r\n"
        s += "redis     redis:7.4-alpine                    Up 12 days\r\n"
        s += prompt() + "tail -n 3 /var/log/nginx/access.log\r\n"
        s += "10.0.0.7 - - [20/Nov/2026:21:29:58 +0000] \"GET /api/orders?page=2 HTTP/1.1\" \(e)32m200\(e)0m 4182\r\n"
        s += "10.0.0.7 - - [20/Nov/2026:21:30:01 +0000] \"POST /api/cart HTTP/1.1\" \(e)32m201\(e)0m 311\r\n"
        s += "10.0.0.9 - - [20/Nov/2026:21:30:04 +0000] \"GET /healthz HTTP/1.1\" \(e)32m200\(e)0m 2\r\n"
        s += prompt()
        return s
    }()

    /// 真的 Claude Code（2.1）在这个终端尺寸下的输出字节，`script` 录的（见 `Recordings/README.md`）。
    /// Claude Code 是全屏界面、按录制时的行列数用绝对坐标排版，所以每个尺寸录一份，喂给同样大小的终端。
    static func claudeCode(cols: Int, rows: Int) -> String {
        let name = "claude-code-\(cols)x\(rows)"
        guard let url = Bundle(for: UICatalogRecordingAnchor.self).url(forResource: name, withExtension: "raw"),
              let data = try? Data(contentsOf: url) else {
            return "缺录制文件 \(name).raw\r\n"
        }
        return prompt() + "claude\r\n" + String(decoding: data, as: UTF8.self)
    }

    static let claude: String = {
        var s = prompt() + "claude\r\n\r\n"
        s += "\(e)38;5;209m✻\(e)0m \(e)1mWelcome to Claude Code\(e)0m\r\n\r\n"
        s += "\(e)2m>\(e)0m nginx 偶尔回 502，帮我看看是怎么回事\r\n\r\n"
        s += "\(e)38;5;141m⏺\(e)0m 先看 nginx 的错误日志。\r\n\r\n"
        s += "\(e)38;5;141m⏺\(e)0m \(e)1mBash\(e)0m(tail -n 40 /var/log/nginx/error.log)\r\n"
        s += "  \(e)2m⎿\(e)0m  connect() failed (111: Connection refused) while connecting to upstream,\r\n"
        s += "     upstream: \"http://127.0.0.1:8080/api/orders\"\r\n\r\n"
        s += "\(e)38;5;141m⏺\(e)0m \(e)1mBash\(e)0m(journalctl -k --since \"1 hour ago\" | grep -i oom)\r\n"
        s += "  \(e)2m⎿\(e)0m  Out of memory: Killed process 41823 (java) total-vm:6.1G\r\n\r\n"
        s += "\(e)38;5;141m⏺\(e)0m 502 的原因找到了：应用进程 21:02 因内存不足被内核杀掉，\r\n"
        s += "  重启前 nginx 连不上 8080。建议把 JVM 的 -Xmx 从 6g 调到 4g，\r\n"
        s += "  或者给这台机器加 2 GB 交换空间。\r\n\r\n"
        s += "\(e)2m" + String(repeating: "─", count: 48) + "\(e)0m\r\n> "
        return s
    }()

    static let memory: String = {
        var s = prompt() + "free -h\r\n"
        s += "               total        used        free      shared  buff/cache   available\r\n"
        s += "Mem:           7.6Gi       \(e)31m7.1Gi\(e)0m       212Mi        12Mi       310Mi       298Mi\r\n"
        s += "Swap:             0B          0B          0B\r\n"
        s += prompt() + "ps aux --sort=-%mem | head -4\r\n"
        s += "USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND\r\n"
        s += "app        43107 38.2 71.4 6391204 5582132 ?    Ssl  21:03  12:41 java -Xmx6g -jar api.jar\r\n"
        s += "redis       1201  0.4  1.2  81244 96512 ?       Ssl  Nov08  41:12 redis-server *:6379\r\n"
        s += "www-data    1124  0.1  0.3  56120 25480 ?       S    Nov16   3:02 nginx: worker process\r\n"
        s += prompt()
        return s
    }()

    static let disk: String = {
        var s = prompt() + "df -h /\r\n"
        s += "Filesystem      Size  Used Avail Use% Mounted on\r\n"
        s += "/dev/vda1        80G   \(e)33m71G\(e)0m  9.0G  \(e)33m89%\(e)0m /\r\n"
        s += prompt() + "du -xh /var --max-depth=2 2>/dev/null | sort -h | tail -4\r\n"
        s += "3.1G\t/var/lib/docker\r\n"
        s += "4.4G\t/var/lib\r\n"
        s += "18G\t/var/log/app\r\n"
        s += "23G\t/var\r\n"
        s += prompt()
        return s
    }()
}

// MARK: - 远程文件

enum UICatalogFiles {
    private static let t = UICatalogFixtures.now

    private static func dir(_ name: String, _ ago: Double) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o040_755, size: nil, modifiedAt: t.addingTimeInterval(-ago),
                    uid: 0, gid: 0, ownerName: "root", groupName: "root")
    }

    private static func file(_ name: String, _ size: UInt64, _ ago: Double, mode: UInt32 = 0o100_644) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: mode, size: size, modifiedAt: t.addingTimeInterval(-ago),
                    uid: 0, gid: 0, ownerName: "root", groupName: "root")
    }

    static let tree: [String: [RemoteEntry]] = [
        "/etc/nginx": [
            dir("conf.d", 86_400 * 4), dir("sites-available", 86_400 * 4), dir("sites-enabled", 86_400 * 4),
            dir("snippets", 86_400 * 90), file("fastcgi_params", 1_007, 86_400 * 300),
            file("mime.types", 5_349, 86_400 * 300), file("nginx.conf", 1_482, 3_600 * 2),
            file("proxy_params", 222, 86_400 * 300), file("uwsgi_params", 636, 86_400 * 300),
        ],
        "/etc/nginx/sites-enabled": [file("api.example.com", 1_903, 3_600 * 2)],
        "/home/deploy": [
            dir(".ssh", 86_400 * 60), dir("releases", 3_600 * 5), file(".bashrc", 3_771, 86_400 * 200),
            file("docker-compose.yml", 2_048, 86_400 * 2), file("deploy.sh", 1_204, 86_400 * 2, mode: 0o100_755),
        ],
    ]

    /// 「最近打开」里的文件（最后一个在最上面）。
    static let recents = [
        "/home/deploy/deploy.sh", "/home/deploy/docker-compose.yml",
        "/etc/nginx/conf.d/upstream.conf", "/etc/nginx/nginx.conf",
    ]

    static let blobs: [String: String] = [
        "/home/deploy/deploy.sh": "#!/usr/bin/env bash\nset -euo pipefail\ndocker compose pull && docker compose up -d\n",
        "/home/deploy/docker-compose.yml": "services:\n  api:\n    image: registry.example.com/api:2.14.0\n",
        "/etc/nginx/conf.d/upstream.conf": "upstream api {\n    server 127.0.0.1:8080 max_fails=3;\n}\n",
        "/etc/nginx/nginx.conf": """
        user www-data;
        worker_processes auto;
        pid /run/nginx.pid;
        include /etc/nginx/modules-enabled/*.conf;

        events {
            worker_connections 1024;
        }

        http {
            sendfile on;
            tcp_nopush on;
            types_hash_max_size 2048;
            server_tokens off;

            include /etc/nginx/mime.types;
            default_type application/octet-stream;

            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_prefer_server_ciphers on;

            access_log /var/log/nginx/access.log;
            error_log /var/log/nginx/error.log;

            gzip on;
            gzip_types text/plain application/json application/javascript text/css;

            upstream api {
                server 127.0.0.1:8080 max_fails=3 fail_timeout=10s;
                keepalive 32;
            }

            include /etc/nginx/conf.d/*.conf;
            include /etc/nginx/sites-enabled/*;
        }

        """,
    ]
}

// MARK: - 状态栏遥测

/// `TelemetryParser.command` 在一台 Ubuntu 上的输出，两拍（CPU% 按两拍的 /proc/stat 差分）。
enum UICatalogTelemetry {
    static var samples: [String] { [sample(idle: 1_843_201, total: 2_201_904), sample(idle: 1_843_296, total: 2_202_031)] }

    private static func sample(idle: Int, total: Int) -> String {
        let user = total - idle - 21_000
        return [
            "__UT_OS__", "Linux",
            "__UT_REL__", "PRETTY_NAME=\"Ubuntu 24.04.1 LTS\"", "NAME=\"Ubuntu\"",
            "__UT_UP__", "357120.44 1402377.10",
            "__UT_LOAD__", "0.42 0.37 0.31 2/311 48211",
            "__UT_STAT__", "cpu  \(user) 412 21000 \(idle) 0 0 0 0 0 0",
            "__UT_NPROC__", "4",
            "__UT_MEM__", "MemTotal:        8131876 kB", "MemFree:          912344 kB",
            "MemAvailable:    5102316 kB",
            "__UT_DISK__", "/dev/vda1 82438832 73318840 9103608 89% /",
            "__UT_TIME__", "\(Int(UICatalogFixtures.now.timeIntervalSince1970))",
            "__UT_END__",
        ].joined(separator: "\n")
    }
}

// MARK: - Agent 对话

enum UICatalogChat {
    /// 一段「磁盘为什么一直涨」的对话：提问 → run_command（已执行）→ 结论。
    @MainActor
    static func diskSession() -> ChatSession {
        let t = UICatalogFixtures.now
        let session = ChatSession(title: "磁盘一直涨", createdAt: t.addingTimeInterval(-300))
        let calls = """
        [{"id":"call_1","name":"run_command","command":"du -xh /var --max-depth=2 2>/dev/null | sort -h | tail -4",\
        "explanation":"看 /var 下哪个目录最大","status":"done","exitCode":0,\
        "output":"3.1G\\t/var/lib/docker\\n4.4G\\t/var/lib\\n18G\\t/var/log/app\\n23G\\t/var"},\
        {"id":"call_2","name":"run_command","command":"ls -lh /var/log/app | tail -3",\
        "explanation":"看日志文件是否在轮转","status":"done","exitCode":0,\
        "output":"-rw-r--r-- 1 app app 6.1G Nov 19 23:59 api.log.2\\n-rw-r--r-- 1 app app 5.8G Nov 20 23:59 api.log.1\\n-rw-r--r-- 1 app app 6.2G Nov 20 21:30 api.log"}]
        """
        let records = [
            ChatMessageRecord(roleRaw: "user", text: "prod-web-01 的磁盘为什么一直在涨？", orderIndex: 0,
                              createdAt: t.addingTimeInterval(-300)),
            ChatMessageRecord(roleRaw: "assistant", text: "我先看看 /var 下哪些目录占得最多。", toolCallsJSON: calls,
                              orderIndex: 1, createdAt: t.addingTimeInterval(-290)),
            ChatMessageRecord(roleRaw: "assistant", text: """
            主要是 **/var/log/app**：18 GB，全是应用日志。

            - `api.log` 每天约 6 GB，按天切了文件，但旧文件没有删除，也没有压缩
            - 磁盘现在用了 89%，照这个速度两天左右会写满

            建议加一条 logrotate 规则：每天轮转、压缩、保留 7 天。要我写好配置并先用 `logrotate -d` 演练一遍吗？
            """, orderIndex: 2, createdAt: t.addingTimeInterval(-280)),
        ]
        session.messages = records
        return session
    }
}
