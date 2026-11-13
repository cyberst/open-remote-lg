import Foundation
import Testing
import LGKit
@testable import OpenRemote

struct AppOrderTests {
    private func apps(_ titles: String...) -> [TVApp] { titles.map { TVApp(id: $0.lowercased(), title: $0) } }
    private func titles(_ list: [TVApp]) -> [String] { list.map(\.title) }

    @Test func neverArrangedIsAlphabetical() {
        let order = AppOrder()
        #expect(titles(order.arranged(apps("YouTube", "Netflix", "app 10", "app 9"))) == ["app 9", "app 10", "Netflix", "YouTube"])
        #expect(order.including(apps("Netflix")) == order)  // stays A–Z, so new apps keep slotting in alphabetically
    }

    @Test func customOrderIsKept() {
        let order = AppOrder(ids: ["youtube", "netflix", "browser"])
        #expect(titles(order.arranged(apps("Browser", "Netflix", "YouTube"))) == ["YouTube", "Netflix", "Browser"])
    }

    @Test func newAppsJoinAtTheEndAndStayThere() {
        var order = AppOrder(ids: ["youtube", "netflix"])
        order = order.including(apps("Netflix", "YouTube", "Zattoo", "Disney+"))
        #expect(order.ids == ["youtube", "netflix", "disney+", "zattoo"])
        // A later install that sorts before them doesn't push them around.
        order = order.including(apps("Netflix", "YouTube", "Zattoo", "Disney+", "Apple TV"))
        #expect(titles(order.arranged(apps("Apple TV", "Disney+", "Netflix", "YouTube", "Zattoo")))
                == ["YouTube", "Netflix", "Disney+", "Zattoo", "Apple TV"])
    }

    @Test func uninstalledAppIsHiddenAndReturnsToItsPlace() {
        let order = AppOrder(ids: ["youtube", "prime", "netflix"])
        #expect(titles(order.arranged(apps("Netflix", "YouTube"))) == ["YouTube", "Netflix"])
        #expect(order.including(apps("Netflix", "YouTube")) == order)  // the missing app keeps its slot
        #expect(titles(order.arranged(apps("Netflix", "Prime", "YouTube"))) == ["YouTube", "Prime", "Netflix"])
    }

    @Test func movingForwardAndBack() {
        let installed = apps("A", "B", "C", "D")
        let order = AppOrder(ids: ["a", "b", "c", "d"])
        #expect(order.moving("a", to: "c", among: installed).ids == ["b", "c", "a", "d"])
        #expect(order.moving("d", to: "b", among: installed).ids == ["a", "d", "b", "c"])
        #expect(order.moving("b", to: "b", among: installed) == order)
        #expect(order.moving("x", to: "b", among: installed) == order)
    }

    @Test func firstMoveFreezesAlphabeticalOrder() {
        let moved = AppOrder().moving("c", to: "a", among: apps("B", "C", "A"))
        #expect(moved.ids == ["c", "a", "b"])
    }

    @Test func movingPastHiddenAppsKeepsThemInPlace() {
        // "prime" isn't installed on this TV; dragging YouTube onto Netflix swaps the two visible apps.
        let order = AppOrder(ids: ["youtube", "prime", "netflix"])
        let moved = order.moving("youtube", to: "netflix", among: apps("Netflix", "YouTube"))
        #expect(titles(moved.arranged(apps("Netflix", "YouTube"))) == ["Netflix", "YouTube"])
        #expect(moved.ids == ["prime", "netflix", "youtube"])
    }

    @Test func movingAlsoRecordsNewApps() {
        let moved = AppOrder(ids: ["a", "b"]).moving("c", to: "a", among: apps("A", "B", "C"))
        #expect(moved.ids == ["c", "a", "b"])
    }

    @Test func pinnedFavouritesMigrateToTheFront() {
        let d = UserDefaults.standard
        let keys = [AppOrder.key, AppOrder.legacyFavoritesKey, PrefKey.favoriteApps]
        let backup = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, backup) { d.set(v, forKey: k) } }

        keys.forEach(d.removeObject(forKey:))
        d.set(["netflix", "youtube"], forKey: AppOrder.legacyFavoritesKey)
        #expect(AppOrder.saved.ids == ["netflix", "youtube"])
        #expect(d.object(forKey: AppOrder.legacyFavoritesKey) == nil)
        #expect(d.stringArray(forKey: AppOrder.key) == ["netflix", "youtube"])

        keys.forEach(d.removeObject(forKey:))
        d.set("prime\nnetflix", forKey: PrefKey.favoriteApps)
        #expect(AppOrder.saved.ids == ["prime", "netflix"])

        keys.forEach(d.removeObject(forKey:))
        #expect(AppOrder.saved == AppOrder())
    }
}
