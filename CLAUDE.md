# CLAUDE.md — mentis-plugins

Claude Code 플러그인 마켓플레이스 저장소다. 코드가 아니라 **스킬(SKILL.md) 문서**로 이루어진 플러그인(`work-dobby`)을 담는다.

## 구조

- `.claude-plugin/marketplace.json` — 마켓플레이스 정의(플러그인 목록·버전)
- `plugins/work-dobby/` — 플러그인 루트
  - `.claude-plugin/plugin.json` — 플러그인 메타(버전 등)
  - `reference/config.md` — 모든 스킬이 공유하는 **설정 절차·환경 변수 단일 출처**
  - `skills/*/SKILL.md` — 각 스킬. 설정 블록은 인라인하지 말고 `${CLAUDE_PLUGIN_ROOT}/reference/config.md`를 참조한다.

## 버전 규칙 (커밋 전 필수)

**커밋하기 전에 `main` 브랜치의 현재 버전을 확인하고, 이번 수정이 플러그인을 업데이트해야 하는 변경이면 버전의 마지막 자리(patch)를 하나 올린 뒤 커밋한다.**

- **판단 기준 — 플러그인 업데이트가 필요한 변경**: `plugins/work-dobby/` 아래 내용(스킬 SKILL.md, `reference/`, `config.env.example`, `plugin.json` 등) 변경. 이 경우 버전을 올린다.
- **버전을 올리지 않는 변경**: 저장소 루트의 문서만 손대는 경우(예: `README.md`, 이 `CLAUDE.md`)처럼 플러그인 동작·배포 산출물에 영향이 없는 변경.
- **올리는 방법**: `main`의 버전을 기준으로 마지막 자리를 +1 한다(예: `0.4.1 → 0.4.2`). 두 곳을 **함께** 바꾼다 — 값이 어긋나면 안 된다.
  - `plugins/work-dobby/.claude-plugin/plugin.json`의 `version`
  - `.claude-plugin/marketplace.json`의 `plugins[].version`(work-dobby 항목)
- `marketplace.json`의 `metadata.version`은 **마켓플레이스 스키마 버전**으로, 플러그인 릴리스 버전과 별개다. 플러그인 수정만으로는 건드리지 않는다.
- 이미 이번 브랜치에서 버전을 올려 뒀다면(= `main`보다 이미 앞서 있으면) 중복해서 또 올리지 않는다. 기준은 항상 **`main`과의 차이**다.

## 규약

- 스킬 문서는 어려운 용어를 지양하고 쉬운 말로 쓴다(플러그인 스킬들의 공통 원칙과 일치).
- 설정 절차·환경 변수를 바꿀 때는 `reference/config.md` **한 곳만** 고친다. 스킬 본문에 다시 인라인하지 않는다.
