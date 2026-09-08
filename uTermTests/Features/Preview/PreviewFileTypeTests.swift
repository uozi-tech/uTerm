import XCTest
@testable import uTerm

final class PreviewFileTypeTests: XCTestCase {
    func testBlocksArchivesExecutablesMediaAndDocuments() {
        let blocked: [(String, String)] = [
            ("/root/mysql-5.5.5-x86_64.tar.gz", "gz"),
            ("/root/backup.tar", "tar"),
            ("/opt/app.jar", "jar"),
            ("/usr/lib/libcrypto.dylib", "dylib"),
            ("/tmp/CAP.pcap.zst", "zst"),
            ("/srv/media/clip.MP4", "mp4"),
            ("/srv/report.PDF", "pdf"),
            ("/var/lib/app/data.sqlite3", "sqlite3"),
            ("/models/llama.safetensors", "safetensors"),
            ("/etc/ssl/client.p12", "p12"),
            ("/root/.viminfo.swp", "swp"),
        ]
        for (path, ext) in blocked {
            XCTAssertEqual(PreviewFileType.blockedExtension(forPath: path), ext, path)
            XCTAssertFalse(PreviewFileType.isPreviewable(path: path), path)
            XCTAssertEqual(PreviewFileType.unsupportedReason(forPath: path),
                           PreviewFileType.unsupportedMessage, path)
        }
    }

    /// 尾部纯数字段先剥掉，`libssl.so.1.1` 才判得出 `so`。
    func testStripsNumericVersionSuffixes() {
        XCTAssertEqual(PreviewFileType.blockedExtension(forPath: "/root/libncurses.so.5"), "so")
        XCTAssertEqual(PreviewFileType.blockedExtension(forPath: "/usr/lib/libssl.so.1.1"), "so")
        XCTAssertEqual(PreviewFileType.blockedExtension(forPath: "/usr/lib/libz.so.1.2.13"), "so")
    }

    /// 剥数字尾缀不能把正常的轮转日志/文本一起剥没。
    func testRotatedLogsAndPlainTextStayPreviewable() {
        let allowed = [
            "/var/log/nginx/access.log.1",
            "/var/log/syslog",
            "/root/.p10k.zsh",
            "/root/.zshrc",
            "/etc/nginx/nginx.conf",
            "/root/Dockerfile",
            "/root/README.md",
            "/root/config.json",
            "/root/cert.pem",
            "/root/.ssh/id_rsa.pub",
            "/root/1.2.3",
            "/root/noext",
        ]
        for path in allowed {
            XCTAssertNil(PreviewFileType.blockedExtension(forPath: path), path)
            XCTAssertTrue(PreviewFileType.isPreviewable(path: path), path)
            XCTAssertNil(PreviewFileType.unsupportedReason(forPath: path), path)
        }
    }

    /// 内置能解码的图片格式走 `.image` 预览，不该被类型门拦掉。
    func testDecodableImagesRemainPreviewable() {
        for path in ["/root/shot.png", "/root/photo.HEIC", "/root/icon.icns",
                     "/root/favicon.ico", "/root/scan.tiff"] {
            XCTAssertTrue(PreviewFileType.isPreviewable(path: path), path)
            XCTAssertEqual(LanguageDetector.kind(forPath: path), .image, path)
        }
    }

    /// 目录名里的扩展名不能误伤文件本身。
    func testOnlyLastPathComponentMatters() {
        XCTAssertNil(PreviewFileType.blockedExtension(forPath: "/backups/2026.zip/notes.txt"))
        XCTAssertNil(PreviewFileType.blockedExtension(forPath: "/opt/app.jar/README"))
    }
}
