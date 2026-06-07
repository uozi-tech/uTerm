import Foundation
import SwiftData

/// ServerProfile ordering helpers. `sortOrder` is global, while grouped views
/// display a filtered slice of that global order.
@MainActor
struct ServerProfileStore {
    let context: ModelContext

    func nextSortOrder() -> Int {
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        return (profiles.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Reorders a visible filtered slice by replacing its original slots in
    /// the complete visible order, then compacts all profiles to 0...n.
    func reorderVisible(_ orderedVisible: [ServerProfile], within allProfiles: [ServerProfile]) {
        guard !orderedVisible.isEmpty else { return }
        let visibleIDs = Set(orderedVisible.map(\.id))
        var replacement = orderedVisible.makeIterator()
        var merged: [ServerProfile] = []

        for profile in allProfiles {
            if visibleIDs.contains(profile.id) {
                guard let next = replacement.next() else { return }
                merged.append(next)
            } else {
                merged.append(profile)
            }
        }

        guard replacement.next() == nil else { return }
        reorderAll(merged)
    }

    func reorderAll(_ ordered: [ServerProfile]) {
        var changed = false
        for (index, profile) in ordered.enumerated() where profile.sortOrder != index {
            profile.sortOrder = index
            changed = true
        }
        if changed { try? context.save() }
    }
}
