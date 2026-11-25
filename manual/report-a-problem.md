# Report a Problem

**English** · [Русский](ru/report-a-problem.md) · [简体中文](zh/report-a-problem.md)

← [Manual](README.md)

If something does not work, send a report to the developers directly from the launcher:
**Help → Report a Problem…** (or from the app menu), the **Report a Problem…** button in
Settings → General, the **Report…** link on the “SteamOS is not responding…” card, and the
**Report…** button in the “FX Steam Launcher stopped unexpectedly” window that appears after
the VM exits unexpectedly (crash, error). The dialog has:
email (required, remembered on this Mac so the developers can reply), a description (what you did,
what you expected, what happened), and checkboxes for attachments:

- **Include launcher logs** (enabled) — messages from the launcher, libkrun, virglrenderer, and MoltenVK
  for this session (the last ~2 MB, both processes) and `perf:`/`stall:` lines; paths `/Users/<name>` → `~`,
  the user and computer names, email addresses, and IP addresses are redacted;
- **Include SteamOS logs (system journal, Steam/Proton logs)** (enabled) — the guest console (hvc0) for
  the session and a `steamos-logs.tar.gz` archive collected by the guest agent: the systemd journal
  for the current boot (`journalctl -b`, the last 5000 lines, plus the user journal), `coredumpctl list`/`info`,
  `dmesg`, `systemctl --failed`, `os-release`, `layer-release`, `/proc/cmdline`, `df`/`free`,
  thread IDs/states/CPU/wait channels and command names (`threads.txt`, no command arguments), tails of
  Steam client logs (`console_log`, `stderr`, `bootstrap_log`, `compat_log`, `connection_log`,
  `webhelper`, `cef_log`, `shader_log`, `steamui_*`, Steam Input's `controller`, `controller_ui` and
  `cloud_log`) and Proton logs (`~/steam-*.log` from `PROTON_LOG=1`,
  `version` and `config_info` of prefixes in `compatdata`), FEX tool build ID / Steam manifest /
  configuration, an opt-in FEX log, memory limits, memory/IO/CPU pressure (`/proc/pressure/*`),
  `/proc/vmstat` and three `vmstat` samples, SteamVR and streaming log tails (`vrserver`,
  `vrcompositor`, `vrmonitor`, `vrwebhelper`, `vrstream`, `streaming_log`, 256 KiB each, IP addresses
  redacted), and the last 512 KiB of American Truck
  Simulator's `game.log.txt`. For an ATS emulator crash, set its Steam launch options to
  `FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%`, reproduce, and report;
  the collector includes the last 512 KiB of that log. Remove the launch options afterwards.
  Proton logs larger than 1 MiB are collected as a scrubbed first-1 MiB startup excerpt plus the last
  1 MiB, with the middle omitted, so the runtime header and the first exception survive crash-handler
  spam (STEAMAC-AA). Desktop Mode reports record whether `plasmashell`, KWin and Discover are running and
  allowlisted renderer flags, without process arguments or environment values (STEAMAC-9P). Launcher logs
  record Game Mode eligibility (Info.plist keys at runtime and on disk), native fullscreen state and
  filtered `gamepolicyd` messages (STEAMAC-9V).
  Without Proton logs the archive notes that `PROTON_LOG=1 %command%` as a game's launch options,
  one reproduction and a new report are needed to see a Windows game's own failure. Unity Player and
  Easy Anti-Cheat text logs are collected from the running or last-launched game's Proton prefix and the
  three most recently modified prefixes across Steam libraries (at most four logs of 256 KiB per prefix,
  no links out of the prefix, no saves or binaries, scrubbed); they do not imply that a game or its
  anti-cheat works.
  FEX re-raises a crash of the emulated game from its JIT code, so the core's stack shows only an
  anonymous AArch64 address. To record where the x86_64 code faulted, create
  `~/.local/share/Steam/steamapps/compatdata/<appid>/fex-emu/AppConfig/<executable>.json` (ATS:
  `270880/fex-emu/AppConfig/amtrucks.json`) containing
  `{"Config":{"Env":"LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so"}}`, reproduce, and report.
  Steam launch options cannot do this: FEX's compat tool removes `LD_PRELOAD` from the environment.
  On SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT the library writes the x86_64 RIP, the fault address,
  the registers, a backtrace with the module and offset of every frame, and the memory map to
  `~/.local/state/steamac/fault-report.txt`. The file stays under 256 KiB and the report includes it
  as `fex/fault-report.txt`. Then the game's own handler or the default action runs, so the crash and
  its core dump are unchanged. Without that file the library is never loaded; delete it afterwards.
  Completed crash metadata is exported by a root hook for `steamos` only (root-owned, mode 0640);
  raw cores remain private and are never attached. `coredump-pending.txt` identifies dumps still
  running: reports do not wait for them; send another report once they finish. Namespace-aware
  stack extraction resolves pressure-vessel libraries where symbols are available (FEX JIT code
  may still be unsymbolized). Core processing limits are not lowered: oversized cores would lose
  their backtraces, and `Storage=none` still writes a full temporary core. Steam IDs (`[U:1:…]`,
  7656119…, account IDs as in `userdata/<n>`), Steam account/persona names and email addresses are replaced with placeholders before
  packaging; `collect-notes.txt` lists what could be read. Over SSH, the same scrubbed archive is
  available with `/usr/lib/steamac/fx-progress-agent collect > /tmp/steamos-logs.tar.gz`;
- **Include a screenshot of the VM window** (disabled by default: the image may show your Steam
  account name and friends).

`system-info.txt` (app and macOS versions, Mac model, GPU, build UUIDs of libkrun/virglrenderer/MoltenVK,
kernel, SteamOS BUILD_ID, layer release, disk sizes, VM settings, collection notes) and `settings.txt`
(saved settings and command-line overrides; the SSH password is stored in Keychain and never included
in the report, nor are game titles) are always attached. **Show What Will Be Sent** assembles the report
and opens its folder in Finder — exactly its contents are sent.

The report goes to Sentry (`sentry.fxgam.es`, the same project) as User Feedback: email, description, a
link to the latest error event in this session (if any), and files as attachments, in one envelope sent
directly to the envelope endpoint so the server's response is visible. It also works with crash reports
disabled (an explicit user action: the SDK and crash handler do not start in that case). Attachments are
limited to 20 MB (older portions of logs are trimmed first, then the screenshot and SteamOS archive are
dropped); on an HTTP 413 response, the limit is halved and the report is sent again. After sending, a
short Report ID is shown (the first 8 characters of the event ID). If sending fails, the folder remains
at `~/Library/Logs/es.fxgam.steamac/reports/<date>-<ID>/` (`report.json` with the email and description
plus files); the dialog offers **Retry** and **Reveal in Finder**, and the folder can be emailed.

How it works: the supervisor always pipes stderr from both processes and writes it to
`/tmp/steamac-<pid>/launcher.log` (timestamped, rotated at 4 MB); the VM process writes the hvc0
console to `console.log` alongside it; the directory is removed when the launcher exits. Guest logs
are requested over the same `fx.progress` port in the reverse direction: the launcher writes
`collect-logs <id>`, the agent (running as the session user, with access only to what that user can read)
responds with `logs-begin <id> <size>`, lines of `logs <id> <base64>`, and
`logs-end <id> <sha256>` (or `logs-failed <id> <reason>`); the launcher assembles the archive and
verifies its size and SHA-256. If there is no response within 20 s or the agent is not running (no
heartbeat), the report is sent without guest logs, with a note in `system-info.txt`.

Testing: `--control-fifo PATH`, commands `report open`, `report fill EMAIL TEXT…` (event tagged
`test=true`), `report include launcher|steamos|screenshot on|off`, `report preview`, `report send`,
`report retry`, `report dsn DSN|default`, `report dump PNG`, `report close`; `STEAMAC_REPORT_DSN`
overrides the DSN (failure path), `STEAMAC_SENTRY_DEBUG=1` prints the server's response. Post-crash
window: `--sentry-test-crash abort` with `STEAMAC_REPORT_DUMP=<dir>` (PNGs of the window and dialog,
then it closes on its own; `STEAMAC_REPORT_TEST_SEND=1` also sends a test report).
