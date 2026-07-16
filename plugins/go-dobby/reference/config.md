# go-dobby 공통 설정

go-dobby의 모든 스킬(`dobby-order`·`dobby-start`·`dobby-impl`·`dobby-produce`·`dobby-test`·`dobby-resolve`·`dobby-end`)이 공유하는 **설정 절차와 환경 변수 규격**이다. 각 스킬은 본문에서 이 문서를 참조하고, 아래 절차를 그대로 따른다.

> 이 문서는 스킬 본문에 중복 복사돼 있던 설정 블록을 한곳으로 모은 단일 출처다. 변수·기본값을 바꿀 때는 **여기만** 고치면 된다.

## 설정 절차 (작업 스킬 — 읽기 전용)

작업을 시작하기 전에 `~/.config/go-dobby/config.env`를 **읽기만** 한다:

```bash
[ -f ~/.config/go-dobby/config.env ] && source ~/.config/go-dobby/config.env
```

⛔ **비파괴 원칙 (강제 — 가장 중요):** `dobby-order`·`dobby-start`·`dobby-impl`·`dobby-produce`·`dobby-test`·`dobby-resolve`·`dobby-end`·`dobby-explain`·`dobby-qa`·`dobby-jira-tab` 등 **모든 작업 스킬은 `config.env`를 절대 생성·수정·삭제하지 않는다.** 값 채우기·저장·`export` 후 기록은 **오직 `dobby-init` 스킬**만 한다. **헤드리스(무인) 실행에서도 예외 없다.** 작업 스킬이 config.env를 다시 쓰면, 사용자가 지정한 선택 값(예: `ORCHESTRATION_META_PATH`)이 조용히 사라져 대시보드가 엉뚱한 폴더를 읽는 사고가 난다(실제 발생 이력).

값을 읽은 뒤 처리:

- **값이 있으면** 그대로 쓴다.
- **기본값이 있는 변수가 비어 있으면** 그 기본값을 **메모리에서만** 쓴다(아래 "환경 변수" 표의 기본값). config.env에 되쓰지 않는다.
- **`~/.config/go-dobby/config.env` 파일 자체가 없으면**(최초 실행) → **작업을 멈추고** "go-dobby 초기 설정이 필요합니다. 먼저 `/dobby-init`을 실행하세요"라고 안내한다. **작업 스킬이 임의로 config.env를 만들지 않는다.**

> 값을 새로 정하거나 **바꾸는 것은 초기 설정 또는 사용자가 명시적으로 "설정을 바꿔라"고 요청한 경우에만** 가능하며, 그 작업은 전용 스킬 **`dobby-init`**으로만 한다.

## 메타 루트

```bash
ORCHESTRATION_META="${ORCHESTRATION_META_PATH:-$ORCHESTRATION_WORKSPACE/meta}"
```

`ORCHESTRATION_META_PATH`가 설정돼 있으면 그 경로, 없으면 `$ORCHESTRATION_WORKSPACE/meta`를 쓴다. 이하 모든 스킬의 메타 경로는 `$ORCHESTRATION_META` 기준이다.

## 폴더 배치

- 워크트리(작업 폴더): `$ORCHESTRATION_WORKSPACE/subtree/` 아래 `{repo}-{이슈키}`
- 메타 파일: `$ORCHESTRATION_META/` 아래 `{키}/` (오더당 폴더 1개 — `status.md`·`analysis.md`·`implementation.md`/`produce.md`·`test-runs/`·`summary.md` 등)

## 환경 변수

| 변수 | 뜻 | 기본값 | 사용 스킬 |
|------|-----|--------|-----------|
| `JIRA_BASE_URL` | Jira 사이트 주소 | `https://wadiz.atlassian.net` | 전체 |
| `ORCHESTRATION_WORKSPACE` | 작업 루트(하위에 `subtree/`·`meta/`) | `$HOME/work/dobby-workspace` | 전체 |
| `ORCHESTRATION_META_PATH` | 메타 경로 직접 지정(선택) | (없음 → `$ORCHESTRATION_WORKSPACE/meta`) | 전체 |
| `ORCHESTRATION_DEFAULT_BASE` | 기본 베이스 브랜치 | `master` | 전체 |
| `ORCHESTRATION_REPOS_ROOT` | 원본 소스 저장소들이 있는 루트. 소스 루트 = `$ORCHESTRATION_REPOS_ROOT/{repo}` | `$HOME/work/repos` | 전체 |
| `ORCHESTRATION_ENV_MAP` | 테스트 환경→호스트 매핑 | `dev=dev.wadiz.io,rc=rc.wadiz.kr,rc2=rc2.wadiz.kr,rc4=rc4.wadiz.io` | dobby-test |
| `ORCHESTRATION_DOCS_ROOT` | 참고 문서 루트. 문서 = `$ORCHESTRATION_DOCS_ROOT/{repo}.md`(파일) 또는 `$ORCHESTRATION_DOCS_ROOT/{repo}/`(폴더) | `$HOME/work/repos/docs` | 전체 |
| `TEST_LOGIN_ID` / `TEST_LOGIN_PW` | 테스트 계정(선택) | (없음 → 로그인 필요 테스트는 건너뜀) | dobby-test |

- "사용 스킬"은 그 변수를 **직접 쓰는** 스킬을 표시한 것이다. 설정 파일(`config.env`)에는 모든 변수를 함께 두고, 각 스킬은 자기에게 필요한 값만 사용한다.
- 기본값 중 일부(Jira 호스트·테스트 환경 매핑)는 와디즈 환경 기준이다. 첫 실행 시 각자 환경에 맞게 바꾸면 된다.
