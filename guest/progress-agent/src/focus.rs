//! Focus reporter: which client gamescope shows (Steam UI or a game) and the
//! size of the surface it shows, for the launcher's mouse handling (pointer
//! grab while a game has focus, host pointer -> guest cursor mapping).
//!
//! gamescope publishes the focused app id as GAMESCOPE_FOCUSED_APP (CARDINAL)
//! on the root window of its Xwayland (:0). 0 = nothing / startup, 769 = the
//! Steam client UI; anything else is a game's Steam app id. The watcher selects
//! PropertyChange on the root window, so it only wakes when that changes.
//!
//! gamescope moves the cursor in the focused surface's pixels (relative motion,
//! clamped to that surface) and scales the surface into the display, so the
//! launcher needs that surface's size, which is not the display size when
//! Steam's Settings > Display > Resolution is not the native one: Steam then
//! sets the Xwayland mode (GAMESCOPE_XWAYLAND_MODE_CONTROL, e.g. 1920x1200 on a
//! 2880x1800 display) and its UI window has that size (STEAMAC-2V/2W). Sizes:
//!   - Steam UI: GAMESCOPE_FOCUSED_WINDOW's geometry (Steam's window on :0);
//!   - a game: the :0 root window, i.e. the Xwayland mode Steam sets on every
//!     gamescope Xwayland (games run on :1, whose window ids mean nothing here);
//!   - Desktop Mode (plasma-session.target, no Steam): the only client is the
//!     nested Plasma desktop, one KWin window: GAMESCOPE_FOCUSED_WINDOW's geometry.
//! StructureNotify on the root (mode changes) and on the focused window
//! (Steam resizes its window after the mode change) re-reports the size.
//!
//! Messages (line protocol, see main.rs): `focus steam <w>x<h>` |
//! `focus game <appid> <w>x<h>` | `focus desktop <w>x<h>` (the size is left out
//! when it cannot be read).

use std::os::fd::{AsRawFd, RawFd};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ChangeWindowAttributesAux, ConnectionExt, EventMask, Window};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

use crate::port::Port;

pub(crate) const STEAM_UI_APPID: u32 = 769;

struct Conn {
    conn: RustConnection,
    root: Window,
    atom: u32,
    window_atom: u32,
    /// The focused window whose StructureNotify is selected (0 = none).
    watched: Window,
}

pub struct Focus {
    conn: Option<Conn>,
    next_connect: Instant,
    /// Last message sent (to report only changes).
    last: Option<String>,
    /// Desktop Mode session (see the module doc).
    desktop: bool,
}

impl Focus {
    pub fn new(desktop: bool) -> Focus {
        Focus { conn: None, next_connect: Instant::now(), last: None, desktop }
    }

    /// Desktop Mode: the desktop window has had gamescope's focus (it is on screen).
    pub fn desktop_shown(&self) -> bool {
        self.desktop && self.last.is_some()
    }

    /// X connection fd to poll on, if connected.
    pub fn fd(&self) -> Option<RawFd> {
        self.conn.as_ref().map(|c| c.conn.stream().as_raw_fd())
    }

    pub fn connected(&self) -> bool {
        self.conn.is_some()
    }

    /// App id of the focused game (last reported), None for Steam / unknown.
    pub fn game(&self) -> Option<u32> {
        self.last.as_deref()?.strip_prefix("focus game ")?.split(' ').next()?.parse().ok()
    }

    /// Connect if needed (rate limited to 1/s), drain pending X events and send
    /// `focus ...` when the focused app changed. `force` resends the current
    /// value even if unchanged (after `ready`, after the port was opened).
    pub fn pump(&mut self, port: &mut Port, force: bool, names: &mut crate::appname::Names) {
        let mut force = force;
        if self.conn.is_none() {
            if Instant::now() < self.next_connect {
                return;
            }
            self.next_connect = Instant::now() + Duration::from_secs(1);
            match connect() {
                Some(c) => {
                    self.conn = Some(c);
                    // New X connection (gamescope (re)started): resend.
                    force = true;
                }
                None => return,
            }
        }
        let mut changed = force;
        loop {
            match self.conn.as_ref().unwrap().conn.poll_for_event() {
                Ok(Some(Event::PropertyNotify(e))) => {
                    let c = self.conn.as_ref().unwrap();
                    if e.window == c.root && (e.atom == c.atom || e.atom == c.window_atom) {
                        changed = true;
                    }
                }
                Ok(Some(Event::ConfigureNotify(e))) => {
                    let c = self.conn.as_ref().unwrap();
                    if e.window == c.root || e.window == c.watched {
                        changed = true;
                    }
                }
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(_) => {
                    // Xwayland went away with the session; reconnect later.
                    self.conn = None;
                    return;
                }
            }
        }
        if changed {
            self.report(port, force, names);
        }
    }

    fn report(&mut self, port: &mut Port, force: bool, names: &mut crate::appname::Names) {
        let Some(c) = self.conn.as_mut() else { return };
        let Some((app, size)) = read_state(c, self.desktop) else {
            // Connection broke: reconnect (and resend) on the next pump.
            self.conn = None;
            return;
        };
        let size = size.map_or(String::new(), |(w, h)| format!(" {w}x{h}"));
        let game = !self.desktop && app != 0 && app != STEAM_UI_APPID;
        let msg = if self.desktop {
            // Nothing focused yet (KWin starting): nothing to report.
            if size.is_empty() {
                return;
            }
            format!("focus desktop{size}")
        } else if game {
            format!("focus game {app}{size}")
        } else {
            format!("focus steam{size}")
        };
        if force || self.last.as_deref() != Some(msg.as_str()) {
            port.send(&msg);
            self.last = Some(msg);
            // Focus can precede scope discovery; both paths share deduplication.
            if game {
                names.report(app, port);
            }
        }
    }
}

/// What gamescope shows: the focused app id (0 = nothing / startup; always 0 in
/// Desktop Mode) and the size of the surface the cursor moves on (see the module
/// doc; None = unknown). Watches the focused window for resizes. None = the
/// connection broke.
fn read_state(c: &mut Conn, desktop: bool) -> Option<(u32, Option<(u16, u16)>)> {
    // Bazzite runs Plasma directly on KWin, so gamescope's properties are absent.
    // Report the desktop's Xwayland root size for absolute pointer mapping.
    if desktop && std::env::var_os("FX_PROGRESS_DESKTOP_NATIVE").is_some() {
        let size = c.conn.get_geometry(c.root).ok()?.reply().ok().map(|g| (g.width, g.height));
        return Some((0, size.filter(|&(w, h)| w > 0 && h > 0)));
    }
    let cardinal = |c: &Conn, atom: u32| -> Option<u32> {
        let r = c.conn.get_property(false, c.root, atom, AtomEnum::CARDINAL, 0, 1).ok()?.reply().ok()?;
        Some(r.value32().and_then(|mut v| v.next()).unwrap_or(0))
    };
    let app = if desktop { 0 } else { cardinal(c, c.atom)? };
    let focused = cardinal(c, c.window_atom)?;
    // A game's window is on another Xwayland: its id means nothing on this connection.
    let game = !desktop && app != 0 && app != STEAM_UI_APPID;
    let window = if game { 0 } else { focused };
    if window != c.watched {
        // A window that is already gone answers with an X error event (ignored by pump).
        if window != 0 {
            c.conn
                .change_window_attributes(window, &ChangeWindowAttributesAux::new().event_mask(EventMask::STRUCTURE_NOTIFY))
                .ok()?;
            c.conn.flush().ok()?;
        }
        c.watched = window;
    }
    let target = match window {
        0 if desktop => return Some((app, None)),
        0 => c.root,   // a game, or Steam before its window has the focus: the Xwayland mode
        w => w,
    };
    let size = c.conn.get_geometry(target).ok()?.reply().ok().map(|g| (g.width, g.height));
    Some((app, size.filter(|&(w, h)| w > 0 && h > 0)))
}

fn connect() -> Option<Conn> {
    let (conn, screen) = RustConnection::connect(None).ok()?;
    let root = conn.setup().roots.get(screen)?.root;
    let atom = conn.intern_atom(false, b"GAMESCOPE_FOCUSED_APP").ok()?.reply().ok()?.atom;
    let window_atom = conn.intern_atom(false, b"GAMESCOPE_FOCUSED_WINDOW").ok()?.reply().ok()?.atom;
    // PropertyChange: focus changes; StructureNotify: Xwayland mode (root size) changes.
    let mask = EventMask::PROPERTY_CHANGE | EventMask::STRUCTURE_NOTIFY;
    conn.change_window_attributes(root, &ChangeWindowAttributesAux::new().event_mask(mask)).ok()?.check().ok()?;
    conn.flush().ok()?;
    Some(Conn { conn, root, atom, window_atom, watched: 0 })
}
