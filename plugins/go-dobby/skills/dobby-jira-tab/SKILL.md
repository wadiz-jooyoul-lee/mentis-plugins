---
name: dobby-jira-tab
description: 오더(이슈/작업)의 Jira 관련 문서를 대시보드 "Jira" 탭용으로 만들거나 Jira에 반영하는 스킬. 네 가지 서브커맨드로 동작한다 — clean(저장된 이슈 원문을 읽기 쉽게 정리), comments(이슈 코멘트를 Atlassian MCP로 조회해 핵심만 정리), enrich(구현 산출물을 분석해 "업데이트 내용" 표준 요약을 작성), post(그 업데이트 요약을 Jira 설명 또는 코멘트에 반영). 모두 사용자가 대시보드 버튼으로 트리거하며, 소감·아바타 같은 재미요소와 내부 오케스트레이션 용어(에이전트 슬러그·라운드·단계 코드·토큰량·세션ID)·mermaid는 제외하고 "나중에 이슈를 읽었을 때 내용이 명확한" 사실 위주로 정리한다. clean/comments/enrich는 파일만 만드는 비파괴 동작이고 post만 Jira에 쓴다. 사용법 /dobby-jira-tab {키} <clean|comments|enrich|post> [target=desc|comment].
---

# dobby-jira-tab

오더의 **Jira 관련 문서**를 대시보드 "Jira" 탭용으로 만들고, 요청 시 Jira에 반영하는 스킬. **사용자 버튼으로만** 실행되며(자동 아님), 에이전트 메인 작업과 분리된 별도 잡으로 돈다.

> 원칙: **사실 기반**(산출물·실제 이슈에 있는 것만, 지어내기 금지). **재미요소(소감·아바타)·내부용어(슬러그·라운드·`P4-L` 등 단계코드·토큰량·세션ID)·mermaid 제외.** 목표는 "**나중에 이 이슈를 읽었을 때 무엇을·왜·어떻게 확인하는지 명확히**".

## 설정 (첫 실행 시)
`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 불러온다. 이하 메타 경로는 `$ORCHESTRATION_META` 기준, 대상 폴더는 `$ORCHESTRATION_META/{키}/`.

## 사용법
`/dobby-jira-tab {키} <snapshot|clean|comments|enrich|post> [target=desc|comment]`
- `{키}`: 이슈 키(예 `FE1-1274`). `TASK-…` 문서 전용 키는 Jira가 없으므로 대상 아님.
- 서브커맨드 하나만 실행한다(대시보드가 버튼별로 호출).

## Atlassian MCP
Jira 조회·쓰기는 Atlassian MCP 도구를 쓴다(필요한 도구만 `ToolSearch`로 로드). 헤드리스 실행에서는 **토큰 기반 Atlassian MCP**가 있어야 동작한다. 도구가 없거나 인증이 안 되면 **그 서브커맨드는 실패로 종료**한다(대시보드가 미완성으로 표시). 조회는 `getJiraIssue`/이슈 코멘트 조회, 쓰기는 이슈 편집(설명)·코멘트 추가/수정 계열을 사용한다.

---

## snapshot — 이슈 원문 가져오기(재활용본이 없을 때)  · [단순 조회: Haiku 가능]
- `dobby-order`가 저장한 `jira-issue.md`가 **없을 때만** 쓰는 폴백. Atlassian MCP로 **이슈 설명을 조회해 원문 그대로** `$ORCHESTRATION_META/{키}/jira-issue.md`에 저장한다(요약·정리 없이 원문만).
- 설명이 비어 있으면 저장하지 않고 그 사실만 알린다. 코멘트는 여기서 다루지 않는다(`comments`가 별도).
- 이미 `jira-issue.md`가 있으면 덮어쓰지 않는다(재활용 우선).

## clean — 저장된 이슈 원문을 읽기 쉽게 정리  · [분석: Opus]
- 입력: `$ORCHESTRATION_META/{키}/jira-issue.md`(dobby-order가 조회 시 저장한 **원문**). 없으면 아무 것도 안 하고 종료.
- 원문을 **핵심 위주로 읽기 쉽게** 재구성한다(요구·배경·수용조건 등 이슈가 담고 있는 내용). 원문에 없는 내용은 넣지 않는다.
- 산출: `$ORCHESTRATION_META/{키}/jira-issue-clean.md`. (원문은 그대로 두어 대시보드가 "원문 접기"로 함께 보여준다.)

## comments — 코멘트 핵심 정리  · [분석: Opus]
- Atlassian MCP로 **이슈의 전체 코멘트를 조회**한다(일부만 재활용하지 않는다 — 누락 방지).
- 대화형 코멘트에서 **결정·요청·합의·미해결 이슈** 같은 핵심만 뽑아 시간 흐름이 드러나게 정리한다. 잡담·인사는 뺀다.
- 산출: `$ORCHESTRATION_META/{키}/jira-comments.md`. 코멘트가 없으면 "코멘트 없음"만 1줄 기록.

## enrich — 업데이트 내용 정리(표준 6섹션)  · [분석: Opus]
- **근거(있는 것만, 사실 위주)**: `explainer.md`(있으면 **1차 참고**) · `implementation.md`/`produce.md` · `analysis.md` · `decisions.md` · `side-effects.md` · `test-guide.md` · `reviews/`.
  - **explainer는 참고일 뿐, 사실은 원 산출물로 교차 확인**한다. 근거가 부족하면 코드/문서를 더 읽어 확인한다(추측 금지). 큰 diff·로그 전체는 불필요하면 요약·변경파일 목록으로 대체하되, **불명확하면 원본을 더 읽는다**.
- 산출: `$ORCHESTRATION_META/{키}/jira-enrich.md`, 아래 **표준 6섹션**(한국어, 사실 위주):

```markdown
## 구현 요약 (mentis 자동 보강)

**한 줄 요약**
- {무엇을 했는지 한 문장}

**구현 내용**
- {실제 변경을 쉬운 말로 2~5줄}

**변경 범위**
- 파일: {주요 변경 파일}
- 브랜치: {작업 브랜치}  ·  PR/머지: {있으면 링크/상태, 없으면 생략}

**주요 결정과 이유**
- {선택}: {이유}   ← decisions.md에서, 내부용어 없이

**영향·주의**
- [{영향도}] {인접 기능 회귀 포인트}   ← side-effects.md 요지

**확인 방법 (수동 TC)**
- {TC 요지}   ← test-guide.md에서
```

- 섹션 근거가 아예 없으면 그 섹션은 생략한다(빈 껍데기 X). **소감·아바타·내부용어·mermaid·토큰량은 절대 넣지 않는다.**

## post — Jira에 반영  · [단순 반영: Haiku 가능]
- 입력: `$ORCHESTRATION_META/{키}/jira-enrich.md`(사용자가 편집했을 수 있음 — **파일 내용을 그대로** 반영). 없으면 실패 종료.
- `target=comment` (기본): 이 이슈에 **`구현 요약 (mentis 자동 보강)`** 이 포함된 **직전 mentis 코멘트가 있으면 그 코멘트를 수정**, 없으면 **새 코멘트로 추가**.
- `target=desc`: 이슈 **설명**에 **관리 구획만 결정적으로 병합**한다(사람이 쓴 부분 보존):
  - 현재 설명을 읽어, `구현 요약 (mentis 자동 보강)` 제목이 **이미 있으면 그 제목부터 설명 끝까지를 새 내용으로 교체**, **없으면 설명 맨 아래에 추가**한다. 그 제목 위(사람 작성분)는 **절대 건드리지 않는다**. (판단 없는 find-replace식 병합 — 사람 작성분 훼손 금지.)
- 반영 후 **플래그 기록**: `$ORCHESTRATION_META/{키}/jira-enrich.json`에 `{ "desc": "{YYYY-MM-DD HH:MM}" }` 또는 `{ "comment": "..." }`(반영한 대상만). 대시보드가 "추가됨" 배지로 쓴다. **동기화는 하지 않는다**(반영 여부만).

---

## 비파괴 / 범위
- `clean`·`comments`·`enrich`는 **각자의 산출 파일 하나만** 만들고 다른 메타·코드·Jira·워크트리는 건드리지 않는다.
- `post`만 Jira에 쓴다(설명 관리 구획 또는 코멘트). 코드·워크트리·다른 메타는 안 건드린다.
- 각 서브커맨드는 **필요한 파일·MCP 도구만** 읽어 잡을 가볍게 유지한다.

## 실행 주체
- 전부 **대시보드 버튼**이 백그라운드 잡으로 호출한다(사용자 트리거). 오케스트레이터(`dobby-order`)는 이 스킬을 호출하지 않는다 — `dobby-order`는 이슈 원문을 `jira-issue.md`로 저장만 한다(재활용).
