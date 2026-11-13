import Foundation

/// Decides when a numeric clipboard is a one-time code.
///
/// A bare number is ordinary clipboard text: years (`2024`), prices, and counts
/// (`12345`) are not secrets. A 4–8 digit value is an OTP only with a delivery
/// signal — an OTP phrase next to the code, a copy from Messages or an
/// authenticator, or such a copy in the last two minutes. A standalone 6-digit
/// code is the exception: that is the RFC 6238 default TOTP length, and a bare
/// `123456` stays classified as a secret.
final class OTPDetector {
    static let recentWindow: TimeInterval = 120

    /// Messages, and authenticator apps that copy a code by themselves.
    /// Password managers are classified separately.
    static let bundleIDs: [String] = [
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "com.authy.authy",
        "com.authy.authy-mac"
    ]

    static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    static func recentSourceBundleIDs(in items: [ClipboardItem], now: Date = Date()) -> [String] {
        var seen: [String] = []
        for item in items {
            guard let bundleID = item.sourceBundleID, contains(bundleID) else { continue }
            let captured = item.capturedAt ?? item.createdAt
            guard now.timeIntervalSince(captured) >= 0, now.timeIntervalSince(captured) <= recentWindow else { continue }
            if !seen.contains(bundleID) {
                seen.append(bundleID)
            }
        }
        return seen
    }

    /// Pure 4–8 digit text that should be treated as an OTP.
    static func shouldTreatStandaloneCodeAsOTP(
        lowered: String,
        sourceBundleID: String?,
        recentSourceBundleIDs: [String]
    ) -> Bool {
        guard isStandaloneCode(lowered) else { return false }
        if lowered.count == 6 { return true }
        return hasDeliverySignal(sourceBundleID: sourceBundleID, recentSourceBundleIDs: recentSourceBundleIDs)
    }

    /// Short text that names an OTP and includes a 4–8 digit code, such as `验证码：2024`.
    static func hasContextualCode(_ lowered: String) -> Bool {
        guard lowered.count <= 160 else { return false }
        guard lowered.range(of: #"\b\d{4,8}\b"#, options: .regularExpression) != nil else { return false }
        return contextPhrases.contains { lowered.contains($0) }
    }

    private static let contextPhrases = [
        "otp",
        "verification code",
        "one-time code",
        "one time code",
        "passcode",
        "验证码",
        "校验码",
        "动态码",
        "动态密码",
        "一次性密码"
    ]

    private static func isStandaloneCode(_ lowered: String) -> Bool {
        lowered.range(of: #"^\d{4,8}$"#, options: .regularExpression) != nil
    }

    private static func hasDeliverySignal(sourceBundleID: String?, recentSourceBundleIDs: [String]) -> Bool {
        contains(sourceBundleID) || recentSourceBundleIDs.contains(where: contains)
    }

    private init() {}
}
