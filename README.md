# Restricted Item Rule Builder

A native macOS app for authoring, validating, testing and exporting rule files for the **Restricted Item Watcher**
(a Jamf-deployed LaunchDaemon that kills a process and shows a swiftDialog message). The output is a correct rule
`.plist`, ready for Jamf *Application & Custom Settings → Upload*.

> **Status: phase 1 of 3.** The rule model, validation, plist / JSON-schema / `.mobileconfig` writers, importer and the
> built-in template library are done and tested. The editor UI, predicate discovery and test harness are next.
> See [JOURNAL.md](JOURNAL.md) for decisions and progress.

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

Requirements: macOS 26+ on Apple Silicon, Xcode 26+ (developed with Xcode 27). Pure `.xcodeproj`, no Swift packages,
no third-party dependencies, no network access, no telemetry.

```bash
xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder build
xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder -destination 'platform=macOS' test
```

Warnings are treated as errors. To regenerate `Samples/` after an intentional output change:

```bash
TEST_RUNNER_UPDATE_SAMPLES=1 xcodebuild -project LockdownBuilder.xcodeproj -scheme LockdownBuilder -destination 'platform=macOS' test
```

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
