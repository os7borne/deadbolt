import Foundation

/// One merge-able field of an item: how to tell if it changed and how to copy it from another device's version.
struct ItemField<T>: @unchecked Sendable {
    let name: String
    let differs: (T, T) -> Bool
    let copy: (inout T, T) -> Void

    init<V: Equatable>(_ name: String, _ path: WritableKeyPath<T, V>) {
        self.name = name
        self.differs = { $0[keyPath: path] != $1[keyPath: path] }
        self.copy = { $0[keyPath: path] = $1[keyPath: path] }
    }
}

/// Cards, identities and notes. Merged field by field, newest hybrid-logical-clock stamp wins, like logins
/// (but without password history: nothing here needs "undo the old value").
protocol SyncedItem: Codable, Equatable, Identifiable, Sendable where ID == UUID {
    /// Prefix of this type's tombstone key, e.g. "card" -> "card:<uuid>".
    static var kind: String { get }
    static var fields: [ItemField<Self>] { get }
    var clocks: [String: HLC]? { get set }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
}

extension SyncedItem {
    static func tombstoneKey(_ id: UUID) -> String { "\(kind):\(id.uuidString)" }

    func clock(_ field: String) -> HLC { clocks?[field] ?? .zero }
    var newestClock: HLC { clocks?.values.max() ?? .zero }

    func changedFields(from old: Self) -> [String] {
        Self.fields.filter { $0.differs(self, old) }.map(\.name)
    }

    static func merged(_ a: Self, _ b: Self) -> Self {
        var m = a
        for f in fields where b.clock(f.name) > a.clock(f.name) { f.copy(&m, b) }
        var clocks = a.clocks ?? [:]
        for (f, c) in b.clocks ?? [:] where c > clocks[f] ?? .zero { clocks[f] = c }
        m.clocks = clocks
        m.createdAt = min(a.createdAt, b.createdAt)
        m.updatedAt = max(a.updatedAt, b.updatedAt)
        return m
    }
}

extension Vault {
    /// Stamps new/changed items of one type and records tombstones for removed ones.
    mutating func stampItems<T: SyncedItem>(_ items: WritableKeyPath<Vault, [T]>, old: Vault, tick: HLC, tombstones tomb: inout [String: HLC]) {
        let oldItems = Dictionary(uniqueKeysWithValues: old[keyPath: items].map { ($0.id, $0) })
        for i in self[keyPath: items].indices {
            let item = self[keyPath: items][i]
            let fields = item.clocks == nil ? T.fields.map(\.name)
                : oldItems[item.id].map { item.changedFields(from: $0) } ?? T.fields.map(\.name)
            guard !fields.isEmpty else { continue }
            var clocks = item.clocks ?? [:]
            for f in fields { clocks[f] = tick }
            self[keyPath: items][i].clocks = clocks
        }
        for id in Set(oldItems.keys).subtracting(self[keyPath: items].map(\.id)) { tomb[T.tombstoneKey(id)] = tick }
    }

    /// Merges another device's items of one type. A delete wins over edits made before it; a later edit brings the item back.
    mutating func mergeItems<T: SyncedItem>(_ items: WritableKeyPath<Vault, [T]>, from other: [T], tombstones tomb: [String: HLC]) {
        var byID = Dictionary(uniqueKeysWithValues: self[keyPath: items].map { ($0.id, $0) })
        for item in other { byID[item.id] = byID[item.id].map { T.merged($0, item) } ?? item }
        self[keyPath: items] = byID.values.filter { item in
            guard let t = tomb[T.tombstoneKey(item.id)] else { return true }
            return item.newestClock > t
        }
        .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    mutating func upsertItem<T: SyncedItem>(_ items: WritableKeyPath<Vault, [T]>, _ item: T, now: Date) {
        var item = item
        item.updatedAt = now
        if let i = self[keyPath: items].firstIndex(where: { $0.id == item.id }) { self[keyPath: items][i] = item } else { self[keyPath: items].append(item) }
    }
}
