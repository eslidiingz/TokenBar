import SwiftUI

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The actual UI lives in the NSStatusItem + NSPopover set up by
        // AppDelegate; this empty Settings scene just satisfies SwiftUI's
        // App protocol without showing a window on launch.
        Settings {
            EmptyView()
        }
    }
}
