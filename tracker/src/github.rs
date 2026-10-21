use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct Issue {
    pub number: u64,
    pub title: String,
    pub labels: Vec<String>,
    pub assignees: Vec<String>,
    pub updated_at: DateTime<Utc>,
}

// ── raw JSON structs ───────────────────────────────────────────────

#[derive(Deserialize)]
struct RawLabel { name: String }

#[derive(Deserialize)]
struct RawAssignee { login: String }

#[derive(Deserialize)]
struct RawIssue {
    number: u64,
    title: String,
    labels: Vec<RawLabel>,
    assignees: Vec<RawAssignee>,
    #[serde(rename = "updatedAt")]
    updated_at: DateTime<Utc>,
}

// ── gh CLI helpers ─────────────────────────────────────────────────

fn gh_json<T: for<'de> Deserialize<'de>>(args: &[&str]) -> Result<T> {
    let out = Command::new("gh")
        .args(args)
        .output()
        .context("gh CLI not found")?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("gh error: {}", stderr.trim());
    }
    serde_json::from_slice(&out.stdout).context("JSON parse error")
}

// ── public API ─────────────────────────────────────────────────────

pub fn fetch_issues(repo: &str) -> Result<Vec<Issue>> {
    let raw: Vec<RawIssue> = gh_json(&[
        "issue", "list",
        "--repo", repo,
        "--state", "open",
        "--limit", "50",
        "--json", "number,title,labels,assignees,updatedAt",
    ])?;

    let mut issues: Vec<Issue> = raw.into_iter().map(|r| Issue {
        number:     r.number,
        title:      r.title,
        labels:     r.labels.into_iter().map(|l| l.name).collect(),
        assignees:  r.assignees.into_iter().map(|a| a.login).collect(),
        updated_at: r.updated_at,
    }).collect();

    issues.sort_by(|a, b| b.number.cmp(&a.number));
    Ok(issues)
}
