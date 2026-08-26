# go-dobby 훅 가이드 — 최적화 원칙과 작성 규칙

이 폴더(`hooks/`)는 go-dobby 스킬 문서의 ⛔ 규칙 중 **코드로 강제 가능한 것**을 훅으로 구현한다.
스킬 프롬프트는 어겨질 수 있지만 훅은 하네스가 실행하므로 우회가 안 된다 — **마지막 방어선**이다.
새 훅을 추가할 때는 반드시 이 문서의 원칙을 따른다.

## 왜 이렇게 만들었나 (조사한 최적화 프랙티스 → 우리 적용)

훅은 도구 호출마다 동기로 실행돼 **훅 실행 시간이 그대로 대화 지연**이 된다.
셸 프로세스 fork(~50–150ms)가 로직보다 무거우므로, 핵심은 "**안 뜰 프로세스는 아예 안 띄우고,
뜬 프로세스는 한 번에 여러 검사를 처리**"하는 것이다.

### 1. `if` 필드 — 가장 효과 큰 최적화 (프로세스 스폰 자체를 건너뜀)

```json
{ "matcher": "Bash", "if": "Bash(*git *)|Bash(*rm *)", "command": "..." }
```

- `matcher`는 도구 이름만 거르지만, `if`는 **도구 입력(명령 문자열)까지** 하네스 레벨에서 거른다.
- `if` 불일치면 **셸이 fork되지 않는다** → 관심 없는 호출의 비용이 사실상 0.
- 스크립트 안의 조기 종료(early exit)보다 한 단계 앞에서 컷하는 것이므로, **`if`를 먼저 설계**하고
  스크립트 조기 종료는 이중 방어로 둔다.
- 패턴은 glob이다. 복합 명령(`cd x && git push`)을 잡으려면 `Bash(git *)`가 아니라 `Bash(*git *)`처럼
  **앞에 `*`를 붙인다**.

### 2. 디스패처 패턴 — matcher 그룹당 스크립트 1개

- 같은 matcher에 훅 N개를 등록하면 이벤트마다 셸이 N번 fork된다. **1개로 합치고 스크립트 안에서
  case 분기**한다(이 폴더의 `pre-bash.sh`가 G1·G5·G6을 한 번에 처리하는 이유).
- 부가 이점: 검사 순서가 결정적이고, `updatedInput` 경쟁(여러 훅이 입력을 동시 수정)이 없다.

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

## 현재 구현된 규칙

| ID | 규칙 | 이벤트 | 처리 | 근거 스킬 |
|----|------|--------|------|-----------|
| G1 | 정식 배포 베이스(master)로 push·merge·PR 금지 | PreToolUse·Bash | deny | dobby-order C1 |
| G5 | subtree 밖 워크트리 제거·rm 금지 | PreToolUse·Bash | deny | dobby-end 안전 경계 |
| G6 | 메타 폴더($ORCHESTRATION_META) 삭제 금지 | PreToolUse·Bash | deny | 비파괴 원칙 |

## 로드맵 (다음 단계 후보 — 분석 완료, 미구현)

- **2단계 (pre-bash 확장)**: G2 커밋 메시지 규칙(내부 용어·금지 서명·접두어), G3 워크트리 커밋
  `--no-verify` 자동 삽입(updatedInput), G4 docs 게이트(worktree add 시 docs-refs.md 확인),
  G7 미푸시 커밋 있는 워크트리 제거 차단, G8 브랜치 삭제 escalate, G9 config.env 리다이렉트 차단.
- **2단계 (post-meta-lint 신설, async)**: 상태표 5상태 값·이벤트 로그 형식·카드 `## ` 헤더·
  side-effects "미검증" 문구·리뷰 카드 헤더·해결 근거 placeholder·mermaid 라벨 인용·
  아티팩트 외부 호스트·jira-enrich 내부 용어 누출·`## 세션` 섹션.
- **3단계 (스킬 frontmatter 훅)**: 백그라운드 잡 쓰기 범위(avatar-quips는 `.mentis-quips/`만,
  explain/retro/share/jira-tab은 자기 산출 파일만) + dobby-init의 config.env 쓰기 허용 예외.
