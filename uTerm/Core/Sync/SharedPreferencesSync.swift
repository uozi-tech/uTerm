import Foundation
import Observation

/// Bridges app-level UserDefaults to iCloud's small key-value store.
///
/// SwiftData + CloudKit covers persisted records, while UserDefaults is scoped
/// to one bundle ID. This bridge keeps the scalar preferences that are useful
/// on both macOS and iOS in the same iCloud KVS namespace. Device-local
/// security and window/session state intentionally stay out of this list.
@MainActor @Observable
final class SharedPreferencesSync {
    private enum ValueKind {
        case string
        case bool
        case integer
    }

    private enum Value: Equatable {
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
    ]

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var defaultsObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?
    private var lastValues: [String: Value] = [:]
    private(set) var isReady = false

    init(defaults: UserDefaults = .standard,
         store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// Starts the bridge once for the lifetime of the app.
    func start() {
        guard defaultsObserver == nil, storeObserver == nil else { return }

        migrateLegacyKeys()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushLocalChanges()
            }
        }
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

        // Pull first so a new install does not overwrite an existing device's
        // configuration with its local defaults.
        store.synchronize()
        reconcileInitialValues()
        isReady = true
    }

    private func migrateLegacyKeys() {
        for definition in Self.definitions where !definition.legacyKeys.isEmpty {
            guard defaults.object(forKey: definition.key) == nil,
                  store.object(forKey: definition.key) == nil else { continue }
            guard let legacyKey = definition.legacyKeys.first(where: {
                defaults.object(forKey: $0) != nil
            }), let legacyValue = defaults.object(forKey: legacyKey) else { continue }

            defaults.set(legacyValue, forKey: definition.key)
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func reconcileInitialValues() {
        for definition in Self.definitions {
            if let remote = value(store.object(forKey: definition.key), for: definition) {
                defaults.set(remote.object, forKey: definition.key)
                lastValues[definition.key] = remote
            } else if let local = value(defaults.object(forKey: definition.key), for: definition) {
                store.set(local.object, forKey: definition.key)
                lastValues[definition.key] = local
            } else {
                defaults.set(definition.defaultValue.object, forKey: definition.key)
                store.set(definition.defaultValue.object, forKey: definition.key)
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
            store.set(local.object, forKey: definition.key)
            lastValues[definition.key] = local
            changed = true
        }

        if changed { store.synchronize() }
    }

    private func applyExternalChanges(_ changedKeys: [String]) {
        guard isReady else { return }
        let changed = Set(changedKeys)

        for definition in Self.definitions where changed.contains(definition.key) {
            guard let remote = value(store.object(forKey: definition.key), for: definition) else { continue }
            lastValues[definition.key] = remote
            if value(defaults.object(forKey: definition.key), for: definition) != remote {
                defaults.set(remote.object, forKey: definition.key)
            }
        }
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
