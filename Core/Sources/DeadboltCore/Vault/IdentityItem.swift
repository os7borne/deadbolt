import Foundation

/// A person's details for filling forms: name, contact, address and ID numbers.
/// `ssn`, `passportNumber` and `licenseNumber` are secrets: masked by default, re-auth to reveal or copy.
public struct IdentityItem: Codable, Equatable, Identifiable, Sendable, SyncedItem {
    public var id: UUID
    public var title: String
    public var salutation: String
    public var firstName: String
    public var middleName: String
    public var lastName: String
    public var username: String
    public var company: String
    public var email: String
    public var phone: String
    public var address1: String
    public var address2: String
    public var address3: String
    public var city: String
    public var state: String
    public var postalCode: String
    public var country: String
    public var ssn: String
    public var passportNumber: String
    public var licenseNumber: String
    public var label: String?
    public var notes: String?
    public var customFields: [CustomField]?
    /// When it was last filled or copied. Orders suggestions, newest first. nil = never used.
    public var lastUsedAt: Date? = nil
    public var createdAt: Date
    public var updatedAt: Date
    public var clocks: [String: HLC]? = nil

    public init(id: UUID = UUID(), title: String = "", firstName: String = "", lastName: String = "", now: Date = Date()) {
        self.id = id; self.title = title; self.firstName = firstName; self.lastName = lastName
        salutation = ""; middleName = ""; username = ""; company = ""; email = ""; phone = ""
        address1 = ""; address2 = ""; address3 = ""; city = ""; state = ""; postalCode = ""; country = ""
        ssn = ""; passportNumber = ""; licenseNumber = ""
        createdAt = now; updatedAt = now
    }

    static let kind = "identity"
    static var fields: [ItemField<IdentityItem>] {
        [ItemField("title", \.title), ItemField("salutation", \.salutation), ItemField("firstName", \.firstName),
         ItemField("middleName", \.middleName), ItemField("lastName", \.lastName), ItemField("username", \.username),
         ItemField("company", \.company), ItemField("email", \.email), ItemField("phone", \.phone),
         ItemField("address1", \.address1), ItemField("address2", \.address2), ItemField("address3", \.address3),
         ItemField("city", \.city), ItemField("state", \.state), ItemField("postalCode", \.postalCode),
         ItemField("country", \.country), ItemField("ssn", \.ssn), ItemField("passportNumber", \.passportNumber),
         ItemField("licenseNumber", \.licenseNumber), ItemField("label", \.label), ItemField("notes", \.notes),
         ItemField("customFields", \.customFields), ItemField("lastUsedAt", \.lastUsedAt)]
    }

    /// Fields masked until revealed.
    public static let secretFieldNames: Set<String> = ["ssn", "passportNumber", "licenseNumber"]

    public var fullName: String {
        [firstName, middleName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Street address as lines, skipping empty ones.
    public var addressLines: [String] {
        let region = [city, state, postalCode].filter { !$0.isEmpty }.joined(separator: ", ")
        return [address1, address2, address3, region, country].filter { !$0.isEmpty }
    }

    /// What a search may look at. Never the ID numbers.
    public var searchText: String {
        [title, fullName, company, email, label ?? ""].joined(separator: " ").lowercased()
    }
}
