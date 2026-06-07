import XCTest
@testable import uTerm

final class LanguageDetectorTests: XCTestCase {

    func test_extensionMap() {
        XCTAssertEqual(LanguageDetector.kind(forPath: "main.swift"), .code(language: "swift"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "main.go"), .code(language: "go"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "main.py"), .code(language: "python"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "app.ts"), .code(language: "typescript"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "config.json"), .code(language: "json"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "app.yaml"), .code(language: "yaml"))
    }

    func test_markdown() {
        XCTAssertEqual(LanguageDetector.kind(forPath: "README.md"), .markdown)
        XCTAssertEqual(LanguageDetector.kind(forPath: "doc.markdown"), .markdown)
    }

    func test_image() {
        XCTAssertEqual(LanguageDetector.kind(forPath: "logo.png"), .image)
        XCTAssertEqual(LanguageDetector.kind(forPath: "photo.JPG"), .image)
        XCTAssertEqual(LanguageDetector.kind(forPath: "anim.gif"), .image)
    }

    func test_byBasename_nginxAndDockerfile() {
        XCTAssertEqual(LanguageDetector.kind(forPath: "/etc/nginx/nginx.conf"), .code(language: "nginx"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "/app/Dockerfile"), .code(language: "dockerfile"))
        XCTAssertEqual(LanguageDetector.kind(forPath: "Dockerfile.prod"), .code(language: "dockerfile"))
    }

    func test_plainTextFallback() {
        XCTAssertEqual(LanguageDetector.kind(forPath: "notes.txt"), .plainText)
        XCTAssertEqual(LanguageDetector.kind(forPath: "no-ext-file"), .plainText)
    }

    func test_grammarId_returnsEmptyString_inSpec2A() {
        // Spec 2A 不带 Tree-sitter 高亮（CodeEditLanguages 被剔出，见 spec §4）；
        // grammarId 保留方法签名但始终返回 ""，供后续 spec 接管。
        XCTAssertEqual(LanguageDetector.grammarId(for: "swift"), "")
        XCTAssertEqual(LanguageDetector.grammarId(for: "unknown"), "")
    }
}
