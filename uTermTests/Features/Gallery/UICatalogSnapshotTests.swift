import AppKit
import XCTest
@testable import uTerm

/// 界面画廊出图：把 `UICatalog.all` 每条记录浅 / 深各渲染一张 PNG，外加 `manifest.json`。
///
/// 只落图不断言 —— 设 `UI_GALLERY_OUT=<目录>`（xcodebuild 下写成 `TEST_RUNNER_UI_GALLERY_OUT`）才跑，
/// 否则跳过，不进常规全量。一键入口：`make gallery`（出图 + 拼 HTML）。
///
/// 测试宿主带沙盒，`UI_GALLERY_OUT` 多半写不进去：每张图和清单同时挂成 `XCTAttachment`，
/// `make gallery` 从 xcresult 里导出（`scripts/ui-gallery.py collect`）。写得进去时两份一样。
///
/// - `UI_GALLERY_FILTER=<子串>`：只渲染 ID 含这个子串的记录（逗号分隔多个）。
@MainActor
final class UICatalogSnapshotTests: XCTestCase {

    func testRenderCatalog() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["UI_GALLERY_OUT"] ?? env["TEST_RUNNER_UI_GALLERY_OUT"], !out.isEmpty else {
            throw XCTSkip("设 UI_GALLERY_OUT（xcodebuild 下 TEST_RUNNER_UI_GALLERY_OUT）才出画廊图；入口 make gallery")
        }
        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        let canWrite = (try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)) != nil
            && FileManager.default.isWritableFile(atPath: outDir.path)

        let filterRaw = env["UI_GALLERY_FILTER"] ?? env["TEST_RUNNER_UI_GALLERY_FILTER"] ?? ""
        let filters = filterRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let all = UICatalog.all
        let dupes = Dictionary(grouping: all, by: \.id).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(dupes.isEmpty, "目录里有重复 ID：\(dupes.sorted())")
        let entries = all.filter { e in filters.isEmpty || filters.contains { e.id.contains($0) } }

        let stage = UICatalogStage()
        var shots: [UICatalogRenderer.Shot] = []
        for (i, entry) in entries.enumerated() {
            let shot = await UICatalogRenderer.render(entry, stage: stage) { name, png in
                if canWrite { try? png.write(to: outDir.appendingPathComponent(name)) }
                let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                a.name = name
                a.lifetime = .keepAlways
                add(a)
            }
            print("[ui-gallery] \(i + 1)/\(entries.count) \(entry.id) \(shot.millis)ms\(shot.error.map { " ERROR \($0)" } ?? "")")
            shots.append(shot)
        }
        let manifest = try UICatalogRenderer.manifest(shots)
        if canWrite { try manifest.write(to: outDir.appendingPathComponent("manifest.json")) }
        let a = XCTAttachment(data: manifest, uniformTypeIdentifier: "public.json")
        a.name = "manifest.json"
        a.lifetime = .keepAlways
        add(a)
        print("[ui-gallery] \(shots.count) 条，\(shots.filter { $0.error != nil }.count) 条出错")
    }
}
