import XCTest
@testable import uTerm

/// 设置清单（`SettingsCatalog`）的对账：同步键两端入口、键名都在 `DefaultsKey` 表里、分区表钉死。
@MainActor
final class SettingsCatalogTests: XCTestCase {

    // MARK: - 同步键

    /// 每个同步键要么两端都有设置入口，要么在 `syncedKeyExemptions` 里写明为什么没有。
    func testEverySyncedKeyHasBothEntriesOrAnExemption() {
        let keysWithBothEntries = Set(SettingsCatalog.items
            .filter { $0.platforms == .both }
            .compactMap(\.key))
        var missing: [String] = []
        for key in SharedPreferencesSync.syncedKeys
        where !keysWithBothEntries.contains(key) && SettingsCatalog.syncedKeyExemptions[key] == nil {
            missing.append(key)
        }
        XCTAssertTrue(missing.isEmpty, "同步键既没有两端入口、也没写豁免理由：\(missing.sorted())")
    }

    /// 豁免只给同步键，且不和「两端都有入口」重叠——否则豁免表会悄悄过期。
    func testExemptionsAreSyncedKeysWithoutBothEntries() {
        let synced = Set(SharedPreferencesSync.syncedKeys)
        let keysWithBothEntries = Set(SettingsCatalog.items.filter { $0.platforms == .both }.compactMap(\.key))
        for (key, reason) in SettingsCatalog.syncedKeyExemptions {
            XCTAssertTrue(synced.contains(key), "\(key) 不在同步清单里，不需要豁免")
            XCTAssertFalse(keysWithBothEntries.contains(key), "\(key) 两端已有入口，豁免过期了")
            XCTAssertFalse(reason.isEmpty, "\(key) 的豁免理由为空")
        }
    }

    /// 清单里标了「同步」的条目，键必须真在同步清单里；反之亦然。
    func testSyncScopeMatchesSyncManifest() {
        let synced = Set(SharedPreferencesSync.syncedKeys)
        for item in SettingsCatalog.items {
            guard let key = item.key else {
                XCTAssertNotEqual(item.syncScope, .synced, "\(item.id) 标了同步却没有键")
                continue
            }
            XCTAssertEqual(item.syncScope == .synced, synced.contains(key),
                           "\(item.id) 的 syncScope 与 SharedPreferencesSync 清单不一致")
        }
    }

    // MARK: - 键名

    /// 清单引用的每个键都是 `DefaultsKey` 表里的常量值（从源码读，与 `DefaultsKeyTests` 同法）。
    func testEveryCatalogKeyIsADefaultsKeyConstant() throws {
        let source = try String(contentsOf: DefaultsKeyLintTests.repoRoot
            .appendingPathComponent("uTerm/Core/Preferences/DefaultsKey.swift"), encoding: .utf8)
        let declared = Set(source.matches(of: /static let \w+ = "([^"]+)"/).map { String($0.output.1) })
        XCTAssertGreaterThan(declared.count, 40, "夹具失效：应能从键名表读到四十多个常量")
        for item in SettingsCatalog.items {
            guard let key = item.key else { continue }
            XCTAssertTrue(declared.contains(key), "\(item.id) 引用的键 \(key) 不在 DefaultsKey 里")
        }
        for key in SettingsCatalog.syncedKeyExemptions.keys {
            XCTAssertTrue(declared.contains(key), "豁免表里的键 \(key) 不在 DefaultsKey 里")
        }
    }

    func testItemIDsAreUnique() {
        let ids = SettingsCatalog.items.map(\.id)
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "清单 id 重复：\(duplicates.sorted())")
    }

    /// 条目的入口平台不能超出它所在分区的可用平台。
    func testItemPlatformsFitSectionAvailability() {
        for item in SettingsCatalog.items {
            for platform in [SettingsPlatform.macOS, .iOS] where item.platforms.includes(platform) {
                XCTAssertTrue(item.section.availability.includes(platform),
                              "\(item.id) 在 \(platform) 有入口，但分区 \(item.section) 不在该端")
            }
        }
    }

    // MARK: - 分区

    /// rawValue 存在 `settingsTabSelection` 里，钉死。
    func testSectionRawValuesArePinned() {
        XCTAssertEqual(SettingsSection.allCases.map(\.rawValue), [
            "general", "appearance", "terminal", "providers", "connection", "security",
            "sync", "remote", "cli", "diagnostics", "about",
        ])
    }

    func testSectionSymbolsAreDistinct() {
        let symbols = SettingsSection.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "分区图标重复：\(symbols)")
    }

    func testSectionTitlesAreDistinctAndNonEmpty() {
        let titles = SettingsSection.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertFalse(titles.contains(""))
    }

    func testMacOnlySections() {
        XCTAssertEqual(SettingsSection.allCases.filter { $0.availability == .macOS }, [.general, .cli])
    }
}
