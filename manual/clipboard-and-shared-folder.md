# Clipboard and shared folder

**English** · [Русский](ru/clipboard-and-shared-folder.md) · [简体中文](zh/clipboard-and-shared-folder.md)

← [Manual](README.md)

## Clipboard

Settings → General → **Share clipboard with SteamOS** (on by default, applies now): text (UTF-8)
and PNG images copied on the Mac can be pasted in SteamOS (Ctrl+V — in Steam's text fields, games
and Desktop Mode apps) and the other way round; limits 1 MiB of text and 16 MiB per image (larger
items are skipped with a log line). Items that password managers mark as concealed or transient
(`org.nspasteboard.ConcealedType` / `TransientType`) stay on the Mac unless **Include concealed
(password manager) items** is on. The launcher checks the pasteboard's `changeCount` on a 0.5 s
timer only while the app is active and the VM runs, and once on every activation — never in the
background, while suspended or asleep; images from SteamOS land on the Mac as PNG + TIFF.

Transport: the virtio-console port `fx.clipboard`, framed binary messages (`HELLO` / `STATE` /
`SET` with sequence numbers / `ACK`; `host/launcher/Sources/steamac-vm/Clipboard.swift`,
`guest/progress-agent/src/clipboard.rs`). In the guest the user service
`fx-clipboard-agent.service` (`fx-progress-agent clipboard`, wanted by the gaming and the Desktop
Mode session) owns and watches `CLIPBOARD` (XFixes; TARGETS, UTF8_STRING, text/plain;charset=utf-8,
TEXT, STRING, image/png, INCR above 256 KiB) on **both** gamescope Xwayland servers (`:0` Steam,
`:1` games): gamescope syncs plain text between them itself by taking the selection over, but not
images or INCR-sized text. In Desktop Mode it also uses the Plasma session's Wayland clipboard
through `zwlr_data_control_manager_v1` (`ext_data_control_manager_v1` if present); KWin bridges it
to X11 apps there while an X11 window is active. Echo suppression is by content: each side
remembers the content it last sent or took over, so one copy is one transfer however often
gamescope, KWin or Klipper re-announce it. The selection present when a display appears (e.g.
Klipper's restored history) is not sent to the Mac; the shared content is offered there instead.
`--control-fifo` has `chord KEYCODE ctrl` (e.g. `chord 9 ctrl` = Ctrl+V in the guest) and
`set shareClipboard on|off`.

## Shared folder

**Settings → Advanced → Shared folder** (next start) exposes one Mac folder to SteamOS as a
virtio-fs device tagged `macshare`, mounted at **Mount point in SteamOS** (default
`/home/steamos/MacShare`) on every boot. Files are read and written in place, nothing is copied:
games stored on the Mac load at the Mac disk's speed, and what SteamOS writes there is on the Mac
at once. Off by default (no folder chosen). Command line: `--share DIR`, `--share-mount PATH`,
`--no-share` for one launch.

**Use as a Steam library** is on by default when a folder is shared (next start).
SteamOS creates **`<mount>/SteamLibrary/steamapps`** and registers `<mount>/SteamLibrary`
before Steam starts; no Desktop Mode “Add Drive” dialog is needed. In Steam's Storage settings
and install-location picker it is a second library named **Mac Share**, not a Deck-style
removable drive to format. `--share-library` / `--no-share-library` overrides this for one launch;
turning it off does not delete files or remove an already registered library.

Registration is **once per guest library path**. Removing it later in Steam is respected, even
after selecting another share and switching back. The marker is
`~/.local/share/Steam/config/steamac-share-library.json` (next to `config.vdf`); to register a
removed path automatically again, remove that path from the marker with Steam stopped.
Changing only the Mac folder while keeping the same guest mount path does not register it again.

**Filesystem: APFS recommended.** Proton stores Windows prefixes in each library's
`steamapps/compatdata`; these need symbolic links, not just writable game files. The hook probes
creating and following a symlink on the mounted share as `steamos`, and skips registration if
that fails (including exFAT, which has no symlinks). Mac OS Extended/HFS+ supports symlinks and
is not excluded by filesystem name. APFS virtio-fs read/write, chmod and a Proton 11 ARM64 prefix's
`dosdevices/c:` / `z:` symlinks were checked in the VM. A normal case-insensitive APFS share remains
case-insensitive in Linux: games that require distinct case-only filenames still need a
case-sensitive volume or the VM's internal library. This does not convert a Mac/Windows Steam
library into a Linux one; use a separate folder for SteamOS.

Implementation: `steam-share-library` is a non-blocking `ExecStartPre` of `steam.service`,
enabled by `steamac.share_library=1` alongside `steamac.share=PATH`. It checks the **exact
mount point** with `findmnt -t virtiofs` before touching any files. The Deck client tested
(1792618285) reads `~/.local/share/Steam/steamapps/libraryfolders.vdf` first, falls back to
`config/libraryfolders.vdf` if it is absent, and rewrites both as matching copies. The hook
atomically edits the authoritative file, preserving existing numbered entries (or importing
the legacy file); it supplies only `path` and `label`. Steam assigns `contentid`, measures
`totalsize`, and populates `apps` itself. No guessed IDs or installed-app records are written.
With a previously registered share absent, Steam **keeps the entry but logs “Install folder …
not mounted”**; it is not a usable install location until the share returns. The hook leaves
both the list and marker alone in that case, never creating a substitute library on the guest
disk. Keep an external volume connected before starting the VM; reconnect and restart if missing.

The launcher adds the device with `krun_add_virtiofs4` (`KRUN_SEMANTICS_LINUX_SIMPLIFIED`: the
guest sees its own uid/gid on every file, so the `steamos` user reads and writes without ownership
mapping; no DAX window) and passes `steamac.share=PATH` on the kernel command line. The initramfs
("shared folder" section) checks the path — a subdirectory of `/home/steamos/`, no empty, `.` or `..`
components, `[A-Za-z0-9/_.-]` only — and writes a runtime mount unit
(`/run/systemd/system/<path>.mount`, `What=macshare`, `Type=virtiofs`, `TimeoutSec=15`) wanted by
`multi-user.target`. It requires and runs after `steamos-create-homedir.service`, before user
sessions: on a fresh disk SteamOS must create and populate the user's home before systemd creates
the mount point, otherwise the home would be root-owned and its skeleton skipped. The unit has
`DefaultDependencies=no` to avoid ordering it before `local-fs.target` (home creation runs later);
it retains the usual unmount-on-shutdown ordering. A failed share does not prevent boot. The unit
lives for that boot only, like the runtime unit masks. A folder that is not there at start
(external drive unplugged, renamed) is logged and skipped — the launcher starts without the share;
only an explicit `--share` refuses to start. The Settings row shows it in red as not found.

**Security.** Per libkrun's security model, virtio-fs does not confine the guest to the shared
directory: on macOS the lookup does not filter `..`, and the launcher is not sandboxed. With a
share set, root in SteamOS (anything that gains root there: a game, a Flatpak, a Proton exploit)
can potentially read anything your Mac user can read, and write where that user can write. Share
only with a SteamOS you trust, and keep the share off when you do not need it. SSH is not involved.
