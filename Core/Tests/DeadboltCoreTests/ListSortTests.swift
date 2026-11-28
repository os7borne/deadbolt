import Foundation
import Testing
@testable import DeadboltCore

@Suite struct ListSortTests {
    struct Row: Listable, Equatable {
        var name: String, user = "", rank = 0, id = UUID().uuidString
        var created = Date(timeIntervalSince1970: 1000), updated = Date(timeIntervalSince1970: 1000), used: Date? = nil
        var sortName: String { name }
        var sortTiebreak: String { user }
        var sortTypeRank: Int { rank }
        var sortID: String { id }
        var createdAt: Date { created }
        var updatedAt: Date { updated }
        var lastUsedAt: Date? { used }
    }
    static func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86400) }
    func names(_ rows: [Row]) -> [String] { rows.map(\.name) }

    @Test func nameSortsIgnoreCaseAndReverse() {
        let rows = [Row(name: "zeta"), Row(name: "Alpha"), Row(name: "beta")]
        #expect(names(ListSort.nameAZ.sorted(rows)) == ["Alpha", "beta", "zeta"])
        #expect(names(ListSort.nameZA.sorted(rows)) == ["zeta", "beta", "Alpha"])
    }

    @Test func sameNameFallsBackToUsernameThenTypeAndIsStable() {
        let rows = [Row(name: "Github", user: "bob", rank: 0), Row(name: "Github", user: "alex", rank: 0), Row(name: "Github", user: "", rank: 3), Row(name: "Github", user: "", rank: 1)]
        let out = ListSort.nameAZ.sorted(rows)
        #expect(out.map(\.user) == ["", "", "alex", "bob"] && out.map(\.rank).prefix(2) == [1, 3])
        #expect(ListSort.nameAZ.sorted(out.reversed()) == out)     // same answer whatever order it started in
    }

    @Test func modifiedAndAddedAreNewestFirstWithNameAsTieBreak() {
        let rows = [Row(name: "B", created: Self.day(1), updated: Self.day(9)), Row(name: "A", created: Self.day(3), updated: Self.day(2)), Row(name: "C", created: Self.day(3), updated: Self.day(9))]
        #expect(names(ListSort.modified.sorted(rows)) == ["B", "C", "A"])     // B and C tie on day 9: B before C
        #expect(names(ListSort.added.sorted(rows)) == ["A", "C", "B"])        // A and C tie on day 3: A before C
    }

    @Test func lastUsedPutsNeverUsedLastInNameOrder() {
        let rows = [Row(name: "Never2"), Row(name: "Old", used: Self.day(1)), Row(name: "Never1"), Row(name: "Recent", used: Self.day(8))]
        #expect(names(ListSort.lastUsed.sorted(rows)) == ["Recent", "Old", "Never1", "Never2"])
    }

    @Test func realItemTypesMixAndNotesCountTheirEditTimeAsUse() throws {
        var v = Vault()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let login = try v.save(host: "github.com", username: "alex", password: "pw", now: t)
        v.markUsed(login, now: t.addingTimeInterval(500))
        var note = NoteItem(title: "Wifi", body: "x", now: t); note.updatedAt = t.addingTimeInterval(900)
        #expect(note.lastUsedAt == t.addingTimeInterval(900) && note.sortTypeRank == 3)
        let l = try #require(v.login(login))
        #expect(l.sortName == "Github" && l.lastUsedAt == t.addingTimeInterval(500))
        // Notes can sit among logins in one list through the same protocol.
        struct Boxed: Listable { let i: any Listable
            var sortName: String { i.sortName }; var sortTiebreak: String { i.sortTiebreak }; var sortTypeRank: Int { i.sortTypeRank }
            var sortID: String { i.sortID }; var createdAt: Date { i.createdAt }; var updatedAt: Date { i.updatedAt }; var lastUsedAt: Date? { i.lastUsedAt } }
        #expect(ListSort.lastUsed.sorted([Boxed(i: l), Boxed(i: note)]).map(\.sortName) == ["Wifi", "Github"])
    }

    @Test func savedValuesFallBackToTheDefault() {
        #expect(ListSort(stored: "lastUsed") == .lastUsed)
        #expect(ListSort(stored: nil) == .nameAZ && ListSort(stored: "nonsense") == .nameAZ)
        #expect(ListSort.allCases.count == 5 && Set(ListSort.allCases.map(\.label)).count == 5)
    }
}
