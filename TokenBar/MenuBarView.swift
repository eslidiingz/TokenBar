import SwiftUI

/// A provider's badge, drawn from the asset catalog.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 15
    /// Overrides the provider's own rendering mode. The menu bar forces the
    /// silhouette on for both providers, because there the icon sits on a
    /// coloured fill rather than on the bar itself.
    var template: Bool?

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private var image: Image {
        let base = Image(provider.iconAssetName)
        let asTemplate = template ?? provider.iconIsTemplate
        return asTemplate ? base.renderingMode(.template) : base
    }
}

/// Each provider's fill in the menu bar — the brand hues, laid on as a wash
/// rather than a solid: the colour only has to be enough to tell the two
/// groups apart, and filled in fully they read as two loud buttons parked in
/// the bar. Because the wash lets the bar through, the label keeps the menu
/// bar's own text colour instead of a fixed white, which is what holds the
/// contrast up on a light bar as well as a dark one.
extension AIProvider {
    var menuBarTint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.50)
        }
    }

    static let menuBarTintOpacity = 0.75
}

/// The compact label shown in the actual menu bar: each provider's logo
/// followed by its short-window and weekly percentages, so both horizons are
/// readable without opening the popover. The popover is for detail only.
///
/// Each provider rides on its own coloured capsule, which is what separates
/// the two groups at a glance — otherwise the four figures read as one run of
/// digits and the logos have to be decoded to tell which pair is which.
struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// Darker than the bar under a dark menu bar, lighter under a light one:
    /// either way it moves the plate away from the text colour.
    private var scrim: Color {
        colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.45)
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(viewModel.visibleProviders, id: \.self) { provider in
                HStack(spacing: 5) {
                    // Silhouette even for Claude: its own orange mark would
                    // sink into the wash behind it, and as a silhouette it
                    // tracks the text colour the way the Codex mark does.
                    ProviderIcon(
                        provider: provider,
                        size: provider == .claude ? 15 : 14,
                        template: true
                    )

                    percentages(for: provider)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                // Two layers, tint over scrim. The tint alone at this opacity
                // sits lighter than the bar it covers, which is what softened
                // the digits; the scrim pushes the plate the other way from
                // the text — away from white on a dark bar, away from black on
                // a light one — so regular weight stays crisp.
                .background(
                    provider.menuBarTint.opacity(AIProvider.menuBarTintOpacity),
                    in: Capsule()
                )
                .background(scrim, in: Capsule())
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 4)
        .fixedSize()
    }

    private func percentages(for provider: AIProvider) -> some View {
        let texts = viewModel.menuBarTexts(for: provider)

        return HStack(spacing: 3) {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                if index > 0 {
                    Text("|")
                        .foregroundStyle(.secondary)
                }

                // Monospaced digits stop the item resizing on every tick.
                Text(text)
                    .monospacedDigit()
            }
        }
    }
}

/// The popover content shown when the menu bar item is clicked.
struct MenuBarView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            ForEach(Array(viewModel.visibleProviders.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider() }

                UsageSection(usage: viewModel.usage(for: provider)) {
                    viewModel.signIn(provider)
                }
            }

            Divider()

            footer
        }
        .padding(12)
        .frame(width: 250)
    }

    private var header: some View {
        HStack {
            Text("TokenBar").font(.headline)

            Spacer()

            Button {
                viewModel.refresh()
            } label: {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            // Fixed size so swapping in the spinner doesn't shift the header.
            .frame(width: 14, height: 14)
        }
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
    }
}

/// One provider: its name, plan, and a row per rate-limit window.
private struct UsageSection: View {
    let usage: ProviderUsage
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ProviderIcon(provider: usage.provider, size: 13)
                    .foregroundStyle(.secondary)

                Text(usage.provider.displayName)
                    .font(.footnote.weight(.semibold))

                if let planName = usage.planName {
                    Text(planName.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }

                Spacer()

                if usage.needsLogin {
                    Button("Sign in", action: onSignIn)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            // While signed out the header's button says everything; the
            // underlying "no credentials" text would only repeat it.
            if !usage.needsLogin {
                if let errorMessage = usage.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if usage.windows.isEmpty {
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usage.windows) { window in
                        UsageWindowRow(window: window)
                    }
                }
            }
        }
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindowDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Reset time rides along on the label row rather than taking a line
            // of its own, which is what makes a window two lines tall, not three.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let resetsAt = window.resetsAt {
                    Text("Resets \(relativeReset(resetsAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        // Exact timestamp stays reachable without cluttering the row.
                        .help(resetsAt.formatted(date: .abbreviated, time: .shortened))
                }

                Spacer(minLength: 4)

                Text("\(Int(window.percent.rounded()))%")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(max(window.percent / 100, 0), 1))
                }
            }
            .frame(height: 4)
        }
    }

    private var color: Color {
        switch window.percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// "in 3h 20m" reads faster than a timestamp for something this short-lived.
    private func relativeReset(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "now" }

        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h" }
        return "in \(max(minutes, 1))m"
    }
}
