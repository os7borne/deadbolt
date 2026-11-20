import Foundation

/// Hybrid logical clock: wall-clock milliseconds + a counter + the device that wrote it.
/// Totally ordered, so every device picks the same winner for a field without talking to the others.
public struct HLC: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var millis: UInt64
    public var counter: UInt32
    public var node: String

    public init(millis: UInt64, counter: UInt32 = 0, node: String) {
        self.millis = millis; self.counter = counter; self.node = node
    }

    public static let zero = HLC(millis: 0, counter: 0, node: "")

    public static func < (a: HLC, b: HLC) -> Bool {
        (a.millis, a.counter, a.node) < (b.millis, b.counter, b.node)
    }

    /// The next stamp for `node`: never earlier than anything already seen, even if this device's clock is behind.
    public static func next(after seen: HLC?, node: String, now: Date = Date()) -> HLC {
        let wall = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        guard let seen, seen.millis >= wall else { return HLC(millis: wall, counter: 0, node: node) }
        return HLC(millis: seen.millis, counter: seen.counter &+ 1, node: node)
    }

    public var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
    public var description: String { "\(millis).\(counter)@\(node.prefix(6))" }
}
