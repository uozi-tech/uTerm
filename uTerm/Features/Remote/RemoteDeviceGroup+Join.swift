import CryptoKit
import Foundation

// 加入设备组的两端（docs/remote-device-group-design.md §7.1「加入」）。
//
// 1. 新设备点「加入」：生成 6 位数、sid、Ya，写 `join`，显示数字。
// 2. 组员看到不认识的设备的 `join`，弹输码框；输入后算 Yb 与会话密钥，写 `answer`（Yb、Tb、入组包），
//    此时还**不认**新设备，只在本机记下它该回的 Ta。
// 3. 新设备看到 `answer`：Tb 对了就收下入组包里的名单、写 `done`（Ta）；错了这个数作废，换一个。
// 4. 组员看到 `done`：Ta 对了才认新设备，之后由补签把 `admit` 写出去。
//
// 冒充者（在钥匙串圈里、没见过这个数）每一轮只能猜一次：新设备对每个 sid 只处理第一条 `answer`，不论对错
// 都换数；组员对同一台新设备 10 分钟内最多输 3 次。

extension RemoteDeviceGroup {
    /// 本机作为新设备、屏幕上的这个数。
    struct CandidateSession {
        let code: String
        let cpace: CPaceSession
        let join: RemoteGroupJoin
        /// 前面作废过几个数。
        let burns: Int

        var sid: Data { join.sid }
    }

    // MARK: - 本机是新设备

    /// 「加入」：生成一个数显示出来。本机此刻在哪个组都不动：核对通过的那一刻才离开原组（`adopt`），
    /// 取消、输错、过期都还留在原组里。
    func startJoin() {
        guard let state = loadState() else { return }
        if let candidate { roster.delete(account: candidate.join.account) }
        issueCode(burns: 0)
        publish(state, roster.load())
    }

    /// 取消加入，或看过结果之后关掉。
    func cancelJoin() {
        if let candidate { roster.delete(account: candidate.join.account) }
        candidate = nil
        updateJoinState(nil)
    }

    private func issueCode(burns: Int) {
        let code = RemoteGroupJoinCrypto.newCode()
        let sid = RemoteGroupJoinCrypto.newSessionID()
        do {
            let cpace = try RemoteGroupJoinCrypto.session(.initiator, code: code, candidate: local.id, sid: sid, local: local)
            let join = RemoteGroupJoin(device: local, sid: sid, share: cpace.publicShare, createdAt: now())
            candidate = CandidateSession(code: code, cpace: cpace, join: join, burns: burns)
            write(.join(join))
            updateJoinState(.showingCode(code, attemptsLeft: Self.codeAttempts - burns))
        } catch {
            candidate = nil
            updateJoinState(.failed(String(localized: "无法生成验证码：\(error.localizedDescription)")))
        }
    }

    /// 每一轮：看有没有组员回了当前这个数。
    func advanceCandidate(_ snapshot: RemoteGroupSnapshot, _ state: inout RemoteGroupLocalState) {
        advanceSentDone(snapshot, state)
        guard let session = candidate else { return }
        guard now().timeIntervalSince(session.join.createdAt) <= Self.codeLifetime else {
            stopJoin(String(localized: "验证码已过期。如需加入，重新点「加入」。"))
            return
        }
        let answers = snapshot.answers
            .filter { $0.candidate == local.id && $0.sid == session.sid }
            .sorted { ($0.createdAt, $0.member.id.uuidString) < ($1.createdAt, $1.member.id.uuidString) }
        // 一个数只试一次：只处理第一条，不论对错这个数都作废。同一轮里有几条也只看一条：
        // 每多验一条，冒充者就多猜一次。
        guard let answer = answers.first else {
            // 名册里的 join 没同步上、被删了或被改了：按本机的重写。
            if !snapshot.joins.contains(where: { $0 == session.join }) { write(.join(session.join)) }
            return
        }
        if let (package, keys) = verify(answer, session: session) {
            adopt(package, keys: keys, answer: answer, session: session, snapshot: snapshot, state: &state)
        } else {
            burn(session)
        }
    }

    /// Tb 对、入组包打得开、包里的组员就是喂进 `finish` 的那份 AD 里的那台、给本机的加入信息由它签过，
    /// 才算核对通过。
    private func verify(_ answer: RemoteGroupAnswer,
                        session: CandidateSession) -> (RemoteGroupAdmissionPackage, CPaceKeys)? {
        guard let keys = try? session.cpace.finish(peerShare: answer.share,
                                                   peerAssociatedData: answer.member.associatedData),
              keys.verifyPeerConfirmation(answer.confirmation),
              let package = RemoteGroupJoinCrypto.openPackage(answer.package, key: RemoteGroupJoinCrypto.packageKey(keys),
                                                              sid: session.sid, candidate: local.id,
                                                              member: answer.member.id),
              package.member.device.sameKeys(as: answer.member),
              package.member.admission.isValid(for: package.member.device),
              package.admission.admitterID == answer.member.id,
              package.admission.admitterKey == answer.member.signingKey,
              package.admission.isValid(for: local) else { return nil }
        return (package, keys)
    }

    /// 核对通过：这时才离开原组（签离开记录、删掉本机签过的所有 `admit`），本机的名单换成入组包里的
    /// （含那台组员），回 `done`。入组包整份可信（来自核对过的组员），只把签名对不上的条目丢掉。
    private func adopt(_ package: RemoteGroupAdmissionPackage, keys: CPaceKeys, answer: RemoteGroupAnswer,
                       session: CandidateSession, snapshot: RemoteGroupSnapshot, state: inout RemoteGroupLocalState) {
        let entry: Data
        do {
            entry = try RemoteGroupJoinCrypto.sealEntry(local, key: RemoteGroupJoinCrypto.entryKey(keys), sid: session.sid,
                                                        candidate: local.id, member: answer.member.id)
        } catch {
            fail(error)
            burn(session)
            return
        }
        // 换组：只有本机过去，原来的组员不跟着走。被移出过的组里已经不认本机，不用再签离开。
        if !state.selfRemoved, !state.members.isEmpty { writeLeave(state) }
        deleteOwnAdmits(snapshot)
        var adopted = state.solo()
        adopted.selfAdmission = package.admission
        adopted.acknowledgementFrom = answer.member.id
        for var removal in package.removals where removal.signingKey != local.signingKey {
            if !removal.hasValidAdmission { removal.admission = nil }
            adopted.recordRemoval(removal)
        }
        // 组里早就处理过的移除：本机不再去请 Mac 撤销（只撤本机进组之后认下的）。
        adopted.settleRevocations(for: package.removals)
        // 本机重装之前的那一份（同一个设备 ID）不当组员：组员核对通过时会移除它。
        for member in [package.member] + package.others where member.device.hasValidKeys
            && member.admission.isValid(for: member.device) && member.device.id != local.id
            && member.device.signingKey != local.signingKey && adopted.member(signingKey: member.device.signingKey) == nil {
            adopted.members.append(member)
        }
        adopted.dropRemovedMembers()
        state = adopted

        let done = RemoteGroupDone(candidate: local.id, member: answer.member.id, sid: session.sid,
                                   confirmation: keys.localConfirmation, entry: entry, createdAt: now())
        write(.done(done))
        sentDone = done
        roster.delete(account: session.join.account)
        candidate = nil
        updateJoinState(.joined)
        AppLogger.notice("设备组：经「\(package.member.device.name)」加入，组里 \(adopted.members.count + 1) 台设备",
                         category: RemoteLog.category)
    }

    /// 这个数作废：换一个新数、新 sid 重写 `join`；作废够了次数就停。
    private func burn(_ session: CandidateSession) {
        let burns = session.burns + 1
        AppLogger.notice("设备组：组员回的核对没对上，这个数作废（第 \(burns) 次）", category: RemoteLog.category)
        guard burns < Self.codeAttempts else {
            stopJoin(String(localized: "连续 \(Self.codeAttempts) 次核对失败，本次加入已中止。可能是验证码输入有误，也可能有设备冒充。"))
            return
        }
        issueCode(burns: burns)
    }

    private func stopJoin(_ reason: String) {
        if let candidate { roster.delete(account: candidate.join.account) }
        candidate = nil
        updateJoinState(.failed(reason))
    }

    /// 回出去的 `done`：组里有设备认了本机（看得到它签的、认本机这次加入的 admit）或等太久就收起，
    /// 名册里没了就重写。
    private func advanceSentDone(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState) {
        guard let done = sentDone else { return }
        if hasAcceptedAdmitOfSelf(snapshot, state)
            || now().timeIntervalSince(done.createdAt) > Self.pendingLifetime {
            roster.delete(account: done.account)
            sentDone = nil
        } else if !snapshot.dones.contains(where: { $0.sameContent(as: done) }) {
            write(.done(done))
        }
    }

    // MARK: - 本机是组员

    /// 输入新设备屏幕上的 6 位数。算出这一轮的会话密钥，回 `answer`；这时还不认它，等它回的 Ta 对了才认。
    /// 返回有没有发出去（格式不对、请求已过期、输够了次数都返回 false）。
    @discardableResult
    func submitCode(_ text: String, for candidateID: UUID) -> Bool {
        guard let code = RemoteGroupJoinCrypto.normalizedCode(text), candidate == nil,
              var state = loadState(), !state.selfRemoved else { return false }
        let snapshot = roster.load()
        guard let join = openJoin(candidateID, snapshot: snapshot, state: state),
              state.submissionsLeft(for: candidateID, now: now(), window: Self.submissionWindow,
                                    limit: Self.submissionLimit) > 0 else { return false }
        // 先记次数再算：对方发来的份额不合法也算一次。
        state.pruneSubmissions(now: now(), window: Self.submissionWindow)
        state.submissions[candidateID, default: []].append(now())
        defer { publish(state, snapshot) }
        do {
            let answer = try makeAnswer(join, code: code, state: &state)
            // 先存待核对、再写 answer：中间 App 被结束，回来还能接着核对。
            guard persist(state) else { return false }
            write(.answer(answer))
            AppLogger.notice("设备组：已回「\(join.device.name)」的加入请求，等它核对", category: RemoteLog.category)
            return true
        } catch {
            persist(state)
            AppLogger.notice("设备组：「\(join.device.name)」的加入请求不合法（\(error)）", category: RemoteLog.category)
            return false
        }
    }

    private func makeAnswer(_ join: RemoteGroupJoin, code: String,
                        state: inout RemoteGroupLocalState) throws -> RemoteGroupAnswer {
        let cpace = try RemoteGroupJoinCrypto.session(.responder, code: code, candidate: join.device.id, sid: join.sid,
                                                      local: local)
        let keys = try cpace.finish(peerShare: join.share, peerAssociatedData: join.device.associatedData)
        let current = RemoteGroupTime(now())
        // 一直只有自己一台的设备第一次替别人输码：从这一刻起它是组里的第一台（自己签自己）。
        let selfAdmission = try state.selfAdmission
            ?? RemoteGroupAdmission.make(device: local, admitter: local, admittedAt: current, key: signingKey)
        state.selfAdmission = selfAdmission
        // 重新加入的设备：加入时间要晚于本机记下的、对它的移除，不然一认就又被那条移除去掉了。
        let admittedAt = max(current, state.latestRemoval(of: join.device.signingKey)?.next ?? current)
        // 由本机签：之后谁补签都只能原样带着它，改不了「是谁加的」。
        let admission = try RemoteGroupAdmission.make(device: join.device, admitter: local, admittedAt: admittedAt,
                                                      key: signingKey)
        // 新设备重装之前的那一份（同一个设备 ID）不交给它：核对通过时本机就移除它（`retireOldIncarnations`）。
        let others = state.members.filter { $0.device.id != join.device.id }
        let package = RemoteGroupAdmissionPackage(member: RemoteGroupMember(device: local, admission: selfAdmission),
                                                  others: others, removals: state.removals, admission: admission)
        let sealed = try RemoteGroupJoinCrypto.sealPackage(package, key: RemoteGroupJoinCrypto.packageKey(keys), sid: join.sid,
                                                           candidate: join.device.id, member: local.id)
        let expected = try RemoteGroupJoinCrypto.expectedCandidateConfirmation(keys: keys, sid: join.sid, join: join)
        let entryKey = RemoteGroupJoinCrypto.entryKey(keys).withUnsafeBytes { Data($0) }
        state.pendingJoins.append(RemoteGroupPendingJoin(candidate: join.device, sid: join.sid, expectedConfirmation: expected,
                                                         entryKey: entryKey, admission: admission, submittedAt: now()))
        return RemoteGroupAnswer(candidate: join.device.id, sid: join.sid, member: local, share: cpace.publicShare,
                                 confirmation: keys.localConfirmation, package: sealed, createdAt: now())
    }

    /// 「拒绝」：不是你发起的，或者不想让它加入。这一轮不再显示，本机等着的核对也作废。
    func dismissJoin(_ candidateID: UUID) {
        admittedJoins[candidateID] = nil
        let snapshot = roster.load()
        if let join = snapshot.join(for: candidateID) { dismissedJoins.insert(join.sid) }
        guard var state = loadState() else { return }
        if state.pendingJoins.contains(where: { $0.candidate.id == candidateID }) {
            state.pendingJoins.removeAll { $0.candidate.id == candidateID }
            persist(state)
        }
        roster.delete(account: RemoteGroupAnswer.account(candidate: candidateID, member: local.id))
        publish(state, snapshot)
    }

    /// 一台新设备当前可以输码的请求：不是本机、本机还不认它、没过期。
    func openJoin(_ candidateID: UUID, snapshot: RemoteGroupSnapshot, state: RemoteGroupLocalState) -> RemoteGroupJoin? {
        guard let join = snapshot.join(for: candidateID), join.device.id != local.id,
              join.device.signingKey != local.signingKey, state.member(signingKey: join.device.signingKey) == nil,
              now().timeIntervalSince(join.createdAt) <= Self.codeLifetime else { return nil }
        return join
    }

    /// 每一轮：核对新设备回的 Ta。对了才认它（加入时间用输码时定下、封进入组包的那个）。
    func advancePendingJoins(_ snapshot: RemoteGroupSnapshot, _ state: inout RemoteGroupLocalState) {
        var waiting: [RemoteGroupPendingJoin] = []
        for pending in state.pendingJoins {
            // 别的组员先认了它（读到了它们签的 admit），本机这边就不用等了。
            guard state.member(signingKey: pending.candidate.signingKey) == nil else { continue }
            if let entry = verifiedEntry(pending, snapshot: snapshot) {
                state.members.append(RemoteGroupMember(device: entry, admission: pending.admission))
                admittedJoins[entry.id] = entry
                AppLogger.notice("设备组：「\(entry.name)」核对通过，已加入", category: RemoteLog.category)
                retireOldIncarnations(of: entry, in: &state)
                continue
            }
            if now().timeIntervalSince(pending.submittedAt) <= Self.pendingLifetime { waiting.append(pending) }
        }
        state.pendingJoins = waiting
        state.pruneSubmissions(now: now(), window: Self.submissionWindow)
    }

    /// 重装过的设备（§7.3「重装过的设备」）：组里已有同一个设备 ID、钥匙不同的组员，就是它重装之前的那一份。
    /// 认下新的这一份时同时移除旧的（不连带：旧的加进来的设备不受影响）。之后各台组员照移除的规则先请 Mac 撤掉旧钥匙，
    /// 再替新钥匙开通（`RemoteDeviceGroup+Revoke.swift`：同一个 ID 在那台 Mac 上还有没撤完的就先不开通）。
    func retireOldIncarnations(of entry: RemoteGroupDevice, in state: inout RemoteGroupLocalState) {
        let old = state.members.filter { $0.device.id == entry.id && !$0.device.sameKeys(as: entry) }
        guard !old.isEmpty else { return }
        for member in old {
            AppLogger.notice("设备组：「\(entry.name)」重装过，移除它之前的身份", category: RemoteLog.category)
            writeRemoval(of: member, in: &state)
        }
        state.dropRemovedMembers()
    }

    /// 这一轮的 `done`：Ta 与存下的期望值相同，封着的条目打得开、ID 与两把钥匙就是本机喂进 `finish` 的那份。
    /// Ta 是 64 字节的 MAC，猜不出来，所以假的 `done` 只是忽略、继续等，不作废这一轮。
    private func verifiedEntry(_ pending: RemoteGroupPendingJoin, snapshot: RemoteGroupSnapshot) -> RemoteGroupDevice? {
        let key = SymmetricKey(data: pending.entryKey)
        for done in snapshot.dones where done.candidate == pending.candidate.id && done.member == local.id
            && done.sid == pending.sid
            && RemoteGroupJoinCrypto.constantTimeEqual(done.confirmation, pending.expectedConfirmation) {
            if let entry = RemoteGroupJoinCrypto.openEntry(done.entry, key: key, sid: pending.sid,
                                                           candidate: pending.candidate.id, member: local.id),
               entry.hasValidKeys, entry.sameKeys(as: pending.candidate) {
                return entry
            }
        }
        return nil
    }

    /// 弹窗用的加入请求。本机自己在加入、或已被移出时不显示。
    func buildRequests(_ state: RemoteGroupLocalState, _ snapshot: RemoteGroupSnapshot) -> [JoinRequest] {
        guard !state.selfRemoved, candidate == nil else { return [] }
        var requests: [UUID: JoinRequest] = [:]
        for (id, device) in admittedJoins {
            requests[id] = JoinRequest(candidate: device, status: .admitted)
        }
        let ids = Set(snapshot.joins.map(\.device.id)).union(state.pendingJoins.map(\.candidate.id))
        for id in ids where requests[id] == nil {
            // 「上一次不对」只看这 10 分钟里输的：更早的早就不是这一轮了。
            let pendings = state.pendingJoins.filter {
                $0.candidate.id == id && now().timeIntervalSince($0.submittedAt) <= Self.codeLifetime
            }
            let left = state.submissionsLeft(for: id, now: now(), window: Self.submissionWindow, limit: Self.submissionLimit)
            if let join = openJoin(id, snapshot: snapshot, state: state) {
                guard !dismissedJoins.contains(join.sid) else { continue }
                let status: JoinRequest.Status
                if pendings.contains(where: { $0.sid == join.sid }) {
                    status = .verifying
                } else if left == 0 {
                    status = .limitReached
                } else if !pendings.isEmpty {
                    status = .wrongCode(attemptsLeft: left)
                } else {
                    status = .waitingForCode(attemptsLeft: left)
                }
                requests[id] = JoinRequest(candidate: join.device, status: status)
            } else if let latest = pendings.max(by: { $0.submittedAt < $1.submittedAt }),
                      state.member(signingKey: latest.candidate.signingKey) == nil,
                      now().timeIntervalSince(latest.submittedAt) <= Self.codeLifetime {
                // 新设备已经收起了请求（多半是核对通过了，`done` 还在路上）。
                requests[id] = JoinRequest(candidate: latest.candidate, status: .verifying)
            }
        }
        return requests.values.sorted { ($0.candidate.name, $0.candidate.id.uuidString) < ($1.candidate.name, $1.candidate.id.uuidString) }
    }
}
