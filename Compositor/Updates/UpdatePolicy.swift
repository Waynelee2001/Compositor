import Foundation

/// This distribution must never update from the upstream app's feed or accept an unsigned archive.
nonisolated enum UpdatePolicy {
    static let bundleID = "com.waynelee.compositor.codex"
    static let repository = "Waynelee2001/Compositor"
    static let feed = "https://raw.githubusercontent.com/Waynelee2001/Compositor/updates-codex/appcast.xml"
    static let publicKey = "+2rKo6EKXYu2Z3Usv+6U7AQb8OoN0Wk2phRCmLzUV9w="

    static func isConfigured(_ info: [String: Any]) -> Bool {
        info["CFBundleIdentifier"] as? String == bundleID
            && info["SUFeedURL"] as? String == feed
            && info["SUPublicEDKey"] as? String == publicKey
            && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true
            && info["SUAllowsAutomaticUpdates"] as? Bool == false
    }

    static func acceptsArchive(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        let segments = parts.path.split(separator: "/").map(String.init)
        return segments.count == 6 && segments[0] == "Waynelee2001" && segments[1] == "Compositor"
            && segments[2] == "releases" && segments[3] == "download"
            && segments[4].hasPrefix("ai-v") && segments[5] == "Compositor-AI-arm64.zip"
    }
}
