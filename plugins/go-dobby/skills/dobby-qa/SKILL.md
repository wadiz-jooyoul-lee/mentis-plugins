---
name: dobby-qa
description: 개발(dobby-order)이 통합된 뒤 진입하는 QA 감시·수정 루프 스킬. 5분 주기로 Jira를 폴링해 "최근 나에게 할당된 버그 이슈"를 찾아, 이 오케스트레이션에서 처리해야 하는 버그인지 세 기준(①부모 QA/루트키의 버그 하위이슈 ②사용자 명시 ③내용 판단→슬랙 문의)으로 트리아지한다. 편입된 버그는 그 기능을 구현한 담당 에이전트(계약 화이트리스트로 식별)가 dobby-impl로 고치고, 담당 리뷰 에이전트가 리뷰하는 dobby-order P8 재개 흐름으로 처리한다. 로컬 세션 루프(모드 A)로 동작하며 로컬 PC/세션이 떠 있어야 수정까지 완주한다. 사용법 /dobby-qa {루트키} [parent=QA키] [bugs=키,키] [interval=5m], 중단 /dobby-qa stop {루트키}.
---

# dobby-qa

개발이 상위 브랜치로 통합(dobby-order P7)된 뒤, **머지·정리(dobby-end) 전후로** 진입하는 **QA 감시 모드**. Jira를 주기적으로 폴링해 이 오케스트레이션에 속하는 버그 이슈를 잡아, **원래 그 기능을 구현한 에이전트가 고치고 담당 리뷰어가 리뷰**하도록 라우팅한다. 라우팅·수정·리뷰·재통합 절차는 dobby-order **P8(후속 작업 재개)** 규칙을 그대로 따른다 — dobby-qa는 그 P8을 **Jira 폴링으로 자동 트리거**하는 스킬이다.

```
dobby-order (개발·통합)  →  ★dobby-qa (QA 감시·수정 루프)★  →  dobby-test → dobby-resolve → dobby-end
```

> **동작 전제(중요)**: 감지(Jira 폴링)·문의(Slack)는 원격 MCP만 있으면 되지만, **실제 수정(워크트리·git·dobby-impl)과 검증(chrome-devtools)은 로컬 PC/세션이 떠 있어야** 한다. 그래서 이 스킬은 **로컬 세션 루프(모드 A)**로 동작한다 — 세션을 닫으면 폴링·수정이 함께 멈춘다.

## 설정 (첫 실행 시 확인)

작업을 시작하기 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 **읽기만** 한다. ⛔ **이 스킬은 config.env를 저장·수정·생성하지 않는다**(값 변경은 `dobby-init` 전용 — config.md '비파괴 원칙'). config.env 파일이 아예 없으면 멈추고 `/dobby-init`을 먼저 실행하도록 안내한다. 메타 루트 `ORCHESTRATION_META`, 폴더 배치(워크트리 `$ORCHESTRATION_WORKSPACE/subtree/` · 메타 `$ORCHESTRATION_META/`), `$JIRA_BASE_URL`은 그 문서에 있다. 이하 메타 경로는 `$ORCHESTRATION_META` 기준.

## 원칙 (필수 — 시작 전 숙지)

- 분석·수정 에이전트를 스폰할 때 프롬프트 상단에 **`${CLAUDE_PLUGIN_ROOT}/reference/analysis-discipline.md` 원칙 1·2·3**(이중경로면 1·4)을 넣고, 그 뒤에 **`${CLAUDE_PLUGIN_ROOT}/reference/role-personas.md`의 역할 블록**(수정=「구현 에이전트」, 리뷰=「리뷰 에이전트」)을 삽입한다.
- **사실 기반·추측 금지**: 버그가 이 오케스트레이션 소관인지, 어느 에이전트 담당인지는 **계약 화이트리스트·코드로 확인한 사실**로만 판단한다. 애매하면 자동 편입하지 말고 슬랙으로 문의한다(기준 ③).

## 사전 조건

- `$ORCHESTRATION_META/{루트키}/` 가 존재해야 한다(`orchestration.md` · `agents/{슬러그}.md` 계약 · `review-agent.md`). 없으면 "먼저 dobby-order로 개발·통합하라"고 알리고 중단한다.
- 담당 에이전트 **브랜치**가 살아 있어야 수정 가능하다. 워크트리가 정리됐어도 브랜치는 dobby-end가 보존하므로, 아래 "Q4. 워크트리 확보"에서 재생성한다.

## 입력 / 중단

```
/dobby-qa {루트키} [parent=QA부모키] [bugs=키,키] [interval=5m]
/dobby-qa stop {루트키}     # 감시 종료
```

- `{루트키}`: QA를 붙일 오케스트레이션(방금 개발·통합한 이슈/에픽).
- `parent=`: 기준 ①의 부모 QA 이슈. 그 하위 버그를 후보로 본다.
- `bugs=`: 기준 ②로 "같은 컨텍스트에서 처리"할 버그 키를 사용자가 명시.
- `interval=`: 폴링 주기(기본 `5m`). 초로 환산해 다음 폴을 예약한다.

## 절차 (Phase — 매 폴링 틱마다 반복)

전이는 객관적 조건으로 자율 진행한다. 각 틱은 **Q1 폴링 → Q2 트리아지 → Q3 슬랙 응답 확인 → Q4~Q6 편입 버그 처리 → Q7 다음 폴 예약** 순이다.

### Q0. 진입 (최초 1회)
- `status.md`에 `## QA` 표(아래 "산출물")를 만들고 현재 단계를 **`QA감시중`**으로 둔다.
- `qa-watch.md`(폴링·트리아지 이력)를 없으면 생성한다.
- `parent=`/`bugs=` 인자를 기록한다. 사용자가 "같은 컨텍스트에서 처리"를 구두로 지시한 버그가 있으면 그것도 `bugs=`에 준한다.

### Q1. 폴링 (Jira 조회)
- **JQL**(할당 *시각* 기준 최근 24h, 진행중 포함):
  ```
  assignee = currentUser()
  AND issuetype = Bug
  AND assignee CHANGED TO currentUser() AFTER "-1d"
  ORDER BY updated DESC
  ```
  `mcp__mcp-atlassian__jira_search`로 조회한다. `assignee CHANGED TO`로 "**나에게 할당된 시각**" 기준을 쓴다(생성/수정 시각이 아니라). 진행중이어도 제외하지 않는다 — "할당 24h 이내 + 아직 한 번도 확인 안 한" 것을 잡기 위함이다.
- **중복 제거**: `qa-watch.md`에 이미 있는(=이전 틱에서 트리아지한) 이슈는 건너뛴다. 남은 것만 **신규 후보**로 Q2로 넘긴다.

### Q2. 트리아지 (이 오케스트레이션 소관인가)
신규 후보마다 아래 순서로 판정한다. **①②는 자동 편입**, **③은 슬랙 문의 후 편입**. 결과를 `qa-watch.md`에 남긴다.

- **① 부모/하위 관계 → 자동 편입**: 버그가 `parent=`로 받은 부모 QA의 하위 이슈이거나, **루트키의 버그 타입 하위 이슈**(`parent = {루트키} AND issuetype = Bug`)이면 편입.
- **② 사용자 명시 → 자동 편입**: `bugs=`에 포함되거나 사용자가 같은 컨텍스트 처리로 지정한 버그이면 편입.
- **③ 내용 기반 판단 → 슬랙 문의**: ①②에 안 걸리면 버그 내용(`jira_get_issue`, `expand: renderedFields`)을 읽고, **이 오케스트레이션 에이전트의 계약 화이트리스트에 속한 파일/기능과 관련되는지**를 코드로 확인한다. 관련된다고 판단되면 **자동 진행하지 말고 슬랙으로 문의**한다(Q3). 관련 없으면 `qa-watch.md`에 `무관`으로 남기고 종료.

**③ 슬랙 문의** — 본인 DM(Slack User ID `U03SRUFP97W`)으로 `mcp__claude_ai_Slack__slack_send_message` 발송, 반환된 메시지 `ts`를 `qa-watch.md`에 저장한다.
```
🐞 QA 버그가 현재 개발 건과 관련돼 보입니다. 이 컨텍스트에서 처리할까요?
• 현재 이슈: {루트키} — {제목}  {$JIRA_BASE_URL/browse/{루트키}}
• 버그 이슈: {버그키} — {제목}  {$JIRA_BASE_URL/browse/{버그키}}
• 판단 근거: {관련 파일/기능 + 담당 에이전트 슬러그}
→ :넵: 이면 처리, :아니오: 이면 넘어갑니다.
```
상태를 `qa-watch.md`에 `문의대기`로 남긴다.

### Q3. 슬랙 응답 확인 (지난 틱의 `문의대기` 처리)
- `문의대기`인 각 건에 대해 저장한 `ts`로 `mcp__claude_ai_Slack__slack_get_reactions`를 호출해 이모지를 확인한다.
  - `:넵:` → **편입**(Q4로). `qa-watch.md` `편입(③)`.
  - `:아니오:` → `보류`로 남기고 **다시 문의하지 않는다**.
  - 반응 없음 → 그대로 `문의대기` 유지(다음 틱에 재확인). 재문의 메시지는 보내지 않는다.

### Q4. 편입 버그 처리 — 담당 에이전트 라우팅 (dobby-order P8 준용)
편입된 버그마다:
1. **담당 에이전트 특정**: 버그를 분석해 고쳐야 할 파일을 `파일:라인`으로 잡고, 그 파일이 어느 에이전트의 **계약(`agents/{슬러그}.md`) 화이트리스트**에 속하는지로 담당을 정한다. 여러 계약에 걸치거나 못 정하면 **확인 게이트**(슬랙/세션)로 사용자에게 확인. 에이전트가 하나뿐이면 그 에이전트가 담당이다.
2. **버그 이슈 진행중 전환**: `jira_get_transitions`에서 도착 상태 `indeterminate`인 전이로 `jira_transition_issue`.
3. **워크트리 확보 (dobby-end 이후 대응)**: `status.md`의 담당 에이전트 워크트리 경로가 실재하면 재사용. 없으면(정리됨):
   - 담당 에이전트 브랜치가 **origin 최신 master에 머지됐는지 확인**: `git fetch origin` 후 `git branch -r --contains {브랜치}` 또는 `git merge-base --is-ancestor {브랜치} origin/{DEFAULT_BASE}`.
   - **머지됨** → `origin/{DEFAULT_BASE}` 최신에서 `bugfix/{버그키}` 워크트리를 새로 만든다(수정은 master 위에). 담당은 계약 화이트리스트로 그대로 식별된다.
   - **미머지** → 살아있는 담당 에이전트 브랜치에서 워크트리를 재생성한다(수정은 그 브랜치 위에).
4. **상태 선(先)갱신**(P8 규칙): 작업 전에 `orchestration.md`의 `## 에이전트 상태표`(에이전트 상태 단일 정본)를 해당 에이전트 `완료 → 구현`(재분석 필요하면 `분석`), **라운드 +1**, 착수 시각·갱신 일시 기록. `## 이벤트 로그`에 `- {YYYY-MM-DD HH:MM} QA: {슬러그} 버그 {버그키} 편입(기준 ①/②/③) — {요약}` 1줄.
5. **수정 실행**: 담당 슬러그의 계약·브랜치·`implementation.md`·`analysis.md`를 컨텍스트로 실어 `dobby-impl`을 재기동한다(모드 A: 세션이 살아있으면 `SendMessage`로 같은 에이전트 이어감, 아니면 같은 슬러그·계약으로 다시 기동). 프롬프트에 analysis-discipline + role-personas「구현 에이전트」주입. 커밋은 `fix: {버그키} ...`, 자기 브랜치에만 푸시.

### Q5. 리뷰 (담당 리뷰어 — dobby-order P5 준용)
- **별도 리뷰 에이전트**(`review-agent.md` 계약 + role-personas「리뷰 에이전트」)를 기동해 그 diff(`git diff {fork}..HEAD`, `fork = git merge-base origin/{base} HEAD`)를 적대적으로 리뷰한다(리뷰어≠구현자). 루브릭 A~E는 dobby-order P5와 동일.
- 결과를 `$ORCHESTRATION_META/{루트키}/qa/{버그키}/reviews/round-{n}.md`에 심각도·`파일:라인`·수정 제안으로 남긴다.
- blocking(blocker·major)=0이 될 때까지 구현 에이전트 `구현`·리뷰 에이전트 `리뷰`로 반복(**최대 라운드 기본 3**, 초과 시 사용자 에스컬레이션).

### Q6. 재통합 → 검증 → 해결
- 리뷰 클린 → 담당 에이전트 브랜치를 **루트 브랜치로 재머지·푸시**한다(에이전트가 하나면 그 브랜치가 곧 루트라 머지 없음). ⛔ **정식 배포 베이스(master)로의 PR·머지는 금지**. 상태 `구현 → 완료`.
- 사용자에게 `dobby-test {버그키|루트키}`로 해당 시나리오 검증을 안내/실행하고, 통과하면 `dobby-resolve {버그키}`로 버그 이슈 해결 표시.
- `qa-watch.md`·`status.md` `## QA` 표를 `해결`로 갱신, 이벤트 로그 1줄.

### Q7. 다음 폴 예약 (또는 종료)
- 종료 조건(아래)이 아니면 **`ScheduleWakeup`으로 `interval`(기본 300초) 뒤 같은 `/dobby-qa {루트키} ...` 재실행을 예약**한다(reason에 "QA 폴링" 명시). `/loop {interval} /dobby-qa {루트키}`로도 대체 가능.
- **종료 조건**: `/dobby-qa stop {루트키}` 수신, 또는 루트 이슈가 정식 배포 베이스로 머지/종료됨. 종료 시 `ScheduleWakeup stop:true`로 루프를 끊고 `status.md` 단계를 QA 이전 상태로 되돌리며 이벤트 로그에 종료 1줄.

## 산출물 (기존 메타 폴더 확장)

```
$ORCHESTRATION_META/{루트키}/
├── qa-watch.md                    # 폴링·트리아지 이력 (이슈별 1행: 편입기준/상태/슬랙 ts)
├── qa/{버그키}/                    # 버그별 처리 산출물
│   ├── analysis.md                #   원인(파일:라인)·담당 에이전트 판정
│   ├── implementation.md          #   수정 요약(담당 에이전트가 기록)
│   └── reviews/round-{n}.md       #   리뷰 결과
└── (기존 orchestration.md · agents/ · status.md …)
```

**`qa-watch.md` 표**:
```markdown
# {루트키} QA 감시 로그

## 폴링
- **주기**: {interval} · **마지막 폴**: {YYYY-MM-DD HH:MM}

## 트리아지
| 버그키 | 제목 | 판정 | 기준 | 담당 슬러그 | 슬랙 ts | 갱신 |
|--------|------|------|------|-------------|---------|------|
```
- 판정값: `편입` · `무관` · `문의대기` · `보류` · `해결`.

**`status.md`에 추가하는 `## QA` 표**:
```markdown
## QA
| 버그키 | 편입 기준 | 담당 슬러그 | 상태 | 리뷰 라운드 | 갱신 |
```
- 상태값: `QA감시중`(전체)·`구현`·`리뷰`·`검증`·`해결`.

## 확인 게이트 (좁음 — 이때만 사용자를 부른다)

1. **기준 ③ 편입 여부**: 내용상 관련돼 보이지만 ①②로 확정 못 하는 버그 → 슬랙 문의(:넵:/:아니오:).
2. **담당 에이전트 모호**: 버그가 여러 계약에 걸치거나 어느 계약에도 안 들어감 → 확인(후자면 dobby-order P8처럼 계약 확장/신규가 필요).
3. **최대 리뷰 라운드 초과**(기본 3).
4. **master 밖 반영**: 정식 배포 베이스 PR·머지는 확인이 아니라 **금지**.
