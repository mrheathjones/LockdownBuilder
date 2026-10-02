# LockdownBuilder

A native macOS app for authoring, validating, testing and exporting rule files for the **Restricted Item Watcher**
(a Jamf-deployed LaunchDaemon that kills a process and shows a swiftDialog message). The output is a correct rule
`.plist`, ready for Jamf *Application & Custom Settings → Upload*.

> **Status:** feature-complete per the original brief: rule editor, validation, exports, dialog designer, test harness,
> target picker, predicate discovery and optional on-device Apple Intelligence help.

## Add a rule in 2 minutes

1. **⌘N** for a new rule (or pick a built-in template and click **Duplicate to Edit**). Give it a kebab-case name.
2. **KillProcess → Choose…**: pick the running app, drop an `.app`, or type a CLI path. The editor shows whether a
   process with exactly that name is running (`pgrep -x`).
3. **Rule type**:
   - *Presence* for an app: done.
   - *Event* to catch a specific click: **Discover…** → type the action (e.g. "Internet Accounts") → **Start Baseline**
     → **Start Action** → do it once → **Stop**. Click **Test** on the top candidate, repeat the action, and when it
     fires, **Use** it.
   - *Watch & Kill* to watch an extension and kill its host.
4. **Dialog**: pick a preset, edit the Markdown, check the **Dialog** preview; **⌘T → Simulate Dialog** shows the real
   swiftDialog window.
5. **⌘E** to export the plist (or `.mobileconfig`), then upload it in Jamf: *Application & Custom Settings → Upload*,
   preference domain = the file name without `.plist`. Optionally upload `restricted-item-rule.schema.json` as the
   custom schema.

## Apple Intelligence (optional)

On Macs with Apple Intelligence enabled, two features use the on-device model (Foundation Models). Nothing is sent off
the Mac, and you can turn them off in Settings:

- **Draft…** next to DialogMessage: describe what's blocked in one line, pick a tone, and get an editable draft with a
  live preview. It only replaces your message when you click **Use Draft**.
- **Suggest with Apple Intelligence** in discovery: the model picks the most specific of the top ranked candidates
  and explains why. It can't write its own predicate, and its pick can only be used after its live **Test** fires.

Everything else works without it. If it's unavailable, the buttons are disabled and say why.

## Rule format

One plist per rule, named `<ORG_PLIST_DOMAIN>.<PREFERENCE>.<rule-name>.plist` (e.g. `com.company.restrict.apple-account.plist`).

| Key | Type | Required | Notes |
|---|---|---|---|
| `KillProcess` | string | yes | Exact process name (`pgrep -x` / `pkill -x`); may contain spaces |
| `DialogMessage` | string | yes | swiftDialog Markdown; start with `# Title` |
| `Predicate` | string | no | Unified-log predicate. Present = event rule; absent = presence rule (polled every 0.5 s) |
| `WatchProcess` | string | no | Presence rules only; invalid together with `Predicate` |
| `CooldownSeconds` | integer ≥ 0 | no | Default 5; rate-limits the dialog only |
| `ButtonText` | string | no | Primary button label, default `OK` |
| `ButtonAction` | string | no | Absolute path or `scheme://…` URL; `file://` and control characters refused |
| `DismissButtonText` | string | no | Adds a secondary button that only closes the dialog |

Rule names are lowercase kebab-case (`^[a-z0-9]+(-[a-z0-9]+)*$`); `watcher` is reserved. `KillProcess` may never be
`launchd`, `kernel_task`, `loginwindow`, `WindowServer`, `bash`, `log`, `dialog` or `Restricted-Item-Watcher.sh`.

`Samples/` holds the built-in templates exactly as the app exports them, plus the draft-04 JSON schema for Jamf's custom
schema field. They double as golden files for the tests.

## Build

Requirements: macOS 26+ on Apple Silicon, Xcode 26+ (developed with Xcode 27 on macOS 27). Apple Intelligence is
optional. Pure `.xcodeproj`, no Swift packages,
no third-party dependencies, no network access, no telemetry.

```bash
xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder build
xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder -destination 'platform=macOS' test
```

Warnings are treated as errors. To also run the tests against the real on-device model (needs Apple Intelligence):

```bash
TEST_RUNNER_LIVE_AI=1 xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder -destination 'platform=macOS' test
```

To regenerate `Samples/` after an intentional output change:

```bash
TEST_RUNNER_UPDATE_SAMPLES=1 xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder -destination 'platform=macOS' test
```

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New rule |
| ⌘O | Open a folder of rule plists |
| ⇧⌘I | Import (and validate) plists |
| ⌘S | Save all rules to the folder |
| ⌘E / ⇧⌘E | Export the selected rule as .plist / .mobileconfig |
| ⌘T | Test the selected rule (dry run, simulate dialog, live kill test) |

## Testing a rule locally

**Test (⌘T)** never changes anything unless you ask it to:

- **Dry run** explains what the watcher will do and shows whether a matching process is running now (`pgrep -x`).
- **Simulate dialog** launches `/usr/local/bin/dialog` with exactly the flags the watcher uses. Nothing is killed and
  `ButtonAction` is reported, not opened.
- **Live kill test** (optional, clearly labelled) runs `pkill -x` only after you type the process name exactly.

## Why it is not sandboxed

The app must run `/usr/bin/log`, `pgrep` and `plutil`, read `/Applications`, and launch `/usr/local/bin/dialog`, none of
which the App Sandbox allows. It is built with the **hardened runtime** and is Developer ID signable. It makes no
network connections.

## Signing and notarisation

1. Set your Developer ID team in the target's Signing settings (the checked-in team ID is the author's).
2. Archive, then export with *Developer ID* distribution.
3. `xcrun notarytool submit LockdownBuilder.zip --keychain-profile <profile> --wait`, then `xcrun stapler staple LockdownBuilder.app`.

## License

MIT, see [LICENSE](LICENSE).
