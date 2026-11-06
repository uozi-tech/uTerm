import Foundation

/// 按扩展名记住「用哪个应用打开」。
///
/// 只在用户**主动选过**应用时写入（「打开方式…」或没有默认应用时弹的选择框）；
/// 之后同扩展名直接用它，不再问。记的是应用包路径——应用被删 / 挪走时视为没记过。
nonisolated struct ExternalAppPreference {
    static let defaultsKey = DefaultsKey.externalOpenAppByExtension

    private let defaults: UserDefaults
    private let fileExists: (String) -> Bool

    init(defaults: UserDefaults = .standard,
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.defaults = defaults
        self.fileExists = fileExists
    }

    /// 记忆的键：小写扩展名；没有扩展名的文件（`Makefile`、`authorized_keys`）共用一个空键。
    static func key(forPath path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    func application(forPath path: String) -> URL? {
        let table = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        guard let appPath = table[Self.key(forPath: path)], fileExists(appPath) else { return nil }
        return URL(fileURLWithPath: appPath, isDirectory: true)
    }

    func remember(_ application: URL, forPath path: String) {
        var table = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        table[Self.key(forPath: path)] = application.path
        defaults.set(table, forKey: Self.defaultsKey)
    }

    func forget(forPath path: String) {
        var table = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        table.removeValue(forKey: Self.key(forPath: path))
        defaults.set(table, forKey: Self.defaultsKey)
    }
}
