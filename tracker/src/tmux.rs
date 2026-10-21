use std::collections::HashMap;

pub fn is_in_tmux() -> bool {
    std::env::var("TMUX").is_ok()
}

/// Returns map of window_name → window_index
pub fn list_windows() -> HashMap<String, u32> {
    let mut map = HashMap::new();
    let Ok(out) = std::process::Command::new("tmux")
        .args(["list-windows", "-F", "#{window_name}:#{window_index}"])
        .output()
    else {
        return map;
    };
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some((name, idx)) = line.rsplit_once(':') {
            if let Ok(i) = idx.parse::<u32>() {
                map.insert(name.to_string(), i);
            }
        }
    }
    map
}

/// Jump to existing window by name, or create a new one running `cmd`.
/// Returns true on success.
pub fn open_or_jump(win_name: &str, cmd: &str) -> bool {
    let windows = list_windows();
    if windows.contains_key(win_name) {
        std::process::Command::new("tmux")
            .args(["select-window", "-t", win_name])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    } else {
        std::process::Command::new("tmux")
            .args(["new-window", "-n", win_name, cmd])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }
}
