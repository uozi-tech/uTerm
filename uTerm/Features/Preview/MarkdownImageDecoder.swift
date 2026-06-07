import AppKit
import WebKit

enum MarkdownImageDecoder {
    @MainActor
    static func decode(_ data: Data) async -> NSImage? {
        guard isSVG(data) else {
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
}

@MainActor
private final class SVGSnapshotRenderer: NSObject, WKNavigationDelegate {
    private let data: Data
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var webView: WKWebView?

    init(data: Data) {
        self.data = data
    }

    func render() async -> NSImage? {
        guard let size = SVGMetadata.intrinsicSize(from: data),
              size.width > 0,
              size.height > 0
        else {
            return nil
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size),
                                configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(Self.html(for: data, size: size), baseURL: nil)
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
        continuation?.resume(returning: image)
        continuation = nil
        webView?.navigationDelegate = nil
        webView = nil
    }

    private static func html(for data: Data, size: CGSize) -> String {
        let width = cssNumber(size.width)
        let height = cssNumber(size.height)
        let encoded = data.base64EncodedString()

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
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

    private static func cssNumber(_ value: CGFloat) -> String {
        String(format: "%.3f",
               locale: Locale(identifier: "en_US_POSIX"),
               Double(value))
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
