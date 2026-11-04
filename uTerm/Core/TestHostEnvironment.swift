import Foundation

/// 是否跑在 XCTest 宿主里。宿主与正式版同 bundle id、同沙盒容器、同 iCloud 权限，
/// 启动时会碰真实数据的服务要靠它跳过。
enum TestHostEnvironment {
    static var isActive: Bool { isActive(environment: ProcessInfo.processInfo.environment) }

    static func isActive(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
