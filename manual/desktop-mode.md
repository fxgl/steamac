# Desktop Mode

**English** · [Русский](ru/desktop-mode.md) · [简体中文](zh/desktop-mode.md)

← [Manual](README.md)

Steam → Power → **Switch to Desktop** starts KDE Plasma; the desktop's **Return to Gaming Mode** icon
goes back. On the Steam Frame image this mode is a VR desktop (`plasma-session.target` wants
SteamVR, which the VM masks), so the layer replaces it: `plasma-session.target` and
`steamac-nested-desktop.service` run Plasma as one KWin window inside the same gamescope
(`/usr/lib/steamac/nested-desktop`, like Valve's `steamos-nested-desktop`), sized to the display, so
gamescope shows it 1:1. `gamescope-onready` waits for that service: when Plasma exits, the session
ends and SDDM logs back in. Plasma gets its own runtime directory and D-Bus session bus; the layer's
`steamosctl` shim (`/usr/lib/steamac/desktop-bin`, first in its PATH) sends SteamOS commands such as
Return to Gaming Mode to the outer session bus, where steamos-manager runs. The desktop's Steam
autostart (`/usr/lib/steamac/desktop-xdg/autostart/steam.desktop`) keeps the client chosen in the
launcher instead of the stock `-deckard` (Frame client), which would download the other client on
every switch. The progress agent reports `focus desktop <w>x<h>` (the Plasma window): the launcher
keeps the relative pointer and maps it onto that window as gamescope scales it, and a boot straight
into Desktop Mode (`steamos-session-select plasma-persistent`) reports `ready` when the desktop is up.

**Keyboard layouts.** With Settings > General **Use the Mac's keyboard layouts in Desktop Mode** (on
by default, applies now), Desktop Mode has the keyboard layouts enabled on the Mac, in the Input
menu's order, and switches with the Mac's input source (Globe key, Control-Space). The launcher maps
each to an XKB layout (`com.apple.keylayout.Russian` → `ru(mac)`, `RussianWin` → `ru(winkeys)`,
`German` → `de(mac)`, …; otherwise only a closed list of unambiguous first languages; unknown
sources are skipped; an input method counts as the layout it types with). At most four layouts
are sent (XKB's limit), always including the active one, as `keyboard-layout <active index> <layout(variant)>…` over
`fx.progress` on every change and whenever Desktop Mode gets the focus, again 1.5, 4 and 8 s later
(Plasma's startup selects its first layout after KWin took ours). The agent runs
`/usr/lib/steamac/desktop-keyboard` (latest request only, never blocking): it checks each layout
and variant against the guest's XKB symbols, drops unknown ones and recomputes the active index
(if the active layout was dropped, it does not switch). Like the Mac clock format, it follows
the Mac until changed in SteamOS: the first sync replaces even existing custom layouts; after
that an observed user edit of Plasma's layouts wins permanently. The marker is
`~/.config/steamac/mac-keyboard.json`; switching off the setting stops sync, without restoring
the old list. While following, it writes `kxkbrc` (including empty `DisplayNames`), asks KWin to
reload when the file changes or KWin's layout codes differ (`reloadConfig` on `org.kde.keyboard`
`/Layouts`), and selects the active layout (`org.kde.KeyboardLayouts.setLayout`) on the live nested
session bus (`nested_plasma/steamac-session-bus`; absent or stale bus means no-op). macOS often
posts its input-source notification 0.55–0.85 s after a Globe-key switch, so only while this setting
is on, Desktop Mode has focus and the launcher is active, it polls the current layout every 30 ms.
The keys stay the Mac's physical keys (evdev codes); the layout decides what they type.
Gaming mode keeps its layout.

Flatpak apps (Discover) run in bubblewrap, which mounts its own procfs in a user namespace. The kernel
allows that only while some procfs in the mount namespace is fully visible, and the initramfs binds
the synthesized `/proc/cmdline` over the real one; so it also mounts an untouched procfs at
`/run/steamac/proc` (`nosuid,nodev,noexec`). Without it every Flatpak app exits with `bwrap: Can't mount
proc on /newroot/proc: Operation not permitted`.

Desktop Mode runs `plasmashell` under `/usr/lib/steamac/desktop-shell`: the nested session has no systemd
user manager, so the stock service's restart does not apply, and a Wayland protocol error makes the shell
exit (`_exit`) without a crash handler, leaving a black desktop with only the KWin window (STEAMAC-AJ/9P).
After an abnormal exit the shell is restarted, at most three starts per minute; a normal logout or shell
exit is not restarted. Problem reports include the desktop's package versions and a journal of the shell
and compositor.
