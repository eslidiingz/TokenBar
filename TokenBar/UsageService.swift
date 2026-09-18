import Foundation

/// Reads Claude Code's local OAuth credentials and calls Anthropic's usage
/// endpoint, the same one the `claude` CLI itself uses to show rate limits.
///
/// NOTE: `/api/oauth/usage` is internal and undocumented. It is not officially
/// supported and may change without notice.
final class UsageService {

    private static let credentialsFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    /// Matches the shape Claude Code stores, in the Keychain and on disk alike:
    /// { "claudeAiOauth": { "accessToken": ..., "refreshToken": ..., "expiresAt": ... } }
    private struct ClaudeCredentialsWrapper: Decodable {
        struct ClaudeOAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
        }
        let claudeAiOauth: ClaudeOAuth
    }

    /// Why one credential source could not supply a token, kept short so the
    /// combined message stays readable when every source fails.
    private struct SourceUnavailable: Error {
        let reason: String
    }

    func fetchUsage() async throws -> ProviderUsage {
        let credentials = try loadCredentials()

        // `expiresAt` is epoch milliseconds.
        if let expiresAt = credentials.claudeAiOauth.expiresAt,
           Date(timeIntervalSince1970: expiresAt / 1000) <= Date() {
            throw UsageServiceError.tokenExpired
        }

        let token = credentials.claudeAiOauth.accessToken
        guard !token.isEmpty else { throw UsageServiceError.emptyAccessToken }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.0.32", forHTTPHeaderField: "User-Agent")
        // Without this the OAuth token is not accepted on this endpoint.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageServiceError.httpError(statusCode: -1, body: "Not an HTTP response")
        }
        if http.statusCode == 401 {
            throw UsageServiceError.tokenExpired
        }
        guard (200...299).contains(http.statusCode) else {
            throw UsageServiceError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        do {
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            return .loaded(.claude, planName: nil, windows: decoded.displayWindows)
        } catch {
            throw UsageServiceError.decodingFailed(error)
        }
    }

    // MARK: - Credentials

    /// Prefers the login Keychain, where Claude Code stores credentials by
    /// default, and falls back to the on-disk file some installs use instead.
    private func loadCredentials() throws -> ClaudeCredentialsWrapper {
        var failures: [String] = []

        for load in [readKeychainJSON, readCredentialsFileJSON] {
            do {
                let (raw, source) = try load()
                do {
                    return try JSONDecoder().decode(ClaudeCredentialsWrapper.self, from: Data(raw.utf8))
                } catch {
                    throw SourceUnavailable(reason: "\(source): unexpected JSON")
                }
            } catch let failure as SourceUnavailable {
                failures.append(failure.reason)
            }
        }

        throw UsageServiceError.credentialsNotFound(detail: failures.joined(separator: " / "))
    }

    private func readKeychainJSON() throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw SourceUnavailable(reason: "keychain: \(error.localizedDescription)")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !raw.isEmpty else {
            throw SourceUnavailable(reason: "keychain: no entry")
        }

        return (raw, "keychain")
    }

    private func readCredentialsFileJSON() throws -> (String, String) {
        let url = Self.credentialsFileURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SourceUnavailable(reason: "~/.claude/.credentials.json: missing")
        }
        return (raw, "~/.claude/.credentials.json")
    }
}
