import Foundation

/// A secure note: a title and free text (licence keys, Wi-Fi details, recovery codes…). The text is always masked in lists.
public struct NoteItem: Codable, Equatable, Identifiable, Sendable, SyncedItem {
    public var id: UUID
    public var title: String
    public var body: String
    public var label: String?
    public var customFields: [CustomField]?
    public var createdAt: Date
    public var updatedAt: Date
    public var clocks: [String: HLC]? = nil

    public init(id: UUID = UUID(), title: String = "", body: String = "", label: String? = nil, now: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.label = label
        createdAt = now; updatedAt = now
    }

    static let kind = "note"
    static var fields: [ItemField<NoteItem>] {
        [ItemField("title", \.title), ItemField("body", \.body), ItemField("label", \.label), ItemField("customFields", \.customFields)]
    }

    /// Titles only: the text of a note is never searched or shown in a list.
    public var searchText: String { [title, label ?? ""].joined(separator: " ").lowercased() }
}
