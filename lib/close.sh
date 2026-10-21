#!/usr/bin/env bash
# 머지된 이슈 정리: base 갱신, worktree·로컬·원격 브랜치 제거, GitHub 이슈 클로즈.
# 사용: git issue-agent close 17   (보통은 git issue-agent run / git issue-agent merge 가 부른다)
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

ISSUE="${1:-}"
gia_require_issue "$ISSUE" close
BRANCH="$(gia_branch "$ISSUE")"
WORKTREE="$(gia_worktree "$ISSUE")"
BASE="$GIA_BASE_BRANCH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  이슈 #$ISSUE 정리"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PR_STATE=$(gh pr list --repo "$GIA_REPO" --head "$BRANCH" --state all --json state,number -q '.[0] | "\(.state) \(.number)"' 2>/dev/null || echo "")
if [ -z "$PR_STATE" ]; then
  echo "  ⚠️  $BRANCH 에 연결된 PR을 찾을 수 없습니다."
  read -p "  그래도 계속 정리하시겠습니까? (y/N) " -n 1 -r; echo ""
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
elif echo "$PR_STATE" | grep -q "^OPEN"; then
  PR_NUM=$(echo "$PR_STATE" | awk '{print $2}')
  echo "  ⚠️  PR #$PR_NUM 이 아직 열려 있습니다. https://github.com/$GIA_REPO/pull/$PR_NUM"
  read -p "  머지 없이 정리하시겠습니까? (y/N) " -n 1 -r; echo ""
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
else
  PR_NUM=$(echo "$PR_STATE" | awk '{print $2}')
  echo "  ✅ PR #$PR_NUM 머지 확인"
fi

echo "  $BASE fetch + ff-only 갱신..."
git -C "$GIA_WORKDIR" fetch origin "$BASE" --quiet
git -C "$GIA_WORKDIR" checkout "$BASE" --quiet
git -C "$GIA_WORKDIR" merge "origin/$BASE" --ff-only --quiet
echo "  ✅ $BASE 최신화 ($(git -C "$GIA_WORKDIR" rev-parse --short HEAD))"

if git -C "$GIA_WORKDIR" worktree list | grep -q "$WORKTREE"; then
  git -C "$GIA_WORKDIR" worktree remove "$WORKTREE" --force
  echo "  ✅ worktree 제거: $WORKTREE"
else
  echo "  - worktree 없음 (이미 제거): $WORKTREE"
fi

if git -C "$GIA_WORKDIR" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git -C "$GIA_WORKDIR" branch -D "$BRANCH"
  echo "  ✅ 로컬 브랜치 제거: $BRANCH"
fi

if git -C "$GIA_WORKDIR" ls-remote --exit-code origin "$BRANCH" > /dev/null 2>&1; then
  git -C "$GIA_WORKDIR" push origin --delete "$BRANCH"
  echo "  ✅ 원격 브랜치 제거: origin/$BRANCH"
fi

ISSUE_STATE=$(gh issue view "$ISSUE" --repo "$GIA_REPO" --json state -q '.state' 2>/dev/null || echo "")
if [ "$ISSUE_STATE" = "OPEN" ]; then
  gh issue close "$ISSUE" --repo "$GIA_REPO"
  echo "  ✅ GitHub 이슈 #$ISSUE 클로즈"
else
  echo "  - 이슈 #$ISSUE 이미 클로즈됨"
fi

echo ""
echo "  이슈 #$ISSUE 정리 완료"
echo ""
