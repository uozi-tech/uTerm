import SwiftUI

/// 把 SwiftData providers + @AppStorage activeProviderID 灌进 assistant model。
/// 拆成独立 modifier 是为了让 `workspaceBody` 主表达式不至于让编译器超时；
/// `[AIProvider]` 是 `@Model` class，非 `Equatable`，所以 onChange 用 `id` 列表比较。
struct AssistantBindingModifier: ViewModifier {
    let assistant: AssistantModel
    let providers: [AIProvider]
    let activeProviderIDString: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                assistant.providers = providers
                assistant.activeProviderID = UUID(uuidString: activeProviderIDString)
            }
            .onChange(of: providers.map(\.id)) { _, _ in
                assistant.providers = providers
            }
            .onChange(of: activeProviderIDString) { _, new in
                assistant.activeProviderID = UUID(uuidString: new)
            }
    }
}
