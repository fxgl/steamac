# Crash reports, updates and game statistics

**English** · [Русский](ru/privacy-and-updates.md) · [简体中文](zh/privacy-and-updates.md)

← [Manual](README.md)

## Crash reports (Sentry)

The launcher sends crash reports and a few errors to the developers' own Sentry server
(`sentry.fxgam.es`, sentry-cocoa 9.30.0 SDK via SwiftPM). Enabled by default; disable it with the
**Send crash reports and diagnostics** checkbox in Settings → General, in the first-launch window,
or in the Create SteamOS Disk window (the “What is sent” link displays the list below). When disabled,
the SDK does not start at all and makes no network connections (reports already saved on disk remain
there and are not sent). For one launch: `--no-crash-reports` or `STEAMAC_SENTRY=0`.

What is sent:

- Crashes of the supervisor and VM processes (signal/abort, unhandled exceptions): cause, thread
  stacks, list of loaded libraries. This includes Metal/MoltenVK asserts, libkrun/virglrenderer
  aborts, and Rust panics propagated through the libkrun C API. A VM process crash report is sent on
  the next VM launch. An uncaught Objective-C exception is grouped by its reason (the first-throw
  message and stack from stderr), not under `CPPExceptionTerminate` (STEAMAC-58);
- A few errors (no more than once per fingerprint per process, subject to a global limit; the same
  fingerprint is not sent again for at least a day, or 30 days for shader compilation errors): the
  guest GPU context becomes fatal/device lost (vkr “fatal decoder state”, “device lost”), MoltenVK
  pipeline compilation errors (`[mvk-error] … compile failed`; if MoltenVK printed MSL source
  (`[mvk-msl] …`: the first 40 lines and lines around the error), it is sent in extra `msl_source`,
  not in breadcrumbs; the complete failing shader, up to 256 KiB and scrubbed, is attached as a `.metal`
  file, at most two different shaders per process, deduplicated by content hash (STEAMAC-AD); the vkr
  line “pipeline … creation failed on host” is a breadcrumb only), a
  Rust panic in libkrun (`thread … panicked at`), failure of initial disk provisioning (`provision
  failed`), failure to create a disk, unexpected VM exit (nonzero exit code or signal when shutdown
  was not requested by the user), and the idle indicator's “SteamOS is not responding”. For a VM
  process crash, the supervisor's report adds macOS's own crash report of it
  (`~/Library/Logs/DiagnosticReports/steamac-vm-*.ips`, matched by pid): the crash site in the title
  and the `crash_site` tag (reports group by it), and in extra `macos_crash_report` the exception, the
  Application Specific Information lines (libmalloc's message on a heap corruption trap) and the
  crashed thread's first 16 frames (library and symbol names); the same summary is written to the session
  log, so Report a Problem after a crash carries the crash site with crash reporting off (STEAMAC-BC);
  Not-responding reports include `stall_history`: up to 32 one-second GPU command-counter, heartbeat age,
  guest uptime/load, process CPU-time and host polling-gap samples, even with performance statistics
  off (STEAMAC-8). Missing agent heartbeats alone do not prove that the whole guest or GPU hung.
  GPU-activity, VM-memory and host-thread snapshots are bounded separately; thread states and CPU
  estimates are evidence, not backtraces or proof of a GPU deadlock. The history also records host
  activation, key window and window visibility/occlusion. “Still working” means the guest heartbeat is
  alive; it does not prove that a game is progressing or compiling shaders. A VM exit report states why
  macOS's crash report was not attached (none written in time, unreadable, incomplete or another pid).
  The same samples are logged once when an idle indicator lasts 10 s, including with a live
  heartbeat, so Report a Problem can diagnose game stalls without enabling performance statistics.
  After a host scheduling gap (the launcher itself not running for seconds) the detector watches a
  fresh heartbeat window before reporting, instead of counting the gap as a guest hang.
- VM exit due to SIGTERM/SIGINT/SIGHUP (logging out, `kill`, ^C before handlers are installed) is not
  a crash: only a log line, with no event and no Report a Problem window. Neither is SIGPIPE (both
  processes ignore it: a closed output pipe — the terminal, or the supervisor's stderr channel after
  the supervisor was killed — only fails the write; the VM process then logs to
  `~/Library/Logs/es.fxgam.steamac/steamac-vm.log` or drops the lines, and lets the guest finish
  shutting down; STEAMAC-10). SIGKILL generates a
  warning-level `vm-killed` event, “VM process killed (SIGKILL — memory pressure or force quit)”: 
  whether the kernel killed it for memory (jetsam, `NOTE_EXIT_DETAIL` from the supervisor's kqueue),
  VM memory and the VM process footprint at exit/peak, host `vm_stat` numbers (free/compressed/wired,
  swap), `kern.memorystatus_level`, and the history of memory pressure levels since launch
  (transitions are also written to the log: `memory pressure: …`). Force Quit from the app menu (or a
  second shutdown request) is a requested exit, not a report: the VM process exits with status 3, which
  the supervisor recognizes without the `user-exit` marker file (with the Mac's disk full the marker
  could not be written, STEAMAC-15);
  The kernel's memory-kill flag is reported separately from the SIGKILL's unknown source (its absence does
  not mean Force Quit), with the peak footprint relative to VM and Mac memory and the highest sampled
  memory pressure, not only the levels macOS announced (STEAMAC-S).
  `memory_history` adds up to two minutes of pre-exit VM footprint and host memory samples (every
  10 s); the separate report-time snapshot is labelled post-exit because VM memory is already freed.
  GPU-fatal and SIGKILL reports add the VM process's recent GPU/heartbeat history and process, Metal,
  Vulkan-allocation and shared-memory snapshots; these counters overlap and are not a sum. A second
  VM refused because its disk is in use exits with status 4: the explanation, no report.
- Every event includes the last ~200 lines of launcher stderr as breadcrumbs (`[steamac-vm]`,
  `[mvk-*]`, libkrun/virglrenderer warnings, startup stages) and tags: version
  (`es.fxgam.steamac@<CFBundleShortVersionString>+<git sha>`), environment, and `build_kind` tag:
  `release` — only a `dist.sh` build with notarization (Info.plist `SteamacDistTeamID`, and the
  running code's signature is Developer ID for that team, checked with `SecCodeCheckValidity`),
  `source-build` — any other `.app` (`bundle.sh`, ad-hoc/re-signed copies, `dist.sh --no-notarize`),
  `development` — `work/out/steamac-vm` outside the bundle; macOS, Mac model, GPU, vCPU/RAM, display
  mode, build UUIDs of libkrun / virglrenderer / MoltenVK, `MVK_PATCH_REVISION`, kernel version,
  SteamOS BUILD_ID and layer release (from initramfs lines), the `appid` of the game in guest focus
  (while it is in focus), and a random installation ID.

Not sent: guest console (hvc0), user and computer names (`/Users/<name>` → `~`, name and hostname are
redacted), IP address (`sendDefaultPii=false`, the server does not expose IP addresses), locale/time
zone, Steam account, game titles (App ID only), or files. The supervisor routes its stderr through a
channel (everything still appears in the terminal/log), so it also sees the last lines from a crashed
VM process.

Testing: `--sentry-test-event` (a test event from the supervisor and VM process; the VM process also
sends a pending crash report and exits), `--sentry-test-crash abort|segv|metal|panic|kill|term|shader`
(the VM process crashes: `abort()` inside a C call, `EXC_BAD_ACCESS` in `memset`, Metal assert, Rust
panic in `krun_start_enter` due to an overly long kernel command line — `panic` requires `--kernel`
and, if necessary, `--initrd`; `kill`/`term` — the VM process kills itself with SIGKILL (`vm-killed`
report) or SIGTERM (no report or window); `shader` — prints an example MoltenVK compilation error
with `[mvk-msl]` and a vkr line, then exits). These events have `environment=development` and the
`test=true` tag. `STEAMAC_SENTRY_DEBUG=1` prints the SDK debug log (server responses).

Symbols: `build.sh` puts dSYMs for `steamac-vm` and bundled libraries in `work/out/dSYMs` (libkrun,
virglrenderer, and MoltenVK are built without DWARF — they contain only symbol tables). `dist.sh`
uploads them and every Mach-O the app ships (executable, Frameworks, helpers in Resources; each must pass
`sentry-cli debug-files check`) with `sentry-cli --url https://sentry.fxgam.es debug-files upload --wait`,
and keeps the dSYMs as `work/out/dist/FX-Steam-Launcher-<version>-dSYMs`. A notarized build requires
`SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, and `SENTRY_PROJECT` (checked before signing; `--no-sentry-upload` opts
out): 1.9 shipped without an upload, and crashes in `steamac-vm` and libkrun stayed unsymbolicated.

## Update check

Releases update themselves in the app (Sparkle); every other build checks GitHub's latest release and
offers the DMG. Both use the same window next to the VM window (not over it if there is room on screen;
without taking focus — the keyboard and captured mouse remain with the VM), the app menu's **Check for
Updates…** item (“Update Available: X.Y…” with a New badge once a version was found), and the **Check for
updates at startup** checkbox in Settings → General (effective immediately).

**In-app updates (releases).** A release (`dist.sh` puts the feed and its EdDSA public key into
Info.plist) runs [Sparkle](https://sparkle-project.org) 2.10.1 (`Contents/Frameworks/Sparkle.framework`,
without its XPC services: the app is not sandboxed) with its own UI replaced by the window above. While
the checkbox is on, it fetches `https://fxgl.github.io/steamac/appcast.xml` at most every 6 hours, also
during a session. The feed is signed as a whole and every update carries its own EdDSA signature, both
checked against the key in the app before anything is unpacked (`SURequireSignedFeed`,
`SUVerifyUpdateBeforeExtraction`); Sparkle also requires the new app's code signature to match.
Versions that need a newer macOS (or another Mac) are not offered; the menu's check says why. A new
version shows its release notes and **Install Update** (downloads in the background — SteamOS keeps
running, **Hide** closes the window, **Cancel** stops the download — then Sparkle's installer prepares
it), **Skip This Version**, and **Remind Me Later**. A prepared update offers **Install and Relaunch**:
SteamOS shuts down exactly as with Shut Down SteamOS (power key, up to 180 s, never a force quit), then
Sparkle's installer replaces the app from outside the running process and opens it again; and
**Install on Quit** (also closing the window): the update installs whenever the launcher exits. A delta
update (only the changed files) is used when the feed has one for the installed version, else the full DMG.

The VM process hosts Sparkle (it is the only one running NSApplication); quitting never goes through
AppKit (the guest powers off and libkrun ends the process), and the supervisor starts a new VM process
from the bundle after a guest reboot, which would race with the installer replacing it. So, while an
update is prepared, the VM process leaves an `update` marker in the run dir and the supervisor never
boots again; a SteamOS restart (from SteamOS or Restart VM) becomes Install and Relaunch. Sparkle's own
quit request (it follows the shutdown the launcher started) is ignored, so it cannot turn into a force
quit; the user's second quit still force-quits as before.

Copies that cannot replace themselves keep the GitHub check below (logged as `update: in-app updates
off (…)`): source builds (`bundle.sh`), the dev launcher, an app started from the DMG or translocated by
Gatekeeper (not moved to Applications), and copies on a read-only volume.

Privacy: Sparkle's requests go only to `fxgl.github.io` (the feed) and GitHub release downloads, with
its standard `User-Agent` (app and Sparkle versions); no system profile, no Mac or user identifiers, no
Sentry. Sparkle keeps its state (last check time, skipped version) in the app's defaults (`SU…` keys).

**GitHub release check (other builds).** When the app starts (once per launch, not on every VM reboot,
and no more than once every 6 hours — even across launches), the launcher requests the latest release in
the background without delaying startup from `https://api.github.com/repos/fxgl/steamac/releases/latest`
(unauthenticated, 10 s timeout; drafts and prereleases are excluded) and compares its `vX.Y[.Z]` tag with
its own version (`CFBundleShortVersionString`, numerically: 1.3.10 > 1.3.9). If a new version is
available, the window shows “FX Steam Launcher X.Y is available — you have …”, with the release
description and buttons **Download** (opens the release's `.dmg` in a browser, or the release page
otherwise), **Skip This Version** (this version is no longer offered at startup), and **Remind Me Later**
(offers it again at the next check). The menu item checks immediately — without the 6-hour limit and
including skipped versions — and reports “You're up to date” or an error; network and HTTP errors at
startup are only logged (`update: …`). The dev launcher `work/out/steamac-vm` does not check at startup
(the menu works); source builds (`bundle.sh`) do.

Privacy of the GitHub check: the request goes only to `api.github.com` (GitHub) and includes only `User-Agent:
FXSteamLauncher/<version>` (plus standard HTTP headers and the previous response's ETag, so GitHub can
reply “not modified”); no Mac or user identifiers, cookies, or Sentry. The check time, ETag, response,
and skipped version are stored in settings (`updateLastCheck`, `updateETag`, `updateCachedBody`,
`updateCachedURL`, `updateSkippedVersion`).

Tests: `STEAMAC_UPDATE_URL` overrides the URL (release JSON or a `/releases` array, `http(s)://` or
`file://`; it also enables the startup check for the dev launcher), `STEAMAC_FAKE_VERSION` overrides
the launcher version, `STEAMAC_UPDATE_FEED` the appcast of in-app updates; FIFO `--control-fifo`:
`update check|startup|state`, `update press download|skip|later|ok|releases|cancel|hide|install|quit`
(`install` / `quit`: Install and Relaunch / Install on Quit), `update dump PNG` (the window and
`-with-vm.png` — together with the VM window, as shown on screen). Local feed: see
[Distribution](building.md#distribution-dmg).

## Game statistics

Which games start and how fast they run on which Mac, collected from players who agree and shown
to everyone at <https://fxgl.github.io/steamac/games.html> (`docs/games.html`).

The guest agent watches Steam's game scopes (`app-steam-app<appid>-*.scope`, the same cgroups
**Pause the game** freezes) on its 1 s heartbeat and reports `game-start <appid>`, `game-mem <appid>
<anon_kib> <guest_used_kib>` every 5 s (the game's anonymous memory and the guest's used memory),
`game-proton <appid> <version>` (the prefix's `compatdata/<appid>/version`), immediately followed by
`game-gfx <appid> dxmt|vulkan` (the actual graphics path), and `game-exit <appid>`;
`game <appid> <name>` follows the first `game-start` or focus of an app id per boot. The launcher
(`GameStats.swift`) makes one report per game run: how long it ran and had focus (not paused, VM
not suspended), whether a window ever appeared and after how long (a run without one is a failed
start), frame rate from the guest's scanout-0 flush intervals while the game has focus (average,
median, 1% low, hitches over 50 ms per minute; gaps over 1 s are left out; libkrun's
`present_frame`, the same flushes `--perf-stats` reports), peak game / guest memory, the VM
process's peak `phys_footprint` on the Mac, resolution, Proton version, and the end (`exit`,
`shutdown`, `session`). Each report carries the Mac (model, chip, P and total cores, GPU cores,
RAM, macOS), the VM (vCPUs, RAM, Vulkan driver, wmtr, refresh rate, SteamOS build) and the
launcher version.
New session and rating reports use schema `v:2`, with optional `gfx` (`vulkan` or `dxmt`) and `env`
(the allowlisted launch words described in “Per-game profiles”, at most 256 characters). The actual
graphics path comes from `game-gfx`; ratings use the last session's graphics path and launch words.
The service still accepts v1 (including previously saved sessions), storing its `gfx`/`env` as NULL.
Invalid v2 assignments are rejected with HTTP 400; valid ones are sorted by name, last duplicate wins.

Every report is kept on this Mac (`~/Library/Application Support/es.fxgam.steamac/game-stats.json`,
20 sessions per game) and listed in **Settings → Games**. Session reports and ratings are uploaded
only when **Share game statistics** is on. After the first game with a window, the launcher asks
once in a window beside the VM window that does not take the keyboard or the captured mouse
(**Share** / **Don't Share**); the switch in Settings → Games changes it at any time. While it is on,
finished sessions and ratings go to the statistics service (`POST /v1/sessions`, `POST /v1/ratings`),
sessions recorded earlier included. For a game whose **Share** box is off, no sessions are uploaded
and any shared rating is withdrawn (`"rating": "none"`). Uploads go one at a time; HTTP 400/413
drops a report, anything else is retried after 10 minutes, at the next session end or the next boot.

Recommendation lookups are separate from uploads. Opening **Settings → Games** never fetches
recommendations. Clicking **Get Recommendation** or **Retry** sends the game's Steam App ID and
this Mac's RAM, GPU core count and performance core count to the statistics service, even if sharing
is off.

Privacy: no name, user or computer name, Steam account, files or arbitrary typed text (only the
allowlisted graphics launch words above are shared); the install ID is a
random UUID used only for distinct-Mac counts and rate limits (not the crash reports' ID); the
service uses the client address only as a transient rate-limit key and never stores it.

The page publishes aggregates only, never single sessions, and lists the chips each game was tested
on. Configurations group by chip, RAM, Vulkan driver, graphics path and launch words (`gfx`/`env`;
`wmtr` is retained for compatibility). For old rows, NULL `gfx` means `vulkan` when `wmtr=0`,
but unknown when `wmtr=1`: permission to use DXMT does not prove a game used it.
Its **My Mac** filter keeps only reports from Macs that are not better than the visitor's (GPU cores,
RAM and performance cores each at most the given value; the API's `max_gpu_cores`, `max_ram_gb`,
`max_pcores`): what runs there should run here. **Open Statistics Page** in the launcher passes this
Mac's values (`?chip=…&gpu=…&ram=…&pcores=…`) and turns the filter on; the page remembers them.

`GET /v1/games/<appid>` also returns `recommended` (or `null` if no profile qualifies).
It groups `(driver, gfx, env)` across all chips within the same My Mac filters, requiring at least
two distinct installations across sessions or ratings; unknown graphics paths cannot win.
Score = `(well + 0.5 × issues) / total ratings` (zero without ratings); ties favor higher
`launch_rate`, then lower `early_exit_rate`, with missing rates last and deterministic
driver/graphics/env ordering after that. The result includes driver, graphics path, launch words,
install/session counts, ratings, median average FPS and launch rate. The site and launcher show
the recommendation, but it is never applied automatically.

Service: `services/game-stats` — a Cloudflare Worker with a D1 database (strict validation,
idempotent session IDs, 30 POSTs per minute per address, a daily cap per install, aggregates
`GET /v1/games` and `GET /v1/games/<appid>` cached for 5 minutes in D1, because the Cache API does
nothing on `workers.dev`). Deploy once:

```sh
cd services/game-stats && npm install
npx wrangler login
npx wrangler d1 create steamac-game-stats      # put the printed database_id into wrangler.toml
npx wrangler d1 migrations apply steamac-game-stats --remote
npx wrangler deploy                            # prints https://steamac-game-stats.<account>.workers.dev
```
For an existing deployment, migration `0002_profiles.sql` adds `gfx`/`env` to sessions and ratings
and updates the grouping indexes while preserving v1 data; `0003_responses.sql` adds the response
cache table. Run `npx wrangler d1 migrations apply steamac-game-stats --remote` **before**
`npx wrangler deploy`.

The Worker URL goes into `host/launcher/Info.plist` (`SteamacGameStatsURL`) and `docs/assets/games.js`
(`API`). Local: `npx wrangler d1 migrations apply steamac-game-stats --local && npx wrangler dev`,
`npm test`.

Tests: `STEAMAC_GAME_STATS_URL` overrides the service (and enables uploads in the dev launcher
`work/out/steamac-vm`, which otherwise sends nothing), `STEAMAC_GAME_STATS_FILE` the local file;
FIFO `--control-fifo`: `guest game-start <appid>` etc. feed the tracker, `stats state|flush|ask|dump
PNG|reset-question`, `stats press share|decline`, `settings games`.
