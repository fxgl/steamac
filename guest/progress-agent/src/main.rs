//! fx-progress-agent — steamac guest side of the "FX STEAM LAUNCHER" overlay.
//!
//! Runs as the session user inside the gamescope session
//! (fx-progress-agent.service, pulled in by gamescope-session.target and, in
//! Desktop Mode, plasma-session.target) and
//! writes the line protocol of local://overlay-contract.md to the
//! virtio-console port /dev/virtio-ports/fx.progress:
//!
//!   stage <id> <percent> <text>   ids: session steam-check steam-download
//!                                 steam-install steam-start; percent -1 = indeterminate
//!   log <text>                    detail line ("583 / 662 MB · 12.4 MB/s")
//!   ready                         Steam UI (Desktop Mode: the desktop) is on screen
//!   shutdown <poweroff|reboot>    session torn down by a system shutdown
//!   game <appid> <name>           display name from the appmanifest, once per app id and
//!                                 boot, after its first `game-start` or `focus game`
//!   focus steam [<w>x<h>] | focus game <appid> [<w>x<h>] | focus desktop [<w>x<h>]
//!                                 gamescope's focused app (GAMESCOPE_FOCUSED_APP; 0 and
//!                                 769 = Steam UI) and the size of the surface the cursor
//!                                 moves on (focus.rs), for the launcher's pointer handling;
//!                                 `focus desktop <w>x<h>` = the Desktop Mode session's Plasma
//!                                 window of that size, bare `focus desktop` = the session
//!                                 ended without a system shutdown
//!   alive <uptime_ms> <loadavg1>  heartbeat, once a second from agent start
//!   logs-begin / logs / logs-end / logs-failed   log bundle answering the
//!                                 host's `collect-logs <id>` (collect.rs; the
//!                                 launcher's Report a Problem)
//!   game-frozen <appid> / game-thawed <appid>   a freeze took effect / the game
//!                                 was thawed (freeze.rs; the "Game paused" overlay)
//!   game-start <appid>            first Steam scope appeared, including at agent start
//!   game-mem <appid> <anon_kib> <guest_used_kib>   every 5 s: summed scope anon
//!                                 memory and MemTotal - MemAvailable, both in KiB
//!   game-proton <appid> <version>  once per run when compatdata version is readable:
//!                                 first token of the first line, printable ASCII, <= 64 chars
//!   game-gfx <appid> dxmt|vulkan  immediately after game-proton, from that Proton's DXMT marker
//!   profiles-ok <sha256> applied|pending  exact received JSON digest; pending needs a Steam restart
//!   game-exit <appid>             last Steam scope disappeared (games.rs);
//!                                 app ids 0 and 769 are excluded from per-game statistics
//!   cursor-ready                  port opened; host resends its cursor-track policy
//!   cursor 0|1                    the focused game's cursor visible (cursor.rs; DXMT path overlay)
//!   cursor-image <w> <h> <xhot> <yhot> <base64>   the X cursor bitmap (BGRA), on change
//!   cursor-pos <x> <y> <win_w> <win_h>           its position in the focused game's X window
//!
//! Host -> guest (same port): `collect-logs <id>`, served at any point of the
//! lifecycle below (worker thread; the bundle goes out from the main loop);
//! `compact-disk <id>` (compact.rs: root fstrim via fx-compact-disk.service so
//! the Mac's sparse steamos.img reclaims SSD space); `freeze-game <appid>` /
//! `thaw-game` / `still-background` (freeze.rs: pause the focused game while the
//! launcher is in the background); `profiles <base64-json>`, `launch <appid>`,
//! `restart-steam` (profiles.rs: serialized background worker);
//! `keyboard-layout <index> <layout[(variant)]>...` (keyboard.rs: latest-only worker);
//! `cursor-track 1|0` enables/disables cursor X work (default off); enable also
//! resynchronizes the full snapshot after the host/agent connection restarts.
//!
//! Lifecycle
//!   1. port missing (older launcher) -> exit 0 quietly.
//!   2. `stage session 100`, then follow the Steam bootstrapper log
//!      (steamlog.rs, messages in any Steam language: steamstrings.rs) and the
//!      X11 window list (ui.rs) until a Steam UI window has been full-screen
//!      and focused for 1.5 s -> `ready`. Desktop Mode (GAMESCOPE_SESSION_TARGET
//!      plasma-session.target, no Steam): `ready` once the desktop window has
//!      gamescope's focus (focus.rs).
//!   3. `ready` is sent at most once per boot (marker in /tmp, keyed by
//!      boot_id): a restarted session/agent goes straight to step 4.
//!   4. Idle in ppoll(2) on the X connections and the heartbeat timerfd (one
//!      wakeup a second unless cursor tracking is enabled): report focus changes (focus.rs; also
//!      once at start, after `ready` and after every X reconnect) and wait
//!      for the shutdown:
//!      SIGTERM -> classify (shutdown.rs, bounded ~1.5 s) -> `shutdown <kind>`
//!      or `focus desktop` if only the session ends -> close port, exit 0.
//!
//! Never blocks the session: the port is non-blocking, all work is a 200 ms
//! tick of a few cheap reads.
//!
//! Environment overrides (testing / debugging):
//!   FX_PROGRESS_PORT=<path>   write to <path> instead of the virtio port
//!                             (a regular file, FIFO or another char device)
//!   FX_PROGRESS_STEAM_LOG=<path>  bootstrapper log to follow
//!   FX_PROGRESS_FORCE=1       ignore the once-per-boot `ready` marker
//!   FX_PROGRESS_STEAM_ROOT=<dir>  Steam root for appmanifest / compatdata lookup and
//!                             bootstrapper language files (default ~/.local/share/Steam)
//!   FX_PROGRESS_CGROUP_ROOT=<dir>  override the user manager cgroup for game tracking
//!                             and freezing (default discovered from /proc/self/cgroup)
//!
//! `fx-progress-agent clock-sync` is a separate mode, run as root by
//! fx-clock-sync.service: it steps the wall clock after the launcher resumes a
//! suspended VM (clock.rs, port fx.clock).
//!
//! `fx-progress-agent sleep <action>` replaces systemd-sleep as the ExecStart of
//! systemd-suspend.service (root): the launcher pauses the whole VM instead of
//! a guest kernel suspend nothing could wake (sleep.rs, port fx.sleep).
//!
//! `fx-progress-agent pad` is the root service fx-pad.service: the guest's
//! gamepad as a uinput device driven by the launcher, its rumble sent back, or
//! the Mac's DualSense itself as a uhid device (pad.rs, uhid.rs; port fx.pad).
//!
//! `fx-progress-agent clipboard` is the user service fx-clipboard-agent.service:
//! the clipboard shared with the Mac (clipboard.rs, clipx11.rs, clipwl.rs; port
//! fx.clipboard).

mod alive;
mod clock;
mod clipboard;
mod clipwl;
mod clipx11;
mod appname;
mod codec;
mod collect;
mod compact;
mod cursor;
mod focus;
mod pad;
mod port;
mod shutdown;
mod sleep;
mod steamlog;
mod steamstrings;
mod ui;
mod uhid;
mod freeze;
mod games;
mod profiles;
mod keyboard;

use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

use port::Port;
use ui::{Ui, UiState};

const DEFAULT_PORT: &str = "/dev/virtio-ports/fx.progress";
const TICK_MS: u64 = 200;
/// The UI window must stay on screen this long before `ready`.
const SETTLE: Duration = Duration::from_millis(1500);
/// "Verification complete" is followed within the same second by
/// "Downloading update..." when an update is pending; only without that is it
/// the plain start path.
const START_GRACE: Duration = Duration::from_millis(1500);
/// Give up on boot progress (overlay has its own 15 min fallback); keep only
/// the shutdown reporting.
const GIVE_UP: Duration = Duration::from_secs(30 * 60);

static SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_signal(sig: libc::c_int) {
    SIGNAL.store(sig, Ordering::SeqCst);
}

fn install_signals() {
    for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as *const () as usize;
            // No SA_RESTART: pause()/nanosleep() return on the signal.
            sa.sa_flags = 0;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(sig, &sa, std::ptr::null_mut());
        }
    }
}

fn terminated() -> bool {
    SIGNAL.load(Ordering::SeqCst) != 0
}

/// One nanosleep; returns early when a signal arrives.
fn nap(ms: u64) {
    let ts = libc::timespec { tv_sec: (ms / 1000) as _, tv_nsec: ((ms % 1000) * 1_000_000) as _ };
    unsafe { libc::nanosleep(&ts, std::ptr::null_mut()) };
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Stage {
    Session,
    Check,
    Download,
    Install,
    Start,
}

impl Stage {
    fn id(self) -> &'static str {
        match self {
            Stage::Session => "session",
            Stage::Check => "steam-check",
            Stage::Download => "steam-download",
            Stage::Install => "steam-install",
            Stage::Start => "steam-start",
        }
    }
}

struct Reporter {
    port: Port,
    stage: Stage,
    last_stage_line: String,
    last_log_line: String,
    pending_start: Option<Instant>,
    /// (log timestamp, KB) samples for the download rate.
    dl_samples: Vec<(i64, u64)>,
    pct: i32,
    /// Bootstrapper messages of every Steam UI language.
    msgs: steamstrings::Messages,
}

impl Reporter {
    /// Stages only move forward (the bootstrapper restarts itself after an
    /// update and logs "Verifying installation" again; that is still the start
    /// phase from the overlay's point of view), and within a stage the percent
    /// never goes back (-1 = indeterminate counts as lowest).
    fn stage(&mut self, s: Stage, pct: i32, text: &str) {
        if s < self.stage || (s == self.stage && pct < self.pct) {
            return;
        }
        self.stage = s;
        self.pct = pct;
        let line = format!("stage {} {} {}", s.id(), pct, text);
        if line != self.last_stage_line {
            self.port.send(&line);
            self.last_stage_line = line;
        }
    }

    fn log(&mut self, text: &str) {
        let line = format!("log {text}");
        if line != self.last_log_line {
            self.port.send(&line);
            self.last_log_line = line;
        }
    }

    /// One bootstrapper log line. Its progress messages are in the Steam UI
    /// language (steamstrings.rs); its plain log lines are always English.
    fn steam_line(&mut self, l: &steamlog::Line) {
        use steamstrings::Msg;
        let t = l.text.as_str();
        if t.starts_with("Startup - ") {
            self.stage(Stage::Check, -1, "Starting Steam client");
            return;
        } else if t.starts_with("Verification complete") {
            if self.stage < Stage::Start {
                self.pending_start = Some(Instant::now() + START_GRACE);
            }
            return;
        } else if t.starts_with("Nothing to do") || t.starts_with("Download skipped") {
            self.pending_start = None;
            self.stage(Stage::Start, -1, "Starting Steam");
            return;
        }
        match self.msgs.classify(t) {
            Some(Msg::Downloading(done, total)) => self.download(l.ts, done, total),
            Some(Msg::Verifying) => self.stage(Stage::Check, -1, "Verifying Steam installation"),
            Some(Msg::Checking | Msg::DownloadStarting) => {
                self.pending_start = None;
                self.stage(Stage::Check, -1, "Checking for Steam updates");
            }
            Some(Msg::Downloaded) => self.stage(Stage::Download, 100, "Steam update downloaded"),
            Some(Msg::Extracting) => self.stage(Stage::Install, 10, "Extracting Steam update"),
            Some(Msg::Installing) => self.stage(Stage::Install, 50, "Installing Steam update"),
            Some(Msg::CleaningUp) => self.stage(Stage::Install, 90, "Installing Steam update"),
            Some(Msg::UpdateComplete) => {
                self.stage(Stage::Install, 100, "Steam update installed");
                self.stage(Stage::Start, -1, "Restarting Steam");
            }
            None => {}
        }
    }

    /// "Downloading update (<done> of <total> KB)..." -> stage + "583 / 662 MB · 12.4 MB/s".
    fn download(&mut self, ts: Option<i64>, done: u64, total: u64) {
        self.pending_start = None;
        let pct = if total > 0 { (done * 100 / total).min(100) as i32 } else { -1 };
        self.stage(Stage::Download, pct, "Downloading Steam update");
        if let Some(ts) = ts {
            self.dl_samples.push((ts, done));
            self.dl_samples.retain(|&(t0, _)| ts - t0 <= 5);
        }
        let mb = |kb: u64| kb as f64 / 1000.0;
        let rate = match (self.dl_samples.first(), self.dl_samples.last()) {
            (Some(&(t0, k0)), Some(&(t1, k1))) if t1 > t0 && k1 >= k0 => Some(mb(k1 - k0) / (t1 - t0) as f64),
            _ => None,
        };
        let detail = match rate {
            Some(r) => format!("{:.0} / {:.0} MB · {:.1} MB/s", mb(done), mb(total), r),
            None => format!("{:.0} / {:.0} MB", mb(done), mb(total)),
        };
        self.log(&detail);
    }

    fn tick(&mut self, now: Instant) {
        if let Some(at) = self.pending_start {
            if now >= at {
                self.pending_start = None;
                self.stage(Stage::Start, -1, "Starting Steam");
            }
        }
    }
}

/// Is a process with this comm running (/proc scan, cheap)?
fn process_running(comm: &str) -> bool {
    let Ok(dir) = std::fs::read_dir("/proc") else { return false };
    for e in dir.flatten() {
        let name = e.file_name();
        let Some(n) = name.to_str() else { continue };
        if !n.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if let Ok(c) = std::fs::read_to_string(format!("/proc/{n}/comm")) {
            if c.trim_end() == comm {
                return true;
            }
        }
    }
    false
}

fn boot_time() -> i64 {
    std::fs::read_to_string("/proc/stat")
        .ok()
        .and_then(|s| s.lines().find_map(|l| l.strip_prefix("btime ").and_then(|v| v.trim().parse().ok())))
        .unwrap_or(0)
}

fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id").unwrap_or_default().trim().to_string()
}

fn ready_marker() -> String {
    format!("/tmp/.fx-progress-ready-{}", unsafe { libc::getuid() })
}

/// Host -> guest requests on the port: `<command> [args]`, one per line,
/// never blocking (each handler only starts work or answers right away).
fn serve_host(port: &mut Port, collector: &mut collect::Collector, freezer: &mut freeze::Freezer, focus: &focus::Focus,
              profiles: &profiles::Requests, compact: &compact::Compact, cursor: &mut cursor::Cursor, games: &games::Games) {
    for line in port.read_lines() {
        let line = line.trim();
        if let Some(enabled) = port::cursor_tracking(line) {
            cursor.set_tracking(enabled);
            // Hide old state until the new snapshot (also when a host reconnects).
            port.send_quiet("cursor 0");
            continue;
        }
        let (cmd, arg) = line.split_once(' ').map_or((line, ""), |(c, a)| (c, a.trim()));
        match cmd {
            "collect-logs" => collector.request(arg, port, games.diagnostic_appid()),
            "compact-disk" => compact.request(arg),
            "profiles" | "launch" | "restart-steam" => profiles.request(cmd, arg),
            "freeze-game" => match arg.parse::<u32>() {
                // Only the game that has the focus (the host may be a step behind).
                Ok(id) if focus.game() == Some(id) => freezer.freeze(id),
                Ok(id) => eprintln!("fx-progress: freeze-game {id}: not the focused game ({:?})", focus.game()),
                Err(_) => eprintln!("fx-progress: freeze-game: bad app id {arg:?}"),
            },
            "thaw-game" => freezer.thaw("launcher active again"),
            "still-background" => freezer.keepalive(),
            "keyboard-layout" => keyboard::request(arg),
            "" => {}
            _ => eprintln!("fx-progress: ignoring unknown host request {cmd:?}"),
        }
    }
    freezer.pump(focus.game());
    freezer.send_replies(port);
    profiles.pump(port);
    compact.pump(port);
}

/// Boot progress until `ready` (or give-up / SIGTERM); focus changes are
/// reported along the way.
fn report_boot(
    rep: &mut Reporter,
    focus: &mut focus::Focus,
    heartbeat: Option<&alive::Heartbeat>,
    collector: &mut collect::Collector,
    freezer: &mut freeze::Freezer,
    games: &mut games::Games,
    names: &mut appname::Names,
    profiles: &profiles::Requests,
    compact: &compact::Compact,
    cursor: &mut cursor::Cursor,
) {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/steamos".into());
    let log_path = std::env::var("FX_PROGRESS_STEAM_LOG")
        .unwrap_or_else(|_| format!("{home}/.local/share/Steam/logs/bootstrap_log.txt"));
    // 5 s margin: the guest clock is set from the RTC before Steam writes.
    let mut tail = steamlog::Tailer::new(log_path, boot_time() - 5);
    let mut ui = Ui::new();

    rep.stage(Stage::Session, 100, "Session started");
    rep.stage(Stage::Check, -1, "Starting Steam client");

    let begin = Instant::now();
    let mut on_screen_since: Option<Instant> = None;
    let mut next_ui = Instant::now();
    let mut next_proc = Instant::now();
    while !terminated() {
        let now = Instant::now();
        for l in tail.poll() {
            rep.steam_line(&l);
        }
        rep.tick(now);

        if now >= next_proc {
            next_proc = now + Duration::from_secs(1);
            // UI process up while no update is in progress: Steam is starting.
            if (rep.stage <= Stage::Check || rep.stage == Stage::Start) && process_running("steamwebhelper") {
                rep.pending_start = None;
                rep.stage(Stage::Start, 50, "Loading Steam UI");
            }
        }
        if now >= next_ui {
            next_ui = now + Duration::from_millis(500);
            match ui.check() {
                UiState::OnScreen => {
                    let since = *on_screen_since.get_or_insert(now);
                    if rep.stage < Stage::Download || rep.stage == Stage::Start {
                        rep.stage(Stage::Start, 90, "Opening Steam");
                    }
                    if now.duration_since(since) >= SETTLE {
                        rep.stage(Stage::Start, 100, "Steam is ready");
                        rep.port.send("ready");
                        eprintln!("fx-progress: ready: Steam UI {}", ui.on_screen_window());
                        let _ = std::fs::write(ready_marker(), boot_id());
                        return;
                    }
                }
                UiState::Partial => {
                    on_screen_since = None;
                    if rep.stage < Stage::Download || rep.stage == Stage::Start {
                        rep.stage(Stage::Start, 80, "Opening Steam");
                    }
                }
                UiState::NoWindow | UiState::NoDisplay => on_screen_since = None,
            }
        }
        rep.port.flush();
        serve_host(&mut rep.port, collector, freezer, focus, profiles, compact, cursor, games);
        collector.pump(&mut rep.port);
        focus.pump(&mut rep.port, false, names);
        cursor.pump(&mut rep.port);
        if let Some(hb) = heartbeat {
            if hb.pump(&mut rep.port) {
                games.pump(Instant::now(), &mut rep.port, names);
            }
        }
        if now.duration_since(begin) > GIVE_UP {
            eprintln!("fx-progress: no Steam UI after {} min, stop reporting boot progress", GIVE_UP.as_secs() / 60);
            return;
        }
        nap(cursor.wait_ms().map_or(TICK_MS, |ms| TICK_MS.min(ms as u64)));
    }
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("clock-sync") => std::process::exit(clock::run()),
        Some("sleep") => std::process::exit(sleep::run(&std::env::args().nth(2).unwrap_or_else(|| "suspend".into()))),
        Some("pad") => std::process::exit(pad::run()),
        Some("clipboard") => std::process::exit(clipboard::run()),
        Some("collect") => std::process::exit(collect::run_cli()),
        _ => {}
    }
    let port_path = std::env::var("FX_PROGRESS_PORT").unwrap_or_else(|_| DEFAULT_PORT.into());
    let mut port = match Port::open(&port_path) {
        Ok(p) => p,
        Err(e) => {
            // Older launcher without the port (or no permission): nothing to report to.
            eprintln!("fx-progress: {port_path}: {e}; exiting");
            return;
        }
    };
    // Old hosts ignore this; new hosts resend their current cursor-track policy.
    port.send_quiet("cursor-ready");
    install_signals();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/steamos".into());
    let steam_root = std::env::var("FX_PROGRESS_STEAM_ROOT").unwrap_or_else(|_| format!("{home}/.local/share/Steam"));
    let mut rep = Reporter {
        port,
        stage: Stage::Session,
        last_stage_line: String::new(),
        last_log_line: String::new(),
        pending_start: None,
        dl_samples: Vec::new(),
        pct: -1,
        msgs: steamstrings::Messages::new(steam_root, format!("{home}/.steam/registry.vdf")),
    };

    // Desktop Mode: Plasma instead of Steam in this gamescope session (focus.rs).
    let desktop = std::env::var("GAMESCOPE_SESSION_TARGET").is_ok_and(|t| t == "plasma-session.target")
        || std::env::var_os("FX_PROGRESS_DESKTOP_NATIVE").is_some();
    let mut focus = focus::Focus::new(desktop);
    let heartbeat = alive::Heartbeat::new();
    let mut collector = collect::Collector::new();
    let mut freezer = freeze::Freezer::new();
    let mut games = games::Games::new();
    let mut cursor_state = cursor::Cursor::new();
    let profiles = profiles::Requests::new();
    let compact = compact::Compact::new();
    let mut names = appname::Names::new(appname::steam_root(),
        format!("/tmp/.fx-progress-named-{}", unsafe { libc::getuid() }).into());
    let force = std::env::var("FX_PROGRESS_FORCE").map_or(false, |v| v == "1");
    let already = !force && std::fs::read_to_string(ready_marker()).map_or(false, |s| s.trim() == boot_id());
    let mut desktop_ready_pending = false;
    if already {
        eprintln!("fx-progress: ready already reported this boot; reporting focus/shutdown only");
    } else if desktop {
        // Booted straight into Desktop Mode (steamos-session-select plasma-persistent):
        // `ready` once the desktop is on screen (main loop).
        rep.stage(Stage::Session, 100, "Session started");
        desktop_ready_pending = true;
    } else {
        report_boot(&mut rep, &mut focus, heartbeat.as_ref(), &mut collector, &mut freezer, &mut games, &mut names, &profiles, &compact, &mut cursor_state);
    }
    // Once after `ready` (or at agent start on a later session): current focus.
    focus.pump(&mut rep.port, true, &mut names);

    // Idle until the session is torn down: block in ppoll(2) on the X
    // connection (focus changes), the heartbeat timer, host requests on the
    // port and finished log bundles, with the termination signals blocked
    // everywhere except inside ppoll, so a SIGTERM can neither be lost between
    // the flag check and the wait nor delay the shutdown report. Without an X
    // connection (gamescope restarting) it retries once a second.
    unsafe {
        let mut block: libc::sigset_t = std::mem::zeroed();
        let mut old: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut block);
        for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut block, sig);
        }
        libc::sigprocmask(libc::SIG_BLOCK, &block, &mut old);
        let mut pfds = Vec::with_capacity(8);
        while !terminated() {
            rep.port.flush();
            serve_host(&mut rep.port, &mut collector, &mut freezer, &focus, &profiles, &compact, &mut cursor_state, &games);
            collector.pump(&mut rep.port);
            focus.pump(&mut rep.port, false, &mut names);
            cursor_state.pump(&mut rep.port);
            if desktop_ready_pending && focus.desktop_shown() {
                desktop_ready_pending = false;
                rep.port.send("ready");
                eprintln!("fx-progress: ready: desktop on screen");
                let _ = std::fs::write(ready_marker(), boot_id());
            }
            if let Some(hb) = heartbeat.as_ref() {
                if hb.pump(&mut rep.port) {
                    games.pump(Instant::now(), &mut rep.port, &mut names);
                }
            }
            pfds.clear();
            pfds.extend_from_slice(&[
                libc::pollfd { fd: focus.fd().unwrap_or(-1), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: heartbeat.as_ref().map_or(-1, |h| h.fd()), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: rep.port.read_fd().unwrap_or(-1), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: collector.wake_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: profiles.wake_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: compact.wake_fd(), events: libc::POLLIN, revents: 0 },
            ]);
            cursor_state.poll_fds(&mut pfds);
            let mut wait_ms: i64 = if focus.connected() { -1 } else { 1000 };
            for deadline in [
                rep.port.has_pending().then_some(TICK_MS as i64),
                freezer.wait_ms(),
                cursor_state.wait_ms(),
            ].into_iter().flatten() {
                if wait_ms < 0 || deadline < wait_ms {
                    wait_ms = deadline;
                }
            }
            let ts;
            let tsp = if wait_ms < 0 {
                std::ptr::null()
            } else {
                ts = libc::timespec { tv_sec: (wait_ms / 1000) as _, tv_nsec: ((wait_ms % 1000) * 1_000_000) as _ };
                &ts as *const libc::timespec
            };
            libc::ppoll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, tsp, &old);
            // Host side of the port closed: no input until the agent restarts
            // (POLLHUP would otherwise end every wait at once).
            if pfds[2].revents & libc::POLLHUP != 0 {
                eprintln!("fx-progress: host closed the port; no more host requests");
                rep.port.stop_reading();
                cursor_state.set_tracking(false);
            }
        }
        libc::sigprocmask(libc::SIG_SETMASK, &old, std::ptr::null_mut());
    }
    // Never leave a game frozen behind (shutdown, session end).
    freezer.thaw("agent exiting");
    freezer.send_replies(&mut rep.port);
    let sig = SIGNAL.load(Ordering::SeqCst);
    match shutdown::detect() {
        Some(kind) => rep.port.send(&format!("shutdown {}", kind.word())),
        None => {
            // Only the gamescope session ends (Switch to Desktop, relogin):
            // whatever comes next is not gamescope, so the launcher should use
            // its absolute pointer (KWin handles it exactly). The next
            // gamescope session's agent sends `focus steam` again.
            eprintln!("fx-progress: signal {sig}, session ends without system shutdown");
            rep.port.send("focus desktop");
        }
    }
    // Short bounded retry if the host is momentarily not reading.
    let deadline = Instant::now() + Duration::from_millis(300);
    while rep.port.has_pending() && Instant::now() < deadline {
        nap(20);
        rep.port.flush();
    }
    // Port is closed on drop.
}
