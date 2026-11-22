import AppKit
import WebKit

enum MarkdownImageDecoder {
    @MainActor
    static func decode(_ data: Data) async -> NSImage? {
        guard isSVG(data) else {
            // 图来自主机：先看声明的像素尺寸，超过上限不解（`RemoteImageGuard`）。
            guard RemoteImageGuard.admits(data) else { return nil }
            return NSImage(data: data)
        }

        return await SVGSnapshotRenderer(data: data).render() ?? NSImage(data: data)
    }

    nonisolated static func isSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(512)
        guard let text = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return text.contains("<svg")
    }

    /// 把 SVG 放进无网络权限的 HTML 壳。SVG 来自远程主机，即便 Markdown 层只允许
    /// SFTP 路径，SVG 自身仍可通过 `<image href>` / CSS url() 引入第三方资源；CSP
    /// 把 WKWebView 的子资源限制为当前 data image 与内联样式。
    nonisolated static func htmlForSVG(_ data: Data, size: CGSize) -> String {
        let width = cssNumber(size.width)
        let height = cssNumber(size.height)
        let encoded = data.base64EncodedString()

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        html, body {
          margin: 0;
          padding: 0;
          width: \(width)px;
          height: \(height)px;
          overflow: hidden;
          background: transparent;
        }
        img {
          display: block;
          width: \(width)px;
          height: \(height)px;
        }
        </style>
        </head>
        <body><img alt="" src="data:image/svg+xml;base64,\(encoded)"></body>
        </html>
        """
    }

    private nonisolated static func cssNumber(_ value: CGFloat) -> String {
        String(format: "%.3f",
               locale: Locale(identifier: "en_US_POSIX"),
               Double(value))
    }
}

@MainActor
private final class SVGSnapshotRenderer: NSObject, WKNavigationDelegate {
    /// 渲染挂起的兜底超时：导航卡死时仍能 resume continuation，避免泄漏
    /// renderer + WKWebView。
    private static let renderTimeout: Duration = .seconds(5)

    private let data: Data
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    /// 一次性闸：保证 continuation 恰好 resume 一次（超时与导航回调互斥）。
    private var didFinish = false

    init(data: Data) {
        self.data = data
    }

    func render() async -> NSImage? {
        guard let declared = SVGMetadata.intrinsicSize(from: data),
              declared.width > 0,
              declared.height > 0
        else {
            return nil
        }
        // SVG 来自主机：`width="100000"` 会让 WebView 和快照大到把 App 撑死，按像素上限缩（保持宽高比）。
        let size = RemoteImageGuard.fittedSize(declared, maxLongEdge: 4096)

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size),
                                configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            scheduleTimeout()
            webView.loadHTMLString(MarkdownImageDecoder.htmlForSVG(data, size: size),
                                   baseURL: nil)
        }
    }

    private func scheduleTimeout() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.renderTimeout)
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForImageThenSnapshot(webView)
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(nil)
    }

    private func waitForImageThenSnapshot(_ webView: WKWebView) {
        let script = """
        new Promise(resolve => {
          const image = document.images[0];
          if (!image) {
            resolve(false);
          } else if (image.complete) {
            resolve(true);
          } else {
            image.onload = () => resolve(true);
            image.onerror = () => resolve(false);
          }
        });
        """

        webView.evaluateJavaScript(script) { [weak self, weak webView] _, _ in
            guard let self, let webView else { return }
            self.snapshot(webView)
        }
    }

    private func snapshot(_ webView: WKWebView) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.afterScreenUpdates = true

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            self?.finish(image)
        }
    }

    private func finish(_ image: NSImage?) {
        // 一次性：超时兜底与导航回调可能竞争，只允许首个 resume 生效。
        guard !didFinish else { return }
        didFinish = true

        timeoutTask?.cancel()
        timeoutTask = nil

        let continuation = self.continuation
        self.continuation = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        continuation?.resume(returning: image)
    }

}

private enum SVGMetadata {
    static func intrinsicSize(from data: Data) -> CGSize? {
        let parserDelegate = SVGMetadataParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        _ = parser.parse()
        return parserDelegate.size
    }
}

private final class SVGMetadataParser: NSObject, XMLParserDelegate {
    private(set) var size: CGSize?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName.lowercased() == "svg" else { return }

        if let width = Self.length(attributeDict["width"]),
           let height = Self.length(attributeDict["height"]) {
            size = CGSize(width: width, height: height)
        } else {
            size = Self.viewBoxSize(attributeDict["viewBox"])
        }

        parser.abortParsing()
    }

    private static func length(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("%") else { return nil }

        let number = trimmed.prefix { character in
            character.isNumber || character == "." || character == "-" || character == "+"
        }
        guard let parsed = Double(number), parsed > 0 else { return nil }
        return CGFloat(parsed)
    }

    private static func viewBoxSize(_ value: String?) -> CGSize? {
        guard let value else { return nil }
        let parts = value
            .split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            .compactMap { Double($0) }
        guard parts.count == 4,
              parts[2] > 0,
              parts[3] > 0
        else {
            return nil
        }
        return CGSize(width: parts[2], height: parts[3])
    }
}
