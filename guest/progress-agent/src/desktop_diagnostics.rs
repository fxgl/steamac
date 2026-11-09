//! Passive Desktop Mode evidence for shell-only exits (STEAMAC-9P). Never collect
//! process arguments, arbitrary environment values, mapped paths or D-Bus addresses.
use std::io::{BufRead, Read};
use std::path::Path;

const PROCESSES: &[&str] = &["nested-desktop", "kwin_wayland", "plasmashell", "plasma-discover"];
const FLAGS: &[(&str, &[&str])] = &[
    ("ENABLE_GAMESCOPE_WSI", &["0", "1"]),
    ("DISABLE_GAMESCOPE_WSI", &["0", "1"]),
    ("QT_QUICK_BACKEND", &["software", "opengl", "rhi"]),
    ("MESA_LOADER_DRIVER_OVERRIDE", &["zink", "llvmpipe"]),
];

pub fn snapshot(proc: &Path) -> String {
    let Ok(entries) = std::fs::read_dir(proc) else { return "process inventory unavailable\n".into() };
    let mut pids: Vec<u32> = entries.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok()).collect();
    pids.sort_unstable();
    let mut out = String::new();
    let mut seen = [false; 4];
    let mut count = 0;
    for pid in pids {
        let root = proc.join(pid.to_string());
        let Ok(comm) = std::fs::read_to_string(root.join("comm")) else { continue };
        let Some(index) = PROCESSES.iter().position(|name| *name == comm.trim()) else { continue };
        seen[index] = true;
        count += 1;
        if count > 16 { out.push_str("additional desktop processes omitted\n"); break; }
        out.push_str(&format!("pid={pid} comm={}\n", PROCESSES[index]));
        match std::fs::File::open(root.join("environ")) {
            Ok(file) => {
                let mut bytes = Vec::new();
                match file.take(64 << 10).read_to_end(&mut bytes) {
                    Ok(_) => out.push_str(&environment_flags(&bytes)),
                    Err(_) => out.push_str("environment flags unavailable\n"),
                }
            }
            Err(_) => out.push_str("environment flags unavailable\n"),
        }
        match std::fs::File::open(root.join("maps")) {
            Ok(file) => {
                let mut gamescope_wsi = false;
                let mut gallium = false;
                let mut venus = false;
                for line in std::io::BufReader::new(file.take(2 << 20)).lines().map_while(Result::ok) {
                    gamescope_wsi |= line.contains("libVkLayer_FROG_gamescope_wsi");
                    gallium |= line.contains("libgallium") || line.contains("zink_dri.so");
                    venus |= line.contains("libvulkan_virtio");
                }
                out.push_str(&format!("mapped gamescope_wsi={gamescope_wsi} gallium_or_zink={gallium} venus={venus}\n"));
            }
            Err(_) => out.push_str("graphics mappings unavailable\n"),
        }
    }
    for (name, present) in PROCESSES.iter().zip(seen) {
        if !present { out.push_str(&format!("comm={name} not running\n")); }
    }
    out
}

fn environment_flags(bytes: &[u8]) -> String {
    let mut out = String::new();
    for (key, allowed) in FLAGS {
        let value = bytes.split(|b| *b == 0).find_map(|entry| {
            let equals = entry.iter().position(|b| *b == b'=')?;
            (&entry[..equals] == key.as_bytes()).then_some(&entry[equals + 1..])
        });
        let display = match value {
            None => "unset",
            Some(value) => allowed.iter().find(|v| v.as_bytes() == value).copied().unwrap_or("<other>"),
        };
        out.push_str(&format!("{key}={display}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reports_only_allowlisted_values() {
        let out = environment_flags(b"SECRET=private\0ENABLE_GAMESCOPE_WSI=secret\0DISABLE_GAMESCOPE_WSI=1\0QT_QUICK_BACKEND=software\0MESA_LOADER_DRIVER_OVERRIDE=zink\0");
        assert!(out.contains("ENABLE_GAMESCOPE_WSI=<other>"));
        assert!(out.contains("DISABLE_GAMESCOPE_WSI=1"));
        assert!(out.contains("QT_QUICK_BACKEND=software"));
        assert!(!out.contains("private") && !out.contains("secret"));
    }
    #[test]
    fn distinguishes_shell_exit_from_desktop_session_exit() {
        let root = std::env::temp_dir().join(format!("steamac-desktop-diagnostics-{}", std::process::id()));
        std::fs::create_dir_all(root.join("123")).unwrap();
        std::fs::write(root.join("123/comm"), "kwin_wayland\n").unwrap();
        std::fs::write(root.join("123/environ"), b"DISABLE_GAMESCOPE_WSI=1\0").unwrap();
        std::fs::write(root.join("123/maps"), "ffff /private/libVkLayer_FROG_gamescope_wsi.so\nffff /private/libgallium.so\n").unwrap();
        let out = snapshot(&root);
        std::fs::remove_dir_all(root).unwrap();
        assert!(out.contains("pid=123 comm=kwin_wayland"));
        assert!(out.contains("comm=plasmashell not running"));
        assert!(out.contains("gamescope_wsi=true gallium_or_zink=true venus=false"));
        assert!(!out.contains("/private"));
    }
}
