import Foundation
import Observation

/// Owns the allow-listed scalar preferences stored locally in UserDefaults, and
/// replicates them over two channels that share one clock:
///
/// - **iCloud KVS（保底）**：`NSUbiquitousKeyValueStore`，后台自动、跨网络。UserDefaults
///   本身是 bundle 内的，靠它把标量偏好带到同一 iCloud 命名空间。
/// - **局域网**：`LANSyncCoordinator` 导出完整偏好并由 Mac 权威覆盖。
///
/// iCloud 继续使用 key 级 last-write-wins；LAN 导入走独立的覆盖入口，不发布到 KVS。
/// 设备本地的安全状态与窗口 / 会话状态刻意不在清单内。
@MainActor @Observable
final class SharedPreferencesSync {
    private enum ValueKind {
        case string
        case bool
        case integer
    }

    fileprivate enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case integer(Int)

        var object: Any {
            switch self {
            case .string(let value): return value
            case .bool(let value): return value
            case .integer(let value): return value
            }
        }
    }

    private struct Definition {
        let key: String
        let kind: ValueKind
        let defaultValue: Value
        let legacyKeys: [String]
    }

    /// Keep this list explicit. A UserDefaults key is not shared merely because
    /// it exists: window state, app lock, and other device-specific values must
    /// not unexpectedly overwrite another device.
    private static let definitions: [Definition] = [
        Definition(key: "appearancePreference", kind: .string, defaultValue: .string("system"), legacyKeys: []),
        Definition(key: "appLanguage", kind: .string, defaultValue: .string("system"), legacyKeys: []),
        Definition(key: "accentColor", kind: .string, defaultValue: .string("blue"), legacyKeys: []),
        Definition(key: "startupBehavior", kind: .string, defaultValue: .string("welcome"), legacyKeys: []),
        Definition(key: "restoreTerminalSession", kind: .bool, defaultValue: .bool(true), legacyKeys: []),
        Definition(key: "sshConnectTimeout", kind: .integer, defaultValue: .integer(30), legacyKeys: []),
        Definition(key: "sshHostKeyPolicy", kind: .string, defaultValue: .string("ask"), legacyKeys: []),
        Definition(key: "logLevel", kind: .string, defaultValue: .string("info"), legacyKeys: []),
        Definition(key: "sftpMaxConcurrentTransfers", kind: .integer, defaultValue: .integer(4), legacyKeys: []),
        Definition(key: "terminalCursorShape", kind: .string, defaultValue: .string("block"), legacyKeys: []),
        Definition(key: "terminalCursorBlink", kind: .bool, defaultValue: .bool(false), legacyKeys: []),
        Definition(key: "terminalScrollback", kind: .integer, defaultValue: .integer(3_000), legacyKeys: []),
        Definition(key: "terminalCopyOnSelect", kind: .bool, defaultValue: .bool(false), legacyKeys: []),
        Definition(key: "activeProviderID", kind: .string, defaultValue: .string(""), legacyKeys: ["mobileAgentActiveProviderID"]),
        Definition(key: "agentSafety", kind: .string, defaultValue: .string("readAuto"), legacyKeys: ["mobileAgentSafety"]),
        Definition(key: "globalForwarding.launchAtAppStart.enabled", kind: .bool, defaultValue: .bool(true), legacyKeys: []),
        Definition(key: ChatHistoryStore.retentionDaysKey, kind: .integer,
                   defaultValue: .integer(ChatHistoryStore.defaultRetentionDays), legacyKeys: []),
    ]

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var defaultsObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?
    private var lastValues: [String: Value] = [:]
    private var lastModified: [String: Date] = [:]
    private(set) var isReady = false

    init(defaults: UserDefaults = .standard,
         store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// App 启动入口。测试宿主共用正式版的设置和 iCloud 命名空间，在里面启动的话，
    /// 测试改一个设置就会被推给用户的所有设备。
    func startForAppLaunch() {
        guard !TestHostEnvironment.isActive else { return }
        start()
    }

    /// Starts the bridge once for the lifetime of the app.
    func start() {
        guard defaultsObserver == nil, storeObserver == nil else { return }

        migrateLegacyKeys()
        storeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                self?.applyExternalChanges(keys)
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushLocalChanges()
            }
        }
        // Pull first so a new install does not overwrite an existing device's
        // configuration with its local defaults.
        store.synchronize()
        reconcileInitialValues()
        isReady = true
    }

    private func migrateLegacyKeys() {
        for definition in Self.definitions where !definition.legacyKeys.isEmpty {
            guard defaults.object(forKey: definition.key) == nil else { continue }
            guard let legacyKey = definition.legacyKeys.first(where: {
                defaults.object(forKey: $0) != nil
            }), let legacyValue = defaults.object(forKey: legacyKey) else { continue }

            defaults.set(legacyValue, forKey: definition.key)
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func reconcileInitialValues() {
        for definition in Self.definitions {
            let localDate = defaults.object(forKey: modifiedKey(definition.key)) as? Date
            let remote = value(store.object(forKey: definition.key), for: definition)
            let remoteDate = store.object(forKey: modifiedKey(definition.key)) as? Date

            if let local = value(defaults.object(forKey: definition.key), for: definition) {
                // 本机有值：只有 KVS 那份**更新**才覆盖，否则把本机的推上去。
                if let remote, remote != local, (remoteDate ?? .distantPast) > (localDate ?? .distantPast) {
                    defaults.set(remote.object, forKey: definition.key)
                    lastValues[definition.key] = remote
                    lastModified[definition.key] = remoteDate ?? Date()
                    defaults.set(lastModified[definition.key], forKey: modifiedKey(definition.key))
                    continue
                }
                lastValues[definition.key] = local
                // 没时间戳又等于默认值：是以前种下的默认值，不是用户的选择，不该盖掉别的设备。
                if localDate == nil, local == definition.defaultValue { continue }
                lastModified[definition.key] = localDate ?? Date()
                publish(local, for: definition.key, at: lastModified[definition.key] ?? Date())
            } else if let remote {
                // 本机没值（新装机）：直接采用 iCloud 那份，不要用本地默认值把别的设备冲掉。
                defaults.set(remote.object, forKey: definition.key)
                lastValues[definition.key] = remote
                lastModified[definition.key] = remoteDate ?? Date()
                defaults.set(lastModified[definition.key], forKey: modifiedKey(definition.key))
            } else {
                // iCloud 可能只是还没下载完。默认值只落本机、不带时间戳，等它到了直接让路。
                defaults.set(definition.defaultValue.object, forKey: definition.key)
                lastValues[definition.key] = definition.defaultValue
            }
        }
        store.synchronize()
    }

    private func pushLocalChanges() {
        guard isReady else { return }
        var changed = false
        for definition in Self.definitions {
            guard let local = value(defaults.object(forKey: definition.key), for: definition),
                  lastValues[definition.key] != local else { continue }
            lastValues[definition.key] = local
            markModified(definition.key)
            publish(local, for: definition.key, at: lastModified[definition.key] ?? Date())
            changed = true
        }
        if changed { store.synchronize() }
    }

    /// iCloud KVS 外部变更：按同一套 last-write-wins 落到本机。
    private func applyExternalChanges(_ changedKeys: [String]) {
        guard isReady else { return }
        let changed = Set(changedKeys)
        for definition in Self.definitions where changed.contains(definition.key) {
            guard let remote = value(store.object(forKey: definition.key), for: definition) else { continue }
            let remoteDate = store.object(forKey: modifiedKey(definition.key)) as? Date ?? Date()
            let localDate = lastModified[definition.key] ?? .distantPast
            guard remoteDate >= localDate else { continue }
            lastValues[definition.key] = remote
            lastModified[definition.key] = remoteDate
            defaults.set(remoteDate, forKey: modifiedKey(definition.key))
            if value(defaults.object(forKey: definition.key), for: definition) != remote {
                defaults.set(remote.object, forKey: definition.key)
            }
        }
    }

    func lanSnapshot() -> [LANSyncPreference] {
        Self.definitions.compactMap { definition in
            guard let current = value(defaults.object(forKey: definition.key), for: definition) else { return nil }
            return LANSyncPreference(key: definition.key,
                                     value: current.lanValue,
                                     modifiedAt: lastModified[definition.key] ?? Date())
        }
    }

    @discardableResult
    func mergeLANSnapshot(_ incoming: [LANSyncPreference]) -> Bool {
        var changed = false
        for item in incoming {
            guard let definition = Self.definitions.first(where: { $0.key == item.key }) else { continue }
            let incomingValue = Value(item.value)
            guard let local = value(defaults.object(forKey: definition.key), for: definition) else { continue }
            let localDate = lastModified[definition.key] ?? .distantPast
            guard item.modifiedAt >= localDate, local != incomingValue else { continue }
            defaults.set(incomingValue.object, forKey: definition.key)
            lastValues[definition.key] = incomingValue
            lastModified[definition.key] = item.modifiedAt
            defaults.set(item.modifiedAt, forKey: modifiedKey(definition.key))
            // 快通道赢下的值同样推给 iCloud，避免两条通道各执一词。
            publish(incomingValue, for: definition.key, at: item.modifiedAt)
            changed = true
        }
        if changed { store.synchronize() }
        return changed
    }

    /// LAN 是 Mac 权威的全量覆盖通道，不受本地时间戳和 iCloud KVS 的 LWW 规则影响。
    /// 这里故意不 publish 到 KVS，让 LAN 与 iCloud 保持独立的传输语义。
    @discardableResult
    func replaceFromLAN(_ incoming: [LANSyncPreference]) -> Bool {
        var changed = false
        for item in incoming {
            guard let definition = Self.definitions.first(where: { $0.key == item.key }) else { continue }
            let incomingValue = Value(item.value)
            guard value(_defaultsValue(for: definition), for: definition) != incomingValue else { continue }
            defaults.set(incomingValue.object, forKey: definition.key)
            defaults.set(item.modifiedAt, forKey: modifiedKey(definition.key))
            lastValues[definition.key] = incomingValue
            lastModified[definition.key] = item.modifiedAt
            changed = true
        }
        return changed
    }

    private func _defaultsValue(for definition: Definition) -> Any? {
        defaults.object(forKey: definition.key)
    }

    /// 把一个值连同它的时间戳写进 iCloud KVS（不调 synchronize，由调用方成批触发）。
    private func publish(_ value: Value, for key: String, at date: Date) {
        store.set(value.object, forKey: key)
        store.set(date, forKey: modifiedKey(key))
    }

    private func markModified(_ key: String) {
        let date = Date()
        lastModified[key] = date
        defaults.set(date, forKey: modifiedKey(key))
    }

    private func modifiedKey(_ key: String) -> String {
        "lanSync.preferenceModified.\(key)"
    }

    private func value(_ raw: Any?, for definition: Definition) -> Value? {
        guard let raw else { return nil }
        switch definition.kind {
        case .string:
            guard let value = raw as? String else { return nil }
            return .string(value)
        case .bool:
            if let value = raw as? Bool { return .bool(value) }
            if let value = raw as? NSNumber { return .bool(value.boolValue) }
            return nil
        case .integer:
            if let value = raw as? Int { return .integer(value) }
            if let value = raw as? NSNumber { return .integer(value.intValue) }
            return nil
        }
    }
}

fileprivate extension SharedPreferencesSync.Value {
    var lanValue: LANSyncValue {
        switch self {
        case .string(let value): return .string(value)
        case .bool(let value): return .bool(value)
        case .integer(let value): return .integer(value)
        }
    }

    init(_ value: LANSyncValue) {
        switch value {
        case .string(let value): self = .string(value)
        case .bool(let value): self = .bool(value)
        case .integer(let value): self = .integer(value)
        }
    }
}
