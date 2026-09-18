import AppKit
import SwiftUI
import Combine

// The view model is main-actor isolated and every delegate callback here
// already runs on the main thread, so the whole class is isolated to it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingView: NSHostingView<MenuBarLabel>?
    private var cancellables = Set<AnyCancellable>()
    let viewModel = UsageViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            // The button's own `image` + `title` can only carry one icon and one
            // string, which is not enough for two providers side by side, so the
            // label is a hosted SwiftUI view instead.
            let hostingView = NSHostingView(rootView: MenuBarLabel(viewModel: viewModel))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: button.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            self.hostingView = hostingView

            // A status item with a custom hosted view does not get the
            // system-styled bezel other menu bar items show — it gets the
            // legacy dark fill, which reads as a black flash for the length of
            // the click. Nothing takes its place: the label's own coloured
            // capsules already read as one item, and an open-state wash over
            // them only muddied them.
            (button.cell as? NSButtonCell)?.highlightsBy = []

            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView(viewModel: viewModel))
        self.popover = popover

        // A hosted view does not drive the status item's width the way a plain
        // title does, so it is applied by hand whenever the label's content
        // changes — otherwise "9%" and "100%" get the same slot.
        Publishers.CombineLatest3(viewModel.$claude, viewModel.$codex, viewModel.$codexAvailable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.resizeStatusItem() }
            .store(in: &cancellables)

        resizeStatusItem()
        viewModel.start(refreshEvery: 60)
    }

    private func resizeStatusItem() {
        guard let hostingView, let statusItem else { return }

        // Measuring before layout has run reports zero, which would leave the
        // item with no width and nothing visible in the menu bar.
        hostingView.layoutSubtreeIfNeeded()
        // The ideal width, not the larger of the two measurements: anything
        // wider than the label leaves dead space inside the item, which throws
        // off where the popover's arrow lands.
        let ideal = hostingView.intrinsicContentSize.width
        let width = ideal > 0 ? ideal : hostingView.fittingSize.width
        guard width > 0 else { return }

        statusItem.length = width
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // A status item is not a regular window, so the popover needs the
            // app brought forward or it opens behind whatever was in use.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
