# git-issue-agent

GitHub Issue 를 작업 큐로, git worktree 를 격리 작업공간으로 쓰는 코딩 에이전트(Claude Code·Codex CLI) 흐름과 이슈 현황판.
여러 레포에서 같이 쓴다. 레포마다 다른 것은 그 레포의 `.issue-agent/` 에만 둔다.

```
이슈(ready) → git issue-agent run → worktree + Claude 세션 하나
   작업 → PR → 리뷰 서브에이전트 ─ 반려 → 같은 세션이 재작업 → 다시 리뷰
                                  └ 승인 → (Jira 키 있으면 작업시간·특이사항만 질문) → 머지 → 종료 → 정리
```

예전에는 이슈 처리 에이전트와 PR 리뷰 에이전트가 따로 돌았다(폴러 둘, 세션 둘, 반려되면 이슈가 큐로 돌아가 새 세션이 다시 읽음).
이제 **세션 하나가 리뷰를 서브에이전트로 받고, 반려되면 그 자리에서 이어서 고친다.** 리뷰 승인 = 머지 승인이다.

## 설치

```bash
git clone https://github.com/Korshort/git-issue-agent.git ~/git-issue-agent
ln -s ~/git-issue-agent/bin/git-issue-agent ~/.local/bin/git-issue-agent   # PATH 에 있는 아무 곳
```
필요: `git` 2.31+, `gh`(로그인), `jq`, 에이전트 CLI **`claude` 또는 `codex`**(설치·로그인). 선택: tracker 용 `cargo`, `tmux`.

## 레포에 붙이기

```bash
cd <레포>
git issue-agent init                 # 또는 --agent claude|codex, 묻지 않으려면 --yes
```
`init` 이 하는 일:
1. 필요한 도구 점검 (빠진 것만 알려 준다)
2. 이슈 세션을 띄울 에이전트 CLI 선택: `claude` 또는 `codex`
3. `.issue-agent/` 생성 (이미 있는 파일은 건드리지 않는다)
   - `config` — 레포 이름·기본 브랜치는 `gh` 로 채운다
   - `agent.md` — 이 레포의 작업 규칙: 읽을 문서, 검증 게이트(lint/test 명령), 금지 행동, Jira 설정값 (템플릿의 TODO 를 채운다)
   - `review.md` — 이 레포의 리뷰 기준(공통 기준에 더해지는 것)
4. 상태 라벨 5종 생성. 옛 `am:*` 라벨이 있으면 지우지 않고 이름만 바꾼다(이슈 이력 보존). dry-run 을 먼저 보여 준다.
5. 에이전트별 권한 안내 (claude: 허용 목록 예시, codex: 샌드박스 설정)

**그다음 작업 규칙은 직접 써야 한다.** `agent.md`·`review.md` 템플릿의 TODO 를 채우고 커밋한다.
에이전트는 이 두 파일로 이 레포의 검증 명령·금지 행동·리뷰 기준을 안다. TODO 가 남아 있거나 파일이 없으면 `run` 이 거부한다.

`.issue-agent/config` 는 bash 로 source 하지 않는다 — `GIA_*=값` 줄만 읽는다:
```
GIA_REPO="owner/repo"            # 필수
GIA_AGENT="claude"               # claude | codex
GIA_BASE_BRANCH="main"
GIA_WT_BASE="/abs/path/wt"       # 기본: ~/issue-agent-wt/<레포 디렉터리명>
GIA_BRANCH_PREFIX="fix/issue-"
GIA_MODEL=""                     # 이슈 세션 모델. claude 기본 sonnet, codex 기본은 ~/.codex/config.toml
GIA_EFFORT=""                    # claude 기본 medium, codex 는 model_reasoning_effort
GIA_REVIEW_MODEL=""              # 리뷰 서브에이전트 모델. claude 기본 opus, codex 는 세션과 같은 모델
```

## claude 와 codex

| | claude | codex |
|---|---|---|
| 세션 실행 | `claude --model … --effort … --append-system-prompt <계약>` | `codex -C <worktree> -c developer_instructions=<계약> …` |
| 리뷰어 | Agent 도구 서브에이전트 (`GIA_REVIEW_MODEL`) | `spawn_agent` → `wait_agent` → `close_agent` |
| 사용자에게 묻기 | AskUserQuestion | 선택지를 출력하고 턴을 끝내 기다림 |
| 권한 | 메인 작업공간 `.claude/settings.local.json` 을 worktree 로 복사 | 샌드박스 workspace-write + 승인 on-request, worktree·메인 작업공간 쓰기와 네트워크 허용 |

공통 계약(`prompts/issue_agent.md`)은 같고, 도구마다 다른 부분만 `prompts/agent_<claude|codex>.md` 에 둔다.
Jira 단계는 세션에 Jira 도구(MCP 등)가 있을 때만 돈다. 없으면 건너뛰고 완료 보고에 적는다.

`.issue-agent/agent.md`·`review.md` 안에서 `{ISSUE}` `{REPO}` `{BRANCH}` `{BASE}` `{WORKTREE}` `{WORKDIR}` `{CLI}` `{REVIEW_MODEL}` 을 쓰면 실행 시 치환된다.

## 명령

| 명령 | 하는 일 |
|------|---------|
| `git issue-agent init [--agent claude\|codex]` | 레포에 붙이기 (위 참고) |
| `git issue-agent run <N>` | worktree 준비 → 세션(작업→리뷰→재작업→머지) → 세션이 끝나면 PR 머지 확인 후 정리 |
| `git issue-agent merge <N> [--yes]` | origin/base rebase + force-with-lease push + rebase 머지. worktree 밖에서 부르면 정리까지 |
| `git issue-agent close <N>` | worktree·로컬/원격 브랜치 제거 + 이슈 클로즈 |
| `git issue-agent label <N> <상태>` | 상태 라벨을 하나로 교체(나머지 상태 라벨은 뗌). `none` 은 전부 뗌 |
| `git issue-agent end` | 세션 스스로 종료(세션 내부 전용). `awaiting-user` 면 거부 |
| `git issue-agent poll [초]` | `ready` 이슈 감지 → `in-progress` 로 클레임하고 실행 명령 안내(직접 실행 안 함) |
| `git issue-agent labels [--dry-run]` | 상태 라벨 5종 생성/정렬 |
| `git issue-agent tracker` | 이슈 현황판(이슈 패널 하나). Enter: tmux 안이면 이슈 세션 창 생성/전환, 밖이면 실행 명령 복사 |

어느 디렉터리에서 불러도(이슈 worktree 안 포함) 메인 작업공간과 `.issue-agent/config` 를 찾는다.

## 라벨 = 상태 (이슈에 하나만)

| 라벨 | 뜻 | 누가 바꾸나 |
|------|----|-------------|
| `ready` | 착수 대기 | 사람(이슈 등록 시) |
| `in-progress` | 작업 중 | 세션 |
| `on-review` | 리뷰 서브에이전트 검토 중 (사람 손 불필요) | 세션 |
| `rework` | 리뷰 반려 → 같은 세션이 재작업 중 | 세션 |
| `awaiting-user` | **사람의 답이 필요** — 세션은 살아서 터미널에서 대기 | 세션 |

```
ready → in-progress → on-review ─ APPROVE ─→ (awaiting-user: Jira 질문) → 머지 → 클로즈
              ▲           │
              └─ rework ◀─┘ REQUEST_CHANGES (3회째면 awaiting-user 로 사람에게 물음)
   어느 단계든 사람 판단이 필요하면 awaiting-user → 답 받으면 원래 단계로
```

현황판에는 PR 을 띄우지 않는다. PR 은 머지 수단일 뿐이고, 상태는 이슈 라벨이 전부 말한다.

## 설계 메모

- **리뷰 결과는 이슈 댓글로 남긴다.** `git issue-agent run` 은 이슈 body + 이슈 댓글만 세션에 넣는다. 세션이 중간에 죽어도
  다음 `git issue-agent run` 이 앞 라운드 지적을 읽고 이어받는다. PR 댓글은 다음 세션에 안 보인다.
- **리뷰어는 읽기 전용 + 새 컨텍스트**(fork 아님). 판정(`APPROVE`/`REQUEST_CHANGES`/`NEEDS_USER`)과 근거만 돌려준다.
  고치는 것은 작성자 세션뿐이라 한 worktree 에 쓰는 주체가 둘이 되지 않는다.
- **공식 PR 리뷰 API 를 쓰지 않는다.** 리뷰어와 PR 작성자가 같은 gh 계정이라 GitHub 이 본인 PR 승인/변경요청을 거부한다.
- **정리는 세션 밖에서.** 세션의 cwd 가 worktree 라 세션 안에서 worktree 를 지우면 이후 명령이 깨진다.
  세션은 `git issue-agent merge` 까지만 하고(worktree 안에서 부르면 정리를 미룬다), `git issue-agent end` 로 에이전트가 끝나면
  `git issue-agent run` 이 머지를 확인하고 `git issue-agent close` 한다. 그래서 `git issue-agent end` 는 tmux 창을 죽이지 않고 에이전트 프로세스만 끝낸다.
- **질문 대기 가드.** 질문을 남긴 세션이 스스로 죽으면 사용자가 답할 창을 잃는다. `git issue-agent end` 는 `awaiting-user` 면
  거부하고, 라벨 조회에 실패해도 종료하지 않는다.
- **항상 대화형.** `git issue-agent poll` 은 명령을 안내만 하고 실행하지 않는다. cron 같은 무인 실행 경로를 만들면 답할 사람이 없어
  awaiting-user 에서 조용히 멈춘다 — 그 가드를 먼저 다시 설계할 것.
- bash 3.2(macOS 기본) 호환을 유지한다.

## 구조

```
bin/git-issue-agent    디스패처 (git 하위 명령으로도 동작: git issue-agent)
lib/common.sh          .issue-agent/config 로딩·경로 계산
lib/{init,run,merge,close,label,end,poll,labels,tracker}.sh
prompts/issue_agent.md 공통 세션 계약 (라벨·리뷰 루프·머지·Jira)
prompts/agent_claude.md, agent_codex.md   도구별 방법 (리뷰어 띄우기·사용자에게 묻기)
prompts/reviewer.md    리뷰 서브에이전트 브리프 (공통 기준 + 출력 형식)
templates/             init 이 까는 .issue-agent/agent.md·review.md 템플릿
tracker/               현황판 TUI (Rust, ratatui)
```

세션 시스템 프롬프트 = `prompts/issue_agent.md` + 레포 `.issue-agent/agent.md` + `prompts/agent_<도구>.md` + `prompts/reviewer.md` + 레포 `.issue-agent/review.md`.
