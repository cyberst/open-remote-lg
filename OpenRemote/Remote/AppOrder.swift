import Foundation
import LGKit

/// The user's arrangement of the TV's apps in the Apps tab.
///
/// Stored as `apps.order` ([String], app ids). Absent until the user first drags an app, so until then the grid
/// stays A–Z and new apps slot in alphabetically. Once the user has arranged their apps:
/// - an app installed later joins at the end (A–Z among several new ones) and keeps that place from then on;
/// - an uninstalled app is hidden but keeps its id in the list, so if it comes back it returns to its old place;
/// - app ids are the same on every TV, so one arrangement serves all TVs (each shows only its own apps).
struct AppOrder: Equatable {
    /// App ids in the user's order, including apps that aren't installed right now. `nil` = never arranged (A–Z).
    var ids: [String]?

    var isCustom: Bool { ids != nil }

    /// `apps` in this order; apps the order doesn't know yet follow at the end, A–Z.
    func arranged(_ apps: [TVApp]) -> [TVApp] {
        let alphabetical = apps.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard let ids else { return alphabetical }
        var rank: [String: Int] = [:]
        for (i, id) in ids.enumerated() where rank[id] == nil { rank[id] = i }
        let known = alphabetical.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return known + alphabetical.filter { rank[$0.id] == nil }
    }

    /// Appends apps this order hasn't seen yet, so their place at the end sticks. A–Z (never arranged) stays as is.
    func including(_ apps: [TVApp]) -> AppOrder {
        guard let ids else { return self }
        let seen = Set(ids)
        let new = arranged(apps).map(\.id).filter { !seen.contains($0) }
        return new.isEmpty ? self : AppOrder(ids: ids + new)
    }

    /// Puts `id` in `target`'s place, as when a dragged tile passes over another one: it lands after `target` when
    /// moving forward and before it when moving back. `apps` are the installed apps (an A–Z order is frozen from them).
    func moving(_ id: String, to target: String, among apps: [TVApp]) -> AppOrder {
        guard id != target else { return self }
        var list = including(apps).ids ?? arranged(apps).map(\.id)
        guard let from = list.firstIndex(of: id), let to = list.firstIndex(of: target) else { return self }
        list.remove(at: from)
        list.insert(id, at: to)  // after the removal, index `to` is just past `target` when moving forward
        return AppOrder(ids: list)
    }
}

// MARK: Storage

extension AppOrder {
    static let key = "apps.order"
    /// Pinned favourites from builds before apps could be arranged; migrated to the front of the order.
    static let legacyFavoritesKey = "apps.favorites"

    static var saved: AppOrder {
        get {
            let d = UserDefaults.standard
            if let ids = d.stringArray(forKey: key) { return AppOrder(ids: ids) }
            // One-time migration: pinned apps (v2 array, or v1 newline-separated string) lead the order.
            let pinned = d.stringArray(forKey: legacyFavoritesKey)
                ?? (d.string(forKey: PrefKey.favoriteApps) ?? "").split(separator: "\n").map(String.init)
            d.removeObject(forKey: legacyFavoritesKey)
            d.removeObject(forKey: PrefKey.favoriteApps)
            guard !pinned.isEmpty else { return AppOrder() }
            d.set(pinned, forKey: key)
            return AppOrder(ids: pinned)
        }
        set {
            if let ids = newValue.ids { UserDefaults.standard.set(ids, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
