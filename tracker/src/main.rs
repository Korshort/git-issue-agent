mod app;
mod github;
mod tmux;
mod ui;

use std::{
    collections::HashSet,
    io,
    path::PathBuf,
    time::{Duration, Instant},
};

use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers, MouseButton, MouseEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    event::{DisableMouseCapture, EnableMouseCapture},
};
use ratatui::{backend::CrosstermBackend, Terminal};

use app::{App, Theme};

const TOAST_DURATION: Duration = Duration::from_secs(2);

fn poll_data(app: &mut App) {
    let prev_issue_map: std::collections::HashMap<u64, _> =
        app.issues.iter().map(|i| (i.number, i.clone())).collect();

    match github::fetch_issues(&app.repo) {
        Ok(issues) => {
            app.new_issue_nums = issues.iter()
                .filter(|i| !prev_issue_map.contains_key(&i.number))
                .map(|i| i.number)
                .collect();
            let mut changed: HashSet<u64> = HashSet::new();
            for i in &issues {
                if let Some(prev) = prev_issue_map.get(&i.number) {
                    let prev_labels: HashSet<_> = prev.labels.iter().collect();
                    let cur_labels:  HashSet<_> = i.labels.iter().collect();
                    if i.updated_at != prev.updated_at || prev_labels != cur_labels {
                        changed.insert(i.number);
                    }
                }
            }
            app.changed_nums.extend(changed);
            app.issues = issues;
            app.last_error.clear();
        }
        Err(e) => { app.last_error = e.to_string(); }
    }
}

fn run(mut app: App) -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // 첫 폴링
    poll_data(&mut app);
    app.refresh_tmux_sessions();

    let tick = Duration::from_secs(app.interval);
    let mut last_poll      = Instant::now();
    let mut last_tmux_poll = Instant::now();
    let mut toast_time: Option<Instant> = None;

    loop {
        terminal.draw(|f| ui::render(f, &mut app))?;

        // 토스트 TTL 체크
        if let Some(t) = toast_time {
            if t.elapsed() >= TOAST_DURATION {
                app.toast = None;
                toast_time = None;
            }
        }

        if event::poll(Duration::from_millis(100))? {
            match event::read()? {
                Event::Mouse(mouse) => {
                    match mouse.kind {
                        MouseEventKind::Down(MouseButton::Left) => {
                            app.handle_click(mouse.column, mouse.row);
                        }
                        MouseEventKind::ScrollDown => app.scroll_down(),
                        MouseEventKind::ScrollUp   => app.scroll_up(),
                        _ => {}
                    }
                }
                Event::Key(key) => {
                    match (key.code, key.modifiers) {
                        (KeyCode::Char('q'), _)
                        | (KeyCode::Char('c'), KeyModifiers::CONTROL) => break,

                        (KeyCode::Down, _) | (KeyCode::Char('j'), _) => app.scroll_down(),
                        (KeyCode::Up, _)   | (KeyCode::Char('k'), _) => app.scroll_up(),

                        // Enter: tmux window 생성/전환 (tmux 밖이면 실행 명령 클립보드 복사)
                        (KeyCode::Enter, _) => {
                            app.launch_selected();
                            toast_time = Some(Instant::now());
                        }

                        (KeyCode::Char('r'), _) => {
                            app.new_issue_nums.clear();
                            app.changed_nums.clear();
                            poll_data(&mut app);
                            last_poll = Instant::now();
                            app.toast = Some("↺ 새로고침 완료".to_string());
                            toast_time = Some(Instant::now());
                        }

                        (KeyCode::Char('t'), _) => {
                            app.next_theme();
                            toast_time = Some(Instant::now());
                        }

                        _ => {}
                    }
                }
                _ => {}
            }
        }

        // 주기 폴링
        if last_poll.elapsed() >= tick {
            app.new_issue_nums.clear();
            app.changed_nums.clear();
            poll_data(&mut app);
            last_poll = Instant::now();
        }

        // tmux 세션 5s 주기 갱신
        if last_tmux_poll.elapsed() >= Duration::from_secs(5) {
            app.refresh_tmux_sessions();
            last_tmux_poll = Instant::now();
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
    Ok(())
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut repo:      Option<String>  = None;
    let mut workspace: Option<PathBuf> = None;
    let mut cli_bin:    Option<PathBuf> = None;
    let mut interval   = 30u64;
    let mut theme      = Theme::Cyberpunk;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--repo"      => { repo = args.next(); }
            "--workspace" => { workspace = args.next().map(PathBuf::from); }
            "--cli"        => { cli_bin = args.next().map(PathBuf::from); }
            "--interval"  => { if let Some(v) = args.next() { interval = v.parse().unwrap_or(30); } }
            "--theme"     => {
                if let Some(v) = args.next() {
                    theme = match v.to_lowercase().as_str() {
                        "dracula"   => Theme::Dracula,
                        "nord"      => Theme::Nord,
                        "gruvbox"   => Theme::Gruvbox,
                        "mono"      => Theme::Mono,
                        _           => Theme::Cyberpunk,
                    };
                }
            }
            "--help" | "-h" => {
                println!("git-issue-agent-tracker — 이슈 현황판 TUI (보통 `git issue-agent tracker` 로 실행)");
                println!();
                println!("옵션:");
                println!("  --interval SECS       갱신 간격 (기본: 30)");
                println!("  --theme NAME          테마: cyberpunk | dracula | nord | gruvbox | mono");
                println!();
                println!("키:");
                println!("  q / Ctrl-C   종료");
                println!("  ↑↓ / j k     스크롤");
                println!("  Enter        tmux 안: 이슈 세션 window 생성/전환, 밖: 실행 명령 클립보드 복사");
                println!("  r            강제 새로고침");
                println!("  t            테마 전환");
                return;
            }
            _ => {}
        }
    }

    // repo·workspace·cli 는 `git issue-agent tracker` 가 .issue-agent/config 에서 읽어 넘긴다.
    let (Some(repo), Some(workspace), Some(cli_bin)) = (repo, workspace, cli_bin) else {
        eprintln!("오류: --repo / --workspace / --cli 이 필요합니다. `git issue-agent tracker` 로 실행하세요.");
        std::process::exit(2);
    };

    let app = App::new(repo, interval, theme, workspace, cli_bin);
    if let Err(e) = run(app) {
        eprintln!("오류: {e}");
        std::process::exit(1);
    }
}
