//! Preserve Proton startup and first-fault context when crash-handler chatter
//! pushes it out of the ordinary log tail (STEAMAC-AA/A8). Read a fixed prefix,
//! not the whole file: verbose Wine logs can grow to several GiB (STEAMAC-A3).

use std::io::Read;
use std::path::Path;

/// Return a collection note only when a separate startup excerpt is needed.
/// The caller keeps collecting the normal tail and supplies the same scrubber.
pub(super) fn copy_startup(
    src: &Path,
    dst: &Path,
    max: usize,
    scrub: impl FnOnce(&str) -> String,
) -> std::io::Result<Option<String>> {
    let file = std::fs::File::open(src)?;
    let size = file.metadata()?.len();
    if size <= max as u64 {
        return Ok(None);
    }
    let mut data = Vec::new();
    file.take(max as u64).read_to_end(&mut data)?;
    // A cut line may contain an incomplete account name or address which the
    // scrubber could no longer recognise. Never emit it, including at EOF if
    // the file was truncated while this report was being collected.
    let end = data.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    let text = String::from_utf8_lossy(&data[..end]);
    let scrubbed = scrub(&text);
    // Replacements can be longer than the original names; keep the on-disk
    // excerpt bounded too, cutting only at a complete scrubbed line.
    let end = scrubbed.as_bytes()[..scrubbed.len().min(max)].iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    std::fs::write(dst, &scrubbed[..end])?;
    Ok(Some(format!("first {} KiB of {} KiB; startup excerpt, not a complete log", max >> 10, size >> 10)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_fault_survives_crash_handler_tail() {
        let dir = std::env::temp_dir().join(format!("fx-proton-startup-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("steam-1761390.log");
        let dst = dir.join("steam-1761390-head.log");
        // Like STEAMAC-AA: a small first fault is followed by over a MiB of
        // crashpad module warnings, so a tail-only report omits the fault.
        let startup = "Proton: test\nCommand: /home/alice/DivaMegaMix.exe\nEXCEPTION_ACCESS_VIOLATION addr=000000014E7DCDB0 reading 10E4\n";
        let fixture = format!("{startup}{}", "crashpad module warning\n".repeat(100));
        std::fs::write(&src, &fixture).unwrap();
        let tail_start = fixture.len().saturating_sub(1024);
        assert!(!fixture[tail_start..].contains("14E7DCDB0"));
        let note = copy_startup(&src, &dst, 1024, |text| text.replace("alice", "<account>")).unwrap().unwrap();
        assert!(note.starts_with("first 1 KiB"), "{note}");
        let text = std::fs::read_to_string(&dst).unwrap();
        assert!(text.starts_with("Proton: test\n"));
        assert!(text.contains("14E7DCDB0"));
        assert!(text.contains("/home/<account>/"));
        assert!(!text.contains("alice"));
        assert!(text.len() <= 1024);
        assert!(text.ends_with('\n'));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn startup_excerpt_skips_short_logs_and_partial_private_lines() {
        let dir = std::env::temp_dir().join(format!("fx-proton-bounds-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("source");
        let dst = dir.join("head");
        std::fs::write(&src, "short\n").unwrap();
        assert_eq!(copy_startup(&src, &dst, 6, str::to_owned).unwrap(), None);
        assert!(!dst.exists());
        std::fs::write(&src, "header\nalice@example.com\ntrailing\n").unwrap();
        copy_startup(&src, &dst, 12, str::to_owned).unwrap().unwrap();
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "header\n");
        std::fs::write(&src, "private-without-newline").unwrap();
        copy_startup(&src, &dst, 8, str::to_owned).unwrap().unwrap();
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "");
        std::fs::remove_file(&src).unwrap();
        assert_eq!(copy_startup(&src, &dst, 8, str::to_owned).unwrap_err().kind(), std::io::ErrorKind::NotFound);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
