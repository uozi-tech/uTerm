import Foundation

/// 接管一台 Mac 时，这台 Mac 的 Code 标签页镜像着 Mac 上的那一个（63 号消息，`RemoteCodeTabInfo`）：Mac 的 Code 标签页里
/// 跑着的会话放进这里（`CodeRunBoard.adoptMirrored`，终端是接着 Mac 上那个会话的远控终端），不再各开一个终端标签页。
///
/// 会话的增减、对上的记录、标题、结束都照 Mac 报的（规则见 `RemoteCodeRunMirror`）；本机不去认记录、不看程序退出
/// （命令不是这边打的，没有 `; exit`）。「结束会话」请 Mac 结束它（`endRun`），关掉这个标签页只断开镜像。
/// 哪个 Code 标签页开出来、开在哪、什么时候关由工作区管（`MobileWorkspace.follow`）。
///
/// Mac 上 SSH 主机的 Code 标签页由手机上那台主机的 Code 标签页镜像（手机上有这台主机、不是仅 SFTP 时）：记录经手机自己的
/// SSH 读（主机上的路径和 Mac 读到的一样），镜像过来的会话和这边直连起的会话放在同一个列表里（`isMirrored` 区分）。
extension ClaudeHistoryTab {
    /// 镜像着的会话此刻的样子（交给 `RemoteCodeRunMirror.plan` 比对）。
    var mirroredRunStates: [RemoteCodeRunMirror.Mirrored] {
        runs.runs.filter(\.isMirrored).map { run in
            RemoteCodeRunMirror.Mirrored(session: run.id, path: run.sessionPath, sessionID: run.sessionID,
                                         title: runTitles[run.id], endedAt: run.endedAt)
        }
    }

    /// 和 Mac 上的这个 Code 标签页对一次（`info` 为 nil = Mac 上已经没有了）。
    func mirrorPlan(_ info: RemoteCodeTabInfo?, listed: Set<UUID>) -> RemoteCodeRunMirror.Plan {
        RemoteCodeRunMirror.plan(mirrored: mirroredRunStates, info: info, listed: listed)
    }

    /// 拿掉镜像着的会话：只断开这边的接入，Mac 上的会话照旧。
    func removeMirroredRuns(_ sessions: [UUID]) {
        for id in sessions {
            guard let run = runs.run(id: id), run.isMirrored else { continue }
            runs.remove(id)
            dispose(id, run.terminal)
        }
    }

    /// 两边都有的会话照 Mac 改：对上的记录、标题、结束时刻。
    func applyMirrorUpdates(_ updated: [RemoteCodeTabInfo.Run]) {
        for info in updated {
            guard let run = runs.run(id: info.session), run.isMirrored else { continue }
            if run.sessionPath != info.path || run.sessionID != info.sessionID {
                runs.updateRecord(info.session, path: info.path, sessionID: info.sessionID)
            }
            if run.endedAt != info.endedAt { runs.setEnded(info.session, at: info.endedAt) }
            runTitles[info.session] = info.title
        }
    }

    /// 加进 Mac 上新出现的会话，返回它们的终端（由工作区屏去连，同接管时开的终端标签页）。
    func addMirroredRuns(_ added: [RemoteCodeTabInfo.Run], client: RemoteMacClient) -> [TermTab] {
        var opened: [TermTab] = []
        for info in added {
            guard let tool = AgentHistoryTool(rawValue: info.tool), runs.run(id: info.session) == nil else { continue }
            let term = TermTab(host: client.tabHost(for: info.session),
                               remote: MRemoteSource(client: client, sessionID: info.session))
            runs.adoptMirrored(session: info.session, tool: tool, directory: info.directory, startedAt: info.startedAt,
                               sessionPath: info.path, sessionID: info.sessionID, endedAt: info.endedAt, terminal: term)
            runTitles[info.session] = info.title
            opened.append(term)
        }
        // 请 Mac 开的会话（`ClaudeHistoryTab+MacActions`）回复先到、这会儿才出现：选上它。
        takePendingMacFocus()
        return opened
    }

    /// 镜像着的会话的终端（按 Mac 上的会话 id 找）。
    func mirroredTerminal(session: UUID) -> TermTab? {
        guard let run = runs.run(id: session), run.isMirrored else { return nil }
        return run.terminal
    }

    /// 详情换成这个镜像着的会话（接管时点的就是它、Mac 第一次报的选中）：列表读出来了就照点了那一行做，还没读出来先看它的终端，
    /// 读出来之后再选上它的记录（`applyRestoredState`）。
    func selectMirroredRun(_ session: UUID) {
        guard runs.run(id: session) != nil else { return }
        if let history = connection.history, history.phase == .ready || history.phase == .empty {
            focusRun(session)
        } else {
            runs.focus(session)
            runs.setShowsTerminal(session, true)
            restoredSelection = .run(session, showsTranscript: false)
        }
    }

    /// 第一次开出这个镜像时照 Mac 那边右边看着的选（之后的选中只在本机）。看着的是一份只读记录的，列表读出来之后选上它。
    func adoptMacSelection(of info: RemoteCodeTabInfo) {
        if let selected = info.selectedRun, runs.run(id: selected)?.isMirrored == true {
            selectMirroredRun(selected)
        } else if let stored = info.selectedRecord, let key = AgentHistoryPinKey(stored: stored) {
            restoredSelection = .record(key)
            applyRestoredState()
        }
    }

    /// 不再镜像（Mac 上那个 Code 标签页没了，而这个标签页是用户自己开的、或者里面有在这边起的会话，留着）：镜像着的会话
    /// 全部断开拿掉，这边起的照旧。直连主机的标签页从此和那台 Mac 无关。
    func stopMirroring() {
        removeMirroredRuns(runs.runs.filter(\.isMirrored).map(\.id))
        mirroredMacTabID = nil
        if remoteMac == nil { mirrorClient = nil }
        dropPendingMacFocus()
    }

    /// 里面有在这边起的会话（直连主机上「继续」「＋」起的，不是镜像过来的）。
    var hasLocalRuns: Bool { runs.runs.contains { !$0.isMirrored } }

    /// Mac 上那个 Code 标签页没了、或者不再跟着那台 Mac 时，这个标签页跟着关：接管时为了镜像才开出来、里面也没有在这边起的
    /// 会话。否则只停镜像（`stopMirroring`）。
    var closesWithMirror: Bool { opensForMirror && !hasLocalRuns }
}
