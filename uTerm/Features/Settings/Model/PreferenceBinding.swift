import SwiftUI

extension Binding where Value == String {
    /// 把存着 rawValue 的字符串偏好（通常是 `@AppStorage` 的 `$raw`）投影成枚举绑定：
    /// 读不出（缺键、旧版本写的未知值）时给 `fallback`，写回时存 `rawValue`。
    ///
    ///     UDSegmented(selection: $themeRaw.rawValue(AppearancePreference.self, default: .system), …)
    func rawValue<E: RawRepresentable & Hashable>(_: E.Type, default fallback: E) -> Binding<E>
        where E.RawValue == String {
        Binding<E>(
            get: { E(rawValue: wrappedValue) ?? fallback },
            set: { wrappedValue = $0.rawValue }
        )
    }
}
