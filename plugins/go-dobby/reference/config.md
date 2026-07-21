# go-dobby 공통 설정

go-dobby의 모든 스킬(`dobby-order`·`dobby-start`·`dobby-impl`·`dobby-produce`·`dobby-test`·`dobby-resolve`·`dobby-end`)이 공유하는 **설정 절차와 환경 변수 규격**이다. 각 스킬은 본문에서 이 문서를 참조하고, 아래 절차를 그대로 따른다.

> 이 문서는 스킬 본문에 중복 복사돼 있던 설정 블록을 한곳으로 모은 단일 출처다. 변수·기본값을 바꿀 때는 **여기만** 고치면 된다.

## 설정 절차 (작업 스킬 — 읽기 전용)

작업을 시작하기 전에 `~/.config/go-dobby/config.env`를 **읽기만** 하고, **공용 헬퍼**를 source 한다(아래 "공용 헬퍼" 참조):

```bash
[ -f ~/.config/go-dobby/config.env ] && source ~/.config/go-dobby/config.env
source "${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh"   # dobby_* 함수 + $ORCHESTRATION_META
dobby_load_config   # config.env 재로드 + $ORCHESTRATION_META 계산(없으면 3 반환 → /dobby-init 안내)
```

> **의존성 없음(추가 설치 불필요)**: dobby-lib.sh는 **어디에나 기본 내장된 `bash`·`awk`·`git`만** 쓴다. `agent-logs.json` 병합도 jq·python 없이 **awk로** 처리하므로 `brew install` 같은 설치가 필요 없다.

⛔ **비파괴 원칙 (강제 — 가장 중요):** `dobby-order`·`dobby-start`·`dobby-impl`·`dobby-produce`·`dobby-test`·`dobby-resolve`·`dobby-end`·`dobby-explain`·`dobby-qa`·`dobby-jira-tab` 등 **모든 작업 스킬은 `config.env`를 절대 생성·수정·삭제하지 않는다.** 값 채우기·저장·`export` 후 기록은 **오직 `dobby-init` 스킬**만 한다. **헤드리스(무인) 실행에서도 예외 없다.** 작업 스킬이 config.env를 다시 쓰면, 사용자가 지정한 선택 값(예: `ORCHESTRATION_META_PATH`)이 조용히 사라져 대시보드가 엉뚱한 폴더를 읽는 사고가 난다(실제 발생 이력).

값을 읽은 뒤 처리:

- **값이 있으면** 그대로 쓴다.
- **기본값이 있는 변수가 비어 있으면** 그 기본값을 **메모리에서만** 쓴다(아래 "환경 변수" 표의 기본값). config.env에 되쓰지 않는다.
- **`~/.config/go-dobby/config.env` 파일 자체가 없으면**(최초 실행) → **작업을 멈추고** "go-dobby 초기 설정이 필요합니다. 먼저 `/dobby-init`을 실행하세요"라고 안내한다. **작업 스킬이 임의로 config.env를 만들지 않는다.**

> 값을 새로 정하거나 **바꾸는 것은 초기 설정 또는 사용자가 명시적으로 "설정을 바꿔라"고 요청한 경우에만** 가능하며, 그 작업은 전용 스킬 **`dobby-init`**으로만 한다.

## 공용 헬퍼 (dobby-lib.sh)

판단이 필요 없는 **결정론적 단계**(git·파일·메타 갱신)는 손으로 하지 말고 **`${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh`의 함수**로 실행한다. 매번 동일하게 돌아 일관성이 오르고, **상태 파일 전체 통독 없이 append·부분수정**이라 토큰을 아낀다. ⛔ 이 함수들은 **기계적 작업만** 한다 — 분석·구현·리뷰·문서 "내용"은 절대 만들지 않는다(그건 LLM 몫). 값(이름/설명/커밋 메시지 등)은 전부 인자로 넘긴다.

| 함수 | 언제 | 하는 일 |
|------|------|---------|
| `dobby_scaffold_meta KEY [제목]` | 진입 즉시 | 메타 폴더 + 골격 status.md(없을 때만) |
| `dobby_ensure_board KEY` | P0 | orchestration.md 상태표+이벤트로그 골격 |
| `dobby_setup_worktree REPO KEY PREFIX BASE` | P0 | fetch·워크트리·브랜치·origin push (경로 stdout, base 로컬/원격 자동 감지, 재호출 시 재사용) |
| `dobby_agent_add KEY 슬러그 이름 설명 상태 [라운드]` | 스폰 전(선갱신) | 상태표 행 추가(중복 무시, 활성이면 착수=now) |
| `dobby_agent_state KEY 슬러그 상태 [라운드]` | 전이마다 | 그 행 상태/갱신만 수정(비활성→활성 진입 시 착수 갱신) |
| `dobby_event KEY "사건 — 설명"` | 타임라인 사건마다 | 이벤트 로그 1줄 append |
| `dobby_log KEY 슬러그 로그경로 [라운드]` | 스폰 직후 | agent-logs.json 기록(라운드는 하위키 병합) |
| `dobby_phase KEY 단계` | 단계 전이 | status.md 현재 단계/갱신 |
| `dobby_review_path KEY 라운드 슬러그` | P5 | reviews/round-N/{슬러그}.md 경로(폴더 생성) |
| `dobby_testrun_new KEY 회차` | dobby-test | test-runs/{시각}/ + result.md 골격 |
| `dobby_commit_push 워크트리 브랜치 "메시지"` | P6 통과 후 | commit --no-verify + push |
| `dobby_merge_root 워크트리 루트 에이전트` | P7 | 에이전트 브랜치 → 루트 머지·push |
| `dobby_resolve KEY [undo]` | dobby-resolve | 단계 해결↔통합 + ## 해결 골격 + 미완료 에이전트 완료 |
| `dobby_subtree_list` | dobby-end | subtree 폴더별 `경로<TAB>키` 목록 |
| `dobby_wt_unpushed WORKTREE` | dobby-end 판정 | origin 미푸시 커밋 수(모르면 `?`) |
| `dobby_end_snapshot KEY WORKTREE BASE` | dobby-end | 제거 전 code-changes/{repo}.commits·.diff 저장 |
| `dobby_end_remove SRCREPO WORKTREE` | dobby-end | 워크트리 제거(브랜치 보존, 거부 시 --force). rm -rf는 안 함 |

- **여전히 LLM 몫(스크립트가 안 함)**: 팬아웃 K·활성경로 증명·범위 배분·이름/설명/슬러그 값 결정·커밋 메시지 문구·리뷰 findings·분석/문서 본문 서술·Jira 상태 전환(MCP)·base 모호 시 확정.
- 값에 `|`·개행이 들어가면 안 된다(표 깨짐). 이름의 `/`는 허용(슬러그엔 금지 — dobby-lib이 그대로 기록만 함).

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
