---
name: dobby-share
description: 오더(이슈/작업)의 "구현 내용"(explainer.md)을 claude.ai 공개 아티팩트로 게시하고, 그 링크를 $ORCHESTRATION_META/{키}/artifact-share.md에 저장하는 대화형 스킬. 헤드리스(대시보드 백그라운드 잡)에서는 Artifact 게시 도구·claude.ai 인증이 없어 게시가 불가능하므로, 사용자가 대화형 Claude Code에서 직접 실행해야 한다. 저장된 artifact-share.md는 대시보드 "아티팩트" 탭이 읽어 공개 링크(복사·열기)를 제공한다. explainer.md만 근거로 self-contained HTML(외부 CDN·호스트 없음, 인라인 CSS)을 만들어 게시한다. 사용법 /dobby-share {키}.
---

# dobby-share

오더의 **구현 내용(`explainer.md`)을 claude.ai 공개 아티팩트로 게시**하고 링크를 남기는 **대화형** 스킬. 대시보드 백그라운드 잡은 Artifact 도구·claude.ai 인증이 없어 게시가 안 되므로, **이 스킬은 사용자가 대화형 Claude Code에서 직접 실행**한다.

```
사용자가 /dobby-share {키} 실행 → 아티팩트 게시 → artifact-share.md에 링크 저장
   → 대시보드 "아티팩트" 탭이 그 링크를 복사·열기 버튼으로 제공
```

## 설정 (첫 실행 시 확인)
작업 시작 전 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 **읽기만** 한다(config.env 없으면 `/dobby-init` 먼저). 이하 메타 경로는 `$ORCHESTRATION_META` 기준.

## 입력
`/dobby-share {키}` — {키}는 이슈 키 또는 `TASK-{slug}`. 대상 폴더 `$ORCHESTRATION_META/{키}/`.

## 사전 조건
- **근거 우선순위**: ① `$ORCHESTRATION_META/{키}/outcome.md`(구현 결과 — 있으면 1차 근거, `design.md`를 배경으로 참고) → ② 없으면 `explainer.md`(기존 방식 — 과거 오더 호환) → ③ 둘 다 없으면 **"먼저 `/dobby-design {키} outcome` 또는 `/dobby-explain {키}`로 생성하라"**고 알리고 중단한다(지어내지 않는다).

## 슬러그 — 신규 게시인지 갱신인지 (먼저 정한다)

한 오더가 아티팩트를 **여러 개** 가질 수 있다(구현 결과·회고 요약·검증 리포트 등). 무엇을 게시하는지를 **슬러그**로 구분하고, 그 슬러그가 신규/갱신을 가른다. 슬러그는 게시 원고 파일명과 짝이다 — `artifacts/{슬러그}.html`.

- **슬러그는 근거 문서에서 정한다**: `outcome.md` → `outcome` · `explainer.md` → `explainer` · `retro.md` → `retro` · `produce.md` → `produce`. 사용자가 별건 주제를 지정하면 그 주제의 짧은 영문 슬러그(소문자·숫자·하이픈).
- **그 슬러그 행이 이미 있으면 = 갱신**: 표의 그 URL을 Artifact 도구 `url` 인자로 넘겨 **같은 링크를 업데이트**하고, 원고는 `artifacts/{슬러그}.html`을 덮어쓴다. 저장은 `dobby_artifact_touch`.
- **없으면 = 신규**: 새로 게시해 URL을 받고 `dobby_artifact_add`로 행을 추가한다.
- **⛔ 슬러그가 다르면 절대 기존 URL로 업데이트하지 마라** — 다른 주제의 아티팩트를 덮어써 이전 링크가 죽는다. 링크를 잃으면 되돌릴 수 없다.
- 현재 행 목록은 `$ORCHESTRATION_META/{키}/artifact-share.md`의 `## 아티팩트` 표에서 확인한다. 그 표가 없고 예전 불릿 형식(`- **링크**: …`)만 있으면 그 한 건을 `outcome`(또는 근거에 맞는 슬러그)의 기존 URL로 보고 갱신한다.

## 절차
1. **근거 읽기**: 위 우선순위의 문서(outcome.md 우선, 없으면 explainer.md) + `status.md`의 제목(아티팩트 제목용). 그 문서 **내용만** 근거로 쓴다(추가 조사·지어내기 금지).
2. **⛔ 용어 게이트(게시 거부)**: 게시 전에 **`dobby_terms_lint {근거 파일}`** 를 실행한다. 내부 용어·줄임말(FE/BE·round-N·P숫자·슬러그·blocking=·K=)이 검출되면 **Artifact publish를 하지 않고 중단**, 해당 줄을 보여주며 근거 문서를 먼저 고치라고 안내한다(아티팩트는 공개 후 되돌릴 수 없다). 코드 안 실제 식별자 인용 등 정당한 예외만 사용자가 시킨 경우 `DOBBY_FORCE=1`.
2. **self-contained HTML 작성**: `$ORCHESTRATION_META/{키}/artifacts/{슬러그}.html`에 근거 문서 내용을 **읽기 좋은 HTML**로 만든다. **⛔ Artifact CSP 준수 — 외부 호스트(CDN·폰트·이미지·스크립트) 금지, 모든 CSS는 인라인**:
   - 마크다운을 직접 HTML로 옮긴다(제목·목록·표·코드블록·인용). 스타일은 `<style>`로 인라인.
   - **mermaid 다이어그램**: claude.ai 아티팩트는 CDN을 못 쓰므로 mermaid를 라이브 렌더할 수 없다. 각 다이어그램을 **의미가 보존되는 대체 표현**으로 바꾼다 — 간단한 흐름은 **인라인 SVG**나 **번호 매긴 단계 목록/화살표 텍스트**로, 표 형태면 HTML 표로. (다이어그램 원문 mermaid 코드는 접기(`<details>`)에 보조로 넣어도 됨.)
   - 톤은 explainer 그대로(비전공자용 한국어). 없는 내용을 만들지 않는다.
3. **게시(Artifact 도구)**: `artifact-design` 스킬 지침에 따라 그 HTML 파일을 **Artifact 도구로 publish**한다. `title`은 `"{키} 구현 내용"`, `description`은 한 줄 요약, `favicon`은 `📦`. 반환된 **URL**을 확보한다.
   - **재게시(업데이트)**: 위 "슬러그" 절의 판정대로 **그 슬러그 행이 이미 있을 때만** Artifact 도구의 `url` 인자에 그 행의 URL을 넘겨 같은 링크를 업데이트한다. 슬러그가 새것이면 `url` 없이 새로 게시해 새 링크를 받는다.
4. **링크 저장 (헬퍼로만 — 파일을 직접 쓰지 않는다)**: 파일에 '어떻게 적히나'는 헬퍼가 고정한다.

   - 신규: **`dobby_artifact_add {키} {슬러그} "{제목}" {URL}`**
   - 갱신: **`dobby_artifact_touch {키} {슬러그} "{무엇을 바꿨나}"`**

   결과 형식(헬퍼가 만든다 — 참고용):

   ```markdown
   # {키} 아티팩트 공유

   ## 아티팩트
   | 슬러그 | 제목 | 링크 | 생성 | 갱신 |
   |--------|------|------|------|------|
   | outcome | 구현 결과 | https://claude.ai/code/artifact/… | 2026-09-08 09:12 | 2026-09-08 11:20 (기기 정보 절 추가) |
   | retro | 회고 요약 | https://claude.ai/code/artifact/… | 2026-09-08 10:05 |  |
   ```

   `dobby_artifact_add`는 **같은 슬러그 행이 있으면 아무것도 하지 않고 1을 반환**한다. 그 경우는 갱신이므로 `dobby_artifact_touch`를 쓴다. 대시보드는 이 표를 읽어 아티팩트를 **전부** 카드로 보여준다(예전 불릿 형식도 계속 읽으므로 끝난 오더의 파일은 고치지 않는다).
5. **보고**: 사용자에게 이번에 게시·갱신한 링크를 보여주고, **대시보드 "아티팩트" 탭에 이 오더의 아티팩트가 모두 복사·열기 버튼으로 표시된다**고 안내한다. 그 오더에 아티팩트가 여럿이면 몇 개인지도 함께 알린다.

## 비파괴
- `artifact-share.md`와 `artifacts/{슬러그}.html`만 만들거나 갱신한다. **다른 슬러그의 행·원고는 건드리지 않는다.** 워크트리·코드·다른 메타·Jira는 건드리지 않는다.
- 실존하지 않는 내용을 아티팩트에 넣지 않는다(explainer.md 근거만).

## 주의
- **대화형 전용**: 헤드리스/백그라운드에서는 Artifact 도구·claude.ai 인증이 없어 실패한다. 대시보드 버튼으로 자동화하지 않는다.
- 아티팩트는 기본 **비공개**로 게시된다(사용자가 claude.ai에서 공유 여부를 결정). 사내 민감 정보가 explainer에 있으면 게시 전 사용자에게 확인한다.
