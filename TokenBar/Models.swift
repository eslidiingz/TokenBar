import Foundation

// MARK: - Provider identifiers

enum AIProvider: String, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex (ChatGPT)"
        }
    }

    /// Image set in Assets.xcassets used as this provider's badge.
    var iconAssetName: String {
        switch self {
        case .claude: return "ClaudeIcon"
        case .codex: return "OpenAILogo"
        }
    }

    /// The OpenAI artwork is solid black with an alpha channel, so it has to be
    /// drawn as a template or it disappears on a dark menu bar. The Claude icon
    /// is full colour and is meant to stay that way.
    var iconIsTemplate: Bool {
        switch self {
        case .claude: return false
        case .codex: return true
        }
    }
}

protocol LoginRecoverableError {
    var needsLogin: Bool { get }
}

// MARK: - One rate-limit window, normalised for display

/// Both providers report several windows with different names and shapes; they
/// are flattened into this so the popover can render them identically.
struct UsageWindowDisplay: Identifiable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?

    init(label: String, percent: Double, resetsAt: Date?) {
        // Window labels are unique within a provider, the only scope these are
        // ever listed in.
        self.id = label
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

// MARK: - Unified usage summary shown in the menu bar / popover

struct ProviderUsage {
    let provider: AIProvider
    var planName: String?
    /// Shortest window first, so `headlinePercent` is the limit that bites first.
    var windows: [UsageWindowDisplay]
    var needsLogin: Bool
    var errorMessage: String?

    /// What the menu bar shows for this provider.
    var headlinePercent: Double? { windows.first?.percent }

    var headlineText: String {
        guard let headlinePercent else { return "--" }
        return "\(Int(headlinePercent.rounded()))%"
    }

    /// The figures the menu bar draws for this provider: the tightest window
    /// and the one after it — in practice the short window and the weekly one,
    /// since `windows` is ordered shortest-first. Showing both means the
    /// long-horizon limit is readable without opening the popover; anything
    /// beyond these two stays there.
    var menuBarPercentTexts: [String] {
        guard !windows.isEmpty else { return ["--"] }
        return windows.prefix(2).map { "\(Int($0.percent.rounded()))%" }
    }

    static func loaded(_ provider: AIProvider, planName: String?, windows: [UsageWindowDisplay]) -> ProviderUsage {
        ProviderUsage(provider: provider, planName: planName, windows: windows, needsLogin: false, errorMessage: nil)
    }

    static func placeholder(_ provider: AIProvider) -> ProviderUsage {
        ProviderUsage(provider: provider, planName: nil, windows: [], needsLogin: false, errorMessage: nil)
    }

    static func error(_ provider: AIProvider, _ error: Error) -> ProviderUsage {
        let needsLogin = (error as? LoginRecoverableError)?.needsLogin ?? false
        return ProviderUsage(
            provider: provider,
            planName: nil,
            windows: [],
            needsLogin: needsLogin,
            // The sign-in button already says what to do, so the plumbing behind
            // it is not repeated as an error message.
            errorMessage: needsLogin ? nil : error.localizedDescription
        )
    }
}

// MARK: - Date helpers

enum ISO8601 {
    /// Parses the timestamps Anthropic returns.
    ///
    /// They carry microseconds ("…:00.489452+00:00") but `ISO8601DateFormatter`
    /// only understands milliseconds, so the fractional part is trimmed and the
    /// parse retried rather than losing the reset time entirely.
    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }

        guard let dot = string.firstIndex(of: "."),
              let zoneStart = string[string.index(after: dot)...]
                  .firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else { return nil }

        return formatter.date(from: String(string[..<dot] + string[zoneStart...]))
    }
}

/// Turns a window length in seconds into "5h" / "7d" for display, since both
/// APIs describe some windows only by their length.
func usageWindowLabel(seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes)m" }

    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }

    return "\(hours / 24)d"
}

// MARK: - Claude Code usage API models
// GET https://api.anthropic.com/api/oauth/usage
//
// Verified against a live response: the windows sit at the TOP LEVEL (not under
// a `rate_limit` object) and carry `utilization`, not `used_percent`:
//   {"five_hour":{"utilization":3.0,"resets_at":"2026-09-18T08:00:00.489452+00:00"},
//    "seven_day":{...},"seven_day_opus":null, …}

struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var resetDate: Date? {
            guard let resetsAt else { return nil }
            return ISO8601.date(from: resetsAt)
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }

    /// Shortest window first. Windows the account does not have come back as
    /// null and are dropped rather than shown as 0%.
    var displayWindows: [UsageWindowDisplay] {
        [("5h", fiveHour), ("7d", sevenDay), ("7d Opus", sevenDayOpus)]
            .compactMap { label, window in
                guard let window, let utilization = window.utilization else { return nil }
                return UsageWindowDisplay(label: label, percent: utilization, resetsAt: window.resetDate)
            }
    }
}

enum UsageServiceError: LocalizedError, LoginRecoverableError {
    case credentialsNotFound(detail: String)
    case emptyAccessToken
    case tokenExpired
    case httpError(statusCode: Int, body: String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound(let detail):
            return "Claude Code credentials were not found (\(detail)). Run `claude` once to sign in."
        case .emptyAccessToken:
            return "Claude Code credentials did not contain an access token."
        case .tokenExpired:
            return "Your Claude Code session has expired."
        case .httpError(let statusCode, let body):
            return "Claude usage request failed (HTTP \(statusCode)). \(body.prefix(120))"
        case .decodingFailed(let error):
            return "Couldn't parse Claude's usage response: \(error.localizedDescription)"
        }
    }

    var needsLogin: Bool {
        switch self {
        case .credentialsNotFound, .emptyAccessToken, .tokenExpired: return true
        case .httpError(let statusCode, _): return statusCode == 401 || statusCode == 403
        case .decodingFailed: return false
        }
    }
}

// MARK: - Codex (ChatGPT) usage API models
// GET https://chatgpt.com/backend-api/codex/usage
//
// Verified against a live response:
//   {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":91,
//    "limit_window_seconds":18000,"reset_after_seconds":14323,"reset_at":1789717617},
//    "secondary_window":{…}}}

struct CodexUsageResponse: Decodable {
    struct RateLimitWindow: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }

        var resetDate: Date? {
            if let resetAt { return Date(timeIntervalSince1970: resetAt) }
            if let resetAfterSeconds { return Date().addingTimeInterval(resetAfterSeconds) }
            return nil
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: RateLimitWindow?
        let secondaryWindow: RateLimitWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    let planType: String?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    /// Shortest window first. Which of primary/secondary is the short one varies
    /// by account, so they are sorted by length rather than assumed.
    var displayWindows: [UsageWindowDisplay] {
        [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .sorted { ($0.limitWindowSeconds ?? .infinity) < ($1.limitWindowSeconds ?? .infinity) }
            .compactMap { window in
                guard let usedPercent = window.usedPercent else { return nil }
                let label = window.limitWindowSeconds.map { usageWindowLabel(seconds: $0) } ?? "Current"
                return UsageWindowDisplay(label: label, percent: usedPercent, resetsAt: window.resetDate)
            }
    }
}

enum CodexUsageServiceError: LocalizedError, LoginRecoverableError {
    case credentialsNotFound(detail: String)
    case emptyAccessToken
    case tokenExpired
    case httpError(statusCode: Int, body: String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound(let detail):
            return "Codex credentials were not found (\(detail)). Sign in to Codex once."
        case .emptyAccessToken:
            return "Codex credentials did not contain an access token."
        case .tokenExpired:
            return "Your Codex session has expired."
        case .httpError(let statusCode, let body):
            return "Codex usage request failed (HTTP \(statusCode)). \(body.prefix(120))"
        case .decodingFailed(let error):
            return "Couldn't parse Codex's usage response: \(error.localizedDescription)"
        }
    }

    var needsLogin: Bool {
        switch self {
        case .credentialsNotFound, .emptyAccessToken, .tokenExpired: return true
        case .httpError(let statusCode, _): return statusCode == 401
        case .decodingFailed: return false
        }
    }
}

enum LaunchError: LocalizedError {
    case commandNotFound(String)
    case terminalOpenFailed

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let name):
            return "Couldn't find the `\(name)` CLI on this Mac."
        case .terminalOpenFailed:
            return "Couldn't open Terminal to run the login command."
        }
    }
}
