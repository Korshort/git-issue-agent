#!/usr/bin/env bash
# 레포에 상태 라벨 5종을 맞춘다. 옛 am:* 라벨이 있으면 지우지 않고 이름을 바꾼다
# (지우면 그 라벨을 달고 있던 이슈 이력이 사라진다).
# 사용: git issue-agent labels [--dry-run]
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true

run() {
  if [ "$DRY" = true ]; then echo "  (dry-run) gh $*"; else gh "$@" > /dev/null; echo "  ✅ gh $*"; fi
}

EXISTING="$(gh label list --repo "$GIA_REPO" --limit 200 --json name -q '.[].name')"
has() { printf '%s\n' "$EXISTING" | grep -qx "$1"; }

# 이름|색|설명
SPECS="ready|0E8A16|에이전트 착수 대기
in-progress|FBCA04|에이전트 작업 중
on-review|D876E3|리뷰 서브에이전트 검토 중 (사람 손 불필요)
rework|F9A03F|리뷰 반려 후 같은 세션이 재작업 중
awaiting-user|D93F0B|사람의 답변·판단 필요"

echo "  레포: $GIA_REPO"
while IFS='|' read -r name color desc; do
  if has "$name"; then
    run label edit "$name" --repo "$GIA_REPO" --color "$color" --description "$desc"
  elif has "am:$name"; then
    run label edit "am:$name" --repo "$GIA_REPO" --name "$name" --color "$color" --description "$desc"
  else
    run label create "$name" --repo "$GIA_REPO" --color "$color" --description "$desc"
  fi
done <<< "$SPECS"
