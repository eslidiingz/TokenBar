import Foundation

/// Reads the Codex CLI's local OAuth credentials and calls the ChatGPT backend
/// usage endpoint the `codex` CLI itself uses to show rate limits.
///
/// NOTE: `/backend-api/codex/usage` is internal and undocumented. It is not
/// officially supported and may change without notice.
final class CodexUsageService {

    /// Honours the `CODEX_HOME` override the Codex CLI itself supports.
    private static var credentialsURL: URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    /// Whether Codex has ever signed in on this Mac.
    ///
    /// Used to hide Codex entirely rather than show a permanent "not signed in"
    /// state to someone who does not use it.
    static var isConfigured: Bool {
        FileManager.default.fileExists(atPath: credentialsURL.path)
    }

    /// Matches the shape the Codex CLI writes to ~/.codex/auth.json:
    /// { "tokens": { "access_token": ..., "refresh_token": ..., "account_id": ... } }
    private struct CodexCredentialsFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountID = "account_id"
            }
        }
        let tokens: Tokens?
    }

    func fetchUsage() async throws -> ProviderUsage {
        let credentials = try loadCredentials()

        guard let token = credentials.tokens?.accessToken, !token.isEmpty else {
            // An API-key-only install has no OAuth token and no usage endpoint
            // to call, so it counts as needing sign-in.
            throw CodexUsageServiceError.emptyAccessToken
        }

        if let expiry = expiry(ofJWT: token), expiry <= Date() {
            throw CodexUsageServiceError.tokenExpired
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Required: without a Codex user agent the request is turned away by
        // bot protection with a 403 HTML page rather than reaching the API.
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.tokens?.accountID {
            // Needed for workspace accounts; harmless for personal ones.
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageServiceError.httpError(statusCode: -1, body: "Not an HTTP response")
        }
        if http.statusCode == 401 {
            throw CodexUsageServiceError.tokenExpired
        }
        guard (200...299).contains(http.statusCode) else {
            throw CodexUsageServiceError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        do {
            let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return .loaded(.codex, planName: decoded.planType, windows: decoded.displayWindows)
        } catch {
            throw CodexUsageServiceError.decodingFailed(error)
        }
    }

    // MARK: - Credentials

    private func loadCredentials() throws -> CodexCredentialsFile {
        let url = Self.credentialsURL
        let display = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        guard let data = try? Data(contentsOf: url) else {
            throw CodexUsageServiceError.credentialsNotFound(detail: "\(display): missing")
        }

        do {
            return try JSONDecoder().decode(CodexCredentialsFile.self, from: data)
        } catch {
            throw CodexUsageServiceError.credentialsNotFound(detail: "\(display): unexpected JSON")
        }
    }

    /// Reads `exp` out of the JWT without verifying it — the server is the real
    /// authority, this only avoids a request that is guaranteed to fail.
    private func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        // base64url, and JWTs drop the padding Foundation's decoder wants.
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double
        else { return nil }

        return Date(timeIntervalSince1970: exp)
    }
}
