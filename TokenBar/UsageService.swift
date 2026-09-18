import Foundation
import Security

/// Reads Claude Code's local OAuth credentials and calls Anthropic's usage
/// endpoint, the same one the `claude` CLI itself uses to show rate limits.
///
/// NOTE: `/api/oauth/usage` is internal and undocumented. It is not officially
/// supported and may change without notice.
final class UsageService {

    private static let credentialsFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    private static let keychainServicePrefix = "Claude Code-credentials"

    /// Matches the shape Claude Code stores, in the Keychain and on disk alike:
    /// { "claudeAiOauth": { "accessToken": ..., "refreshToken": ..., "expiresAt": ... } }
    private struct ClaudeCredentialsWrapper: Decodable {
        struct ClaudeOAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
        }
        let claudeAiOauth: ClaudeOAuth

        /// `expiresAt` is epoch milliseconds.
        var isExpired: Bool {
            guard let expiresAt = claudeAiOauth.expiresAt else { return false }
            return Date(timeIntervalSince1970: expiresAt / 1000) <= Date()
        }
    }

    /// One place a login might be stored, read lazily so a source that prompts
    /// or fails costs nothing until it is actually reached.
    private struct CredentialSource {
        let name: String
        let read: () throws -> String
    }

    /// Why one credential source could not supply a token, kept short so the
    /// combined message stays readable when every source fails.
    private struct SourceUnavailable: Error {
        let reason: String
    }

    func fetchUsage() async throws -> ProviderUsage {
        let credentials = try loadCredentials()

        if credentials.isExpired {
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

    /// Takes the first source holding a live login, so a stale entry left by an
    /// earlier account never shadows the current one.
    private func loadCredentials() throws -> ClaudeCredentialsWrapper {
        var failures: [String] = []
        var expired: ClaudeCredentialsWrapper?

        for source in credentialSources() {
            do {
                let raw = try source.read()
                guard let decoded = try? JSONDecoder()
                    .decode(ClaudeCredentialsWrapper.self, from: Data(raw.utf8)) else {
                    failures.append("\(source.name): no Claude login")
                    continue
                }

                if decoded.isExpired {
                    expired = expired ?? decoded
                    failures.append("\(source.name): expired")
                } else {
                    return decoded
                }
            } catch let failure as SourceUnavailable {
                failures.append(failure.reason)
            }
        }

        // An expired login still tells the user more than "never signed in".
        if let expired { return expired }
        throw UsageServiceError.credentialsNotFound(detail: failures.joined(separator: " / "))
    }

    /// Recent Claude Code versions scope the Keychain item per install, so the
    /// service name carries a suffix ("Claude Code-credentials-1a2b3c4d") while
    /// the unsuffixed entry lives on holding only MCP tokens — reading just that
    /// one makes a signed-in user look signed out. Some installs write the file
    /// instead, which stays as the last resort.
    private func credentialSources() -> [CredentialSource] {
        // Descending order reaches the suffixed services before the legacy one.
        let services = Self.claudeKeychainServices().sorted(by: >)

        return services.map { service in
            CredentialSource(name: "keychain(\(service))") { try Self.readKeychain(service: service) }
        } + [CredentialSource(name: "~/.claude/.credentials.json", read: Self.readCredentialsFile)]
    }

    /// Item attributes are readable without the confirmation prompt the secret
    /// itself triggers, which makes this safe to run on every refresh.
    private static func claudeKeychainServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        let services = items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(keychainServicePrefix) }
        return Array(Set(services))
    }

    /// Shelling out to `security` rather than reading the item directly: the
    /// Keychain ACL is granted per binary, and Apple's stays stable where a
    /// locally signed TokenBar would re-prompt after every rebuild.
    private static func readKeychain(service: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

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

        return raw
    }

    private static func readCredentialsFile() throws -> String {
        guard let raw = try? String(contentsOf: credentialsFileURL, encoding: .utf8) else {
            throw SourceUnavailable(reason: "~/.claude/.credentials.json: missing")
        }
        return raw
    }
}
