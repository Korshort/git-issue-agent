#!/usr/bin/env bash
# 이슈 세션이 일을 "완전히" 마쳤을 때 스스로 부른다 — 현재 에이전트(claude/codex) 세션을 종료한다.
# 사용: git issue-agent end   (세션 내부에서만)
#
# 동작:
#  0) 질문 대기 가드: 이슈가 awaiting-user 면 종료를 거부한다(아래 참조).
#  1) 조상 프로세스를 거슬러 올라가 에이전트 프로세스(GIA_AGENT, 기본 claude)를 찾아 TERM 시그널.
#     tmux 윈도우째 죽이지 않는다 — 에이전트가 끝나야 git issue-agent run 이 이어서 머지 확인·정리를 한다.
set -uo pipefail

# 0) 질문 대기 가드
#
# 에이전트가 질문을 남긴 뒤(awaiting-user) 종료하면 사용자는 터미널에서 답할 창을 잃는다.
# 라벨이 이 흐름의 SSOT 이므로 라벨로 가른다. 라벨 조회 실패 시에도 종료하지 않는다(fail-safe).
# 이슈 번호·레포는 git issue-agent run 이 GIA_ISSUE / GIA_REPO 로 export 한다.
ISSUE="${GIA_ISSUE:-}"
REPO="${GIA_REPO:-}"
if [ -n "$ISSUE" ] && [ -n "$REPO" ]; then
  if LABELS="$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null)"; then
    if printf '%s\n' "$LABELS" | grep -qx "awaiting-user"; then
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  세션 종료 거부 — 이슈 #$ISSUE 가 awaiting-user(사람 답변 대기) 상태입니다."
      echo ""
      echo "  질문을 남긴 세션을 종료하면 사용자가 이 터미널에서 답할 수 없습니다."
      echo "  → AskUserQuestion으로 사용자에게 직접 묻고 답변을 기다리세요."
      echo "  → 답변을 받으면 git issue-agent label $ISSUE <다음 상태> 로 라벨을 바꾸고 작업을 계속하세요."
      echo "  → 질문이 없는데 이 메시지가 떴다면, 라벨을 실제 상태에 맞게 고친 뒤 다시 호출하세요."
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      exit 1
    fi
  else
    echo "  라벨 조회 실패(이슈 #$ISSUE) — 안전을 위해 세션을 유지합니다."
    exit 1
  fi
fi

# 1) 조상 에이전트 프로세스 탐색 후 종료 (실행 파일 경로에 claude/codex 가 들어 있다)
AGENT="${GIA_AGENT:-claude}"
pid="${PPID:-}"
for _ in 1 2 3 4 5 6 7 8; do
  [ -z "$pid" ] && break
  [ "$pid" = "0" ] || [ "$pid" = "1" ] && break
  comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$comm" in
    *"$AGENT"*) kill -TERM "$pid" 2>/dev/null; exit 0 ;;
  esac
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
done

# 폴백: 못 찾으면 조용히 종료(세션은 인터랙티브 프롬프트로 남음)
exit 0
