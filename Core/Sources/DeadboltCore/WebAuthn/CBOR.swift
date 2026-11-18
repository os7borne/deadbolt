import Foundation

/// The tiny subset of CBOR (RFC 8949) WebAuthn needs: unsigned/negative ints, byte and text strings, maps.
/// Callers pass map entries already in CTAP2 canonical order; this encoder does not sort.
indirect enum CBOR {
    case int(Int)
    case bytes(Data)
    case text(String)
    case map([(CBOR, CBOR)])

    var encoded: Data {
        switch self {
        case .int(let v) where v >= 0: return Self.head(major: 0, UInt64(v))
        case .int(let v):              return Self.head(major: 1, UInt64(-1 - v))
        case .bytes(let d):            return Self.head(major: 2, UInt64(d.count)) + d
        case .text(let s):             let d = Data(s.utf8); return Self.head(major: 3, UInt64(d.count)) + d
        case .map(let entries):
            return entries.reduce(Self.head(major: 5, UInt64(entries.count))) { $0 + $1.0.encoded + $1.1.encoded }
        }
    }

    private static func head(major: UInt8, _ value: UInt64) -> Data {
        let m = major << 5
        switch value {
        case 0..<24:            return Data([m | UInt8(value)])
        case 24...0xff:         return Data([m | 24, UInt8(value)])
        case 0x100...0xffff:    return Data([m | 25]) + bigEndian(value, 2)
        case 0x10000...0xffff_ffff: return Data([m | 26]) + bigEndian(value, 4)
        default:                return Data([m | 27]) + bigEndian(value, 8)
        }
    }

    private static func bigEndian(_ v: UInt64, _ n: Int) -> Data {
        Data((0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) })
    }
}
