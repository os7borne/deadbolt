public enum DeadboltError: Error, Equatable, Sendable {
    /// Wrong key, wrong context, or the data was tampered with. Deliberately says nothing more.
    case authenticationFailed
    case malformed
    case unsupportedVersion(UInt8)
    case invalidRecoveryPhrase(String)
    case invalidAccountNumber
    case kdfFailed
    case randomFailed
}
