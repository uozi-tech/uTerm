import Foundation
import Observation

/// 驱动「命令行与技能」设置页的观察式模型。状态住在主线程，文件操作在后台执行。
/// 按工具「整包装」：每个工具下 catalog 的全部技能一起装/卸，多技能状态聚合成一个。
@MainActor
@Observable
final class SkillManagerModel {
    private let installers: [SkillInstaller]
    /// 可选的 `~/.local/bin/utermctl` 链接（默认关，见设置页开关）。
    private let binLink: BinLinkInstaller
    /// 本机在用的工具（CLI 配置目录存在），即可安装技能的对象。
    private(set) var availableTargets: [SkillTarget] = []
    private(set) var statuses: [SkillTarget: SkillInstallStatus] = [:]
    /// 首次 `load()` 是否完成 —— 用于区分「还在检测」与「确实一个都没有」，避免空状态闪烁。
    private(set) var didLoad = false
    /// 正在执行安装/卸载的 target，用于禁用按钮并避免重复点击。
    private(set) var busyTargets: Set<SkillTarget> = []
    var lastError: String?
    /// `~/.local/bin/utermctl` 的当前状态（与技能安装分开：它是独立开关）。
    private(set) var binLinkStatus: SkillInstallStatus = .notInstalled
    private(set) var binLinkBusy = false

    init(
        installers: [SkillInstaller] = SkillDefinition.catalog.map { SkillInstaller(definition: $0) },
        binLink: BinLinkInstaller = BinLinkInstaller()
    ) {
        self.installers = installers
        self.binLink = binLink
    }

    func status(for target: SkillTarget) -> SkillInstallStatus {
        statuses[target] ?? .notInstalled
    }

    func isBusy(_ target: SkillTarget) -> Bool {
        busyTargets.contains(target)
    }

    /// 把一个工具下各技能的状态聚合成一个：任一冲突→冲突；全装→已装；全无→未装；其余→需修复。
    nonisolated static func aggregateStatus(
        installers: [SkillInstaller], target: SkillTarget
    ) -> SkillInstallStatus {
        let pairs = installers.map { ($0.definition.displayName, $0.status(for: target)) }
        if let conflict = pairs.first(where: { $0.1.conflictReason != nil }) {
            return .conflict(reason: "\(conflict.0)：\(conflict.1.conflictReason ?? "")")
        }
        // 全部一致就直接用那个状态（含「全归另一个实例管」——否则会被笼统报成
        // 「需修复」，看不出真正的原因）；参差不齐才落到「需修复」。
        if let first = pairs.first, pairs.allSatisfy({ $0.1 == first.1 }) { return first.1 }
        return .brokenLink
    }

    /// 首次加载：后台判定哪些工具在用，自动修复已由 uTerm 管理的技能链接，并计算聚合状态。
    func load() async {
        let installers = self.installers
        let snapshot = await Task.detached {
            () -> (targets: [SkillTarget], statuses: [SkillTarget: SkillInstallStatus]) in
            var targets: [SkillTarget] = []
            var statuses: [SkillTarget: SkillInstallStatus] = [:]
            // 已经物化过的源目录做一次自检自愈 —— 这也是**老用户的升级路径**：
            // 1.12.x 在源目录里写出的是 app 自己生成的 `bin/utermctl`，带着
            // `com.apple.quarantine`，直接执行必然 EPERM；这一步把它换成指向
            // `uTerm.app/Contents/Resources/utermctl` 的符号链接（app 搬家后
            // 指向旧路径的链接同样在这里重建）。用户不必重装技能，打开一次本页即可。
            // 只修已存在的源，没装过技能的用户不会因此被凭空造出一份。
            for installer in installers { try? installer.repairSourceIfNeeded() }
            for target in SkillTarget.allCases where installers.first?.isToolPresent(target) == true {
                targets.append(target)
                try? Self.repairManagedInstallIfNeeded(installers: installers, target: target)
                statuses[target] = Self.aggregateStatus(installers: installers, target: target)
            }
            return (targets, statuses)
        }.value
        availableTargets = snapshot.targets
        statuses = snapshot.statuses
        didLoad = true
        await refreshBinLink()
    }

    // MARK: - ~/.local/bin/utermctl

    func refreshBinLink() async {
        let binLink = self.binLink
        binLinkStatus = await Task.detached { binLink.status() }.value
    }

    /// 打开开关就建链接、关掉就删。与技能安装互不影响：不装任何技能也能只要这条链接
    /// （客户端源目录由 `install()` 里的 `materializeSource()` 顺带物化）。
    func setBinLinkEnabled(_ enabled: Bool) async {
        guard !binLinkBusy else { return }
        binLinkBusy = true
        defer { binLinkBusy = false }
        let binLink = self.binLink
        do {
            try await Task.detached { enabled ? try binLink.install() : try binLink.uninstall() }.value
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await refreshBinLink()
    }

    /// 开关记在 `UserDefaults` 里，链接却可能被外部删掉（清理脚本、换 home）。
    /// 打开设置页时按开关状态补一次，只在「开着但没链上」时动手。
    func reconcileBinLink(enabled: Bool) async {
        await refreshBinLink()
        guard enabled, binLinkStatus.canInstall else { return }
        await setBinLinkEnabled(true)
    }

    func install(_ target: SkillTarget) async {
        let installers = self.installers
        await mutate(target) {
            try Self.forEachInstaller(installers) { try $0.install(target: target) }
        }
    }

    func uninstall(_ target: SkillTarget) async {
        let installers = self.installers
        await mutate(target) {
            try Self.forEachInstaller(installers) { try $0.uninstall(target: target) }
        }
    }

    /// 对每个 installer 执行操作；保留首个错误并在全部跑完后抛出（保证整包尽力而为）。
    private nonisolated static func forEachInstaller(
        _ installers: [SkillInstaller], _ operation: (SkillInstaller) throws -> Void
    ) throws {
        var firstError: Error?
        for installer in installers {
            do { try operation(installer) } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    /// 只要目标里已经存在任一条 uTerm 管理的链接，就把整个 catalog 补齐。
    /// 这样新增技能或 App Support 源目录丢失时，会在打开设置页时自动恢复；
    /// 用户主动卸载后的全未安装状态不触发。
    /// **故意不含 `managedByOtherInstance`**：那种链接归另一个实例管，自动补齐等于
    /// 静默抢过来，于是两个实例每次打开设置页就互抢一次。接管必须由用户点「安装」。
    private nonisolated static func repairManagedInstallIfNeeded(
        installers: [SkillInstaller], target: SkillTarget
    ) throws {
        let statuses = installers.map { $0.status(for: target) }
        guard statuses.contains(where: { $0 == .installed || $0 == .brokenLink }) else { return }
        try forEachInstaller(installers) { try $0.install(target: target) }
    }

    /// 执行单个 target 的整包安装/卸载：同一 target 不并发；只在结束时写 `lastError`
    /// （成功清空、失败置文案），避免新操作抹掉用户尚未看到的旧错误；完成后只重读该 target 聚合状态。
    private func mutate(_ target: SkillTarget, _ work: @escaping @Sendable () throws -> Void) async {
        guard !busyTargets.contains(target) else { return }
        busyTargets.insert(target)
        defer { busyTargets.remove(target) }

        let installers = self.installers
        do {
            try await Task.detached { try work() }.value
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        statuses[target] = await Task.detached {
            Self.aggregateStatus(installers: installers, target: target)
        }.value
    }
}
