import Foundation
import Observation

/// Owns the allow-listed scalar preferences stored locally in UserDefaults.
/// LANSyncCoordinator exports this list; device-local window/session state stays out.
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
    ]

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?
    private var lastValues: [String: Value] = [:]
    private var lastModified: [String: Date] = [:]
    private(set) var isReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Starts the bridge once for the lifetime of the app.
    func start() {
        guard defaultsObserver == nil else { return }

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
            if let local = value(defaults.object(forKey: definition.key), for: definition) {
                lastValues[definition.key] = local
            } else {
                defaults.set(definition.defaultValue.object, forKey: definition.key)
                lastValues[definition.key] = definition.defaultValue
            }
            lastModified[definition.key] = defaults.object(forKey: modifiedKey(definition.key)) as? Date ?? Date()
        }
    }

    private func pushLocalChanges() {
        guard isReady else { return }
        for definition in Self.definitions {
            guard let local = value(defaults.object(forKey: definition.key), for: definition),
                  lastValues[definition.key] != local else { continue }
            lastValues[definition.key] = local
            markModified(definition.key)
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
            changed = true
        }
        return changed
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
