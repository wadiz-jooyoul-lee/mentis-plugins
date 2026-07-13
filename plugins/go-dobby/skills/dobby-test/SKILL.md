---
name: dobby-test
description: 구현한 내용이 실제 환경에서 정상 동작하는지 chrome-devtools로 검증하는 스킬. dobby-start가 만든 test-plan.md가 있으면 재사용하고 없으면 변경(diff)을 분석해 테스트 목록을 도출한 뒤, 국내/글로벌 국가 전환·로그인을 포함해 실제 브라우저로 테스트하고 결과를 $ORCHESTRATION_META/{키}/test-runs/{시각}/ 에 회차별로(덮어쓰지 않게) 저장하고 화면에도 출력한다. 진행 상태는 이슈 폴더 루트의 단일 status.md(테스트 실행 이력 표·현재 단계)를 갱신한다. 검증은 여기까지이며 상태를 자동으로 "해결"로 올리지 않는다(해결 표시는 dobby-resolve 담당). 사용법 /dobby-test {키|브랜치} 또는 /dobby-test (현재 브랜치).
---

# dobby-test

브랜치에서 작업한 내용이 실제로 동작하는지 chrome-devtools(브라우저 자동화)로 확인하는 스킬. 변경 분석 → 테스트 시나리오 확보 → 실제 브라우저 테스트 → 결과 리포트(회차별 저장 + 화면 출력)까지 한다.

> chrome-devtools: 브라우저를 열어 이동·클릭·입력·스크린샷·네트워크 확인을 자동으로 하는 도구(MCP). `mcp__chrome-devtools__*`를 쓴다.

## 설정 (첫 실행 시 확인)

작업을 시작하기 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 불러오고, **이미 값이 있는 변수는 묻지 않고** 빠진 값만 규칙대로 채워 저장·export 한다. 메타 루트 `ORCHESTRATION_META`, 변수 목록·기본값, 폴더 배치(워크트리 `$ORCHESTRATION_WORKSPACE/subtree/` · 메타 `$ORCHESTRATION_META/`)는 모두 그 문서에 있다. 이하 메타 경로는 `$ORCHESTRATION_META` 기준.

## 산출물 (단일 이슈 폴더)

이슈/작업 루트: `$ORCHESTRATION_META/{키}/`

- `status.md` — **단일 진행 인덱스**(이슈 폴더에 하나). 테스트 진행 중 현재 단계·`테스트 실행 이력` 표를 실시간 갱신한다.
- `test-plan.md` — **테스트 목록**(dobby-start가 초안 생성). 없으면 이 스킬이 diff로 생성. self-contained.
- `test-runs/{YYYYMMDD-HHMMSS}/result.md` — **테스트 결과**. 실행 시각별 폴더에 저장해 **절대 덮어쓰지 않는다**. 스크린샷 등 근거도 같은 폴더.

## 입력

- `args`: 선택. 키(`FE1-1234`)·브랜치명. 없으면 **현재 브랜치**를 대상으로 한다. 브랜치·키에서 이슈 키를 추출(안 되면 물어봄).

## 절차

### 1. 대상 결정
- 입력이 있으면 그 키/브랜치, 없으면 `git rev-parse --abbrev-ref HEAD`. 키로 Jira를 조회해 맥락 파악(작업 키면 대상 문서·analysis.md로 파악).

### 2. 테스트 목록 확보 — 기존 우선, 없으면 생성
- `$ORCHESTRATION_META/{키}/test-plan.md`가 **있으면**(대개 dobby-start 작성) 기본으로 **재사용**한다. 실제 diff와 대조해 빠진 부분만 보강하고, `미정`으로 남은 환경은 3단계에서 채운다.
- **없으면**: 베이스 대비 변경 파일 확인(`git diff --name-only origin/{base}...{branch}`) → 사용자에게 보이는 페이지/기능으로 매핑 → 시나리오(S1, S2…)를 도출해 `test-plan.md`에 저장(self-contained: 대상 URL·사전조건·조작·기대·검증 방법·테스트 데이터+재현 SQL). 재실행 시 최신 분석으로 덮어쓴다.

### 3. 테스트 환경 결정
- 브랜치가 **머지된 환경**에서 테스트한다. `gh pr list --head {branch} --state all --json number,baseRefName,mergedAt,state`로 머지 대상(base)을 확인해 env를 판단.
- env를 **`ORCHESTRATION_ENV_MAP`**으로 접속 호스트에 대응(기본: dev=dev.wadiz.io, rc=rc.wadiz.kr, rc2=rc2.wadiz.kr, rc4=rc4.wadiz.io). **매핑에 없으면 추측하지 말고** 사용자에게 직접 테스트를 부탁한다.
- PR이 없거나 머지 안 됐거나 환경이 애매하면 **중단하고 사용자에게** 어느 환경에서 테스트할지 묻는다.

### 4. 국내/글로벌 판별 + 국가 전환
- 변경이 국내/글로벌 중 무엇인지 판별(`static/*`·레거시 → 국내, `apps/global`의 `korea-routes/` → 국내, `routes/` → 글로벌). 둘 다면 각각 테스트.
- 페이지 진입 후 헤더(GNB) 국가 변경 버튼으로 대상 국가(국내=한국/글로벌=Global)로 전환한 뒤 테스트한다.

### 5. 로그인 (필요 시)
- 자격증명은 `TEST_LOGIN_ID`/`TEST_LOGIN_PW`. 하나라도 없으면 로그인 필요 시나리오는 **SKIP**(사유 기록)하고 로그인 없이 볼 수 있는 것만 테스트.
- 로그인은 UI 버튼으로. **입력 순서(동시 입력 금지)**: ① 아이디 입력 → ② "이메일로 시작하기" → ③ 비밀번호 입력 → ④ 다시 "이메일로 시작하기". 입력 후 값이 들어갔는지 스냅샷으로 확인.

### 6. 테스트 수행
#### 6-0. 시작 전 준비 (조작 전에 반드시 먼저)
1. **결과 폴더 생성**: `date '+%Y%m%d-%H%M%S'`로 `$ORCHESTRATION_META/{키}/test-runs/{YYYYMMDD-HHMMSS}/`를 `mkdir -p`(기존 폴더 안 덮음).
2. **status.md 갱신**: 현재 단계 `검증`, `테스트 실행 이력` 표에 이번 회차 행 추가(회차 = 기존 `test-runs/` 폴더 수 + 1, 상태 `테스트중`, 진행률 `0/N`).
3. **result.md 골격 생성**: 위 폴더에 시나리오 표 행을 미리 깔아둔다(결과·판정 빈칸).

#### 6-1. 시나리오 루프 (각 시나리오 4스텝 한 세트)
1. **조작**: `navigate_page`·`take_snapshot`·`click`/`fill`. 리다이렉트·상태코드는 `list_network_requests`(`includePreservedRequests: true`)로 확인. 화면은 `take_screenshot`으로 결과 폴더에 저장.
2. **판정**: 기대 vs 실제 → PASS/FAIL/SKIP.
3. **result.md 갱신**: 해당 행에 실제값·판정·근거.
4. **status.md 갱신**: 진행률(X/N)·집계·실패 시 한 줄 요약을 **즉시** 반영.

### 7. 결과 마감
- **result.md 완성**: "한눈 요약 → 실패 상세 → 전체 표 → 근거" 순(결론 먼저). 어떤 test-plan으로 실행했는지 명시.
- **status.md 마감**: `테스트 실행 이력` 표의 이번 회차 상태를 `완료`(실패 시 `완료(이슈 있음)`, 중단 시 `중단`)로, 최종 진행률·집계·결과 폴더 경로 확정. 현재 단계는 **`검증완료`**로 둔다.
- **⛔ 상태를 자동으로 `해결`로 올리지 않는다.** 검증은 여기까지다. `해결` 승격은 **`dobby-resolve`**가 단독으로 담당한다. (테스트가 전부 PASS여도 dobby-resolve를 호출해야 해결로 표시된다.)
- 같은 요약을 화면(응답)에도 출력한다.

## 주의

- 추측하지 말고 코드·라우트·네트워크 응답 등 사실로 판정한다. 추측이면 추측이라 밝힌다.
- 테스트 환경이 불확실하면 진행하지 말고 사용자에게 묻는다(잘못된 환경 테스트는 무의미).
- 로그인 입력은 아이디·비밀번호를 **동시 입력하지 않는다**(위 순서 준수).
- live(운영)에서 데이터가 바뀌는 조작(작성/결제/삭제)은 하지 않는다. 조회·이동 위주로 검증.
- 결과는 반드시 파일(`test-runs/{시각}/`)과 화면 양쪽에 남긴다. 진행 상태는 `status.md`에 실시간 기록.
