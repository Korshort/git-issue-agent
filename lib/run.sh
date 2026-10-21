#!/usr/bin/env bash
# 이슈 1건을 처음부터 머지까지: worktree 준비 → Claude 세션 1개
# (작업 → 리뷰 서브에이전트 → 반려 시 재작업 → 승인 시 머지) → 머지됐으면 정리.
# 사용: git issue-agent run 17
#
# 전제: 항상 대화형으로 돈다(사람이 터미널에서 답할 수 있다).
#   - git issue-agent poll 은 실행 명령을 print 만 하고 exec 하지 않는다.
#   - tracker 는 tmux 윈도우로 띄우므로 역시 TTY 가 붙는다.
#   end.sh 의 "질문 대기(awaiting-user) 시 세션 유지" 가드가 이 전제에 의존한다.
#   자동 exec 경로(cron 등)를 새로 만들면 답할 사람이 없어 조용히 hang 한다 — 그 가드를 먼저 재설계할 것.
#
# 정리를 세션 밖(여기)에서 하는 이유: 세션의 cwd 가 worktree 라서, 세션 안에서 worktree 를
# 지우면 이후 명령이 전부 없는 디렉터리에서 돈다. 그래서 세션은 머지까지만 하고,
# claude 가 끝난 뒤 이 스크립트가 PR 머지를 확인하고 정리한다.
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

ISSUE="${1:-}"
gia_require_issue "$ISSUE" run
BRANCH="$(gia_branch "$ISSUE")"
WORKTREE="$(gia_worktree "$ISSUE")"
BASE="$GIA_BASE_BRANCH"

# 작업 규칙이 없거나 템플릿 TODO 가 남아 있으면 세션을 띄우지 않는다(worktree 를 만들기 전에 거른다).
# 검증 게이트가 빈 채로 돌면 리뷰어가 무엇을 근거로 승인할지 없어 결국 사람이 다시 봐야 한다.
for f in agent.md review.md; do
  p="$GIA_CONFIG_DIR/$f"
  [ -f "$p" ] || gia_die ".issue-agent/$f 가 없습니다. git issue-agent init 으로 만들고 내용을 채우세요."
  if grep -n "TODO:" "$p" > /dev/null; then
    echo "  ❌ .issue-agent/$f 에 아직 채우지 않은 TODO 가 있습니다:" >&2
    grep -n "TODO:" "$p" | sed 's/^/     /' >&2
    gia_die "작업 규칙을 채우고 커밋한 뒤 다시 실행하세요. (쓰지 않는 절은 지우면 된다)"
  fi
done

mkdir -p "$GIA_WT_BASE"

WT_REGISTERED=$(git -C "$GIA_WORKDIR" worktree list | grep -q "$WORKTREE" && echo "yes" || echo "no")
WT_DIR_EXISTS=$([ -d "$WORKTREE" ] && echo "yes" || echo "no")

if [ "$WT_REGISTERED" = "yes" ] && [ "$WT_DIR_EXISTS" = "yes" ]; then
  echo "  worktree 이미 존재: $WORKTREE"
  git -C "$GIA_WORKDIR" fetch origin "$BASE" --quiet
else
  if [ "$WT_DIR_EXISTS" = "yes" ]; then
    echo "  고아 디렉토리 감지, 제거 후 재생성: $WORKTREE"
    rm -rf "$WORKTREE"
    git -C "$GIA_WORKDIR" worktree prune
  fi

  git -C "$GIA_WORKDIR" fetch origin --quiet
  if git -C "$GIA_WORKDIR" show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
    git -C "$GIA_WORKDIR" worktree add "$WORKTREE" -b "$BRANCH" "origin/${BRANCH}"
    echo "  worktree 생성 (remote 브랜치): $WORKTREE ← $BRANCH"
  elif git -C "$GIA_WORKDIR" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git -C "$GIA_WORKDIR" worktree add "$WORKTREE" "$BRANCH"
    echo "  worktree 생성 (로컬 브랜치): $WORKTREE ← $BRANCH"
  else
    git -C "$GIA_WORKDIR" worktree add "$WORKTREE" -b "$BRANCH" "origin/$BASE"
    echo "  worktree 생성 (신규 브랜치): $WORKTREE ← $BRANCH (origin/$BASE 기준)"
  fi
fi

# Claude 로컬 권한 설정만 복사 (시크릿/런타임 env 는 복사하지 않음)
SETTINGS_SRC="$GIA_WORKDIR/.claude/settings.local.json"
SETTINGS_DST="$WORKTREE/.claude/settings.local.json"
if [ -f "$SETTINGS_SRC" ] && [ ! -e "$SETTINGS_DST" ]; then
  mkdir -p "$WORKTREE/.claude"
  cp "$SETTINGS_SRC" "$SETTINGS_DST"
  echo "  .claude/settings.local.json 복사 완료"
fi

CONTEXT=$(gh issue view "$ISSUE" --repo "$GIA_REPO" --json number,title,body,comments -q '
"# GitHub Issue #\(.number): \(.title)\n\n" +
"## 이슈 내용\n\n" + .body + "\n\n" +
(if (.comments | length) > 0 then
  "## 대화 히스토리 (시간순)\n\n" +
  (.comments | map("### @\(.author.login) (\(.createdAt))\n\n\(.body)\n") | join("\n"))
else "" end)
')

# 프롬프트 조립: 공통 계약 + 레포 전용 규칙 + 도구별 방법(claude/codex) + 리뷰어 브리프(공통 + 레포 전용).
# 레포 파일은 worktree(=이슈 브랜치) 것을 쓴다. 이슈가 규칙 자체를 고치는 중이면 그 판본이 맞다.
render() {
  sed -e "s|{ISSUE}|$ISSUE|g" -e "s|{REPO}|$GIA_REPO|g" -e "s|{BRANCH}|$BRANCH|g" \
      -e "s|{BASE}|$BASE|g" -e "s|{WORKTREE}|$WORKTREE|g" -e "s|{WORKDIR}|$GIA_WORKDIR|g" \
      -e "s|{CLI}|$GIA_BIN|g" -e "s|{REVIEW_MODEL}|$GIA_REVIEW_MODEL|g" "$1"
}
repo_file_path() {
  local f="$WORKTREE/.issue-agent/$1"
  [ -f "$f" ] || f="$GIA_WORKDIR/.issue-agent/$1"
  echo "$f"
}
repo_file() { render "$(repo_file_path "$1")"; }


SYSTEM_PROMPT="$(render "$GIA_HOME/prompts/issue_agent.md")

# 이 레포 전용 규칙 (.issue-agent/agent.md)

$(repo_file agent.md)

# 도구별 방법 ($GIA_AGENT)

$(render "$GIA_HOME/prompts/agent_$GIA_AGENT.md")

# 리뷰어 브리프 — 리뷰 서브에이전트의 prompt 로 아래 전문을 그대로 넘긴다

$(render "$GIA_HOME/prompts/reviewer.md")

## 이 레포 전용 리뷰 기준 (.issue-agent/review.md)

$(repo_file review.md)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  이슈 #$ISSUE 세션 시작 ($GIA_AGENT: ${GIA_MODEL:-기본 모델}, effort ${GIA_EFFORT:-기본} / 리뷰 ${GIA_REVIEW_MODEL:-세션과 같은 모델})"
echo "  브랜치: $BRANCH"
echo "  경로:   $WORKTREE"
echo "  https://github.com/$GIA_REPO/issues/$ISSUE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$WORKTREE"
# end.sh 가 라벨(awaiting-user)을 조회해 질문 대기 세션의 자살을 막는 데 쓴다.
export GIA_ISSUE="$ISSUE" GIA_REPO GIA_AGENT
# end.sh 가 에이전트 프로세스를 TERM 으로 끝내므로 종료 코드는 보지 않는다.
case "$GIA_AGENT" in
  claude)
    claude --model "$GIA_MODEL" --effort "$GIA_EFFORT" "$CONTEXT" --append-system-prompt "$SYSTEM_PROMPT" || true
    ;;
  codex)
    # 계약은 developer 메시지로 넣는다. 값은 TOML 로 파싱되므로 JSON 문자열(= 유효한 TOML 기본 문자열)로 감싼다.
    # 샌드박스: worktree 쓰기 + 메인 작업공간(.git/worktrees 포함) 쓰기 + 네트워크(gh·git push) 허용,
    # 그 밖의 것은 모델이 승인을 요청한다(on-request).
    set -- -C "$WORKTREE" -s workspace-write -a on-request --add-dir "$GIA_WORKDIR" \
      -c sandbox_workspace_write.network_access=true \
      -c "developer_instructions=$(printf '%s' "$SYSTEM_PROMPT" | jq -Rs .)"
    [ -n "$GIA_MODEL" ] && set -- "$@" -m "$GIA_MODEL"
    [ -n "$GIA_EFFORT" ] && set -- "$@" -c "model_reasoning_effort=\"$GIA_EFFORT\""
    codex "$@" "$CONTEXT" || true
    ;;
esac

cd "$GIA_WORKDIR"
PR_STATE=$(gh pr list --repo "$GIA_REPO" --head "$BRANCH" --state all --json state -q '.[0].state' 2>/dev/null || echo "")
if [ "$PR_STATE" = "MERGED" ]; then
  "$GIA_HOME/lib/close.sh" "$ISSUE"
  # tracker 가 띄운 윈도우면 닫는다(다 끝난 이슈 창이 쌓이지 않게).
  [ -n "${TMUX:-}" ] && tmux kill-window 2>/dev/null
  exit 0
fi

echo ""
echo "  세션 종료 — PR 미머지(${PR_STATE:-PR 없음}). 이어서 하려면: git issue-agent run $ISSUE"
