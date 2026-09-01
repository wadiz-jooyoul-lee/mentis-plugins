# go-dobby 훅 가이드 — 최적화 원칙과 작성 규칙

이 폴더(`hooks/`)는 go-dobby 스킬 문서의 ⛔ 규칙 중 **코드로 강제 가능한 것**을 훅으로 구현한다.
스킬 프롬프트는 어겨질 수 있지만 훅은 하네스가 실행하므로 우회가 안 된다 — **마지막 방어선**이다.
새 훅을 추가할 때는 반드시 이 문서의 원칙을 따른다.

## ⚠️ 전달 경로 — 플러그인 훅 버그 우회 (2026-08 기준, 반드시 읽기)

**플러그인 hooks.json의 PreToolUse/PostToolUse *command* 훅은 Claude Code가 로딩 시 조용히
드랍한다** — [anthropics/claude-code#34573](https://github.com/anthropics/claude-code/issues/34573)
(closed as not planned). prompt 훅과 라이프사이클(SessionStart·Stop 등) command 훅은 정상 발화한다.
v2.1.246에서 실측 확인: 설치본 스크립트를 수동 실행하면 deny JSON이 정확히 나오지만,
실제 세션의 Bash 호출에는 훅이 아예 스폰되지 않았다.

그래서 현재 전달 경로는 다음과 같다:

- **pre-bash.sh(G1·G5·G6)는 `dobby-init`이 배포한다**: `~/.config/go-dobby/hooks/`로 복사 후
  사용자 `~/.claude/settings.json`의 `hooks.PreToolUse`에 등록(dobby-init SKILL.md "안전 훅 등록").
  settings.json 훅은 정상 발화한다.
- **이 폴더의 hooks.json PreToolUse 항목은 일부러 남겨 둔다**(현재는 드랍되어 무해).
  버그가 고쳐지면 그대로 살아나므로, 그때 settings.json 등록·복사본만 제거하면 원복 완료다
  (둘 다 살아 있으면 같은 검사가 두 번 돌 뿐 오동작은 없지만, 중복 스폰 비용이 있으니 제거한다).
- **session-start.sh(SessionStart, 플러그인에서 정상 발화)** 가 세션 시작마다 "config.env는 있는데
  settings.json 미등록" 또는 "복사본이 플러그인 최신본과 다름"을 감지해 `/dobby-init` 실행을
  안내한다. 이미 설치한 사용자도 플러그인 업데이트만 받으면 다음 세션에 자동으로 알게 된다.
- **훅 스크립트를 수정하면**: 플러그인 버전 배포 → 사용자 세션에서 session-start.sh가 버전 차이를
  감지 → `/dobby-init` 재실행으로 복사본 갱신. (자동 갱신이 아니라는 점을 기억하라.)

## 왜 이렇게 만들었나 (조사한 최적화 프랙티스 → 우리 적용)

훅은 도구 호출마다 동기로 실행돼 **훅 실행 시간이 그대로 대화 지연**이 된다.
셸 프로세스 fork(~50–150ms)가 로직보다 무거우므로, 핵심은 "**안 뜰 프로세스는 아예 안 띄우고,
뜬 프로세스는 한 번에 여러 검사를 처리**"하는 것이다.

### 1. `if` 필드 — 가장 효과 큰 최적화 (프로세스 스폰 자체를 건너뜀)

```json
{ "matcher": "Bash", "hooks": [
  { "type": "command", "if": "Bash(git *)", "command": "bash", "args": ["...pre-bash.sh"] },
  { "type": "command", "if": "Bash(rm *)",  "command": "bash", "args": ["...pre-bash.sh"] }
] }
```

- `matcher`는 도구 이름만 거르지만, `if`는 **도구 입력(명령 문자열)까지** 하네스 레벨에서 거른다.
- `if` 불일치면 **셸이 fork되지 않는다** → 관심 없는 호출의 비용이 사실상 0.
- 스크립트 안의 조기 종료(early exit)보다 한 단계 앞에서 컷하는 것이므로, **`if`를 먼저 설계**하고
  스크립트 조기 종료는 이중 방어로 둔다.
- ⚠️ **`if` 문법은 실측으로 확정된 것만 쓴다** (2026-08-26, v2.1.246에서 검증 — 아래 셋을 어기면
  `if`가 영원히 불일치해 **훅이 조용히 아예 안 돈다**. v0.2.16~17이 이 함정으로 불발이었다):
  1. **한 `if`에 권한 규칙 하나만.** `Bash(git *)|Bash(rm *)`처럼 `|`로 잇는 알터네이션은 매칭되지
     않는다. 규칙이 여러 개면 **같은 스크립트를 부르는 훅 항목을 규칙 수만큼 나열**한다(위 예시).
  2. **선행 와일드카드 불가.** `Bash(*git *)`는 아무것도 매칭하지 않는다. 표준 접두사형
     `Bash(git *)`만 쓴다.
  3. **복합 명령은 걱정할 필요 없다.** `true && rm ...`, `cd x && git push` 같은 복합 명령은
     하네스가 권한 규칙처럼 **조각으로 분해해 각 조각을 매칭**하므로 접두사형으로 잡힌다(실측).

### 2. 디스패처 패턴 — 스크립트는 1개, `if` 항목은 규칙별로

- 로직은 **스크립트 1개**에 모으고 안에서 case 분기한다(이 폴더의 `pre-bash.sh`가 G1·G5·G6을
  한 번에 처리하는 이유). 검사 순서가 결정적이고, `updatedInput` 경쟁(여러 훅이 입력을 동시
  수정)이 없다.
- 등록은 `if` 제약(규칙 1개/항목) 때문에 **같은 스크립트를 가리키는 항목 여러 개**가 된다.
  각 항목이 `if`로 게이트되므로 관심 없는 명령엔 fork가 없고, 한 명령이 여러 `if`에 걸리면
  같은 검사가 중복 실행될 뿐 결과는 같다(무해).
- `if` 없이 항목 1개로 모든 Bash 호출에 fork를 감수하는 선택지도 있다(스크립트가 빨리 조기
  종료하므로 ~50–150ms). 규칙이 많아져 항목 나열이 지저분해지면 고려한다.

### 3. PostToolUse 검증은 `async: true` + `asyncRewake: true`

- 형식 검증(상태표 값·이벤트 로그 형식 등)은 차단이 불가능하다(이미 실행됨). 이런 훅은
  **백그라운드(async)로 돌리고, 위반(exit 2)일 때만 asyncRewake로 Claude를 깨워** stderr를 전달한다.
- 통과하는 대부분의 경우 **체감 지연 0**. 위반 시에만 다음 턴에 교정 지시가 도착한다.

### 4. 차단 대신 교정 — `updatedInput`

- PreToolUse는 도구 입력을 **고쳐서 통과**시킬 수 있다. "차단 → LLM 재시도" 왕복(수 초 + 토큰)이
  사라지므로, 기계적으로 고칠 수 있는 위반(예: 워크트리 커밋에 `--no-verify` 자동 삽입)은
  deny 대신 updatedInput을 쓴다.

### 5. exec 형식 — `command` + `args` 배열

```json
{ "command": "bash", "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash.sh"] }
```

- `args`가 있으면 셸을 거치지 않고 직접 spawn된다(셸 프로필 로딩·특수문자 해석 없음).
- 훅 경로는 **호출 시점의 cwd 기준으로 해석**되므로 상대 경로를 쓰지 말고
  `${CLAUDE_PLUGIN_ROOT}` 치환을 쓴다(cwd가 깨진 세션에서도 안전).

### 6. timeout은 짧게

- 기본 600초는 훅이 걸리면 세션이 그만큼 인질로 잡힌다는 뜻. PreToolUse 검사는 **5초**,
  PostToolUse lint는 10초 수준으로 명시한다.

### 7. matcher 함정 (실제 회귀 이력 있음)

- `Edit.*` 같은 언앵커드 정규식은 `NotebookEdit`도 매칭한다. 정확 문자열(`Edit|Write`)을 쓰고,
  정규식이 필요하면 `^Edit$`처럼 앵커한다.
- **settings/hooks.json에 스키마 오류가 하나라도 있으면 그 파일의 훅 전체가 조용히 꺼진다.**
  수정 후 반드시 `jq . hooks.json`으로 파싱 확인 + `/hooks` 메뉴로 등록 확인.
- MCP 도구 matcher는 `mcp__server` 정확 문자열로는 아무것도 안 잡힌다 — `mcp__server__.*`로 쓴다.

## 스크립트 공통 규율 (pre-bash.sh가 기준 구현)

1. **stdin JSON은 jq로 1회만 파싱**해 변수에 캐싱한다(`command`·`cwd` 등). jq가 없으면 exit 0.
2. **config.env 없으면 무조건 통과**(exit 0) — go-dobby를 안 쓰는 환경·프로젝트에 개입하지 않는다.
3. **dobby 스코프 가드**: 전역 성격이 아닌 규칙(G1 등)은 cwd/명령이
   `$ORCHESTRATION_WORKSPACE`·`$ORCHESTRATION_REPOS_ROOT`를 가리킬 때만 적용한다.
4. **차단은 JSON으로**: `permissionDecision: "deny"` + 사유에 **규칙 ID([G1] 등)와 대안**을 함께 적는다.
   LLM이 사유를 읽고 스스로 교정할 수 있어야 한다(막기만 하면 같은 시도를 반복한다).
5. **dobby-lib.sh를 source하지 않는다**(스폰 비용·부작용 방지). 필요한 값 계산은 인라인으로.
   단, 규칙 정규식이 lib과 겹치면(커밋 메시지 규칙 등) 한쪽에 정의하고 다른 쪽이 참조하게 한다.
6. 확신이 없으면 **차단하지 말고 통과**시킨다(오탐으로 정상 작업을 막는 비용 > 미탐 비용 —
   훅은 방어선이지 유일한 수단이 아니다).

## 새 훅 추가 절차

1. 대상 규칙이 **판단 없이 감지 가능한지** 확인한다(문자열/파일 존재/정규식). 판단이 필요하면
   훅이 아니라 스킬 문서 몫이다.
2. 이벤트 선택: 실행 전에 막아야 하면 PreToolUse(+deny/updatedInput), 사후 검증이면
   PostToolUse(+async+asyncRewake).
3. **기존 디스패처에 case를 추가**한다(새 스크립트·새 등록을 늘리지 않는 게 기본).
   새 matcher가 필요할 때만 hooks.json에 항목을 추가하고 `if`를 함께 설계한다.
4. 로컬 테스트: 샘플 stdin JSON으로 직접 실행해 deny/통과를 확인한다.
   ```bash
   echo '{"cwd":"/path","tool_input":{"command":"git push origin master"}}' \
     | bash hooks/pre-bash.sh
   ```
5. `jq . hooks/hooks.json`으로 스키마 확인 → 플러그인 **버전 patch +1**(CLAUDE.md 버전 규칙 —
   plugin.json과 marketplace.json 두 곳) → 커밋.
6. 배포 후 `/hooks` 메뉴에서 등록 확인, `claude --debug-file`로 발화 확인.
7. **PreToolUse/PostToolUse command 훅이면**: 위 "전달 경로" 섹션대로 플러그인 등록만으로는
   발화하지 않는다(#34573). dobby-init의 "안전 훅 등록" 단계가 새 스크립트를 함께 복사·등록하도록
   갱신하고, 사용자에게 `/dobby-init` 재실행이 필요함을 릴리스 노트에 적는다.

## 현재 구현된 규칙

| ID | 규칙 | 이벤트 | 처리 | 전달 경로 | 근거 스킬 |
|----|------|--------|------|-----------|-----------|
| G1 | 정식 배포 베이스(master)로 push·merge·PR 금지 | PreToolUse·Bash | deny | settings.json(dobby-init 등록 — #34573 우회) | dobby-order C1 |
| G5 | subtree 밖 워크트리 제거·rm 금지 | PreToolUse·Bash | deny | settings.json(상동) | dobby-end 안전 경계 |
| G6 | 메타 폴더($ORCHESTRATION_META) 삭제 금지 | PreToolUse·Bash | deny | settings.json(상동) | 비파괴 원칙 |
| G10 | 스폰 시 상태표 자동 등록 + 로그 자동 기록 (유령 에이전트 차단) | PreToolUse·PostToolUse·Agent\|Task | 자동등록/자동기록(형식 없으면 deny) | settings.json(dobby-init 등록) | dobby-order C4 |
| G11 | 설계 문서(design.md) 없이 구현 스폰 금지 — 단계가 구현 이후 + 종류 개발 + 역할 개발자일 때만 | PreToolUse·Agent\|Task | deny | settings.json(상동 — pre-agent.sh에 포함) | dobby-order P3.5 |
| G13 | 설계 문서 없이 에이전트 '구현' 전이 금지(개발 오더·개발자 역할) | dobby_agent_state 헬퍼 | 거부(비0 반환) | 코드 강제(훅 아님) | dobby-order P3.5 |
| G12 | design.md 셸 덮어쓰기 금지(파일이 이미 있을 때 cat>·tee·sed -i·perl -i — 사용자 수정본 보호. append(>>)·최초 생성은 통과, DOBBY_FORCE=1 우회) | PreToolUse·Bash | deny | settings.json(if: cat/tee/sed/perl/python3 — dobby-init 등록) | dobby-design 비파괴 |
| — | 안전 훅 미등록·구버전 감지 안내 | SessionStart | 안내 출력 | 플러그인 hooks.json(라이프사이클 훅은 정상 발화) | dobby-init |

## 로드맵 (다음 단계 후보 — 분석 완료, 미구현)

- **2단계 (pre-bash 확장)**: G2 커밋 메시지 규칙(내부 용어·금지 서명·접두어), G3 워크트리 커밋
  `--no-verify` 자동 삽입(updatedInput), G4 docs 게이트(worktree add 시 docs-refs.md 확인),
  G7 미푸시 커밋 있는 워크트리 제거 차단, G8 브랜치 삭제 escalate, G9 config.env 리다이렉트 차단.
- **2단계 (post-meta-lint 신설, async)**: 상태표 5상태 값·이벤트 로그 형식·카드 `## ` 헤더·
  side-effects "미검증" 문구·리뷰 카드 헤더·해결 근거 placeholder·mermaid 라벨 인용·
  아티팩트 외부 호스트·jira-enrich 내부 용어 누출·`## 세션` 섹션.
- **3단계 (스킬 frontmatter 훅)**: 백그라운드 잡 쓰기 범위(avatar-quips는 `.mentis-quips/`만,
  explain/retro/share/jira-tab은 자기 산출 파일만) + dobby-init의 config.env 쓰기 허용 예외.

## 스폰 훅(G10) — 검증 기록 (2026-08-28)

실제 `Agent` 스폰에 탐침 훅을 걸어 확인한 사실이다(추측 아님).

- **PreToolUse·PostToolUse 둘 다 발화한다**(`matcher: Agent|Task`, 도구 이름은 `Agent`).
- PreToolUse 입력: `tool_input.description`·`prompt`·`subagent_type` + `session_id`·`cwd`·`transcript_path`.
- **PostToolUse `tool_response.outputFile`에 서브 전사 경로가 들어온다** → 손으로 `dobby_log`를 칠 필요가 없다.
  단 그 값은 `/tmp/claude-*/…/tasks/*.output` **심볼릭 링크**이므로 실체(`~/.claude/projects/…`)로 바꿔 기록한다.

### 개입 범위(중요)
오더 세션에서만 동작한다 — `session_id`로 `$ORCHESTRATION_META/*/status.md`를 역추적해 **정확히 1개** 오더가
걸릴 때만 개입하고, 그 외(일반 Agent 사용·여러 오더 매칭)는 조용히 통과한다. 오더 진행 중이라도
`description`이 `[skip-dobby]`로 시작하면 건너뛴다.

### 형식
```
description = "{슬러그}: {한 줄 설명}"        예) impl-fe: 관심사 태그 제거
              "{슬러그}#{라운드}: {설명}"      예) review-fe#6: 6라운드 리뷰
```
`impl-fe-r6`처럼 라운드를 슬러그에 붙이면 거절한다(유령 에이전트의 원점 — 사례 FE1-1301).

## 설계 훅(G11·G12) — 검증 기록 (2026-09-01)

스크립트에 실제 stdin JSON을 주입해 확인한 사실이다(추측 아님).

- **G11**(pre-agent.sh): ①구현단계·개발·설계없음·개발자 재스폰 → deny ②설계있음 → 통과 ③분석단계(P1) → 통과
  ④리뷰어 → 통과 ⑤산출물 오더 → 통과 ⑥통합단계(P8 재개)·설계없음 → deny. **6/6 설계대로.**
  - ⚠️ 배치 주의: G11 검사는 **"이미 등록됨" exit보다 앞**에 있어야 한다 — P4 재스폰은 슬러그가 P1에서
    이미 등록돼 있어, 등록 검사 뒤에 두면 영원히 발화하지 않는다(초기 구현에서 실제로 겪은 순서 버그).
- **G12**(pre-bash.sh): ①존재하는 design.md에 cat> → deny ②append(>>) → 통과 ③파일 없음(최초 생성) → 통과
  ④sed -i → deny ⑤DOBBY_FORCE=1 → 통과 ⑥상대경로 덮어쓰기 → deny ⑦무관한 파일 → 통과. **7/7 설계대로.**
  - G12는 settings.json에 `Bash(cat *)`·`Bash(tee *)`·`Bash(sed *)`·`Bash(perl *)`·`Bash(python3 *)`
    if 규칙이 있어야 발화한다(기존 git/gh pr/rm/rmdir 4개에는 안 걸림). dobby-init 재실행으로 등록.

## G13 — 스폰 훅(G11)의 사각지대를 메운 헬퍼 게이트 (2026-09-01)

G11은 `PreToolUse`·`Agent|Task`, 즉 **새 스폰**만 잡는다. 그런데 go-dobby의 **기본 경로**는
분석 에이전트가 그대로 구현으로 이어가는 것이라(dobby-order C9 — `SendMessage`로 계약 전달)
Agent 도구 호출이 없고, 훅이 발화할 기회 자체가 없다.

**사례 FE1-1732**: `agent-logs.json`에 `image-pipeline`이 1회만 기록(스폰 1회). 13:35 스폰
시점 단계는 `분석`이라 G11이 정상 통과했고, 13:58 `image-pipeline → 구현`은 SendMessage라
훅 밖이었다. 결과적으로 design.md·outcome.md 없이 구현·리뷰 2라운드·통합까지 완주했다.

그래서 **상태를 '구현'으로 바꾸는 길목**(`dobby_agent_state`)에 게이트를 뒀다. 스폰이든
이어가기든 이 함수는 반드시 지난다. 파일을 고치기 **전에** 검사해, 거부되면 상태표도 그대로다.

- 제외: 비개발 오더(종류 산출물·작업정리), 역할 리뷰어·산출자
  (`산출`은 `dobby_norm_state`가 `구현`으로 접으므로 역할 확인이 필요하다)
- 우회: `DOBBY_FORCE=1`

### 검증 기록 (임시 META 픽스처 + FE1-1732 실제 파일 재현)
개발·개발자·설계없음 → 차단 / 설계있음 → 통과 / 리뷰어 → 통과 / 산출물 오더 → 통과 /
`개발자·FE` 표기 → 차단 / `DOBBY_FORCE=1` → 통과 / `분석`·`완료` 전이 → 영향 없음. **7/7**
FE1-1732 실제 status·orchestration으로 사고 시점 재현: 종료코드 1, 상태표 `분석` 유지(미변경).
design.md 생성 후 재실행: 종료코드 0, `구현`으로 정상 갱신.
