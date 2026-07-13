# go-dobby 공통 설정

go-dobby의 모든 스킬(`dobby-order`·`dobby-start`·`dobby-impl`·`dobby-produce`·`dobby-test`·`dobby-resolve`·`dobby-end`)이 공유하는 **설정 절차와 환경 변수 규격**이다. 각 스킬은 본문에서 이 문서를 참조하고, 아래 절차를 그대로 따른다.

> 이 문서는 스킬 본문에 중복 복사돼 있던 설정 블록을 한곳으로 모은 단일 출처다. 변수·기본값을 바꿀 때는 **여기만** 고치면 된다.

## 설정 절차 (첫 실행 시 확인)

작업을 시작하기 전에 `~/.config/go-dobby/config.env`를 읽어 환경 변수를 불러온다:

```bash
[ -f ~/.config/go-dobby/config.env ] && source ~/.config/go-dobby/config.env
```

**이미 값이 있는 변수는 묻지 않는다.** 빠진 변수만 아래 규칙으로 채운다.

- **기본값이 있는 변수**: 현재 기본값을 보여주고 그대로 쓸지 바꿀지 물어본다.
- **선택 변수**(생략 가능): 생략 시 어떤 영향이 있는지 설명하고 생략을 허용한다.
- 사용자가 정한 값은 설정 파일에 저장하고(`mkdir -p ~/.config/go-dobby` 후 기록) `export` 한다.

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
