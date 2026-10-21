#!/usr/bin/env bash
# 레포에 git-issue-agent 를 붙인다: 필요한 도구 점검 → 에이전트(claude/codex) 선택 →
# .issue-agent/ 생성 → 상태 라벨 생성 → 도구별 권한 안내.
# 사용: git issue-agent init [--agent claude|codex] [--yes]
#   --yes: 묻지 않고 기본값으로 진행(에이전트 claude, 라벨 생성 함)
set -euo pipefail
source "$(dirname "$0")/common.sh"

AGENT=""
ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:?--agent 값 필요 (claude|codex)}"; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    *) gia_die "알 수 없는 인자: $1" ;;
  esac
done

ask() {  # ask "질문" "기본값" → REPLY
  if [ "$ASSUME_YES" = true ]; then REPLY="$2"; return; fi
  read -r -p "  $1 [$2] " REPLY
  REPLY="${REPLY:-$2}"
}

ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || gia_die "git 레포 안에서 실행하세요."
DIR="$TOP/.issue-agent"

echo ""
echo "━━━ 1. 필요한 도구 점검"
MISSING=0
GIT_VER="$(git --version | awk '{print $3}')"
if [ "$(printf '%s\n2.31\n' "$GIT_VER" | sort -V | head -1)" = "2.31" ]; then ok "git $GIT_VER"; else warn "git $GIT_VER — 2.31 이상 필요"; MISSING=1; fi
if command -v jq > /dev/null; then ok "jq"; else warn "jq 없음 (brew install jq)"; MISSING=1; fi
if ! command -v gh > /dev/null; then
  warn "gh 없음 (brew install gh)"; MISSING=1
elif gh auth status > /dev/null 2>&1; then
  ok "gh (로그인됨)"
else
  warn "gh 로그인 필요 (gh auth login)"; MISSING=1
fi
for opt in cargo tmux; do
  if command -v "$opt" > /dev/null; then ok "$opt"; else
    case "$opt" in
      cargo) warn "cargo 없음 — tracker(현황판)만 못 쓴다 (https://rustup.rs)" ;;
      tmux)  warn "tmux 없음 — tracker 에서 Enter 로 세션 창 열기가 안 되고 명령 복사로 대신한다" ;;
    esac
  fi
done

echo ""
echo "━━━ 2. 에이전트 CLI 선택"
HAVE=""
command -v claude > /dev/null && HAVE="$HAVE claude"
command -v codex  > /dev/null && HAVE="$HAVE codex"
echo "  설치됨:${HAVE:- (없음)}"
if [ -z "$AGENT" ]; then
  DEFAULT="claude"
  case "$HAVE" in *claude*) ;; *codex*) DEFAULT="codex" ;; esac
  ask "이슈 세션을 띄울 CLI (claude/codex)?" "$DEFAULT"
  AGENT="$REPLY"
fi
case "$AGENT" in claude|codex) ;; *) gia_die "claude 또는 codex 중 하나: '$AGENT'" ;; esac
case " $HAVE " in
  *" $AGENT "*) ok "$AGENT $("$AGENT" --version 2>/dev/null | head -1)" ;;
  *) warn "$AGENT 가 설치돼 있지 않다 — 설치·로그인 후 쓸 수 있다"; MISSING=1 ;;
esac

echo ""
echo "━━━ 3. .issue-agent/ 생성"
mkdir -p "$DIR"
if [ -f "$DIR/config" ]; then
  ok "config 이미 있음 — 건드리지 않음"
else
  REPO="$(cd "$TOP" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] || { ask "GitHub 레포 (owner/name)?" ""; REPO="$REPLY"; }
  [ -n "$REPO" ] || gia_die "레포 이름을 알 수 없습니다."
  BASE="$(cd "$TOP" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)"
  {
    echo "# git-issue-agent 레포 설정 — https://github.com/Korshort/git-issue-agent"
    echo "# bash 로 source 하지 않는다. GIA_*=값 줄만 읽는다."
    echo "GIA_REPO=\"$REPO\""
    echo "GIA_AGENT=\"$AGENT\""
    echo "GIA_BASE_BRANCH=\"${BASE:-main}\""
    echo "# GIA_WT_BASE=\"~/issue-agent-wt/$(basename "$TOP")\"   # worktree 위치"
    echo "# GIA_BRANCH_PREFIX=\"fix/issue-\""
    if [ "$AGENT" = claude ]; then
      echo "# GIA_MODEL=\"sonnet\"          # 이슈 세션 모델 (기본 sonnet)"
      echo "# GIA_EFFORT=\"medium\""
      echo "# GIA_REVIEW_MODEL=\"opus\"     # 리뷰 서브에이전트 모델 (기본 opus)"
    else
      echo "# GIA_MODEL=\"\"                # 비우면 ~/.codex/config.toml 의 기본 모델"
      echo "# GIA_EFFORT=\"\"               # model_reasoning_effort (low|medium|high)"
      echo "# GIA_REVIEW_MODEL=\"\"         # 비우면 세션과 같은 모델"
    fi
  } > "$DIR/config"
  ok "config (레포 $REPO, 에이전트 $AGENT)"
fi
for f in agent.md review.md; do
  if [ -f "$DIR/$f" ]; then ok "$f 이미 있음 — 건드리지 않음"; else cp "$GIA_HOME/templates/$f" "$DIR/$f"; ok "$f (템플릿 — TODO 를 채울 것)"; fi
done

echo ""
echo "━━━ 4. 상태 라벨"
(cd "$TOP" && "$GIA_HOME/lib/labels.sh" --dry-run)
ask "위대로 라벨을 만들까요? (y/N)" "y"
case "$REPLY" in
  [Yy]*) (cd "$TOP" && "$GIA_HOME/lib/labels.sh") ;;
  *) echo "  건너뜀 — 나중에: git issue-agent labels" ;;
esac

echo ""
echo "━━━ 5. 권한 ($AGENT)"
if [ "$AGENT" = claude ]; then
  cat <<EOF
  세션은 대화형 claude 로 뜬다. 아래 명령이 매번 승인을 묻지 않게 하려면
  메인 작업공간의 .claude/settings.local.json 에 허용 목록을 둔다(git issue-agent run 이 worktree 로 복사한다):
    {
      "permissions": {
        "allow": [
          "Bash($GIA_BIN:*)",
          "Bash(gh issue:*)", "Bash(gh pr:*)",
          "Bash(git add:*)", "Bash(git commit:*)", "Bash(git push:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)"
        ]
      }
    }
  검증 게이트 명령(린트·테스트)도 같은 식으로 더한다.
EOF
else
  cat <<EOF
  세션은 대화형 codex 로 뜬다. 샌드박스는 workspace-write + 승인 on-request 이고,
  worktree 와 메인 작업공간 쓰기, 네트워크(gh·git push)를 허용해서 띄운다.
  그 밖의 명령은 codex 가 승인을 요청한다. 로그인: codex login
EOF
fi

echo ""
echo "━━━ 6. 작업 규칙 작성 (필수 — 직접 해야 한다)"
cat <<EOF
  에이전트는 이 두 파일만 보고 이 레포의 방식대로 일하고 리뷰한다. 템플릿의 TODO 를 채운다:
    .issue-agent/agent.md   읽을 문서, 커밋 형식, 검증 게이트(린트·테스트 명령), 금지 행동, Jira 절차
    .issue-agent/review.md  리뷰 기준, 리뷰어가 직접 돌릴 검증 명령
  쓰지 않는 절은 지운다. TODO 가 하나라도 남아 있으면 git issue-agent run 이 실행을 거부한다.
  다 채웠으면 .issue-agent/ 를 커밋해 기본 브랜치에 올린다(이슈 worktree 가 그 판본을 쓴다).
EOF

echo ""
echo "━━━ 끝"
[ "$MISSING" = 0 ] || warn "빠진 도구가 있다 — 위 ⚠️ 를 먼저 해결할 것"
echo "  사용: 이슈에 ready 라벨 → git issue-agent run <N>   (현황판: git issue-agent tracker)"
