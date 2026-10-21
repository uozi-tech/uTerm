import AppKit

/// `session-send --secret` 要用户输的东西是什么、给谁。
struct ControlSecretRequest: Sendable {
    let host: String
    /// 会话在跑的命令（nil = 登录 shell）。
    let command: String?
    /// 远端此刻的提示行（`[sudo] password for alice:`）—— 来自真实的 PTY 输出，不是调用方写的。
    let promptLine: String?
    /// 调用方（Agent）自己写的说明。界面上标明出处，不当成 uTerm 的话。
    let purpose: String?
}

/// 向用户要一段秘密输入。返回 nil = 取消 / 超时。抽成协议是给测试替身用。
@MainActor
protocol ControlSecretPrompting: AnyObject {
    func requestSecret(_ request: ControlSecretRequest, timeout: TimeInterval) async -> String?
}

/// 生产实现：一个浮在最前面的小面板，带安全输入框。
///
/// 非模态（`runModal` 会把 MainActor 卡住，其它命令行请求全得等），几台主机同时要密码时
/// 各弹一个、错开摆放。按需后台启动的实例是 `.accessory`，照样能弹窗。
/// 输入的内容只交给调用方写进 PTY，不进日志、不进响应。
@MainActor
final class ControlSecretPanel: ControlSecretPrompting {
    static let shared = ControlSecretPanel()

    private var open: [SecretPromptController] = []

    func requestSecret(_ request: ControlSecretRequest, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let controller = SecretPromptController(request: request, offset: open.count) { [weak self] controller, value in
                self?.open.removeAll { $0 === controller }
                continuation.resume(returning: value)
            }
            open.append(controller)
            controller.show(timeout: timeout)
        }
    }
}

@MainActor
private final class SecretPromptController: NSObject, NSWindowDelegate {
    private let request: ControlSecretRequest
    private let offset: Int
    private let completion: (SecretPromptController, String?) -> Void
    private var panel: NSPanel?
    private let field = NSSecureTextField()
    private var timer: Timer?
    private var finished = false

    init(
        request: ControlSecretRequest,
        offset: Int,
        completion: @escaping (SecretPromptController, String?) -> Void
    ) {
        self.request = request
        self.offset = offset
        self.completion = completion
    }

    func show(timeout: TimeInterval) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "uTerm 命令行请求输入")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let headline = NSTextField(wrappingLabelWithString:
            String(localized: "主机「\(request.host)」上的命令在等你输入"))
        headline.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        stack.addArrangedSubview(headline)

        if let line = request.promptLine, !line.isEmpty {
            stack.addArrangedSubview(Self.mono(line, secondary: false))
        }
        stack.addArrangedSubview(Self.caption(
            String(localized: "命令：") + (request.command ?? String(localized: "登录 shell"))))
        if let purpose = request.purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty {
            stack.addArrangedSubview(Self.caption(String(localized: "请求方的说明：") + purpose))
        }

        field.placeholderString = String(localized: "输入后按回车")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(field)

        stack.addArrangedSubview(Self.caption(String(localized:
            "输入的内容只写进这台主机的终端，不会返回给命令行或 Agent。不认识这个请求就点取消。")))

        let cancel = NSButton(title: String(localized: "取消"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let send = NSButton(title: String(localized: "发送"), target: self, action: #selector(sendClicked))
        send.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, send])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let row = NSStackView(views: [NSView(), buttons])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(row)

        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.center()
        if offset > 0 {
            var origin = panel.frame.origin
            origin.x += CGFloat(offset * 28)
            origin.y -= CGFloat(offset * 28)
            panel.setFrameOrigin(origin)
        }
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    @objc private func sendClicked() {
        finish(field.stringValue)
    }

    @objc private func cancelClicked() {
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        field.stringValue = ""
        panel?.delegate = nil
        panel?.close()
        panel = nil
        completion(self, value)
    }

    private static func mono(_ text: String, secondary: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
