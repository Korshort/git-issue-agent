#!/usr/bin/env bash
# 이슈 PR 을 origin/<base> 기준 rebase 후 rebase 머지한다.
# 사용: git issue-agent merge 17 [--yes]
#
# 정리(worktree·브랜치 제거)는 호출 위치에 따라 갈린다:
#   - 이슈 worktree 안에서 부르면(=이슈 세션이 머지) 정리하지 않는다. 세션의 cwd 를 지우면
#     이후 명령이 전부 깨진다. 세션이 끝나면 git issue-agent run 이 머지를 확인하고 정리한다.
#   - 그 밖에서 부르면(사람이 직접 머지) 바로 정리한다.
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

ISSUE=""
AUTO_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) AUTO_YES=true ;;
    *) ISSUE="$1" ;;
  esac
  shift
done
gia_require_issue "$ISSUE" merge
BRANCH="$(gia_branch "$ISSUE")"
WORKTREE="$(gia_worktree "$ISSUE")"
BASE="$GIA_BASE_BRANCH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  이슈 #$ISSUE PR rebase 머지"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PR_INFO=$(gh pr list --repo "$GIA_REPO" --head "$BRANCH" --state open --json number,title,url -q '.[0]' 2>/dev/null || echo "")
if [ -z "$PR_INFO" ] || [ "$PR_INFO" = "null" ]; then
  gia_die "$BRANCH 에 열린 PR이 없습니다. 세션에서 PR을 먼저 생성하세요."
fi

PR_NUM=$(echo "$PR_INFO" | jq -r '.number')
echo "  PR #$PR_NUM: $(echo "$PR_INFO" | jq -r '.title')"
echo "  $(echo "$PR_INFO" | jq -r '.url')"
echo ""

PR_CHECKS=$(gh pr checks "$PR_NUM" --repo "$GIA_REPO" 2>/dev/null || echo "")
if echo "$PR_CHECKS" | grep -q "fail"; then
  echo "  ⚠️  CI 실패 항목:"
  echo "$PR_CHECKS" | grep "fail"
  if [ "$AUTO_YES" = true ]; then
    echo "  (--yes 모드: 자동 승인)"
  else
    read -p "  그래도 머지하시겠습니까? (y/N) " -n 1 -r; echo ""
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
  fi
fi

if [ -d "$WORKTREE" ]; then
  echo "  origin/$BASE fetch + ff-only 갱신..."
  git -C "$GIA_WORKDIR" fetch origin "$BASE" --quiet
  git -C "$GIA_WORKDIR" merge "origin/$BASE" --ff-only --quiet 2>/dev/null || true
  echo "  origin/$BASE 기준 rebase..."
  if ! git -C "$WORKTREE" rebase "origin/$BASE"; then
    echo ""
    echo "  ❌ rebase 충돌. 해결 후:"
    echo "     cd $WORKTREE"
    echo "     # 해결 후: git rebase --continue   취소: git rebase --abort"
    exit 1
  fi
  echo "  ✅ rebase 완료"
  git -C "$WORKTREE" push origin "$BRANCH" --force-with-lease
  echo "  ✅ force-with-lease push 완료"
  echo ""
else
  echo "  ⚠️  worktree 없음 ($WORKTREE) — rebase 스킵. 브랜치가 이미 $BASE 기준인지 확인."
  echo ""
fi

# force-push 직후에는 GitHub 가 mergeable 을 다시 계산하는 동안 "not mergeable" 로 거절한다(충돌 아님).
# MERGEABLE 이 될 때까지 잠깐 기다린다. CONFLICTING 이면 진짜 충돌이다.
for _ in $(seq 1 24); do
  MERGEABLE=$(gh pr view "$PR_NUM" --repo "$GIA_REPO" --json mergeable -q '.mergeable' 2>/dev/null || echo "UNKNOWN")
  case "$MERGEABLE" in
    MERGEABLE) break ;;
    CONFLICTING) gia_die "PR #$PR_NUM 충돌(CONFLICTING). worktree 에서 rebase 충돌을 해결하세요." ;;
  esac
  sleep 5
done

# 브랜치 삭제는 close.sh 가 한다. 여기서 --delete-branch 를 주면 worktree 에 체크아웃된
# 로컬 브랜치를 지우려다 실패한다.
echo "  PR 머지 중 (rebase)..."
gh pr merge "$PR_NUM" --repo "$GIA_REPO" --rebase
echo "  ✅ PR #$PR_NUM rebase 머지 완료"
echo ""

WT_REAL=""
[ -d "$WORKTREE" ] && WT_REAL="$(cd "$WORKTREE" && pwd -P)"
# 이 이슈의 세션(git issue-agent run 이 GIA_ISSUE 를 export)이거나 worktree 안이면 정리를 미룬다.
IN_WT=false
if [ -n "$WT_REAL" ]; then
  case "$(pwd -P)/" in "$WT_REAL/"*) IN_WT=true ;; esac
fi
if [ "${GIA_ISSUE:-}" = "$ISSUE" ] || [ "$IN_WT" = true ]; then
  echo "  worktree 안에서 머지 — 정리는 세션 종료 후 git issue-agent run 이 한다."
else
  "$GIA_HOME/lib/close.sh" "$ISSUE"
fi
