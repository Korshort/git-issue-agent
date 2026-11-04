# git-issue-agent

GitHub Issue를 작업 큐로, git worktree를 격리된 작업 공간으로 삼아 코딩 에이전트(Claude Code, Codex CLI)를 돌리는 도구다. 이슈 현황판(TUI)을 포함한다.

이슈 하나당 worktree 하나와 에이전트 세션 하나를 띄운다. 그 세션 안에서 코드 작성, PR 생성, 서브에이전트를 통한 코드 리뷰, 반려 시 재작업, 머지, 브랜치·worktree 정리까지 끝낸다. 리뷰가 반려되어도 새 세션을 띄우지 않고 원래 세션이 그 자리에서 이어서 고친다. 리뷰 승인이 곧 머지 승인이다.

```
이슈(ready) → git issue-agent run <N> → worktree + 에이전트 세션 생성
  └─ 작업 → PR → 리뷰 서브에이전트 호출
                   ├─ 반려(REQUEST_CHANGES) → 같은 세션에서 재작업 → 재리뷰
                   └─ 승인(APPROVE) → (Jira 키가 있으면 작업시간·특이사항 질문) → 머지 → 종료·정리
```

도구 자체는 한 번만 설치해 두고 여러 레포에서 같이 쓴다. 레포마다 다른 규칙과 설정은 각 레포의 `.issue-agent/` 디렉터리에만 둔다.

## 설치

필요한 도구:
- `git` 2.31 이상
- `gh` (로그인 상태)
- `jq`
- `claude` 또는 `codex` CLI (설치 및 로그인 완료)
- 선택: `cargo` (현황판 TUI인 tracker 빌드용), `tmux`

PATH가 잡힌 곳에 실행 파일 심볼릭 링크를 건다.

```bash
git clone https://github.com/Korshort/git-issue-agent.git ~/git-issue-agent
ln -s ~/git-issue-agent/bin/git-issue-agent ~/.local/bin/git-issue-agent
```

`git-issue-agent`라는 이름으로 PATH에 들어가므로 `git issue-agent ...` 하위 명령으로 부를 수 있다.

## 시작하기

### 1. 레포 초기화

작업할 레포에서 `init`을 실행한다.

```bash
cd <레포>
git issue-agent init                 # 또는 --agent claude|codex, 묻지 않으려면 --yes
```

`init`은 다음 작업을 순서대로 처리한다.
1. 필수 도구가 설치되어 있는지 확인하고 빠진 것만 알려 준다.
2. 사용할 에이전트 CLI(`claude` 또는 `codex`)를 선택받는다.
3. `.issue-agent/` 디렉터리에 설정과 규칙 템플릿(`config`, `agent.md`, `review.md`)을 만든다. 이미 있는 파일은 덮어쓰지 않는다.
4. GitHub 레포에 상태 라벨 5종을 만든다. 변경 내역(dry-run)을 먼저 보여 준다. 예전 `am:*` 라벨이 남아 있으면 이슈 이력이 끊기지 않게 삭제 대신 이름만 바꾼다.
5. 선택한 에이전트에 필요한 권한 설정 방법을 안내한다 (claude는 허용 목록 예시, codex는 샌드박스 설정).

### 2. 작업 규칙 작성 (필수)

`init`이 만든 `.issue-agent/agent.md`와 `.issue-agent/review.md`를 열어 `TODO`로 표시된 부분을 채우고 커밋한다. 에이전트는 이 두 파일을 읽고 레포의 규칙을 파악한다. **파일이 없거나 파일 안에 `TODO`가 남아 있으면 `run`이 실행을 거부한다.**

- `.issue-agent/agent.md` : 에이전트가 읽어야 할 문서, 검증 게이트(lint·test 명령), 금지 행동, Jira 연동 설정값
- `.issue-agent/review.md` : 공통 리뷰 기준에 덧붙일 이 레포만의 코드 리뷰 기준

두 파일 안에서 아래 플레이스홀더를 쓰면 실행 시 실제 값으로 치환된다.
`{ISSUE}` `{REPO}` `{BRANCH}` `{BASE}` `{WORKTREE}` `{WORKDIR}` `{CLI}` `{REVIEW_MODEL}`

### 3. 이슈 처리 실행

처리할 GitHub 이슈 번호를 넘겨 실행한다.

```bash
git issue-agent run 42
```

이슈 42번 전용 worktree가 만들어지고 에이전트 세션이 시작된다.

## 명령어

어느 디렉터리에서 실행하든(이슈 worktree 내부 포함) 알아서 메인 작업 공간과 `.issue-agent/config`를 찾아 동작한다.

| 명령 | 동작 |
|---|---|
| `git issue-agent init [--agent claude\|codex]` | 현재 레포에 `.issue-agent/` 생성 및 상태 라벨 설정 (`--yes`로 확인 생략 가능) |
| `git issue-agent run <N>` | N번 이슈용 worktree 준비 → 에이전트 세션 실행(작업·리뷰·재작업·머지) → 세션 종료 후 PR 머지가 확인되면 worktree와 브랜치 정리 |
| `git issue-agent merge <N> [--yes]` | `origin/<base>` 기준으로 rebase → `force-with-lease` push → PR rebase 머지. worktree 밖에서 호출하면 정리(`close`)까지 수행 |
| `git issue-agent close <N>` | worktree와 로컬·원격 브랜치를 지우고 이슈를 닫음 |
| `git issue-agent label <N> <상태>` | 이슈의 상태 라벨을 지정한 하나로 교체(기존 상태 라벨은 제거). `<상태>`에 `none`을 주면 상태 라벨을 모두 뗌 |
| `git issue-agent end` | 에이전트가 자기 세션을 끝낼 때 부르는 내부 전용 명령. 이슈가 `awaiting-user` 상태면 종료를 거부함 |
| `git issue-agent poll [초]` | `ready` 라벨이 붙은 이슈를 감지해 `in-progress`로 바꾸고 실행 명령을 화면에 출력함 (직접 실행하지는 않음) |
| `git issue-agent labels [--dry-run]` | 상태 라벨 5종을 생성하거나 정비함 |
| `git issue-agent tracker` | 이슈 현황판 TUI 실행. 이슈에서 Enter를 누르면 tmux 안에서는 해당 이슈 세션 창을 열거나 전환하고, tmux 밖에서는 실행 명령을 클립보드에 복사함 |

## 이슈 상태와 라벨 흐름

이슈 하나에는 아래 5가지 상태 라벨 중 하나만 붙는다. 현황판(tracker)에도 PR 목록은 따로 띄우지 않는다. PR은 머지 수단일 뿐이고 진행 상태는 전부 이슈 라벨로 표시한다.

| 라벨 | 의미 | 변경 주체 |
|---|---|---|
| `ready` | 착수 대기 | 사람 (이슈 등록 시) |
| `in-progress` | 에이전트가 작업 중 | 세션 |
| `on-review` | 리뷰 서브에이전트가 검토 중 (사람 개입 불필요) | 세션 |
| `rework` | 리뷰 반려 후 같은 세션이 수정 중 | 세션 |
| `awaiting-user` | 사람의 응답 대기 중 (세션은 터미널에 살아 있음) | 세션 |

```
ready → in-progress → on-review ── APPROVE ──→ (awaiting-user: Jira 질문) → 머지 → 클로즈
              ▲           │
              └─ rework ◀─┘ REQUEST_CHANGES (3회 누적 시 awaiting-user로 전환해 사람에게 질문)
```

진행 중 어느 단계에서든 사람의 판단이 필요하거나 리뷰가 `NEEDS_USER` 판정을 내리면 `awaiting-user`로 바뀐다. 사용자가 터미널에서 답을 주면 원래 단계로 돌아가 이어서 진행한다.

Jira 기록 단계는 세션에 Jira 도구(MCP 등)가 연결되어 있을 때만 동작한다. 도구가 없으면 건너뛰고 완료 보고에 그 사실을 적는다.

## 설정 (`.issue-agent/config`)

`init`을 실행하면 레포 이름과 기본 브랜치를 `gh`에서 읽어와 `.issue-agent/config`를 만든다. 이 파일은 bash로 `source` 하지 않고 `GIA_*=값` 형태의 줄만 파싱해서 읽는다.

```ini
GIA_REPO="owner/repo"            # 필수
GIA_AGENT="claude"               # claude | codex
GIA_BASE_BRANCH="main"
GIA_WT_BASE="/abs/path/wt"       # 기본값: ~/issue-agent-wt/<레포 디렉터리명>
GIA_BRANCH_PREFIX="fix/issue-"
GIA_MODEL=""                     # 이슈 세션 모델. claude 기본값은 sonnet, codex는 ~/.codex/config.toml 따름
GIA_EFFORT=""                    # claude 기본값은 medium, codex는 model_reasoning_effort로 전달
GIA_REVIEW_MODEL=""              # 리뷰 서브에이전트 모델. claude 기본값은 opus, codex는 메인 세션과 같은 모델
```

## claude와 codex 동작 차이

공통 작업 계약(`prompts/issue_agent.md`)은 두 도구가 같고, 도구마다 다른 호출 방식만 `prompts/agent_claude.md`와 `prompts/agent_codex.md`로 분리되어 있다.

| 구분 | claude | codex |
|---|---|---|
| 세션 실행 | `claude --model … --effort … --append-system-prompt <계약>` | `codex -C <worktree> -c developer_instructions=<계약> …` |
| 리뷰 서브에이전트 | Agent 도구 호출 (`GIA_REVIEW_MODEL` 사용) | `spawn_agent` → `wait_agent` → `close_agent` |
| 사용자에게 질문 | `AskUserQuestion` 도구 | 선택지를 출력하고 턴을 종료해 입력 대기 |
| 권한 설정 | 메인 작업 공간의 `.claude/settings.local.json`을 worktree로 복사 | 샌드박스 `workspace-write` + 승인 `on-request`, worktree·메인 작업 공간 쓰기 및 네트워크 허용 |

세션에 주입되는 전체 시스템 프롬프트는 다음 순서로 합쳐진다.
`prompts/issue_agent.md` + 레포의 `.issue-agent/agent.md` + `prompts/agent_<도구>.md` + `prompts/reviewer.md` + 레포의 `.issue-agent/review.md`

## 동작 원리와 제약 사항

이 도구를 쓰거나 고칠 때 알아두어야 할 내부 동작 방식이다.

### 리뷰 기록은 PR이 아니라 이슈 댓글에 남긴다
`git issue-agent run`이 세션을 띄울 때 프롬프트에 넣어 주는 맥락은 이슈 본문과 이슈 댓글뿐이다. PR 댓글은 넣지 않는다. 또한 작업자와 리뷰어가 같은 GitHub 계정을 쓰기 때문에 GitHub의 공식 PR Review API(Approve / Request changes)는 본인 PR에 사용할 수 없어 호출하지 않는다. 리뷰 서브에이전트의 판정(`APPROVE`, `REQUEST_CHANGES`, `NEEDS_USER`)과 근거를 이슈 댓글로 남겨야, 세션이 중간에 죽더라도 다음 `run` 세션이 이전 리뷰 내용을 읽고 이어서 작업할 수 있다.

### 리뷰 서브에이전트는 읽기 전용이다
리뷰어는 기존 대화를 포크하지 않고 새 컨텍스트에서 읽기 전용으로 뜬다. 판정과 근거만 본 세션에 돌려주고, 코드 수정은 무조건 본 세션만 한다. 한 worktree에 두 주체가 동시에 파일을 쓰지 않게 하기 위해서다.

### worktree 정리는 세션 밖에서 한다
에이전트 세션의 현재 디렉터리(cwd)가 곧 worktree다. 세션 안에서 자기 발밑의 worktree를 지우면 이후 셸 명령이 전부 깨진다. 그래서 세션 안에서는 `git issue-agent merge`까지만 부르고(worktree 안에서 부르면 정리를 미룬다), `git issue-agent end`로 에이전트 프로세스만 끝낸다(tmux 창 자체는 닫지 않는다). 그러면 바깥에서 대기하던 `git issue-agent run`이 머지 여부를 확인한 뒤 `git issue-agent close`를 불러 정리한다.

### 무인 실행(cron 등)으로 돌리지 않는다
에이전트는 막히거나 질문이 있으면 `awaiting-user` 라벨을 붙이고 터미널에서 사람 답을 기다린다. 이때 세션이 혼자 종료해 버리면 사용자가 답을 입력할 터미널 창이 사라진다. 이를 막기 위해 `git issue-agent end`는 현재 라벨이 `awaiting-user`이거나 라벨 조회 자체가 실패하면 종료를 거부한다. 같은 이유로 `git issue-agent poll`도 새 이슈를 감지하면 실행 명령만 안내할 뿐 세션을 자동으로 띄우지 않는다. 무인 실행 경로를 만들면 답할 사람이 없어 `awaiting-user`에서 영구 대기하게 되므로, 그 전에 질문 대기 구조부터 다르게 설계해야 한다.

### 셸 호환성
macOS 기본 bash인 bash 3.2 호환을 유지한다.

## 디렉터리 구조

```
bin/git-issue-agent              진입점 디스패처 (git issue-agent 하위 명령으로 동작)
lib/common.sh                    .issue-agent/config 파싱 및 경로 계산
lib/{init,run,merge,close,label,end,poll,labels,tracker}.sh
                                 각 하위 명령 구현
prompts/issue_agent.md           공통 세션 계약 (라벨 전이, 리뷰 루프, 머지, Jira)
prompts/agent_claude.md          claude 전용 지침 (서브에이전트 호출, 질문 방식)
prompts/agent_codex.md           codex 전용 지침
prompts/reviewer.md              리뷰 서브에이전트 브리프 (공통 기준 및 출력 형식)
templates/                       init이 복사해 넣는 agent.md, review.md 템플릿
tracker/                         이슈 현황판 TUI (Rust, ratatui)
```
