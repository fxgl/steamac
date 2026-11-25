# Using the launcher

**English** · [Русский](ru/using.md) · [简体中文](zh/using.md)

← [Manual](README.md)

## FX Steam Launcher.app

`host/launcher/build.sh` (and `./build.sh host`) builds `work/out/FX Steam Launcher.app` in
addition to `work/out/steamac-vm` (`host/launcher/bundle.sh`): `es.fxgam.steamac`, libraries
(libkrun, libvirglrenderer, libMoltenVK, libepoxy) in `Contents/Frameworks` via `@rpath`, and in
`Contents/Resources` — gvproxy, the `Image` kernel, `initramfs.cpio.gz`, `steamac-layer.img`,
desync, and Valve's CA for disk creation (licenses are in `Resources/licenses`); the icon:
`host/launcher/AppIcon.icon` (an Icon Composer document) is compiled by `actool` into `Assets.car`
(Liquid Glass on macOS 26, ready-made renders for macOS 15), with a fallback `AppIcon.icns`;
ad-hoc signing with hypervisor + disable-library-validation entitlements. The app can be moved to
`/Applications`.

Launching from Finder (without arguments) uses the kernel, initramfs, and layer from the bundle,
and the SteamOS disk from Settings → Advanced → Disk image. By default:
`~/Library/Application Support/es.fxgam.steamac/steamos.img`; otherwise, the repository's
`work/out/steamos.img` (next to the bundle or where it was built). If there is no disk, a
first-launch window offers **Create New Disk…** (see the next section) or **Use Existing Disk…**
(the image is used in place and never copied; `scripts/build-image.sh` also builds one). A disk must be
a raw SteamOS GPT disk with this layout's partitions: a Steam Deck recovery archive or the macOS Steam
installer is rejected when chosen, and a saved disk that is not one is refused before boot
(STEAMAC-7Y/7Z). If the guest's initramfs fails anyway (`steamac-init: FATAL …`), the window shows the
failure instead of staying at 3%. A disk the launcher may not open or lock (permissions, removable-volume
access) is explained with Finder → Get Info → Sharing & Permissions and Privacy & Security, and logged,
not sent as a crash report (STEAMAC-15). In this
mode, the guest console and launcher log are written to
`~/Library/Logs/es.fxgam.steamac/steamac-vm.log`; SIGUSR1 frame dumps go there too. `./run.sh`
and `work/out/steamac-vm` work as before (window settings also apply to them unless overridden by
flags).

If the image is on an external disk, on the first launch from Finder macOS asks “FX Steam Launcher
would like to access files on a removable volume” — allow it (the VM waits for the disk to open
until you respond). Signing is ad-hoc, so macOS may ask again after the bundle is rebuilt.

One disk image can only be used by one VM at a time: the VM process holds an exclusive lock
(`flock`) on the writable disk until it exits, and a second launcher (another copy of the app, e.g.
a source build next to `/Applications`, or `steamac-vm`) refuses to start with “SteamOS is already
running” instead of mounting the same file systems twice (that corrupts `/home` and `/var`). The lock
outlives a killed launcher while the guest is still shutting down. Launchers built before the lock do
not check it.

If `/home` still has errors at boot (a VM killed while writing, or a disk used by two launchers that
predate the lock), SteamOS repairs it instead of stopping at “Starting SteamOS services…”: the launcher
adds `fsck.repair=yes` to the kernel command line, so systemd-fsck runs e2fsck answering yes rather than
only the safe preen fixes. Files e2fsck cannot place again end up in `/home/lost+found`.

## Uninstalling

The launcher does not partition the Mac's drive: SteamOS, its games and saves live in one disk image
file. To remove everything:

1. Quit FX Steam Launcher (SteamOS shuts down with it).
2. Delete the disk image shown in Settings → Advanced → Disk image (by default
   `~/Library/Application Support/es.fxgam.steamac/steamos.img`, deleted in step 4). A disk on another
   volume may also leave `steamos.provision.img` (until its first start finished) and the download cache
   `steamos.img.cache` next to it.
3. Move `FX Steam Launcher.app` from Applications to the Trash.
4. Delete the launcher's data (disk, game statistics, Moonlight pairing, download and crash-report caches,
   logs, saved problem reports) and settings in Terminal:

   ```
   rm -rf ~/Library/Application\ Support/es.fxgam.steamac ~/Library/Caches/es.fxgam.steamac \
          ~/Library/Logs/es.fxgam.steamac ~/Library/HTTPStorages/es.fxgam.steamac
   defaults delete es.fxgam.steamac
   ```
5. Optionally, in Keychain Access delete the “FX Steam Launcher: SteamOS user steamos” passwords
   (service `es.fxgam.steamac.guest-password`, one per disk).

## Languages

The launcher's interface is in English, Russian and Simplified Chinese and follows the macOS language
(System Settings → General → Language & Region, also per app under Applications). Logs, command-line
output, crash reports and problem reports stay in English. The fixed Steam stage texts of the guest
agent ("Checking for Steam updates", …) are shown translated (`BootProgress.localizedGuestText`); other
guest text (systemd lines, SteamOS itself) is not translated by the launcher.

Strings live in String Catalogs: `host/launcher/Localizable.xcstrings` (keys are the English text) and
`host/launcher/InfoPlist.xcstrings` (permission prompts). In code, SwiftUI literals (`Text("…")`,
`Button("…")`) are localized automatically; every other UI string is written as
`String(localized: "… \(value) …")` — one sentence per key, arguments interpolated, never assembled
from fragments — and text for logs or the CLI stays a plain English string. `host/launcher/build.sh`
compiles with `-emit-localized-strings`, syncs the extracted keys into the catalog (new keys are
added, removed ones marked stale — commit the catalog with the code), prints untranslated keys and
format-argument mismatches (`host/launcher/l10n.py check`), and compiles the catalogs into
`<lang>.lproj` next to `work/out/steamac-vm` and in the app's `Contents/Resources`. `dist.sh` refuses
a release with an incomplete language. Translating outside Xcode: `host/launcher/l10n.py export ru
todo.json` lists what is missing, `host/launcher/l10n.py import ru done.json` adds
`{"key": "text"}` or `{"key": {"plural": {"one": …, "few": …, "many": …, "other": …}}}`; Xcode can
also open the catalogs directly. To check a language without changing the system one:
`work/out/steamac-vm -AppleLanguages '(ru)' …`.

## Steam client

Which Steam client SteamOS launches is selected in the launcher: the first-launch window, the
**Create SteamOS Disk** window, and **Settings → Advanced → Steam client** (applies on next start,
“Restart VM to apply”); for a single launch, use `--steam-client frame|deck|deckbeta`. The launcher
passes the selection on every boot in the kernel cmdline as `steamac.steam_client=…`;
`/usr/lib/steamac/steam-client` in the layer reads it each time Steam starts. The Steam service
remains the stock SteamOS service (`steam.service`); the layer adds only a
`steam.service.d/50-steamac.conf` drop-in to it. Before startup, `steam-client` copies the stock
`/usr/share/deckard/RUNSTEAM.sh` to `~/.local/share/Steam/` — unchanged for the Frame client with
a remembered account, while in `deck`/branch/sign-in modes it removes only the lines containing
the `-deckard` and `-vrgamepadui` arguments from the copy. Valve's files are not included in the
layer.

| Option | What it is | Pros and cons |
|---|---|---|
| **Steam Deck client** (`deck`, by default) | public ARM64 Steam Deck client, `steamdeck_stable` branch (the same build as the public `steam_client_linuxarm64`; not officially announced for ARM) | normal sign-in with an on-screen QR code; a public client branch rather than an internal beta; **Proton Experimental (ARM64)** is a separate compatibility choice from x86-64 **Proton Experimental** |
| **Steam Deck client (beta)** (`deckbeta`) | `steamdeck_publicbeta` branch | like `deck`, but beta |
| **Steam Frame client** (`frame`) | Valve's beta client for Steam Frame (`linux_arm64_beta_<hash>`, flags `-deckard -vrgamepadui`) — as in the image | the client the image ships; an internal beta for a device not yet released; signing in uses sign-in mode (below) |

Changing the option makes Steam download a different client on the next start (up to ~1 GB,
progress in the boot overlay); when switching back to Frame, the Steam bootstrapper switches
automatically based on the `-deckard` flag. A manual `/etc/steamac/steam-client-branch` inside
SteamOS (any client branch) still works when `frame` is selected (or when the launcher passes no
parameter — older versions, a custom `--cmdline`); the launcher's `deck` / `deckbeta` selection
takes precedence over the file.

## Signing in

The Steam Frame client's sign-in screen is designed for a headset: “Tap to confirm” pairs with a
phone over Bluetooth LE, and “Scan QR code” opens a VR window — neither works in the VM (only the
password remains). Therefore, with the Steam Frame client, while `config/loginusers.vdf` has no
remembered account (new disk, signing out, signing in without “Remember me”), `steam-client`
starts Steam without `-deckard`/`-vrgamepadui`: the bootstrapper switches itself to the public
ARM64 Steam Deck client (`steamdeck_stable`), and sign-in shows an on-screen QR code (Steam Mobile
App → Steam Guard → scan) alongside the password form. After signing in with “Remember me”, Steam
restarts once and returns to the Steam Frame client (each client switch downloads up to ~1 GB;
progress is visible in the boot overlay). Without access to `client-update.steamstatic.com`,
sign-in mode is not enabled.

`RecvMsgClientLogOnResponse() : 'Try another CM'` lines in `connection_log.txt` on the sign-in
screen are normal: the CM server drops a connection without an account sign-in after ~60 s, and
the client reconnects.
