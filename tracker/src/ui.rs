use chrono::{DateTime, Local, Utc};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    symbols::border,
    text::{Line, Span},
    widgets::{Block, Borders, Cell, Clear, Paragraph, Row, Table},
    Frame,
};

use crate::app::App;

// ── 시간 포맷 ──────────────────────────────────────────────────────

pub fn time_ago(dt: &DateTime<Utc>) -> String {
    let secs = (Utc::now() - *dt).num_seconds().max(0) as u64;
    if secs < 60      { format!("{}s",  secs) }
    else if secs < 3600   { format!("{}m",  secs / 60) }
    else if secs < 86400  { format!("{}h",  secs / 3600) }
    else                  { format!("{}d",  secs / 86400) }
}

// ── 라벨 배지 ─────────────────────────────────────────────────────

fn label_badge<'a>(name: &str, accent: Color) -> Span<'a> {
    let color = match name {
        "ready"          => Color::Cyan,
        "in-progress"    => Color::LightBlue,
        "on-review"      => Color::LightMagenta,
        "rework"         => Color::Rgb(255, 160, 50),
        "awaiting-user"  => Color::LightYellow,
        "bug"            => Color::Red,
        "critical"       => Color::LightRed,
        "enhancement"    => Color::Green,
        _                => accent,
    };
    Span::styled(format!("[{}]", name), Style::default().fg(color))
}

// 라벨 컬럼은 2개까지만 그린다. 상태 라벨이 뒤에 붙어 있으면 컷에 밀려 안 보이므로 앞에 세운다.
// 상태는 하나만 그리고 나머지 상태 라벨은 뺀다. 상태 외 라벨은 그대로 배지로 남긴다.
fn labels_line(labels: &[String], accent: Color) -> Line<'static> {
    let ordered: Vec<&str> = App::status(labels)
        .into_iter()
        .chain(
            labels
                .iter()
                .map(|lb| lb.as_str())
                .filter(|lb| !App::STATUS_PRIORITY.contains(lb)),
        )
        .collect();

    let mut spans = Vec::new();
    for (i, lb) in ordered.iter().take(2).enumerate() {
        if i > 0 { spans.push(Span::raw(" ")); }
        spans.push(label_badge(lb, accent));
    }
    if ordered.len() > 2 {
        spans.push(Span::styled(
            format!("+{}", ordered.len() - 2),
            Style::default().fg(Color::DarkGray),
        ));
    }
    Line::from(spans)
}

// ── 헤더 ──────────────────────────────────────────────────────────

fn render_header(f: &mut Frame, area: Rect, app: &App) {
    let pal = app.palette();
    let now = Local::now().format("%H:%M:%S").to_string();

    // 좌: 로고 + 레포
    let left = Line::from(vec![
        Span::styled(" ⬡ ", Style::default().fg(pal.issues_accent).add_modifier(Modifier::BOLD)),
        Span::styled("GIT ISSUE AGENT", Style::default().fg(pal.header_fg).add_modifier(Modifier::BOLD)),
        Span::styled("  │  ", Style::default().fg(pal.muted)),
        Span::styled(app.repo.clone(), Style::default().fg(pal.muted)),
    ]);

    let mut right_spans: Vec<Span> = Vec::new();
    if !app.last_error.is_empty() {
        right_spans.push(Span::styled(
            format!("⚠ {}  ", app.last_error.chars().take(30).collect::<String>()),
            Style::default().fg(pal.warning),
        ));
    }
    right_spans.push(Span::styled(
        format!("{}  {} ⟳{}s ", app.theme.name(), now, app.interval),
        Style::default().fg(pal.muted),
    ));

    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Fill(1), Constraint::Fill(1)])
        .split(area);

    f.render_widget(Paragraph::new(left), chunks[0]);
    f.render_widget(
        Paragraph::new(Line::from(right_spans)).alignment(ratatui::layout::Alignment::Right),
        chunks[1],
    );
}

// ── 푸터 ──────────────────────────────────────────────────────────

fn render_footer(f: &mut Frame, area: Rect, app: &App) {
    let pal = app.palette();
    let keys: [(&str, &str); 5] = [
        ("↑↓/jk", "스크롤"),
        ("Enter", "세션 열기/복사"),
        ("t",     "테마전환"),
        ("r",     "갱신"),
        ("q",     "종료"),
    ];

    let mut spans = vec![Span::styled(" ", Style::default())];
    for (i, (key, desc)) in keys.iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled("  ", Style::default().fg(pal.muted)));
        }
        spans.push(Span::styled(
            format!("[{}]", key),
            Style::default().fg(pal.issues_accent).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(
            format!(" {}", desc),
            Style::default().fg(pal.muted),
        ));
    }

    f.render_widget(
        Paragraph::new(Line::from(spans))
            .block(Block::default().borders(Borders::TOP)
                .border_style(Style::default().fg(pal.muted))),
        area,
    );
}

// ── ISSUES ────────────────────────────────────────────────────────

fn render_issues(f: &mut Frame, area: Rect, app: &App) {
    let pal = app.palette();
    let accent = pal.issues_accent;

    let new_count = app.new_issue_nums.len();
    let waiting = app.issues.iter()
        .filter(|i| App::status(&i.labels) == Some("awaiting-user"))
        .count();
    let title = Line::from(vec![
        Span::styled(" ◈ ISSUES ", Style::default().fg(accent).add_modifier(Modifier::BOLD)),
        Span::styled(format!("({}) ", app.issues.len()), Style::default().fg(pal.muted)),
        if waiting > 0 {
            Span::styled(
                format!("⚠ {}건 답변 대기 ", waiting),
                Style::default().fg(pal.warning).add_modifier(Modifier::BOLD),
            )
        } else {
            Span::raw("")
        },
        if new_count > 0 {
            Span::styled(
                format!("▲{} new ", new_count),
                Style::default().fg(pal.new_item).add_modifier(Modifier::BOLD),
            )
        } else {
            Span::raw("")
        },
    ]);

    let header = Row::new(vec![
        Cell::from(" #").style(Style::default().fg(pal.muted).add_modifier(Modifier::BOLD)),
        Cell::from("제목").style(Style::default().fg(pal.muted).add_modifier(Modifier::BOLD)),
        Cell::from("라벨").style(Style::default().fg(pal.muted).add_modifier(Modifier::BOLD)),
        Cell::from("담당자").style(Style::default().fg(pal.muted).add_modifier(Modifier::BOLD)),
        Cell::from("경과").style(Style::default().fg(pal.muted).add_modifier(Modifier::BOLD)),
    ]).height(1).bottom_margin(0);

    let rows: Vec<Row> = app.issues.iter().map(|issue| {
        let (prefix, row_style) = if app.new_issue_nums.contains(&issue.number) {
            ("★ ", Style::default().fg(pal.new_item).add_modifier(Modifier::BOLD))
        } else if app.changed_nums.contains(&issue.number) {
            ("↻ ", Style::default().fg(pal.changed_item))
        } else {
            ("", Style::default().fg(pal.header_fg))
        };

        let title_cell = {
            let mut spans = Vec::new();
            if let Some(win_idx) = app.tmux_win_issue(issue.number) {
                spans.push(Span::styled(
                    format!("[win:{}] ", win_idx),
                    Style::default().fg(pal.win_accent),
                ));
            }
            spans.push(Span::styled(format!("{}{}", prefix, issue.title), row_style));
            Cell::from(Line::from(spans))
        };

        Row::new(vec![
            Cell::from(format!(" #{}", issue.number))
                .style(Style::default().fg(accent)),
            title_cell,
            Cell::from(labels_line(&issue.labels, accent)),
            // 담당자는 흰색 고정 — muted 는 테마에 따라 selected_bg 와 같은 색이라
            // 행이 하이라이트되면 값이 배경에 묻혀 안 보인다.
            Cell::from(issue.assignees.first().map(|s| s.as_str()).unwrap_or("—"))
                .style(Style::default().fg(Color::White)),
            Cell::from(time_ago(&issue.updated_at))
                .style(Style::default().fg(pal.muted)),
        ])
    }).collect();

    let empty_row = if app.issues.is_empty() {
        vec![Row::new(vec![
            Cell::from(""),
            Cell::from(" — 열린 이슈 없음").style(Style::default().fg(pal.muted)),
            Cell::from(""), Cell::from(""), Cell::from(""),
        ])]
    } else {
        vec![]
    };

    let all_rows: Vec<Row> = rows.into_iter().chain(empty_row).collect();

    let table = Table::new(
        all_rows,
        [
            Constraint::Length(7),
            Constraint::Fill(4),
            Constraint::Fill(2),
            Constraint::Length(12),
            Constraint::Length(6),
        ],
    )
    .header(header)
    .block(
        Block::default()
            .borders(Borders::ALL)
            .border_set(border::THICK)
            .border_style(Style::default().fg(accent).add_modifier(Modifier::BOLD))
            .title(title),
    )
    .row_highlight_style(
        Style::default()
            .bg(pal.selected_bg)
            .add_modifier(Modifier::BOLD),
    )
    .highlight_symbol("▶ ");

    let mut state = app.issue_state.clone();
    f.render_stateful_widget(table, area, &mut state);
}

// ── 토스트 팝업 ───────────────────────────────────────────────────

fn render_toast(f: &mut Frame, app: &App) {
    let Some(msg) = &app.toast else { return };
    let pal = app.palette();

    let width = (msg.chars().count() as u16 + 4).min(f.area().width - 4);
    let area = f.area();
    let x = area.width.saturating_sub(width + 2);
    let y = area.height.saturating_sub(3);
    let popup = Rect { x, y, width, height: 3 };

    f.render_widget(Clear, popup);
    f.render_widget(
        Paragraph::new(format!(" {} ", msg))
            .style(Style::default().fg(Color::Black).bg(pal.issues_accent))
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(pal.issues_accent))
            ),
        popup,
    );
}

// ── 메인 렌더 ─────────────────────────────────────────────────────

pub fn render(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Fill(1),
            Constraint::Length(2),
        ])
        .split(f.area());

    // rect 저장 (마우스 hit-test용)
    app.issue_rect = chunks[1];

    render_header(f, chunks[0], app);
    render_issues(f, chunks[1], app);
    render_footer(f, chunks[2], app);
    render_toast(f, app);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::Theme;
    use crate::github::Issue;
    use ratatui::{backend::TestBackend, Terminal};
    use std::path::PathBuf;

    fn issue(number: u64, label_names: &[&str]) -> Issue {
        Issue {
            number,
            title: format!("이슈 {}", number),
            labels: label_names.iter().map(|s| s.to_string()).collect(),
            assignees: vec![],
            updated_at: Utc::now(),
        }
    }

    fn render_issue_panel(issues: Vec<Issue>) -> String {
        let mut app = App::new(
            "owner/repo".into(), 30, Theme::Cyberpunk,
            PathBuf::from("/w"), PathBuf::from("/am"),
        );
        app.issues = issues;

        let mut terminal = Terminal::new(TestBackend::new(132, 10)).unwrap();
        terminal.draw(|f| render_issues(f, f.area(), &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let mut out = String::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                out.push_str(buf[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }

    fn render_full(issues: Vec<Issue>) -> String {
        let mut app = App::new(
            "owner/repo".into(), 30, Theme::Cyberpunk,
            PathBuf::from("/w"), PathBuf::from("/am"),
        );
        app.issues = issues;

        let mut terminal = Terminal::new(TestBackend::new(132, 20)).unwrap();
        terminal.draw(|f| render(f, &mut app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let mut out = String::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                out.push_str(buf[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }

    // 전각 문자는 셀 2칸을 차지하고 두 번째 칸이 공백으로 남는다("유 저 대 기").
    // 공백을 걷어내고 비교한다.
    fn compact(s: &str) -> String {
        s.chars().filter(|c| !c.is_whitespace()).collect()
    }

    #[test]
    fn 이슈_패널이_상태를_라벨_배지로_그린다() {
        let out = render_issue_panel(vec![issue(122, &["awaiting-user"])]);
        let c = compact(&out);
        // 가장 긴 상태 배지도 라벨 컬럼 폭에 잘리지 않아야 한다
        assert!(c.contains("[awaiting-user]"), "이슈 상태 미표시:\n{}", out);
        // 답변 대기는 제목줄에 따로 센다
        assert!(c.contains("1건답변대기"), "답변 대기 수 미표시:\n{}", out);
    }

    #[test]
    fn 라벨이_많아도_이슈_상태가_라벨_컬럼에_남는다() {
        // 상태가 4번째라도 2개 컷에 밀리면 안 된다
        let out = render_issue_panel(vec![issue(29, &["enhancement", "epic", "critical", "rework"])]);
        let c = compact(&out);
        assert!(c.contains("[rework]"), "상태가 라벨 컬럼에서 밀렸다:\n{}", out);
        // 상태 배지가 앞을 차지하므로 일반 라벨은 1개만 보이고 나머지 2개는 +2
        assert!(c.contains("[enhancement]"), "라벨 미표시:\n{}", out);
        assert!(c.contains("+2"), "가려진 라벨 수 미표시:\n{}", out);
    }

    #[test]
    fn 상태가_아닌_라벨은_밀어내지_않는다() {
        // 모르는 라벨(옛 am:* 포함)이 라벨 컬럼에서 조용히 사라지면 안 된다
        let out = render_issue_panel(vec![issue(50, &["am:blocked", "ready"])]);
        let c = compact(&out);
        assert!(c.contains("[ready]"), "상태 미표시:\n{}", out);
        assert!(c.contains("[am:blocked]"), "상태 외 라벨이 사라졌다:\n{}", out);
    }

    #[test]
    fn 상태_라벨이_둘이어도_배지는_하나만_그린다() {
        let out = render_issue_panel(vec![issue(51, &["on-review", "rework", "bug"])]);
        let c = compact(&out);
        assert!(c.contains("[rework]"), "우선 상태 미표시:\n{}", out);
        assert!(!c.contains("[on-review]"), "상태 배지가 중복됐다:\n{}", out);
        assert!(c.contains("[bug]"), "일반 라벨 미표시:\n{}", out);
    }

    #[test]
    fn 상태_라벨이_없는_이슈는_상태_배지가_없다() {
        let out = render_issue_panel(vec![issue(67, &["documentation"])]);
        let c = compact(&out);
        assert!(c.contains("[documentation]"), "라벨 미표시:\n{}", out);
        for s in App::STATUS_PRIORITY {
            assert!(!c.contains(&format!("[{}]", s)), "없는 상태가 표시됐다:\n{}", out);
        }
    }

    #[test]
    fn 화면에는_이슈_패널만_있다() {
        let out = render_full(vec![issue(1, &["in-progress"])]);
        let c = compact(&out);
        assert!(c.contains("ISSUES"), "이슈 패널 미표시:\n{}", out);
        for gone in ["PULLREQUESTS", "LIVEEVENTS", "ROADMAP"] {
            assert!(!c.contains(gone), "{} 패널이 남았다:\n{}", gone, out);
        }
    }
}
