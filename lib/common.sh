# git-issue-agent 공통: 레포별 설정(.issue-agent/config) 로딩과 경로 계산. 각 lib/*.sh 가 source 한다.
# bash 3.2(macOS 기본) 호환을 유지한다: 연관 배열·mapfile 금지, set -u 아래 빈 배열 전개 금지.

GIA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIA_BIN="$GIA_HOME/bin/git-issue-agent"

# 상태 라벨. 이슈에는 이 중 하나만 붙는다(우선순위 순서는 tracker 와 같다).
GIA_STATUS_LABELS="ready in-progress on-review rework awaiting-user"

gia_die() { echo "  ❌ $*" >&2; exit 1; }

# 설정 로딩.
# - GIA_WORKDIR: 메인 작업공간. worktree 안에서 불러도 메인 쪽을 가리킨다(git-common-dir 기준).
# - 설정 파일은 현재 체크아웃(worktree 포함)의 .issue-agent/config 를 먼저 보고, 없으면 메인 작업공간 것을 본다.
# - .issue-agent/config 는 source 하지 않고 GIA_* 키만 읽는다(레포 파일이 임의 코드를 실행하지 않게).
gia_load_config() {
  local common top cfg key val
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || gia_die "git 레포 안에서 실행하세요."
  GIA_WORKDIR="$(dirname "$common")"
  top="$(git rev-parse --show-toplevel 2>/dev/null || echo "$GIA_WORKDIR")"
  cfg="$top/.issue-agent/config"
  [ -f "$cfg" ] || cfg="$GIA_WORKDIR/.issue-agent/config"
  [ -f "$cfg" ] || gia_die ".issue-agent/config 가 없습니다 ($GIA_WORKDIR). 이 레포에 처음 붙이는 거면: git issue-agent init"

  GIA_REPO=""
  GIA_AGENT="claude"
  GIA_WT_BASE="$HOME/issue-agent-wt/$(basename "$GIA_WORKDIR")"
  GIA_BRANCH_PREFIX="fix/issue-"
  GIA_BASE_BRANCH="main"
  GIA_MODEL=""
  GIA_EFFORT=""
  GIA_REVIEW_MODEL=""

  while IFS='=' read -r key val; do
    case "$key" in
      GIA_REPO|GIA_AGENT|GIA_WT_BASE|GIA_BRANCH_PREFIX|GIA_BASE_BRANCH|GIA_MODEL|GIA_EFFORT|GIA_REVIEW_MODEL) ;;
      *) continue ;;
    esac
    val="${val%\"}"; val="${val#\"}"
    case "$val" in "~/"*) val="$HOME/${val#\~/}" ;; esac
    printf -v "$key" '%s' "$val"
  done < <(grep -E '^GIA_[A-Z_]+=' "$cfg")

  [ -n "$GIA_REPO" ] || gia_die "$cfg 에 GIA_REPO 가 없습니다."

  # 에이전트 CLI 별 기본값. 비워 두면 codex 는 ~/.codex/config.toml 의 기본 모델을 쓴다.
  case "$GIA_AGENT" in
    claude)
      : "${GIA_MODEL:=sonnet}"; : "${GIA_EFFORT:=medium}"; : "${GIA_REVIEW_MODEL:=opus}" ;;
    codex) ;;
    *) gia_die "GIA_AGENT 는 claude 또는 codex: '$GIA_AGENT'" ;;
  esac
  GIA_CONFIG_DIR="$(dirname "$cfg")"
}

gia_branch()   { echo "${GIA_BRANCH_PREFIX}$1"; }
gia_worktree() { echo "$GIA_WT_BASE/issue-$1"; }

gia_require_issue() {
  case "${1:-}" in
    ''|*[!0-9]*) gia_die "이슈 번호를 입력하세요. 예: git issue-agent ${2:-run} 17" ;;
  esac
}
