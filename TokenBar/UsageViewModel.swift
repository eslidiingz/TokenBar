import Foundation
import Combine

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var claude: ProviderUsage = .placeholder(.claude)
    @Published private(set) var codex: ProviderUsage = .placeholder(.codex)
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    /// Codex has never signed in on this Mac, so it is left out of both the
    /// menu bar and the popover instead of showing a permanent error.
    @Published private(set) var codexAvailable = CodexUsageService.isConfigured

    private let claudeService = UsageService()
    private let codexService = CodexUsageService()

    private var refreshTimer: Timer?
    private var claudeLoginWatch: Timer?
    private var codexLoginWatch: Timer?

    /// The percentages the menu bar shows for a provider, short window first.
    func menuBarTexts(for provider: AIProvider) -> [String] {
        usage(for: provider).menuBarPercentTexts
    }

    func usage(for provider: AIProvider) -> ProviderUsage {
        provider == .claude ? claude : codex
    }

    /// The providers the menu bar draws, in order.
    var visibleProviders: [AIProvider] {
        codexAvailable ? [.claude, .codex] : [.claude]
    }

    func start(refreshEvery seconds: TimeInterval) {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            // Re-checked every poll so a first-time sign-in lights Codex up
            // without restarting the app.
            let configured = CodexUsageService.isConfigured
            if configured != codexAvailable { codexAvailable = configured }

            async let claudeResult = fetchClaude()
            async let codexResult = configured ? fetchCodex() : ProviderUsage.placeholder(.codex)

            claude = await claudeResult
            codex = await codexResult
            lastUpdated = Date()
            isRefreshing = false
        }
    }

    private func fetchClaude() async -> ProviderUsage {
        do { return try await claudeService.fetchUsage() }
        catch { return .error(.claude, error) }
    }

    private func fetchCodex() async -> ProviderUsage {
        do { return try await codexService.fetchUsage() }
        catch { return .error(.codex, error) }
    }

    /// Launches the CLI's login flow in Terminal, then watches the credentials
    /// file so usage refreshes automatically once the user finishes signing in.
    func signIn(_ provider: AIProvider) {
        do {
            try LoginLauncher.launchLogin(for: provider)
            let watch = LoginLauncher.watchForChange(at: LoginLauncher.credentialsURL(for: provider)) { [weak self] in
                self?.refresh()
            }
            if provider == .claude {
                claudeLoginWatch?.invalidate()
                claudeLoginWatch = watch
            } else {
                codexLoginWatch?.invalidate()
                codexLoginWatch = watch
            }
        } catch {
            let usage = ProviderUsage.error(provider, error)
            if provider == .claude { claude = usage } else { codex = usage }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        claudeLoginWatch?.invalidate()
        codexLoginWatch?.invalidate()
    }
}
