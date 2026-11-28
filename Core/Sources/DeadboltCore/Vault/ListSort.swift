import Foundation

/// What every kind of list row says about itself, so one sort works for logins, cards, identities, notes and site groups.
public protocol Listable {
    /// The name shown on the row (the owner's own name when one is set).
    var sortName: String { get }
    /// Breaks ties between rows with the same name: a login's username.
    var sortTiebreak: String { get }
    /// Last tie-break, so mixed lists always come out in the same order: logins, cards, identities, notes.
    var sortTypeRank: Int { get }
    var sortID: String { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
    /// When it was last filled or copied. Nil means never. Notes can't be "used", so they report when they were last edited.
    var lastUsedAt: Date? { get }
}

/// The order of the item lists. Chosen per device (the apps store it in their own settings, not in the vault).
public enum ListSort: String, CaseIterable, Identifiable, Sendable {
    case nameAZ, nameZA, modified, lastUsed, added

    public var id: String { rawValue }
    public static let `default`: ListSort = .nameAZ

    /// A saved value back into a sort; anything unknown (a future option, a typo) is the default.
    public init(stored raw: String?) { self = raw.flatMap(ListSort.init(rawValue:)) ?? .default }

    public var label: String {
        switch self {
        case .nameAZ: "Name (A–Z)"
        case .nameZA: "Name (Z–A)"
        case .modified: "Last modified"
        case .lastUsed: "Last used"
        case .added: "Date added"
        }
    }

    public func sorted<T: Listable>(_ items: [T]) -> [T] { items.sorted(by: areInIncreasingOrder) }

    public func areInIncreasingOrder<T: Listable>(_ a: T, _ b: T) -> Bool {
        switch self {
        case .nameAZ: return Self.byName(a, b)
        case .nameZA: return Self.byName(b, a)
        case .modified: return a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : Self.byName(a, b)
        case .added: return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : Self.byName(a, b)
        case .lastUsed:
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?): return x != y ? x > y : Self.byName(a, b)
            case (_?, nil): return true              // used things first
            case (nil, _?): return false
            case (nil, nil): return Self.byName(a, b)   // never used: A–Z
            }
        }
    }

    static func byName<T: Listable>(_ a: T, _ b: T) -> Bool {
        let c = a.sortName.localizedCaseInsensitiveCompare(b.sortName)
        if c != .orderedSame { return c == .orderedAscending }
        let d = a.sortTiebreak.localizedCaseInsensitiveCompare(b.sortTiebreak)
        if d != .orderedSame { return d == .orderedAscending }
        if a.sortTypeRank != b.sortTypeRank { return a.sortTypeRank < b.sortTypeRank }
        return a.sortID < b.sortID
    }
}

extension LoginItem: Listable {
    public var sortName: String { title }
    public var sortTiebreak: String { username }
    public var sortTypeRank: Int { 0 }
    public var sortID: String { id.uuidString }
}
extension CardItem: Listable {
    public var sortName: String { title }
    public var sortTiebreak: String { "" }
    public var sortTypeRank: Int { 1 }
    public var sortID: String { id.uuidString }
}
extension IdentityItem: Listable {
    public var sortName: String { title.isEmpty ? fullName : title }
    public var sortTiebreak: String { "" }
    public var sortTypeRank: Int { 2 }
    public var sortID: String { id.uuidString }
}
extension NoteItem: Listable {
    public var sortName: String { title }
    public var sortTiebreak: String { "" }
    public var sortTypeRank: Int { 3 }
    public var sortID: String { id.uuidString }
    /// A note isn't filled or copied like a login, so "last used" means when it was last edited.
    public var lastUsedAt: Date? { updatedAt }
}
