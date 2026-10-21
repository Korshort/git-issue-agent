#!/usr/bin/env bash
# 이슈의 상태 라벨을 하나로 바꾼다. 다른 상태 라벨은 모두 뗀다.
# 사용: git issue-agent label 17 on-review      (상태 = ready|in-progress|on-review|rework|awaiting-user|none)
#
# 에이전트가 --add-label/--remove-label 짝을 손으로 맞추다 상태 라벨이 둘씩 남던 것을 막는다.
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

ISSUE="${1:-}"; STATE="${2:-}"
gia_require_issue "$ISSUE" label
case " $GIA_STATUS_LABELS none " in
  *" $STATE "*) ;;
  *) gia_die "상태는 $GIA_STATUS_LABELS none 중 하나: '$STATE'" ;;
esac

CURRENT="$(gh issue view "$ISSUE" --repo "$GIA_REPO" --json labels -q '.labels[].name')"

ARGS=""
for lb in $GIA_STATUS_LABELS; do
  [ "$lb" = "$STATE" ] && continue
  if printf '%s\n' "$CURRENT" | grep -qx "$lb"; then
    ARGS="$ARGS${ARGS:+,}$lb"
  fi
done

ADD=""
if [ "$STATE" != "none" ] && ! printf '%s\n' "$CURRENT" | grep -qx "$STATE"; then
  ADD="$STATE"
fi

if [ -z "$ADD" ] && [ -z "$ARGS" ]; then
  echo "  이슈 #$ISSUE 이미 '$STATE' 상태"
  exit 0
fi

set -- issue edit "$ISSUE" --repo "$GIA_REPO"
[ -n "$ADD" ] && set -- "$@" --add-label "$ADD"
[ -n "$ARGS" ] && set -- "$@" --remove-label "$ARGS"
gh "$@" > /dev/null
echo "  이슈 #$ISSUE → $STATE"
