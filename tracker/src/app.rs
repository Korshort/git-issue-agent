use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use ratatui::layout::Rect;
use ratatui::style::Color;
use ratatui::widgets::TableState;

use crate::github::Issue;

// ── 테마 ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Theme {
    Cyberpunk,   // 기본: 시안/마젠타/그린 네온
    Dracula,     // 퍼플/핑크/그린
    Nord,        // 차가운 블루/스틸
    Gruvbox,     // 따뜻한 앰버/오렌지
    Mono,        // 흑백 미니멀
}

impl Theme {
    pub const ALL: &'static [Theme] = &[
        Theme::Cyberpunk,
        Theme::Dracula,
        Theme::Nord,
        Theme::Gruvbox,
        Theme::Mono,
    ];

    pub fn name(&self) -> &'static str {
        match self {
            Theme::Cyberpunk => "Cyberpunk",
            Theme::Dracula   => "Dracula",
            Theme::Nord      => "Nord",
            Theme::Gruvbox   => "Gruvbox",
            Theme::Mono      => "Mono",
        }
    }

    pub fn next(&self) -> Theme {
        let idx = Self::ALL.iter().position(|t| t == self).unwrap_or(0);
        Self::ALL[(idx + 1) % Self::ALL.len()]
    }
}

pub struct Palette {
    pub issues_accent:  Color,
    pub win_accent:     Color,
    pub new_item:       Color,
    pub changed_item:   Color,
    pub warning:        Color,
    pub muted:          Color,
    pub header_fg:      Color,
    pub selected_bg:    Color,
}

impl Palette {
    pub fn from(theme: Theme) -> Self {
        match theme {
            Theme::Cyberpunk => Self {
                issues_accent:  Color::Cyan,
                win_accent:     Color::Green,
                new_item:       Color::LightGreen,
                changed_item:   Color::LightCyan,
                warning:        Color::Yellow,
                muted:          Color::DarkGray,
                header_fg:      Color::White,
                selected_bg:    Color::DarkGray,
            },
            Theme::Dracula => Self {
                issues_accent:  Color::Rgb(189, 147, 249),  // purple
                win_accent:     Color::Rgb(80, 250, 123),   // green
                new_item:       Color::Rgb(80, 250, 123),
                changed_item:   Color::Rgb(139, 233, 253),  // cyan
                warning:        Color::Rgb(241, 250, 140),  // yellow
                muted:          Color::Rgb(98, 114, 164),
                header_fg:      Color::Rgb(248, 248, 242),
                selected_bg:    Color::Rgb(68, 71, 90),
            },
            Theme::Nord => Self {
                issues_accent:  Color::Rgb(136, 192, 208),  // nord8
                win_accent:     Color::Rgb(163, 190, 140),  // nord14
                new_item:       Color::Rgb(163, 190, 140),
                changed_item:   Color::Rgb(136, 192, 208),
                warning:        Color::Rgb(235, 203, 139),  // nord13
                muted:          Color::Rgb(76, 86, 106),    // nord3
                header_fg:      Color::Rgb(216, 222, 233),  // nord4
                selected_bg:    Color::Rgb(59, 66, 82),     // nord1
            },
            Theme::Gruvbox => Self {
                issues_accent:  Color::Rgb(131, 165, 152),  // aqua
                win_accent:     Color::Rgb(184, 187, 38),   // green
                new_item:       Color::Rgb(184, 187, 38),
                changed_item:   Color::Rgb(131, 165, 152),
                warning:        Color::Rgb(250, 189, 47),   // yellow
                muted:          Color::Rgb(102, 92, 84),    // bg3
                header_fg:      Color::Rgb(235, 219, 178),  // fg1
                selected_bg:    Color::Rgb(80, 73, 69),     // bg2
            },
            Theme::Mono => Self {
                issues_accent:  Color::White,
                win_accent:     Color::White,
                new_item:       Color::White,
                changed_item:   Color::Gray,
                warning:        Color::White,
                muted:          Color::DarkGray,
                header_fg:      Color::White,
                selected_bg:    Color::DarkGray,
            },
        }
    }
}

// ── App ───────────────────────────────────────────────────────────

pub struct App {
    pub repo:         String,
    pub interval:     u64,
    pub theme:        Theme,
    /// 이슈 세션을 띄울 메인 작업공간 (git issue-agent run 의 cwd)
    pub workspace:    PathBuf,
    /// git-issue-agent 실행 파일 절대경로
    pub cli_bin:       PathBuf,

    // data
    pub issues:         Vec<Issue>,
    pub new_issue_nums: HashSet<u64>,
    pub changed_nums:   HashSet<u64>,
    pub last_error:     String,

    // UI state
    pub issue_state:    TableState,
    pub toast:          Option<String>,

    // 마우스 hit-test용 패널 rect (매 렌더 후 갱신)
    pub issue_rect:   Rect,

    // tmux window 추적: window_name → window_index
    pub tmux_sessions: HashMap<String, u32>,
}

impl App {
    pub fn new(repo: String, interval: u64, theme: Theme, workspace: PathBuf, cli_bin: PathBuf) -> Self {
        Self {
            repo,
            interval,
            theme,
            workspace,
            cli_bin,
            issues: vec![],
            new_issue_nums: HashSet::new(),
            changed_nums: HashSet::new(),
            last_error: String::new(),
            issue_state: TableState::default(),
            toast: None,
            issue_rect: Rect::default(),
            tmux_sessions: HashMap::new(),
        }
    }

    pub fn palette(&self) -> Palette {
        Palette::from(self.theme)
    }

    pub fn scroll_down(&mut self) {
        let len = self.issues.len();
        if len == 0 { return; }
        let i = self.issue_state.selected().map_or(0, |i| (i + 1).min(len - 1));
        self.issue_state.select(Some(i));
    }

    pub fn scroll_up(&mut self) {
        let i = self.issue_state.selected().map_or(0, |i| i.saturating_sub(1));
        self.issue_state.select(Some(i));
    }

    fn selected_issue(&self) -> Option<u64> {
        self.issue_state.selected()
            .and_then(|i| self.issues.get(i))
            .map(|issue| issue.number)
    }

    /// 이슈 세션 실행 명령 (절대경로 — 어느 CWD에 붙여넣어도 동작)
    pub fn run_command(&self, number: u64) -> String {
        format!("cd '{}' && '{}' run {}", self.workspace.display(), self.cli_bin.display(), number)
    }

    // 선택된 이슈의 run 커맨드를 클립보드에 복사
    pub fn copy_selected(&mut self) {
        let Some(number) = self.selected_issue() else { return };
        let cmd = self.run_command(number);
        if copy_to_clipboard(&cmd) {
            self.toast = Some(format!("✓ 복사됨: {}", cmd));
        } else {
            self.toast = Some("클립보드 복사 실패".to_string());
        }
    }

    pub fn next_theme(&mut self) {
        self.theme = self.theme.next();
        self.toast = Some(format!("테마: {}", self.theme.name()));
    }

    // ── 마우스 ────────────────────────────────────────────────────

    pub fn handle_click(&mut self, col: u16, row: u16) {
        let r = self.issue_rect;
        let hit = r.width > 0 && r.height > 0
            && col >= r.x && col < r.x + r.width
            && row >= r.y && row < r.y + r.height;
        if !hit { return; }
        // 테이블: 상단 border(1) + 헤더(1) = 2행 오프셋
        let data_start = r.y.saturating_add(2);
        if row < data_start { return; }
        let idx = (row - data_start) as usize;
        if idx < self.issues.len() {
            self.issue_state.select(Some(idx));
        }
    }

    // ── tmux ──────────────────────────────────────────────────────

    pub fn refresh_tmux_sessions(&mut self) {
        if crate::tmux::is_in_tmux() {
            self.tmux_sessions = crate::tmux::list_windows();
        }
    }

    /// tmux window 이름. 여러 레포의 tracker 를 한 tmux 세션에서 띄워도 겹치지 않게 레포 이름을 붙인다.
    pub fn win_name(&self, number: u64) -> String {
        let short = self.repo.rsplit('/').next().unwrap_or(&self.repo);
        format!("{}-{}", short, number)
    }

    pub fn tmux_win_issue(&self, number: u64) -> Option<u32> {
        self.tmux_sessions.get(&self.win_name(number)).copied()
    }

    // ── 상태 라벨 ─────────────────────────────────────────────────

    /// 상태 라벨. 표시 우선순위 순(위가 먼저)이다.
    /// 사람이 답해야 하는 상태가 다른 상태에 가려지면 안 되므로 awaiting-user 가 맨 앞이다.
    pub const STATUS_PRIORITY: [&'static str; 5] = [
        "awaiting-user",
        "rework",
        "on-review",
        "in-progress",
        "ready",
    ];

    /// 라벨 목록에서 상태 라벨 하나를 우선순위로 고른다.
    pub fn status(labels: &[String]) -> Option<&'static str> {
        Self::STATUS_PRIORITY
            .into_iter()
            .find(|label| labels.iter().any(|l| l == label))
    }

    /// Enter 동작: tmux 안이면 window 생성/전환, 밖이면 클립보드 복사 폴백.
    pub fn launch_selected(&mut self) {
        if !crate::tmux::is_in_tmux() {
            self.copy_selected();
            return;
        }

        let Some(number) = self.selected_issue() else { return };
        let win_name = self.win_name(number);
        let existed  = self.tmux_sessions.contains_key(&win_name);
        let win_idx  = self.tmux_sessions.get(&win_name).copied();
        let cmd = format!("{}; exec $SHELL", self.run_command(number));
        if crate::tmux::open_or_jump(&win_name, &cmd) {
            self.toast = Some(if existed {
                format!("↩ 전환: {} [win:{}]", win_name, win_idx.unwrap_or(0))
            } else {
                // 새 window 생성 — 인덱스는 refresh 후 읽음
                self.refresh_tmux_sessions();
                let idx = self.tmux_sessions.get(&win_name).copied().unwrap_or(0);
                format!("✓ 새 window: {} [win:{}]", win_name, idx)
            });
        }
    }
}

pub fn copy_to_clipboard(text: &str) -> bool {
    std::process::Command::new("pbcopy")
        .stdin(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            use std::io::Write;
            child.stdin.as_mut().unwrap().write_all(text.as_bytes())?;
            child.wait()
        })
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::{App, Theme};
    use std::path::PathBuf;

    fn labels(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn status_picks_single_label_by_priority() {
        // 사람이 답해야 하는 상태가 다른 상태에 가려지면 안 된다
        assert_eq!(App::status(&labels(&["on-review", "awaiting-user"])), Some("awaiting-user"));
        // 반려 직후 on-review 가 덜 떼였어도 재작업 중으로 본다
        assert_eq!(App::status(&labels(&["on-review", "rework"])), Some("rework"));
        assert_eq!(App::status(&labels(&["in-progress"])), Some("in-progress"));
    }

    #[test]
    fn status_is_none_without_status_labels() {
        assert_eq!(App::status(&labels(&["bug", "critical"])), None);
        // 옛 am:* 라벨은 상태로 치지 않는다
        assert_eq!(App::status(&labels(&["am:ready"])), None);
        assert_eq!(App::status(&[]), None);
    }

    #[test]
    fn win_name_includes_repo_name() {
        let app = App::new(
            "owner/my_repo".into(), 30, Theme::Cyberpunk,
            PathBuf::from("/w"), PathBuf::from("/am/bin/am"),
        );
        assert_eq!(app.win_name(17), "my_repo-17");
        assert_eq!(app.run_command(17), "cd '/w' && '/am/bin/am' run 17");
    }
}
