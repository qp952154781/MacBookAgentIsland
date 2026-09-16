# AgentIsland

简体中文：[README.md](README.md)

Turn your Mac's notch into a compact Claude Code and Codex quota and session panel.

See remaining quota at a glance. Working sessions get rotating icons and activity bars; hover or click to expand quota cards, session details and system metrics. Completed sessions never open the panel automatically.

All screenshots use built-in mock data, including plans, usage, sessions and system metrics.
Dates use a fixed example timestamp displayed in UTC. EXIF/XMP and other ancillary metadata have been removed.

**Collapsed** — Claude on the left, Codex on the right.

![Collapsed](docs/images/collapsed.png)

**Active** — a still frame of working-session indicators.

![Active](docs/images/active.png)

**Expanded** — system metrics, two quota cards, and sessions grouped by agent in two columns: Claude on the left, Codex on the right.

![Expanded](docs/images/expanded.png)

Sessions are sorted by status: running tools first, then thinking (including compacting and retrying), followed by waiting for permission, waiting for input, error, idle, and ended. Within each priority tier, sessions from the same project stay together, with project groups ordered by their latest activity and unnamed projects last. Sessions within each group use newest activity first. Each agent is sorted independently in two-column mode; single-column mode sorts the merged list.

Settings → Session list → Layout (设置 → 会话列表 → 布局) defaults to Auto (自动): agent columns appear with at least 5 non-ended sessions and at least 880 pt of available centered panel width. Choose Single column (单列) for a merged list or Two columns (双列) to keep Claude on the left and Codex on the right regardless of count; insufficient screen space always falls back to one column, even with Two columns selected. Headers show each agent’s active count. Empty columns keep a placeholder, and shorter columns leave blank space. Expanding details changes only that column; both columns scroll together.

## Requirements

- macOS 14 or later, Apple Silicon or Intel.
- Best on a MacBook with a notch; other displays use a capsule at the top.
- Install and sign in to Claude Code / Codex to see the corresponding data.
- Swift 6 and Command Line Tools to build. No Xcode or third-party dependencies required.

## Privacy

**No data collection, telemetry or session-content uploads.** Local session files are read to display information on your Mac:

- Claude session metadata, main-session transcripts and desktop session titles.
- Codex's SQLite session index (read-only) and rollout logs as a fallback.
- Claude OAuth credentials, read at runtime through the system keychain, with `~/.claude/.credentials.json` as a compatibility fallback. Tokens stay in memory and are never logged or exported. AgentIsland does not read Claude session key files or `~/.codex/auth.json`.

AgentIsland's own HTTP client only contacts the Claude usage endpoint at `api.anthropic.com`; it does not follow redirects or retain HTTP caches or cookies. Codex quota comes from the official `codex app-server` subprocess. Official subprocesses may contact their own services, including during Claude token renewal described below.

AgentIsland itself reads provider data and settings without modifying them, installing hooks or changing statusLine. Its settings and connection diagnostics remain in its own local storage. Official CLI renewal may update official credentials. Diagnostic exports such as `--dump sessions` contain titles and project paths; redact them before sharing.

Brand icons are loaded from locally installed Claude / ChatGPT apps, with drawn fallbacks. Third-party icon files are not bundled or distributed as standalone assets; screenshots illustrate the interface.

## Build and install

```sh
scripts/build.sh release
scripts/test.sh
scripts/bundle.sh
```

Copy `dist/AgentIsland.app` to `/Applications` and open it. Quit an existing instance through the island's context menu first. Alternatively, `scripts/install.sh` builds and installs the app, keeping the previous bundle as `/Applications/AgentIsland.previous.app`; it does not launch the overlay.

The public bundle identifier is `org.agentisland.AgentIsland`. When upgrading from an early development build, disable its login item before replacing it, then configure the new app and enable its login item if needed. Old preferences are not migrated automatically.

Release builds remap source paths and omit debug maps from the executable to avoid embedding the builder's absolute paths. Use the default debug build for local debugging.

To start at login, right-click the island and open Settings after installing in Applications. Approve the login item in System Settings if requested. See the Chinese README for command-line options and troubleshooting.

## Limitations

- The app is ad-hoc signed and not notarized. If macOS blocks the first launch, allow it under **System Settings → Privacy & Security**.
- Quota polling and system-metric sampling pause while locked or asleep. While the process can still run, session scans are limited to once per provider every 30 seconds; unlock or wake triggers an immediate refresh.
- **Claude token renewal starts the official CLI in a hidden pseudoterminal.** Access tokens typically expire after about eight hours, and ordinary non-interactive queries cannot trigger renewal. When renewal is needed, AgentIsland starts one interactive CLI session, waits for a ready prompt, sends the local `/usage` command to trigger official renewal, then exits. It sends no conversation prompt and uses no model quota. AgentIsland does not call the refresh endpoint or write keychain credentials itself; the official CLI may use the network and update its own credentials.
- Renewal uses a dedicated AgentIsland directory with Chrome prompts and Remote Control disabled by launch arguments. Setup, trust and login prompts stop the attempt and require you to finish in Terminal; the app never accepts them for you. CLI changes or expired login sessions can still require manual action.
- Provider formats may change. Fan metrics are hidden on unsupported devices. Both processor architectures are build targets, but not every hardware combination has been tested.

## Acknowledgments and license

Inspired by notch apps such as Notchy and NookX. This independent project is not affiliated with Anthropic, OpenAI or those apps.

[MIT License](LICENSE). Copyright (c) 2026 AgentIsland contributors.
