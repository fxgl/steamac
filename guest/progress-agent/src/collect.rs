//! Log bundle for the launcher's "Report a Problem" (host -> guest request on
//! the same fx.progress port):
//!
//!   host:  collect-logs <id>
//!   guest: logs-begin <id> <size>     size of the tar.gz in bytes
//!          logs <id> <base64>         CHUNK bytes per line
//!          logs-end <id> <sha256>     hex digest of the whole tar.gz
//!          logs-failed <id> <reason>  instead, when nothing could be packed
//!
//! Gathered in a worker thread as the session user, with whatever that user
//! can read: this boot's journal, coredumps, dmesg, OS/layer release, Steam
//! client logs (tails), Proton logs. Steam IDs, Steam account and persona
//! names and email addresses are replaced where recognisable before anything
//! is written. Packed with tar/gzip under /tmp and removed right after.

use std::os::fd::RawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use crate::codec;
use crate::port::Port;

/// Raw bytes per `logs` line (8192 base64 characters; the launcher splits
/// lines at 16 KiB).
const CHUNK: usize = 6144;
/// Whole transfer must leave the port within this time (the launcher waits 20 s
/// in total for the bundle).
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const JOURNAL_LINES: &str = "5000";
const STEAM_LOGS: &[&str] = &[
    "console_log.txt",
    "stderr.txt",
    "bootstrap_log.txt",
    "compat_log.txt",
    "connection_log.txt",
    "webhelper.txt",
    "cef_log.txt",
    "shader_log.txt",
    // Steam Input: controllers, the configuration each app gets, its cache and
    // workshop downloads (STEAMAC-37: console_log only says "CPrepareConfigWorker
    // failed" for a game whose configurator page stayed blank).
    "controller.txt",
    "controller_ui.txt",
    "cloud_log.txt",
];
const STEAM_LOG_TAIL: usize = 512 * 1024;
const PROTON_LOG_TAIL: usize = 1024 * 1024;
// SteamVR and Remote Play do not write their device/encoder failures to the
// client console reliably (STEAMAC-65). Fixed names bound both size and scope.
const VR_LOGS: &[&str] = &[
    "vrserver.txt",
    "vrcompositor.txt",
    "vrmonitor.txt",
    "vrwebhelper.txt",
    "vrclient_vrstartup.txt",
    "vrclient_vrmonitor.txt",
    "vrclient_vrwebhelper.txt",
    "vrstream.txt",
    "streaming_log.txt",
];
const VR_LOG_TAIL: usize = 256 * 1024;
// Startup failures may never reach Proton's exception log (STEAMAC-8Y/96/97).
// Only text logs in these games' own prefixes, never saves or arbitrary AppData.
const GAME_LOG_TAIL: usize = 256 * 1024;
const GAME_LOG_FILES: usize = 4;
const GAME_LOG_ENTRIES: usize = 128;

type Done = (String, Result<Vec<u8>, String>);

pub struct Collector {
    pending: Option<mpsc::Receiver<Done>>,
    wake_r: RawFd,
    wake_w: RawFd,
}

impl Collector {
    pub fn new() -> Collector {
        let mut fds = [-1; 2];
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } < 0 {
            fds = [-1, -1];
        }
        Collector { pending: None, wake_r: fds[0], wake_w: fds[1] }
    }

    /// Readable when a bundle is ready (for the idle loop's ppoll set).
    pub fn wake_fd(&self) -> RawFd {
        self.wake_r
    }

    /// Host request `collect-logs <id>` (dispatched by main.rs): start
    /// gathering in a worker thread; the bundle goes out from `pump`.
    pub fn request(&mut self, id: &str, port: &mut Port) {
        if id.is_empty() || id.len() > 32 || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            eprintln!("fx-progress: ignoring malformed collect-logs request");
            return;
        }
        if self.pending.is_some() {
            port.send(&format!("logs-failed {id} busy"));
            return;
        }
        eprintln!("fx-progress: collecting logs for the launcher (request {id})");
        let (tx, rx) = mpsc::channel();
        let (id, wake) = (id.to_string(), self.wake_w);
        std::thread::spawn(move || {
            let result = collect(&id);
            let _ = tx.send((id, result));
            unsafe { libc::write(wake, b"x".as_ptr() as *const libc::c_void, 1) };
        });
        self.pending = Some(rx);
    }

    /// Finished bundles to the port. Cheap when idle; call on every loop
    /// iteration.
    pub fn pump(&mut self, port: &mut Port) {
        let mut buf = [0u8; 64];
        while unsafe { libc::read(self.wake_r, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) } > 0 {}
        let Some(rx) = &self.pending else { return };
        let done = match rx.try_recv() {
            Ok(d) => d,
            Err(mpsc::TryRecvError::Empty) => return,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.pending = None;
                return;
            }
        };
        self.pending = None;
        match done {
            (id, Ok(bundle)) => {
                let mut lines = Vec::with_capacity(bundle.len() / CHUNK + 3);
                lines.push(format!("logs-begin {id} {}", bundle.len()));
                for c in bundle.chunks(CHUNK) {
                    lines.push(format!("logs {id} {}", codec::base64(c)));
                }
                lines.push(format!("logs-end {id} {}", codec::sha256_hex(&bundle)));
                let ok = port.send_bulk(&lines, SEND_TIMEOUT);
                eprintln!(
                    "fx-progress: log bundle {id}: {} bytes {}",
                    bundle.len(),
                    if ok { "sent" } else { "NOT sent (host not reading)" }
                );
            }
            (id, Err(reason)) => {
                eprintln!("fx-progress: log bundle {id} failed: {reason}");
                port.send(&format!("logs-failed {id} {reason}"));
            }
        }
    }
}

impl Drop for Collector {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.wake_r);
            libc::close(self.wake_w);
        }
    }
}

// MARK: collection
/// The same scrubbed bundle as Report a Problem, for guest SSH diagnostics.
pub fn run_cli() -> i32 {
    use std::io::Write;
    match collect("cli") {
        Ok(data) => match std::io::stdout().lock().write_all(&data) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("fx-progress: write bundle: {e}");
                1
            }
        },
        Err(e) => {
            eprintln!("fx-progress: {e}");
            1
        }
    }
}


fn collect(id: &str) -> Result<Vec<u8>, String> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/steamos".into());
    let steam = PathBuf::from(
        std::env::var("FX_PROGRESS_STEAM_ROOT").unwrap_or_else(|_| format!("{home}/.local/share/Steam")),
    );
    let base = PathBuf::from(format!("/tmp/.fx-logs-{}-{id}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let dir = base.join("steamos-logs");
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let result = gather(&dir, &steam, Path::new(&home)).and_then(|_| pack(&base));
    let _ = std::fs::remove_dir_all(&base);
    result
}

fn gather(dir: &Path, steam: &Path, home: &Path) -> Result<(), String> {
    let s = Scrubber::from_steam(steam, home);
    let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map_err(|e| format!("read boot ID: {e}"))?;
    let boot_match = format!("_BOOT_ID={}", boot_id.trim().replace('-', ""));
    let mut notes = vec![format!("account names/IDs and persona names recognised for scrubbing: {}", s.names.len())];
    let mut out = |name: &str, args: &[&str], max: usize| {
        let note = run(dir, name, args, max, &s);
        notes.push(format!("{name}: {note}"));
    };
    out("id.txt", &["id"], 4096);
    out("journal.txt", &["journalctl", "-b", "--no-pager", "-o", "short-monotonic", "-n", JOURNAL_LINES], 6 << 20);
    out("journal-user.txt", &["journalctl", "--user", "-b", "--no-pager", "-o", "short-monotonic", "-n", "2000"], 2 << 20);
    out("coredumps.txt", &["coredumpctl", "list", "--no-pager", &boot_match], 256 << 10);
    out("coredump-last.txt", &["coredumpctl", "-1", "info", "--no-pager", &boot_match], 512 << 10);
    out(
        "coredump-pending.txt",
        &["systemctl", "list-units", "systemd-coredump@*.service", "--state=running", "--no-pager"],
        64 << 10,
    );
    out("coredump-config.txt", &["systemd-analyze", "cat-config", "systemd/coredump.conf"], 64 << 10);
    out("dmesg.txt", &["dmesg"], 2 << 20);
    out("systemctl-failed.txt", &["systemctl", "--failed", "--no-pager"], 64 << 10);
    out("systemctl-user-failed.txt", &["systemctl", "--user", "--failed", "--no-pager"], 64 << 10);
    out("uname.txt", &["uname", "-a"], 4096);
    out("df.txt", &["df", "-h"], 64 << 10);
    out("free.txt", &["free", "-m"], 4096);
    // The first row is since boot; the next two measure current swap/IO/CPU
    // stalls. A single free/meminfo snapshot cannot explain STEAMAC-5S.
    out("vmstat.txt", &["vmstat", "-w", "1", "3"], 16 << 10);
    // Game/compositor waits distinguish a live guest waiting for GPU fences from a CPU stall
    // (STEAMAC-4F/3P). Command names only: never include arguments or environment variables.
    out("threads.txt", &["ps", "-eLo", "pid,tid,stat,pcpu,wchan:32,comm"], 256 << 10);
    // Lepton/Android launches (STEAMAC-8E) can wait in a Podman child without ever
    // starting Wine. Keep parent relationships and container state, not arguments,
    // environment, container contents or arbitrary container logs.
    out("process-tree.txt", &["ps", "--forest", "-eo", "pid,ppid,stat,etime,wchan:32,comm"], 256 << 10);
    out("podman-version.txt", &["podman", "--version"], 4096);
    out("podman-containers.txt", &["podman", "ps", "--all", "--format", "{{.ID}} {{.Image}} {{.Status}}"], 64 << 10);
    for (name, path) in [
        ("os-release.txt", "/etc/os-release"),
        ("layer-release.txt", "/usr/lib/steamac/layer-release"),
        ("cmdline.txt", "/proc/cmdline"),
    ] {
        let note = copy_tail(Path::new(path), &dir.join(name), 64 << 10, &s);
        notes.push(format!("{name}: {note}"));
    }
    // The root post-processing hook exports text for steamos only, after stack
    // extraction. Keep cores private, and never block the report on a running
    // dump (large FEX dumps can take minutes).
    for (name, snapshot, max) in [
        ("coredumps.txt", "list.txt", 256 << 10),
        ("coredump-last.txt", "info.txt", 512 << 10),
    ] {
        let path = Path::new("/run/steamac-coredumps").join(snapshot);
        if path.is_file() {
            let note = copy_tail(&path, &dir.join(name), max, &s);
            notes.push(format!("{name}: completed dump snapshot, {note}"));
        }
    }
    notes.push("coredump-pending.txt lists dumps still being processed; retry the report after they finish. Raw cores are never included.".into());
    for (name, path) in [
        ("max-map-count.txt", "/proc/sys/vm/max_map_count"),
        ("overcommit-memory.txt", "/proc/sys/vm/overcommit_memory"),
        ("overcommit-ratio.txt", "/proc/sys/vm/overcommit_ratio"),
        ("meminfo.txt", "/proc/meminfo"),
        ("vmstat-counters.txt", "/proc/vmstat"),
        ("pressure-memory.txt", "/proc/pressure/memory"),
        ("pressure-io.txt", "/proc/pressure/io"),
        ("pressure-cpu.txt", "/proc/pressure/cpu"),
        ("agent-status.txt", "/proc/self/status"),
        ("cpuinfo.txt", "/proc/cpuinfo"),
    ] {
        let note = copy_tail(Path::new(path), &dir.join(name), 64 << 10, &s);
        notes.push(format!("{name}: {note}"));
    }


    let logs = steam.join("logs");
    let steam_dir = dir.join("steam");
    let _ = std::fs::create_dir_all(&steam_dir);
    let mut names: Vec<String> = STEAM_LOGS.iter().map(|n| n.to_string()).collect();
    if let Ok(rd) = std::fs::read_dir(&logs) {
        let mut ui: Vec<String> = rd
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.starts_with("steamui_") && n.ends_with(".txt"))
            .collect();
        ui.sort();
        names.extend(ui);
    } else {
        notes.push(format!("steam logs: {} not readable", logs.display()));
    }
    for n in names {
        let note = copy_tail(&logs.join(&n), &steam_dir.join(&n), STEAM_LOG_TAIL, &s);
        notes.push(format!("steam/{n}: {note}"));
    }
    for n in VR_LOGS {
        let note = copy_tail(&logs.join(n), &steam_dir.join(n), VR_LOG_TAIL, &s);
        notes.push(format!("steam/{n}: {note}"));
    }

    // Proton: PROTON_LOG=1 writes ~/steam-<appid>.log; compatdata holds the
    // Proton version / config of each prefix.
    let proton_dir = dir.join("proton");
    let _ = std::fs::create_dir_all(&proton_dir);
    let mut proton_logs = newest(home, |n| n.starts_with("steam-") && n.ends_with(".log"));
    proton_logs.truncate(5);
    for p in &proton_logs {
        let name = p.file_name().unwrap_or_default().to_string_lossy().to_string();
        let note = copy_tail(p, &proton_dir.join(&name), PROTON_LOG_TAIL, &s);
        notes.push(format!("proton/{name}: {note}"));
    }
    let compat = steam.join("steamapps/compatdata");
    let mut prefixes = newest(&compat, |n| n.bytes().all(|b| b.is_ascii_digit()));
    prefixes.truncate(5);
    for p in &prefixes {
        let appid = p.file_name().unwrap_or_default().to_string_lossy().to_string();
        for f in ["version", "config_info"] {
            let src = p.join(f);
            if src.exists() {
                let note = copy_tail(&src, &proton_dir.join(format!("{appid}-{f}.txt")), 16 << 10, &s);
                notes.push(format!("proton/{appid}-{f}.txt: {note}"));
            }
        }
    }
    if proton_logs.is_empty() {
        notes.push("proton: no PROTON_LOG files. To capture a Windows game's failure, set Steam launch options to PROTON_LOG=1 %command%, reproduce once, then report again. Existing prefixes alone do not contain Wine exception logs.".into());
    }
    let fex_dir = dir.join("fex");
    let _ = std::fs::create_dir_all(&fex_dir);
    let fex_tool = steam.join("steamapps/common/FEX-Emu");
    for (name, src) in [
        ("appmanifest.txt", steam.join("steamapps/appmanifest_3127680.acf")),
        ("config-template.json", fex_tool.join("ConfigTemplate.json")),
        ("steam-amtrucks-config.json", compat.join("270880/fex-emu/Config.json")),
        ("steam-amtrucks-app-config.json", compat.join("270880/fex-emu/app_config.json")),
        ("steam-amtrucks-appconfig-amtrucks.json", compat.join("270880/fex-emu/AppConfig/amtrucks.json")),
        ("config.json", home.join(".fex-emu/Config.json")),
        ("amtrucks.json", home.join(".fex-emu/AppConfig/amtrucks.json")),
    ] {
        let note = copy_tail(&src, &fex_dir.join(name), 64 << 10, &s);
        notes.push(format!("fex/{name}: {note}"));
    }
    let fex_binary = fex_tool.join("usr/bin/FEX");
    if fex_binary.is_file() {
        let note = run(&fex_dir, "build-id.txt", &["readelf", "-n", &fex_binary.to_string_lossy()], 64 << 10, &s);
        notes.push(format!("fex/build-id.txt: {note}"));
    }
    let fex_info = fex_tool.join("usr/bin/FEXGetConfig");
    if fex_info.is_file() {
        let note = run(&fex_dir, "emulator-info.txt", &[&fex_info.to_string_lossy(), "--all-emu-info"], 64 << 10, &s);
        notes.push(format!("fex/emulator-info.txt: {note}"));
    }
    let note = copy_tail(&home.join("fex-amtrucks.log"), &fex_dir.join("amtrucks.log"), STEAM_LOG_TAIL, &s);
    notes.push(format!("fex/amtrucks.log: {note}"));
    notes.push("To enable FEX diagnostics for ATS, use Steam launch options: FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%".into());
    let note = copy_tail(&home.join(".local/state/steamac/fault-report.txt"), &fex_dir.join("fault-report.txt"), 256 << 10, &s);
    notes.push(format!("fex/fault-report.txt: {note}"));
    notes.push("To record where an emulated x86 game faults, create ~/.local/share/Steam/steamapps/compatdata/<appid>/fex-emu/AppConfig/<executable>.json with {\"Config\":{\"Env\":\"LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so\"}} (Steam launch options cannot set LD_PRELOAD: FEX's compat tool removes it)".into());
    collect_game_logs(dir, &compat, home, &s, &mut notes);

    notes.push(String::new());
    std::fs::write(dir.join("collect-notes.txt"), notes.join("\n")).map_err(|e| format!("write notes: {e}"))
}

fn collect_game_logs(dir: &Path, compat: &Path, home: &Path, s: &Scrubber, notes: &mut Vec<String>) {
    let game_dir = dir.join("games");
    let _ = std::fs::create_dir_all(&game_dir);
    let game_log = home.join(".local/share/American Truck Simulator/game.log.txt");
    let note = copy_tail(&game_log, &game_dir.join("amtrucks-game.log.txt"), STEAM_LOG_TAIL, s);
    notes.push(format!("games/amtrucks-game.log.txt: {note}"));
    for (appid, kind, relative) in [
        ("960170", "unity", "drive_c/users/steamuser/AppData/LocalLow"),
        ("2878980", "eac", "drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat"),
        ("381210", "eac", "drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat"),
    ] {
        let label = format!("{appid}-{kind}");
        let prefix = compat.join(appid).join("pfx");
        let files = startup_log_files(&prefix, relative, kind == "unity");
        if files.is_empty() {
            notes.push(format!("games/{label}: no startup logs found inside the game prefix"));
        }
        for (i, src) in files.iter().enumerate() {
            // Directory and file names may include user names or product/account IDs.
            // Stable, anonymous attachment names keep them out of bundle paths/notes.
            let name = format!("{label}-{i}.log");
            let note = copy_tail(src, &game_dir.join(&name), GAME_LOG_TAIL, s);
            notes.push(format!("games/{name}: {note}"));
        }
    }
}

fn startup_log_files(prefix: &Path, relative: &str, unity: bool) -> Vec<PathBuf> {
    let Ok(prefix) = prefix.canonicalize() else { return Vec::new() };
    let Ok(root) = prefix.join(relative).canonicalize() else { return Vec::new() };
    if !root.starts_with(&prefix) {
        return Vec::new();
    }
    let mut files = Vec::new();
    let mut remaining = GAME_LOG_ENTRIES;
    find_startup_logs(&root, 2, unity, &mut remaining, &mut files);
    files.sort_by(|a, b| {
        // Unity's current log before Player-prev.log, then deterministic paths.
        let previous = |p: &Path| p.file_name().is_none_or(|n| n != "Player.log");
        previous(a).cmp(&previous(b)).then_with(|| a.cmp(b))
    });
    files.truncate(GAME_LOG_FILES);
    files
}

fn find_startup_logs(dir: &Path, depth: usize, unity: bool, remaining: &mut usize, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if *remaining == 0 {
            break;
        }
        *remaining -= 1;
        // Never follow symlinks (Wine user folders can point outside the prefix),
        // or open sockets, pipes, device nodes, saves or binary anti-cheat modules.
        let Ok(ty) = entry.file_type() else { continue };
        if ty.is_dir() && depth > 0 {
            find_startup_logs(&entry.path(), depth - 1, unity, remaining, files);
        } else if ty.is_file() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if (unity && matches!(name, "Player.log" | "Player-prev.log"))
                || (!unity && name.ends_with(".log"))
            {
                files.push(entry.path());
            }
        }
    }
}

/// Run a command (10 s limit) and keep the tail of its scrubbed output.
fn run(dir: &Path, name: &str, args: &[&str], max: usize, s: &Scrubber) -> String {
    let out = Command::new("timeout")
        .args(["-k", "2", "10"])
        .args(args)
        .env("SYSTEMD_COLORS", "0")
        .env("SYSTEMD_PAGER", "")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .output();
    let out = match out {
        Ok(o) => o,
        Err(e) => return format!("not run ({e})"),
    };
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    let err = String::from_utf8_lossy(&out.stderr);
    if !err.trim().is_empty() {
        text.push_str("\n--- stderr ---\n");
        text.push_str(&err);
    }
    let lines = out.stdout.iter().filter(|&&b| b == b'\n').count();
    let text = s.scrub(tail(&text, max));
    match std::fs::write(dir.join(name), text) {
        Ok(()) => format!("{lines} lines, exit {}", out.status.code().unwrap_or(-1)),
        Err(e) => format!("write failed ({e})"),
    }
}

fn copy_tail(src: &Path, dst: &Path, max: usize, s: &Scrubber) -> String {
    use std::io::{Read, Seek, SeekFrom};
    let read_tail = || -> std::io::Result<(Vec<u8>, u64)> {
        let mut file = std::fs::File::open(src)?;
        let size = file.metadata()?.len();
        let start = size.saturating_sub(max as u64);
        if start != 0 {
            file.seek(SeekFrom::Start(start))?;
        }
        let mut data = Vec::new();
        file.take(max as u64).read_to_end(&mut data)?;
        Ok((data, size))
    };
    match read_tail() {
        Ok((data, size)) => {
            let text = String::from_utf8_lossy(&data);
            let text = if size > max as u64 { text.split_once('\n').map_or(text.as_ref(), |(_, rest)| rest) } else { &text };
            match std::fs::write(dst, s.scrub(text)) {
                Ok(()) if size > max as u64 => format!("last {} KiB of {} KiB", max >> 10, size >> 10),
                Ok(()) => format!("{} bytes", data.len()),
                Err(e) => format!("write failed ({e})"),
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => "absent".into(),
        Err(e) => format!("not readable ({e})"),
    }
}

/// Entries of `dir` whose name matches, newest first.
fn newest(dir: &Path, keep: impl Fn(&str) -> bool) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut v: Vec<(std::time::SystemTime, PathBuf)> = rd
        .flatten()
        .filter(|e| e.file_name().to_str().is_some_and(&keep))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    v.sort_by(|a, b| b.0.cmp(&a.0));
    v.into_iter().map(|(_, p)| p).collect()
}

/// The last `max` bytes, starting at a line boundary.
fn tail(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut cut = text.len() - max;
    while !text.is_char_boundary(cut) {
        cut += 1;
    }
    let rest = &text[cut..];
    match rest.find('\n') {
        Some(nl) => &rest[nl + 1..],
        None => rest,
    }
}

fn pack(base: &Path) -> Result<Vec<u8>, String> {
    let out = base.join("steamos-logs.tar.gz");
    let status = Command::new("tar")
        .arg("-czf")
        .arg(&out)
        .arg("-C")
        .arg(base)
        .arg("steamos-logs")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("tar: {e}"))?;
    if !status.success() {
        return Err(format!("tar exited {}", status.code().unwrap_or(-1)));
    }
    std::fs::read(&out).map_err(|e| format!("read bundle: {e}"))
}

// MARK: scrubbing

/// Replaces Steam IDs (`[U:1:<n>]`, 64-bit 7656119… IDs, the account IDs of
/// this machine's users as in `userdata/<n>` and `Steam Controller Configs/<n>`),
/// email addresses and the Steam account / persona names this machine knows
/// (loginusers.vdf, registry.vdf AutoLoginUser).
pub struct Scrubber {
    /// (ASCII-lowercased name, replacement)
    names: Vec<(String, &'static str)>,
}

impl Scrubber {
    pub fn from_steam(steam: &Path, home: &Path) -> Scrubber {
        let mut names: Vec<(String, &'static str)> = Vec::new();
        let mut add = |v: String, what: &'static str| {
            let v = v.trim().to_ascii_lowercase();
            if v.chars().count() >= 3 && !names.iter().any(|(n, _)| *n == v) {
                names.push((v, what));
            }
        };
        if let Ok(t) = std::fs::read_to_string(steam.join("config/loginusers.vdf")) {
            for (k, v) in vdf_pairs(&t) {
                match k.as_str() {
                    "AccountName" => add(v, "<account>"),
                    "PersonaName" => add(v, "<persona>"),
                    _ => {}
                }
            }
            for a in account_ids(&t) {
                add(a, "<accountid>");
            }
        }
        if let Ok(t) = std::fs::read_to_string(home.join(".steam/registry.vdf")) {
            for (k, v) in vdf_pairs(&t) {
                if k == "AutoLoginUser" {
                    add(v, "<account>");
                }
            }
        }
        // Longest first: a name containing another is replaced whole.
        names.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
        Scrubber { names }
    }

    #[cfg(test)]
    fn with_names(list: &[(&str, &'static str)]) -> Scrubber {
        Scrubber { names: list.iter().map(|(n, r)| (n.to_ascii_lowercase(), *r)).collect() }
    }

    pub fn scrub(&self, text: &str) -> String {
        let mut s = steam3_ids(text);
        s = steam64_ids(&s);
        s = emails(&s);
        s = ip_addresses(&s);
        for (name, with) in &self.names {
            s = replace_word(&s, name, with);
        }
        s
    }
}

/// Network diagnostics may contain LAN headset addresses or public endpoints.
/// Preserve ports and non-address version strings, but never upload literal IPs.
fn ip_addresses(text: &str) -> String {
    let token_char = |c: char| c.is_ascii_alphanumeric() || ".:%_-".contains(c);
    let mut out = String::with_capacity(text.len());
    let mut start = 0;
    for (end, c) in text.char_indices().chain(std::iter::once((text.len(), ' '))) {
        if token_char(c) {
            continue;
        }
        if start < end {
            let token = &text[start..end];
            let address = token.trim_end_matches('.');
            let host = address.split_once('%').map_or(address, |(host, _)| host);
            if host.parse::<std::net::IpAddr>().is_ok() {
                out.push_str("<ip>");
                out.push_str(&token[address.len()..]);
            } else if let Some((_, port)) = address.rsplit_once(':').filter(|(host, port)| {
                host.parse::<std::net::Ipv4Addr>().is_ok() && port.parse::<u16>().is_ok()
            }) {
                out.push_str("<ip>:");
                out.push_str(port);
                out.push_str(&token[address.len()..]);
            } else {
                out.push_str(token);
            }
        }
        if end < text.len() {
            out.push(c);
        }
        start = end + c.len_utf8();
    }
    out
}

/// `"key"   "value"` lines of a VDF text file.
fn vdf_pairs(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let q: Vec<&str> = l.split('"').collect();
            // ["\t\t", key, "\t\t", value, ""]
            (q.len() >= 5 && q[2].trim().is_empty()).then(|| (q[1].to_string(), q[3].to_string()))
        })
        .collect()
}

/// Account IDs (SteamID64 - 76561197960265728) of the users loginusers.vdf
/// lists, whose SteamID64s are its section names (`"7656119…"` alone on a line).
fn account_ids(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| {
            let id: u64 = l.trim().strip_prefix('"')?.strip_suffix('"')?.parse().ok()?;
            let account = id.checked_sub(76561197960265728)?;
            (id.to_string().starts_with("7656119") && account > 0).then(|| account.to_string())
        })
        .collect()
}

/// `[U:1:12345]` -> `[U:1:<id>]`
fn steam3_ids(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find("[U:1:") {
        out.push_str(&rest[..i + 5]);
        let after = &rest[i + 5..];
        let digits = after.bytes().take_while(|b| b.is_ascii_digit()).count();
        if digits > 0 {
            out.push_str("<id>");
        }
        rest = &after[digits..];
    }
    out.push_str(rest);
    out
}

/// 17-digit SteamID64 (7656119…) -> `<steamid>`
fn steam64_ids(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    let mut i = 0;
    while let Some(off) = text[i..].find("7656119") {
        let start = i + off;
        let end = start + 17;
        let digits_ok = end <= b.len() && b[start..end].iter().all(|c| c.is_ascii_digit());
        let bounded = (start == 0 || !b[start - 1].is_ascii_digit()) && (end >= b.len() || !b[end].is_ascii_digit());
        if digits_ok && bounded {
            out.push_str(&text[last..start]);
            out.push_str("<steamid>");
            last = end;
            i = end;
        } else {
            i = start + 1;
        }
    }
    out.push_str(&text[last..]);
    out
}

/// systemd unit types: `name@instance.<type>` is a unit, not an email address.
const UNIT_SUFFIXES: &[&str] =
    &["service", "socket", "target", "mount", "automount", "timer", "path", "slice", "scope", "device", "swap"];

fn emails(text: &str) -> String {
    if !text.contains('@') {
        return text.to_string();
    }
    let b = text.as_bytes();
    let local = |c: u8| c.is_ascii_alphanumeric() || b"._%+-".contains(&c);
    let domain = |c: u8| c.is_ascii_alphanumeric() || c == b'.' || c == b'-';
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for (at, _) in text.match_indices('@') {
        if at < last {
            continue;
        }
        let mut s = at;
        while s > last && local(b[s - 1]) {
            s -= 1;
        }
        let mut e = at + 1;
        while e < b.len() && domain(b[e]) {
            e += 1;
        }
        let mut host = &text[at + 1..e];
        while host.ends_with('.') || host.ends_with('-') {
            host = &host[..host.len() - 1];
        }
        // systemd instance units (getty@tty1.service, user-runtime-dir@1000.service) are not addresses.
        let tld_ok = host.rsplit_once('.').is_some_and(|(h, t)| {
            !h.is_empty() && t.len() >= 2 && t.bytes().all(|c| c.is_ascii_alphabetic()) && !UNIT_SUFFIXES.contains(&t)
        });
        if s < at && tld_ok {
            out.push_str(&text[last..s]);
            out.push_str("<email>");
            last = at + 1 + host.len();
        }
    }
    out.push_str(&text[last..]);
    out
}

/// Case-insensitive (ASCII) replacement of `name` where it is not part of a
/// longer word.
fn replace_word(text: &str, name: &str, with: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let b = text.as_bytes();
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
    let first_word = name.bytes().next().is_some_and(word);
    let last_word = name.bytes().last().is_some_and(word);
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for (i, _) in lower.match_indices(name) {
        if i < last {
            continue;
        }
        let end = i + name.len();
        let ok_before = !first_word || i == 0 || !word(b[i - 1]);
        let ok_after = !last_word || end >= b.len() || !word(b[end]);
        if ok_before && ok_after && text.is_char_boundary(i) && text.is_char_boundary(end) {
            out.push_str(&text[last..i]);
            out.push_str(with);
            last = end;
        }
    }
    out.push_str(&text[last..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids() {
        assert_eq!(steam3_ids("Logged on [U:1:123456] ok [U:1:]"), "Logged on [U:1:<id>] ok [U:1:]");
        assert_eq!(steam64_ids("id 76561198000000001, x 765611980000000012"), "id <steamid>, x 765611980000000012");
    }

    #[test]
    fn mail() {
        assert_eq!(emails("from a.b+c@example.com."), "from <email>.");
        assert_eq!(emails("x@y nope, user@host.co ok"), "x@y nope, <email> ok");
        assert_eq!(emails("Started getty@tty1.service and dbus-:1.2-org@0.service"), "Started getty@tty1.service and dbus-:1.2-org@0.service");
    }

    #[test]
    fn names() {
        let s = Scrubber::with_names(&[("GamerGuy", "<account>"), ("Ninja Cat", "<persona>")]);
        assert_eq!(
            s.scrub("Logon 'gamerguy' as Ninja Cat; gamerguys stays"),
            "Logon '<account>' as <persona>; gamerguys stays"
        );
    }

    #[test]
    fn network_addresses() {
        let s = Scrubber::with_names(&[("gamer", "<account>")]);
        assert_eq!(
            s.scrub("gamer [U:1:123] 76561198000000001 192.168.1.20:27031 [2001:db8::12]:443 fe80::1%eth0 ::1 8.8.8.8."),
            "<account> [U:1:<id>] <steamid> <ip>:27031 [<ip>]:443 <ip> <ip> <ip>."
        );
        assert_eq!(
            s.scrub("version 1.2.3 encoder h264 2026-11-01T00:21:23Z ::ffff:192.0.2.1"),
            "version 1.2.3 encoder h264 2026-11-01T00:21:23Z <ip>"
        );
    }

    #[test]
    fn vdf() {
        let t = "\"users\"\n{\n\t\"7656\"\n\t{\n\t\t\"AccountName\"\t\t\"bob\"\n\t\t\"PersonaName\"\t\t\"Bobby B\"\n\t}\n}\n";
        let p = vdf_pairs(t);
        assert!(p.contains(&("AccountName".into(), "bob".into())));
        assert!(p.contains(&("PersonaName".into(), "Bobby B".into())));
    }

    #[test]
    fn account_id() {
        let t = "\"users\"\n{\n\t\"76561198000000001\"\n\t{\n\t\t\"AccountName\"\t\t\"bob\"\n\t\t\"Timestamp\"\t\t\"1791700400\"\n\t}\n}\n";
        assert_eq!(account_ids(t), vec!["39734273".to_string()]);
        let s = Scrubber::with_names(&[("39734273", "<accountid>")]);
        assert_eq!(
            s.scrub("userdata/39734273/config, Steam Controller Configs/39734273/config, 139734273 stays"),
            "userdata/<accountid>/config, Steam Controller Configs/<accountid>/config, 139734273 stays"
        );
    }

    #[test]
    fn tails() {
        assert_eq!(tail("aaa\nbbb\nccc\n", 6), "ccc\n");
        assert_eq!(tail("short", 100), "short");
    }

    #[test]
    fn runtime_command_output_is_bounded_and_scrubbed() {
        let dir = std::env::temp_dir().join(format!("fx-runtime-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = Scrubber::with_names(&[("bob", "<account>")]);
        let fixture = format!("{}\nbob@example.com bob 192.168.1.20\n", "old\n".repeat(100));
        let note = run(&dir, "runtime.txt", &["printf", "%s", &fixture], 64, &s);
        assert!(note.ends_with("exit 0"), "{note}");
        let text = std::fs::read_to_string(dir.join("runtime.txt")).unwrap();
        assert!(text.len() <= 64);
        assert!(text.ends_with("<email> <account> <ip>\n"), "{text}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn file_tails_are_bounded_and_scrubbed() {
        let dir = std::env::temp_dir().join(format!("fx-tail-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("source");
        let dst = dir.join("tail");
        std::fs::write(&src, "old data\npartial line\nbob@example.com\n").unwrap();
        let s = Scrubber::with_names(&[]);
        assert!(copy_tail(&src, &dst, 22, &s).starts_with("last "));
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "<email>\n");
        std::fs::write(&src, "short\n").unwrap();
        assert_eq!(copy_tail(&src, &dst, 22, &s), "6 bytes");
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "short\n");
        std::fs::write(&src, format!("{}\nheadset 192.168.1.20:27031\n", "old\n".repeat(VR_LOG_TAIL / 4))).unwrap();
        assert!(copy_tail(&src, &dst, VR_LOG_TAIL, &s).starts_with("last "));
        let text = std::fs::read_to_string(&dst).unwrap();
        assert!(text.len() <= VR_LOG_TAIL);
        assert!(text.ends_with("headset <ip>:27031\n"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn startup_logs_are_collected_without_leaving_game_prefixes() {
        use std::os::unix::fs::symlink;
        let dir = std::env::temp_dir().join(format!("fx-startup-test-{}", std::process::id()));
        let home = dir.join("home");
        let compat = dir.join("compatdata");
        let out = dir.join("out");
        std::fs::create_dir_all(&out).unwrap();
        let player = compat.join("960170/pfx/drive_c/users/steamuser/AppData/LocalLow/NEOWIZ/DJMAX RESPECT V");
        let dbd = compat.join("381210/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat/product");
        let nba = compat.join("2878980/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat");
        for p in [&player, &dbd, &nba] {
            std::fs::create_dir_all(p).unwrap();
        }
        std::fs::write(player.join("Player.log"), "bob@example.com bob 192.168.1.20\n").unwrap();
        std::fs::write(player.join("Player-prev.log"), "previous run\n").unwrap();
        std::fs::write(player.join("save.dat"), "private save\n").unwrap();
        std::fs::write(dbd.join("loader.log"), "Failed to load the anti-cheat module\n").unwrap();
        std::fs::write(nba.join("service.log"), format!("{}\nstartup failure\n", "old\n".repeat(100_000))).unwrap();
        std::fs::write(dir.join("private.log"), "outside prefix\n").unwrap();
        symlink(dir.join("private.log"), player.join("linked.log")).unwrap();
        symlink(dir.join("private.log"), nba.join("linked.log")).unwrap();
        symlink(&home, dbd.join("outside")).unwrap();
        let s = Scrubber::with_names(&[("bob", "<account>")]);
        let mut notes = Vec::new();
        collect_game_logs(&out, &compat, &home, &s, &mut notes);
        assert_eq!(std::fs::read_to_string(out.join("games/960170-unity-0.log")).unwrap(),
                   "<email> <account> <ip>\n");
        assert_eq!(std::fs::read_to_string(out.join("games/960170-unity-1.log")).unwrap(), "previous run\n");
        assert_eq!(std::fs::read_to_string(out.join("games/381210-eac-0.log")).unwrap(),
                   "Failed to load the anti-cheat module\n");
        let nba_log = std::fs::read_to_string(out.join("games/2878980-eac-0.log")).unwrap();
        assert!(nba_log.len() <= 256 * 1024);
        assert!(nba_log.ends_with("startup failure\n"));
        assert_eq!(std::fs::read_dir(out.join("games")).unwrap().count(), 4);
        assert!(notes.iter().all(|n| !n.contains("bob") && !n.contains("NEOWIZ")));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn startup_log_discovery_limits_files_and_rejects_redirected_roots() {
        use std::os::unix::fs::symlink;
        let dir = std::env::temp_dir().join(format!("fx-startup-bounds-{}", std::process::id()));
        let prefix = dir.join("pfx");
        let eac = prefix.join("eac");
        std::fs::create_dir_all(&eac).unwrap();
        for i in 0..GAME_LOG_FILES + 3 {
            std::fs::write(eac.join(format!("{i}.log")), "log\n").unwrap();
        }
        std::fs::create_dir_all(eac.join("one/two/three")).unwrap();
        std::fs::write(eac.join("one/two/three/too-deep.log"), "not collected\n").unwrap();
        let files = startup_log_files(&prefix, "eac", false);
        assert_eq!(files.len(), GAME_LOG_FILES);
        assert!(files.iter().all(|p| p.parent() == Some(eac.as_path())));
        let outside = dir.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("private.log"), "not collected\n").unwrap();
        symlink(&outside, prefix.join("redirect")).unwrap();
        assert!(startup_log_files(&prefix, "redirect", false).is_empty());
        let mut remaining = 1;
        let mut bounded = Vec::new();
        find_startup_logs(&eac, 2, false, &mut remaining, &mut bounded);
        assert_eq!(remaining, 0);
        assert!(bounded.len() <= 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
