import Foundation

/// When an unlocked vault should lock itself for inactivity.
public enum LockPolicy {
    /// The Mac never waits less than this, even if "Lock after" says immediately.
    public static let macMinimum: TimeInterval = 60

    public static func shouldLock(lastActivity: Date, now: Date, lockAfter: TimeInterval, minimum: TimeInterval = macMinimum) -> Bool {
        now.timeIntervalSince(lastActivity) >= max(lockAfter, minimum)
    }

    /// Face ID / Touch ID alone is fine until the periodic master-password check is due.
    public static let passwordReprompt: TimeInterval = 14 * 24 * 3600

    public static func biometricsAllowed(enabled: Bool, available: Bool, lastPasswordUnlock: Date?, now: Date) -> Bool {
        guard enabled, available, let last = lastPasswordUnlock, last <= now else { return false } // a future date is tampering
        return now.timeIntervalSince(last) < passwordReprompt
    }
}
