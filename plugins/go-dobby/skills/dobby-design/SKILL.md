---
name: dobby-design
description: 오더의 설계 문서(design.md)와 구현 결과 문서(outcome.md)를 생성·재생성하는 스킬. design.md는 구현 전 설계(무엇을·어떻게·결정과 근거)를 담고 사용자가 대시보드 "설계/결과" 탭에서 직접 수정할 수 있는 유일한 메타 문서다 — 그래서 이미 있으면 regen 없이 절대 덮어쓰지 않고, regen이어도 dobby_design_backup으로 백업(design.md.bak) 후 Write 도구로만 쓴다(셸 덮어쓰기는 훅 G12가 차단). outcome.md는 통합(P7) 후 설계 대비 실제 구현을 쉬운 용어로 정리한 문서로, 아티팩트(dobby-share)의 1차 근거가 된다 — 내부 용어·줄임말(FE/BE·round-N·P숫자·슬러그·blocking=·K=)은 dobby_terms_lint와 dobby_lint #13이 치명으로 잡는다. 사용법 /dobby-design {키} [outcome] [regen].
---

# dobby-design

오더의 **설계 문서(`design.md`)** 와 **구현 결과 문서(`outcome.md`)** 를 만드는 스킬. 대시보드 "설계/결과" 탭이 두 문서를 한 페이지(상단 설계·하단 결과)로 렌더한다.

> 역할 경계: `design.md` = 구현 **전** 무엇을 어떻게 만들 것인가(사용자 승인·수정 대상). `implementation.md` = 구현 **중** 세부 전부(기존 그대로). `outcome.md` = 통합 **후** 설계 대비 결과(아티팩트 재료). `explainer.md` = 비전공자용 쉬운 설명(기존 그대로).

## 설정 (첫 실행 시 확인)
작업 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**(config.env는 읽기만). 이하 메타 경로는 `$ORCHESTRATION_META` 기준. 공용 헬퍼: `dobby_scaffold_doc {키} design|outcome` · `dobby_design_rev` · `dobby_design_ack` · `dobby_design_backup` · `dobby_terms_lint`.

## 사용법
`/dobby-design {키} [outcome] [regen]`
- 인자 없음: `design.md` 생성. **이미 있으면 아무것도 하지 않는다**(사용자 수정본 보호 — 덮어쓰려면 regen).
- `outcome`: `outcome.md` 생성(통합 후). 이미 있으면 그대로 둠(regen으로 재생성).
- `regen`: 대상 문서를 다시 생성. **⛔ design.md는 반드시 `dobby_design_backup {키}` 로 백업한 뒤** 전체 산출물을 다시 읽어 **Write 도구로** 덮어쓴다(셸 `cat >`·`sed -i`는 훅 G12가 차단 — 우회하지 말 것).

## design.md 생성 (구현 전 — dobby-order P3.5가 호출)

**근거(있는 것만 읽는다)**: `analysis*.md`(분석) · `status.md`(닫히는 조건·종류) · `side-effects.md` · `orchestration.md`(범위 배분·계약) · Jira 이슈(있으면).

1. `dobby_scaffold_doc {키} design`으로 틀을 깐다(없을 때만).
2. 각 섹션을 **사실 기반**으로 채운다 — 틀은 하한선, 필요한 섹션은 자유롭게 추가:
   - **무엇을 만드나** / **닫히는 조건**(status.md의 것 그대로) / **설계**(구성요소별 — 하는 일·어디에·어떻게)
   - **결정과 근거** 표: 설계 중 내린 모든 결정. **⛔ '왜' 칸이 빈 행은 dobby_lint #14가 치명으로 잡는다** — 이유 없는 결정 금지.
   - **확인이 필요했던 것**: 대화형(P3.5 게이트)이면 사용자에게 물은 것과 답을, 자율(mode=B·design=auto)이면 **스스로 정한 결정과 그 이유**를 적는다.
   - **예상 파급**: side-effects.md 요약.
3. **설계 중 모르는 게 나오면 사용자에게 묻지 말고 직접 분석해 채운다. 분석의 깊이는 제한하지 않는다** — 설계를 정확히 쓰는 데 필요한 만큼 판다.

## outcome.md 생성 (통합 후 — dobby-order P7이 인라인으로 작성, 이 스킬은 regen용)

**근거**: `design.md`(설계 대비 비교 축) · `implementation*.md` · 실제 diff · `test-runs/`(있으면).

1. `dobby_scaffold_doc {키} outcome`으로 틀을 깐다.
2. **설계 대비 결과** 표: design.md의 각 설계 항목이 어떻게 구현됐는지, 달라졌으면 왜 달라졌는지.
3. **구현 내용**: 구성요소별로 무엇을 하는가·어디에 있는가(`경로/파일`)·어떻게 동작하는가를 **자세하고 구조적으로**.
4. **⛔ 용어 규칙(치명)**: 아티팩트 문서의 1차 근거이므로 —
   - 오케스트레이션 내부 용어 금지: FE/BE(→프론트엔드/백엔드), 슬러그(impl-fe 등 → "프론트엔드 구현 담당"), round-N(→ N차 검토), P숫자(→ 단계 이름), blocking=·K=.
   - 전문용어는 처음 쓸 때 괄호로 풀이. 과도한 단축어·별명 금지.
   - 작성 후 `dobby_terms_lint $ORCHESTRATION_META/{키}/outcome.md`로 자가 검사한다(검출되면 고친다 — dobby_lint #13 치명).
5. **⛔ 실수·재작업 경위는 쓰지 않는다**(결과만 — dobby_lint #15 경고). 과정은 retro.md 몫.
6. **P8 후속 후에는** 전체 재생성 대신 **`## 후속 {YYYY-MM-DD} — {요약}` 섹션을 append**한다(설계 대비 표의 해당 행만 갱신 가능).

## 비파괴
- 이 스킬은 `design.md`·`outcome.md`(+백업 `.bak`)만 만든다. 다른 메타·코드·Jira를 건드리지 않는다.
- **design.md가 이미 있으면 regen 없이 절대 다시 쓰지 않는다** — 사용자가 대시보드에서 수정했을 수 있다(수정본이 곧 정본).

> **왜 이 문서가 없으면 진행이 막히나**: 스폰 훅 **G11**(구현 에이전트 스폰)과 헬퍼 **G13**
> (`dobby_agent_state … 구현`)이 design.md 없이는 구현 단계로 못 가게 코드로 막는다. 이미
> 진행 중인 작업에 뒤늦게 만들 때는 재분석이 아니라 **현 상태 캡처**로 채우면 된다.

## 자동 실행
- `dobby-order` P3.5가 design.md를 만들고, P7이 outcome.md를 인라인으로 작성한다.
- 대시보드 "설계/결과" 탭의 생성·재생성 버튼이 이 스킬을 백그라운드로 실행한다.
