---
name: dobby-start
description: dobby-order가 각 에이전트(단일 이슈든 하위이슈든)의 착수·분석을 위해 호출하는 building block 스킬. Jira 이슈(또는 문서 전용 작업 키)를 받아 조회·진행중 전환 후, 지정된 베이스 브랜치(로컬 에픽 브랜치 또는 원격 base 모두 처리) 위에 전용 워크트리·이슈 브랜치를 만들고 코드 위치까지 분석해 analysis.md와 test-plan.md 초안을 남기고 status.md를 갱신한다. 분석 중 현재 repo에서 알 수 없는 외부 repo 참조가 나오면 무조건 docs를 참조해 분석하고, 애매한 부분은 docs로 추가 확인해 반드시 사실 기반으로 수정 설계를 제시한다. 코드 수정·커밋·푸시는 하지 않는다. 사용법 /dobby-start {키} base={브랜치}.
---

# dobby-start

`dobby-order`(오케스트레이터)가 P1에서 각 에이전트별 **착수+분석**을 위해 호출하는 building block. 이슈 조회 → 베이스 위에 워크트리·브랜치 생성 → 코드 위치까지 분석 → 수정 설계 제시까지 한다. **실제 코드 수정·커밋·푸시는 하지 않는다**(구현은 `dobby-impl`).

> 워크트리(worktree): 하나의 git 저장소에서 여러 작업 폴더를 동시에 두는 기능. 이슈마다 별도 폴더를 만들어 메인 폴더를 건드리지 않는다.

## 분석 원칙 (필수 — 시작 전 숙지)

**`${CLAUDE_PLUGIN_ROOT}/reference/analysis-discipline.md`를 그대로 따른다.** 핵심:
1. **활성 경로 확정 먼저**: 대상 URL/기능이 실제로 어느 앱/엔트리/라우트에서 렌더·실행되는지 **라우트 등록·마운트로 증명**한 뒤에만 그 코드를 근거로 삼는다. 국내는 `static/entries/*`(레거시)와 `apps/global`(이관본)로 이중화돼 동일 기능이 양쪽에 중복 존재하니, 실행되는 쪽만 근거로 하고 안 되는 쪽은 **데드코드로 명시·제외**. 확정 못 하면 **멈추고 보고**(추측 금지).
2. **전제 반증 허용**: 전달받은 가설·전제는 검증 대상이지 사실이 아니다. 활성 코드로 독립 검증하고, 안 맞으면 반박해 코드가 가리키는 설명을 제시한다.
3. **사실 기반·미증명 금지**: 모든 결론은 직접 읽은 코드 사실이어야 하고 **`파일:라인`** 근거를 댄다. 정적으로 증명 불가한 것(런타임 타이밍·네이티브 등)은 그렇게 표기하고, 미증명 위에 수정 설계를 세우지 않는다.

## 설정 (첫 실행 시 확인)

작업을 시작하기 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 불러오고, **이미 값이 있는 변수는 묻지 않고** 빠진 값만 규칙대로 채워 저장·export 한다. 메타 루트 `ORCHESTRATION_META`, 변수 목록·기본값, 폴더 배치(워크트리 `$ORCHESTRATION_WORKSPACE/subtree/` · 메타 `$ORCHESTRATION_META/`)는 모두 그 문서에 있다. 이하 메타 경로는 `$ORCHESTRATION_META` 기준.

## 입력

- `args`: `{키} [base={브랜치}]`
  - `{키}`: 이슈 키(`FE1-1187`)·URL, 또는 문서 전용 작업 키(`TASK-{slug}`). 없으면 dobby-order에 요청한다.
  - `base={브랜치}`: 워크트리를 만들 베이스. 예: `base=feature/{루트키}`(에픽) 또는 `base=master`. 미지정 시 `$ORCHESTRATION_DEFAULT_BASE`.

## 절차

### 1. 이슈 조회 + 진행중 전환 (작업 키면 건너뜀)
- 이슈 키면 `mcp__mcp-atlassian__jira_get_issue`로 제목·설명·타입·**현재 상태**를 조회(`expand: renderedFields`, 이미지 있으면 `jira_get_issue_images`).
- 상태를 **`statusCategory.key`로 판정**해 "진행 중"으로 전환한다(`indeterminate`면 그대로, `done`이면 전환 말고 사용자 확인, `new`면 `jira_get_transitions`에서 도착 상태 `indeterminate`인 전이를 골라 `jira_transition_issue`). 애매하면 확인.
- **문서 전용 작업 키(`TASK-...`)면 Jira 조회·전환을 건너뛴다.** 대상 문서를 읽어 요구사항을 파악한다.

### 2. 베이스 결정 (로컬/원격 모두 처리)
- `base=` 인자를 `{base}`로 쓴다(미지정 시 `$ORCHESTRATION_DEFAULT_BASE`). 어느 베이스로 잡았는지 밝힌다.
- `{base}`는 **로컬 브랜치**(예: 방금 만든 `feature/{루트키}`) 또는 **원격 기준**(예: `master`→`origin/master`)일 수 있다. 4단계에서 존재로 갈라 처리한다.

### 3. 브랜치 prefix 결정
- 버그 → `bugfix/{키}`, 그 외(작업 등) → `feature/{키}`. 이 값이 **전체 브랜치명**이다(예: `bugfix/QA-22370`).

### 4. 워크트리 + 브랜치 생성
- **소스 루트**: `$ORCHESTRATION_REPOS_ROOT/{repo}`(없으면 `git rev-parse --show-toplevel`). 이후 모든 git 명령은 소스 루트에서(`cd {sourceRoot}`).
- 워크트리는 `$ORCHESTRATION_WORKSPACE/subtree/{repo}-{키}`(없으면 `mkdir -p $ORCHESTRATION_WORKSPACE/subtree`). 한 이슈가 여러 repo면 repo별로 각각 생성한다.
- **중복 확인**: `git worktree list`·`git branch --list {prefix}`. 이미 있으면 메타(`$ORCHESTRATION_META/{키}/status.md`) 존재로 갈라 처리 — 있으면 중단하고 사용자 확인, 없으면 기존 워크트리 재사용 + 분석/메타만 채움(fetch/worktree add 건너뜀).
- **베이스 형태로 갈라 생성**:
  - `{base}`가 **로컬 브랜치로 존재**하면: `git worktree add -b {prefix} $ORCHESTRATION_WORKSPACE/subtree/{repo}-{키} {base}`
  - `{base}`가 **원격 기준**이면: `git fetch origin {base}` 후 `git worktree add -b {prefix} $ORCHESTRATION_WORKSPACE/subtree/{repo}-{키} origin/{base}`
  - 로컬·원격 어디에도 없으면 **중단하고 사용자에게 알린다**(베이스가 아직 안 만들어졌을 수 있음).
- **의존성 안내**(JS repo 한정): 새 워크트리는 `node_modules`가 비어 있을 수 있다. 필요 시 `yarn install`을 **안내만** 하고 자동 실행하지 않는다.
- 커밋·푸시는 하지 않는다.
- **status.md 초기화**: `$ORCHESTRATION_META/{키}/status.md`(없으면 `mkdir -p $ORCHESTRATION_META/{키}`). 이슈/작업 메타·현재 단계 `착수`·워크트리/브랜치·베이스·시작 일시를 기록한다(스키마는 아래).

### 5. 분석 (코드 위치까지)
- 탐색·분석은 새 워크트리 폴더 기준. 이슈/문서 내용으로 관련 코드·컴포넌트를 Grep/Glob으로 찾아 **`파일:라인`까지 특정**한다. 추측하지 않고 코드로 확인한다.
- **docs 참조 규칙(필수)** — "docs 참조" = ① `$ORCHESTRATION_DOCS_ROOT/{repo}.md`(파일) 또는 `$ORCHESTRATION_DOCS_ROOT/{repo}/`(폴더) 문서 확인 → ② 없으면 `$ORCHESTRATION_REPOS_ROOT/{repo}`의 실제 소스 읽기. 문서와 코드가 다르면 **코드가 진실**.
  - **외부 repo 참조가 나오면 무조건 docs 참조**: 현재 repo에서 알 수 없는 외부 repo 동작이 참조되면(현재 워크트리엔 그 코드가 없으므로) 그 외부 repo를 **반드시 docs 참조**(docs → 소스)로 분석한다.
  - **애매하면 docs로 추가 분석**: 확인이 필요한데 현재 코드로 확인 불가하면 docs 참조로 확인하고, **반드시 사실 기반으로만** 설계한다.

### 6. 결과 정리 + 수정 설계 → analysis.md
- 분석 결과(원인·`파일:라인`)와 수정 설계(어디를 어떻게, 대안·더 단순한 방법 포함)를 쉬운 말로 정리해 **`$ORCHESTRATION_META/{키}/analysis.md`**에 상세히 기록한다(나중에 이 파일만 읽어도 재분석 없이 이어갈 수 있을 만큼). status.md 현재 단계를 `분석완료`로 바꾼다.

### 7. 테스트 목록 초안 → test-plan.md
- 수정 설계에서 "무엇이 어떻게 바뀌어야 정상인지"를 시나리오(S1, S2…)로 옮겨 **`$ORCHESTRATION_META/{키}/test-plan.md`**에 self-contained하게 작성한다(대상 페이지/URL·사전조건·조작 단계·기대 결과·검증 방법).
- 테스트 데이터는 실재 값으로 채운다(DB 조회 도구가 있으면 조회만; 재현용 SQL도 함께). 환경(env·base URL)은 `미정 (dobby-test 실행 시 결정)`으로 둔다.

## status.md 스키마 (단일 인덱스)

`$ORCHESTRATION_META/{키}/status.md` — 이슈/작업당 1개. 규격은 재설계 스펙 §6을 따른다.

```markdown
# {키} 상태

## 이슈/작업
- 키 · 타입 · 제목 · Jira URL(문서 전용이면 문서 경로)

## 현재 단계
- **단계**: {착수|분석|구현|리뷰|통합|검증|해결|종료}
- **담당 스킬**: {스킬명}
- **갱신**: {일시}

## 팬아웃
- **에이전트 수(K)**: {n}

## 에이전트
| 슬러그 | 이슈/작업 | 브랜치 | 상태 | 라운드 | 갱신 |

## 단계별 진행
| 단계 | 스킬 | 상태 | 산출물 | 갱신 |

## 워크트리 / 브랜치
| repo | 브랜치 | 경로 |
```

- 상태 파일은 최신 스냅샷으로 덮어쓴다. 여러 repo면 워크트리 표에 행만 누적한다.

## 주의

- **사실 기반 원칙**: 분석·판단은 확인된 사실에만 근거한다. **추측 금지.** 확인 못 한 건 "미확인"으로 명시하고, 외부 repo·애매한 지점은 docs 참조로 확인한다.
- Jira 상태 전환은 `statusCategory`로 판정한다. 종료된 이슈·애매한 전이는 사용자에게 확인한다.
- 커밋·푸시는 하지 않는다(구현은 `dobby-impl`). 워크트리에는 `node_modules`가 없어 이후 커밋은 `--no-verify`로 훅을 건너뛴다.
- 어려운 용어를 지양한다.
