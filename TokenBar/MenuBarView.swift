import SwiftUI

/// A provider's badge, drawn from the asset catalog.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 15

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private var image: Image {
        let base = Image(provider.iconAssetName)
        return provider.iconIsTemplate ? base.renderingMode(.template) : base
    }
}

/// The compact label shown in the actual menu bar: each provider's logo
/// followed by its short-window and weekly percentages, so both horizons are
/// readable without opening the popover. The popover is for detail only.
struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        // Wider gap between providers than between one provider's own figures,
        // so the pairs read as pairs.
        HStack(spacing: 10) {
            ForEach(viewModel.visibleProviders, id: \.self) { provider in
                HStack(spacing: 5) {
                    ProviderIcon(provider: provider, size: provider == .claude ? 16 : 15)
                    percentages(for: provider)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        // AppKit's own bezel is switched off in AppDelegate — a status item
        // with a custom hosted view gets the legacy dark fill instead of the
        // system-styled one, which reads as a black flash. This draws the
        // translucent "menu is open" state other menu bar items show.
        .background {
            if viewModel.isPopoverShown {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.16))
            }
        }
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
            }

            if usage.needsLogin {
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if let errorMessage = usage.errorMessage {
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
