#!/usr/bin/env bash
# ready 라벨 이슈를 감지해 in-progress 로 전환하고 실행 명령을 안내한다(직접 실행하지 않는다).
# 사용: git issue-agent poll [간격초=30]
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

INTERVAL=${1:-30}

echo "[poller] $GIA_REPO — ${INTERVAL}초 간격으로 ready 이슈 감지"
echo "[poller] 종료: Ctrl+C"
echo ""

while true; do
  READY_ISSUES=$(gh issue list --repo "$GIA_REPO" --state open --label "ready" \
                   --json number -q '.[].number' 2>/dev/null || echo "")

  if [ -n "$READY_ISSUES" ]; then
    for ISSUE in $READY_ISSUES; do
      "$GIA_HOME/lib/label.sh" "$ISSUE" in-progress > /dev/null 2>&1 || true
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  [!] 이슈 #$ISSUE 감지"
      echo "  cd $GIA_WORKDIR && git issue-agent run $ISSUE"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
    done
    exit 0
  else
    echo "[poller] $(date '+%H:%M:%S') — 대기 중..."
  fi

  sleep "$INTERVAL"
done
