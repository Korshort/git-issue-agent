#!/usr/bin/env bash
# 이슈 현황판 TUI 실행. 바이너리가 없거나 소스가 더 최신이면 빌드한다.
# 사용: git issue-agent tracker [--interval SECS] [--theme NAME]
set -euo pipefail
source "$(dirname "$0")/common.sh"
gia_load_config

MANIFEST="$GIA_HOME/tracker/Cargo.toml"
BINARY="$GIA_HOME/tracker/target/release/git-issue-agent-tracker"

NEEDS_BUILD=false
if [ ! -f "$BINARY" ]; then
  NEEDS_BUILD=true
else
  for src in "$GIA_HOME"/tracker/src/*.rs "$MANIFEST"; do
    if [ "$src" -nt "$BINARY" ]; then
      NEEDS_BUILD=true
      break
    fi
  done
fi

if [ "$NEEDS_BUILD" = true ]; then
  echo "빌드 중..." >&2
  cargo build --release --manifest-path "$MANIFEST" --quiet
fi

exec "$BINARY" --repo "$GIA_REPO" --workspace "$GIA_WORKDIR" --cli "$GIA_BIN" "$@"
