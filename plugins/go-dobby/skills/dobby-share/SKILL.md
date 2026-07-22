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
- `$ORCHESTRATION_META/{키}/explainer.md` 가 있어야 한다. 없으면 **"먼저 `/dobby-explain {키}`로 구현 내용을 생성하라"**고 알리고 중단한다(지어내지 않는다).

## 절차
1. **근거 읽기**: `explainer.md`(구현 내용, 필수) + `status.md`의 제목(아티팩트 제목용). explainer.md **내용만** 근거로 쓴다(추가 조사·지어내기 금지).
2. **self-contained HTML 작성**: `${CLAUDE_PLUGIN_ROOT}` 밖의 임시 파일(예: 작업 폴더나 `$ORCHESTRATION_META/{키}/artifact.html`)에 explainer 내용을 **읽기 좋은 HTML**로 만든다. **⛔ Artifact CSP 준수 — 외부 호스트(CDN·폰트·이미지·스크립트) 금지, 모든 CSS는 인라인**:
   - 마크다운을 직접 HTML로 옮긴다(제목·목록·표·코드블록·인용). 스타일은 `<style>`로 인라인.
   - **mermaid 다이어그램**: claude.ai 아티팩트는 CDN을 못 쓰므로 mermaid를 라이브 렌더할 수 없다. 각 다이어그램을 **의미가 보존되는 대체 표현**으로 바꾼다 — 간단한 흐름은 **인라인 SVG**나 **번호 매긴 단계 목록/화살표 텍스트**로, 표 형태면 HTML 표로. (다이어그램 원문 mermaid 코드는 접기(`<details>`)에 보조로 넣어도 됨.)
   - 톤은 explainer 그대로(비전공자용 한국어). 없는 내용을 만들지 않는다.
3. **게시(Artifact 도구)**: `artifact-design` 스킬 지침에 따라 그 HTML 파일을 **Artifact 도구로 publish**한다. `title`은 `"{키} 구현 내용"`, `description`은 한 줄 요약, `favicon`은 `📦`. 반환된 **URL**을 확보한다.
   - **재게시(업데이트)**: `artifact-share.md`에 기존 URL이 있으면, Artifact 도구의 `url` 인자에 그 URL을 넘겨 **같은 링크로 업데이트**한다(새 링크를 새로 만들지 않는다).
4. **링크 저장**: `$ORCHESTRATION_META/{키}/artifact-share.md`에 아래 형식으로 저장(대시보드가 첫 `https://` URL을 추출한다):

   ```markdown
   # {키} 아티팩트 공유
   - **링크**: {URL}
   - **제목**: {키} 구현 내용
   - **생성**: {YYYY-MM-DD HH:MM}
   ```
5. **보고**: 사용자에게 링크를 보여주고, **대시보드 "아티팩트" 탭에도 이 링크가 복사·열기 버튼으로 표시된다**고 안내한다.

## 비파괴
- `artifact-share.md`(그리고 선택적으로 `artifact.html`)만 만들거나 갱신한다. 워크트리·코드·다른 메타·Jira는 건드리지 않는다.
- 실존하지 않는 내용을 아티팩트에 넣지 않는다(explainer.md 근거만).

## 주의
- **대화형 전용**: 헤드리스/백그라운드에서는 Artifact 도구·claude.ai 인증이 없어 실패한다. 대시보드 버튼으로 자동화하지 않는다.
- 아티팩트는 기본 **비공개**로 게시된다(사용자가 claude.ai에서 공유 여부를 결정). 사내 민감 정보가 explainer에 있으면 게시 전 사용자에게 확인한다.
