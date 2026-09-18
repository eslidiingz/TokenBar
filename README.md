# TokenBar

A macOS menu bar app that shows how much of your **Claude Code** and **Codex
(ChatGPT)** rate limits you have burned through, side by side, without clicking
anything.

```
✳ 4%  ⬡ 93%
```

Each number is that provider's *tightest* window — the limit that will stop you
working first. Clicking opens a popover with every window broken out: how full
it is, and when it rolls over.

## Requirements

- macOS 14.6 or later
- Xcode 15 or later
- Signed in at least once to Claude Code and/or Codex on this Mac

## Building

1. Open `TokenBar.xcodeproj`.
2. Under **Signing & Capabilities**, pick your Team (`CODE_SIGN_STYLE` is
   `Automatic`, with no team set in the checked-in project).
3. Build and run. The app has `LSUIElement = true`, so it appears only in the
   menu bar — no Dock icon, no window.

To build from the command line without a signing team:

```bash
xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## How it works

TokenBar has no backend and no account of its own. It reads the credentials the
official CLIs already store on this Mac and calls the same usage endpoints those
CLIs call for their own rate-limit displays.

| | Claude Code | Codex (ChatGPT) |
|---|---|---|
| Credentials | login Keychain (`Claude Code-credentials`), falling back to `~/.claude/.credentials.json` | `~/.codex/auth.json` (honours `CODEX_HOME`) |
| Endpoint | `GET https://api.anthropic.com/api/oauth/usage` | `GET https://chatgpt.com/backend-api/codex/usage` |
| Windows | `five_hour`, `seven_day`, `seven_day_opus` | `primary_window`, `secondary_window` |

Usage refreshes every 60 seconds, and on demand from the popover.

> **Both endpoints are internal and undocumented.** They are what the CLIs
> themselves use, not a public API, and either vendor can change or withdraw
> them without notice. Expect to update the `Decodable` structs eventually.

### Things the wire format will trip you up on

These are all load-bearing — each one was a real failure before it was fixed:

- **Claude's windows sit at the top level of the response**, not nested under a
  `rate_limit` object, and the field is `utilization`, not `used_percent`:
  ```json
  {"five_hour": {"utilization": 3.0, "resets_at": "2026-09-18T08:00:00.489452+00:00"},
   "seven_day": {"utilization": 75.0, "resets_at": "…"},
   "seven_day_opus": null}
  ```
- **Claude needs `anthropic-beta: oauth-2025-04-20`** and a `claude-code/*`
  user agent, or the OAuth token is rejected.
- **`resets_at` carries microseconds**, which `ISO8601DateFormatter` refuses
  outright. `ISO8601.date(from:)` trims the extra digits and retries rather
  than silently dropping the reset time.
- **Codex needs `User-Agent: codex_cli_rs`.** Without it, bot protection
  answers with a 403 HTML page instead of the API response.
  `ChatGPT-Account-Id` is also sent, which workspace accounts require.
- **Codex's primary window is not always the short one** — which of
  primary/secondary is 5h vs. weekly varies by account, so they are sorted by
  `limit_window_seconds` instead of assumed.
- Windows an account does not have come back as `null`; they are dropped rather
  than drawn as 0%.

### Menu bar

`NSStatusItem`'s own `image` + `title` can hold one icon and one string, which
is not enough for two providers, so the status button hosts an `NSHostingView`
wrapping `MenuBarLabel`. A hosted view does not drive the item's width the way a
title does, so `AppDelegate.resizeStatusItem()` measures and applies it by hand
whenever the numbers change.

Icons live in `Assets.xcassets`: `ClaudeIcon` (full colour) and `OpenAILogo`
(a monochrome menu-bar template icon). The OpenAI artwork is black with an alpha
channel, so it is drawn with `.renderingMode(.template)` — without that it is
invisible on a dark menu bar.

Codex is hidden from both the menu bar and the popover when `~/.codex/auth.json`
does not exist, rather than showing a permanent error to someone who does not
use it.

### Signing in

When a provider's credentials are missing or expired, its section offers a
**Sign in** button. TokenBar deliberately does not implement either OAuth flow
itself — that would mean impersonating someone else's OAuth client. Instead
`LoginLauncher` opens Terminal running `claude auth login` or `codex login`,
then watches the credentials file and refreshes as soon as it changes.

The Codex CLI is also looked for inside `ChatGPT.app`, which is the only copy on
a Mac that never installed the standalone CLI.

## Source layout

```
TokenBar/
├── TokenBarApp.swift        @main; an empty Settings scene, since the
│                            NSStatusItem owns the whole UI
├── AppDelegate.swift        status item, hosted label, popover, width
├── Models.swift             API response shapes, ProviderUsage, date parsing
├── UsageService.swift       Claude credentials + usage request
├── CodexUsageService.swift  Codex credentials + usage request
├── UsageViewModel.swift     polling, per-provider state, sign-in
├── MenuBarView.swift        MenuBarLabel (menu bar) + MenuBarView (popover)
├── LoginLauncher.swift      locating the CLIs, launching login, watching files
└── Assets.xcassets          ClaudeIcon, OpenAILogo
```

Both providers normalise into `ProviderUsage` holding a list of
`UsageWindowDisplay` values, shortest window first, so the popover renders them
with the same code no matter how differently the two APIs report.

## Troubleshooting

**A provider shows "Sign in"** — its credentials are missing or the token
expired. Run `claude` or `codex` once, or use the button.

**A provider shows a parse error** — the endpoint's response shape changed.
Print the raw body in the relevant `fetchUsage()` and adjust the `Decodable`
structs:

```swift
print(String(data: data, encoding: .utf8) ?? "")
```

**Codex returns HTTP 403 with HTML** — the `User-Agent` header was lost. It must
be `codex_cli_rs`.

**Nothing appears in the menu bar** — the status item has zero width. Check that
`resizeStatusItem()` is measuring a laid-out view, and that the menu bar is not
simply full (macOS hides overflow items when it runs out of room).
