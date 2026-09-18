import AppKit
import Foundation

/// Locates and runs the `claude` / `codex` CLIs so the user can (re-)authenticate
/// from inside the menu bar app, then watches the credentials file until it
/// changes so the UI can refresh automatically.
enum LoginLauncher {
    private static let commonPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "~/.claude/local",
        // The ChatGPT desktop app bundles `codex`, which is the only copy on a
        // Mac that never installed the standalone CLI.
        "/Applications/ChatGPT.app/Contents/Resources"
    ].map { NSString(string: $0).expandingTildeInPath }

    /// Where each CLI stores the credentials a successful login writes.
    ///
    /// Claude Code prefers the Keychain, but it still touches this file on some
    /// installs, and it is the only signal available to watch for.
    static func credentialsURL(for provider: AIProvider) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claude: return home.appendingPathComponent(".claude/.credentials.json")
        case .codex: return home.appendingPathComponent(".codex/auth.json")
        }
    }

    static func resolvePath(for command: String) -> String? {
        let fileManager = FileManager.default
        for dir in commonPaths {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Fall back to `command -v <name>` via the user's login shell so PATH
        // customizations (nvm, asdf, etc.) are respected.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    /// Opens Terminal.app running the login command so the user completes the
    /// interactive/browser login flow themselves.
    ///
    /// Handing a `.command` file to the terminal deliberately avoids
    /// `tell application "Terminal"`: scripting another app needs the Automation
    /// permission, which a hardened-runtime build is refused outright (-1743).
    /// A login shell keeps the PATH the CLI's own launcher may depend on.
    static func launchLogin(for provider: AIProvider) throws {
        let command = provider == .claude ? "claude" : "codex"
        guard let path = resolvePath(for: command) else {
            throw LaunchError.commandNotFound(command)
        }

        let loginArgs = provider == .claude ? "auth login" : "login"
        // A failed login stops before the closer, leaving the error on screen.
        let script = #"""
        #!/bin/zsh -l
        \#(singleQuoted(path)) \#(loginArgs) || exit 1
        \#(Self.closeOwnWindow)
        """#

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-\(command)-login.command")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        guard NSWorkspace.shared.open(scriptURL) else {
            throw LaunchError.terminalOpenFailed
        }
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Terminal leaves a window open after its shell exits unless the user's
    /// profile says otherwise, and closing one that still has processes on its
    /// tty raises a "terminate running processes?" sheet — so the closer
    /// detaches from the terminal and waits for the shell to go away first.
    /// Here `osascript` runs under Terminal, making this Terminal scripting
    /// itself, which macOS allows without the Automation grant TokenBar lacks.
    /// The delay leaves the login's own output readable on the way out.
    private static let closeOwnWindow = #"""
    if [ -x /usr/bin/perl ]; then
      TTY_PATH=$(tty)
      /usr/bin/perl -e '
        use POSIX qw(setsid);
        exit 0 if fork;
        setsid;
        sleep 3;
        exec "/usr/bin/osascript", "-e", $ARGV[0];
      ' "tell application \"Terminal\"
          repeat with w in windows
              repeat with t in tabs of w
                  if tty of t is \"$TTY_PATH\" then close w saving no
              end repeat
          end repeat
      end tell" >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null
    fi
    """#

    /// Polls a credentials file for changes (used right after launching a login
    /// flow) and calls `onChange` once it appears or its modification date updates.
    @discardableResult
    static func watchForChange(at url: URL, timeout: TimeInterval = 180, onChange: @escaping () -> Void) -> Timer {
        let startDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let deadline = Date().addingTimeInterval(timeout)
        return Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard Date() < deadline else {
                timer.invalidate()
                return
            }
            let currentDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            if let currentDate, currentDate != startDate {
                timer.invalidate()
                DispatchQueue.main.async { onChange() }
            }
        }
    }
}
