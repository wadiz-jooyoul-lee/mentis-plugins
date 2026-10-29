---
name: dobby-data
description: 해결된 오더의 성과를 스노우플레이크 와디태그 데이터로 분석하는 스킬. spec 은 오더의 코드 변경과 수집 코드를 읽어 측정 명세(data/spec.json)를 만들고, run 은 명세로 SQL 을 만들어 스노우플레이크 연결 도구로 실행한 뒤 통계·판정 배지를 계산해 data/summary.json 과 해석 report.md 를 남긴다. 대시보드 오더 "데이터" 탭의 버튼이 백그라운드로 실행한다. TASK- 작업은 다루지 않는다. 사용법 /dobby-data spec {키} 또는 /dobby-data run {키} [until=YYYY-MM-DD HH:mm:ss].
---

# dobby-data

해결된 오더가 라이브에서 실제로 효과가 있었는지를 **와디태그**(와디즈 화면이 남기는 사용자 행동 기록. 스노우플레이크 표 `WADIZ_LIVE.WADITAG.TAGEVENT`)로 확인한다.

일은 둘로 나뉜다.

| 명령 | 하는 일 | 남기는 것 |
|---|---|---|
| `spec` | 오더의 코드 변경을 읽어 "무엇으로 성과를 볼지"를 정한다 | `data/spec.json` |
| `run` | 명세대로 데이터를 한 번 모으고(= 회차 하나) 결과를 해석한다 | `data/runs/{회차}/`, `data/summary.json`, `data/report.md` |

> 핵심 원칙: **판단은 이 세션이, 계산은 스크립트가 한다.** 기간, SQL, 통계, 판정 배지는 스크립트 출력을 그대로 쓴다. 세션이 숫자를 고치거나 다시 계산하지 않는다.

## 설정 (첫 실행 시 확인)

작업을 시작하기 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md` 의 "설정 절차"를 그대로 따른다.** 이하 메타 경로는 `$ORCHESTRATION_META` 기준이다.

스크립트는 환경 변수 `ORCHESTRATION_META` 를 읽는다. 설정 절차 뒤에 아래처럼 준비한다.

```bash
export ORCHESTRATION_META
LIB="${CLAUDE_PLUGIN_ROOT}/skills/dobby-data/lib"
```

셸 명령은 부를 때마다 새로 시작해 변수가 남지 않는다. 그래서 아래 스크립트를 부를 때마다 **같은 셸 명령 안에서** 설정 절차와 위 두 줄을 먼저 실행한다.

## 사용법

```
/dobby-data spec {키}
/dobby-data run {키} [until=YYYY-MM-DD HH:mm:ss]
```

- `{키}` 는 Jira 이슈 키다(예: `FE1-1845`).
- `until` 은 이번 회차의 끝 시각(한국 시간)이다. 주지 않으면 지금 시각까지 모은다.

## 지키는 것

- **사람에게 묻지 않는다.** 대시보드가 백그라운드로 띄우는 실행이다. 막히면 이유를 마지막 출력에 적고 끝낸다.
- **`TASK-` 로 시작하는 키는 바로 끝낸다.** 문서 작업이라 라이브 데이터가 없다.
- **판단만 한다.** 기간, SQL, 통계, 배지는 스크립트 출력을 그대로 쓴다. 숫자를 고치거나 다시 계산하지 않는다.
- **공용 제외 규칙(`$ORCHESTRATION_META/.data/exclusions.json`)은 고치지 않는다.** 바꾸면 모든 오더의 다음 회차가 처음부터 다시 센다. 새 제외 후보는 `report.md` 에 제안만 적는다.
- **코드 저장소와 `status.md` 는 고치지 않는다.** 쓰는 곳은 `$ORCHESTRATION_META/{키}/data/` 뿐이다.
- **스노우플레이크는 `SELECT` 만 실행한다.**
- 슬랙·메일 도구를 부르지 않는다.

## spec — 측정 명세 만들기

1. **오더 사실 읽기**: `node "$LIB/window.mjs" facts {키}`
   - `isTask` 가 `true` 면 "TASK- 작업은 데이터 분석 대상이 아닙니다"라고 적고 끝낸다.
   - `resolved` 가 `false` 면 "아직 해결되지 않은 오더입니다"라고 적고 끝낸다.
2. **코드 변경 읽기**: 아래 중 처음으로 있는 것을 쓴다.
   1. `worktrees[]` 중 `exists` 가 `true` 인 워크트리: `git -C {경로} diff origin/{기준 브랜치}...{브랜치}`. 기준 브랜치는 그 저장소의 `origin/HEAD` 다.
   2. `codeChanges` 폴더의 파일.
   3. 저장소에 남은 브랜치(`git -C {저장소} log`, `diff`).
3. **수집 이벤트 찾기**: 바뀐 줄의 `trackingCustomTag` 같은 수집 호출에서 `category`, `action`, `label` 을 **코드에 적힌 값 그대로** 옮긴다. `facts` 의 `trackScan` 표가 어느 파일을 볼지 알려 준다.
   - 와디태그 칸과의 대응은 고정이다: `category → TAGID`, `action → ACTION`, `label → TAGLABEL`. 칸 이름 바꾸기는 스크립트가 한다.
4. **새 이벤트가 없으면**: 바뀐 화면에서 원래 찍히던 이벤트를 찾는다. 배포 전 7일 건수를 `SELECT` 한 번으로 조회해 실제로 쌓이는지 확인한다.
5. **측정 종류(`kind`) 고르기**

   | kind | 언제 |
   |---|---|
   | `ab_test` | 실험군(A/B)을 나누는 이벤트가 있다. 실험군별 전환율을 비교한다 |
   | `new_events` | 새 이벤트를 심었고 비교할 기준이 없다. 잘 쌓이는지만 본다 |
   | `before_after` | 기존 이벤트로 배포 전과 뒤의 비율을 비교할 수 있다 |
   | `value_change` | 기존 이벤트의 라벨 값 분포가 바뀌는 변경이다 |
   | `not_measurable` | 와디태그로 볼 수 없다(오류 감시·서버 로그로만 보이는 변경, 수집 코드가 닿지 않는 변경 등). `reason` 에 사유를 적는다 |

6. **라이브 배포일(`liveDate`)**: `facts` 의 `liveDateFromReleaseNote` 를 쓴다(`liveDateSource: "릴리즈 노트"`). 없으면 `twg` 로 Jira 이슈의 라이브 배포일 칸(`customfield_10217`)을 읽는다(`liveDateSource: "Jira"`). 둘 다 없으면 `not_measurable`, 사유 "라이브 배포일을 찾지 못함".
7. **집계 시작 시각(`startAt`)**: 기본은 `liveDate` 12:00:00 이다. 배포 당일 시험 기록(`test-runs/`)이 그보다 늦으면 그 뒤로 미룬다. 정한 이유를 `notes` 에 적는다.
8. **명세 쓰기**: `$ORCHESTRATION_META/{키}/data/spec.json` 을 아래 "spec.json 형식"대로 쓴다. 그다음 `node "$LIB/render-sql.mjs" check {키}` 가 `ok` 를 낼 때까지 고친다.

마지막 출력에 고른 `kind`, 핵심 지표, 이벤트 목록, `startAt` 과 그 이유를 짧게 적는다.

## run — 데이터 수집

1. **회차 열기**: `node "$LIB/window.mjs" new {키} [--until "YYYY-MM-DD HH:mm:ss"]` → 회차 폴더 경로 한 줄. 실패하면(명세 없음, 측정 불가, 새 기간 없음) 그 메시지를 적고 끝낸다.
2. **SQL 만들기**: `node "$LIB/render-sql.mjs" render {회차 폴더}` → 실행할 SQL 파일 이름 목록.
3. **SQL 실행**: 파일마다 `{회차 폴더}/queries/{이름}.sql` 내용을 **그대로** `mcp__claude_ai_Snowflake__sql_execution_tool` 에 넣어 실행한다. 응답 원문을 `{회차 폴더}/results/{같은 이름}.json` 에 **고치지 않고** 쓴다.
   - 하나라도 실패하면 `stats` 를 돌리지 않고 끝낸다. 실패한 회차는 `stats.json` 이 없어서 다음 회차가 같은 기간을 다시 모은다.
4. **계산**: `node "$LIB/stats.mjs" run {회차 폴더}` → `stats.json` 과 `summary.json`.
5. **해석 쓰기**: `summary.json` 과 이번 회차 `stats.json` 의 `anomalies` 만 읽고 `$ORCHESTRATION_META/{키}/data/report.md` 를 **새로** 쓴다. 절은 아래 여섯 개다.

   | 절 | 내용 |
   |---|---|
   | `## 한 줄 요약` | 배지와 핵심 숫자를 한 문장으로 |
   | `## 핵심 숫자` | 대상과 비교 값, 표본, 변화율, p값. 숫자는 `summary.json` 그대로 |
   | `## 기기 종류별` | `segments` 를 표로 |
   | `## 주의점` | 표본 부족, 균형 검사, 0건인 날 등 판정을 읽을 때 알아야 할 것 |
   | `## 이상 기록 후보 판정` | `anomalies` 의 기기마다 로봇이나 시험 기기로 보이는지와 근거(브라우저 식별 문자열, 건수, 날 수) |
   | `## 제외 규칙 추가 제안` | 공용 제외 규칙에 더할 만한 값. 고치지 않고 제안만 한다 |

   p값은 "두 비율 차이가 우연일 가능성"처럼 쉬운 말로 풀어 쓴다.
6. **한 줄 요약 저장**: `node "$LIB/stats.mjs" oneline {키} "{한 줄 요약}"`

배지의 뜻은 아래와 같다. 배지는 스크립트가 정한다.

| 배지 | 뜻 |
|---|---|
| 수집 이상 | 꽉 찬 날(하루 24시간이 모두 집계 기간에 든 날) 중 건수 0 인 날이 있거나, 실험군 균형 검사 p 가 0.01 보다 작다 |
| 성과 있음 | p 가 0.05 보다 작고 좋아지는 방향이다 |
| 나빠짐 | p 가 0.05 보다 작고 나빠지는 방향이다 |
| 판단 이르다 | 차이가 우연인지 아직 가릴 수 없고, 표본이 필요 표본보다 적다 |
| 차이 없음 | 표본이 충분한데 차이가 우연과 구별되지 않는다 |
| 수집 확인 | `new_events` — 비교 없이 잘 쌓이는지만 본다 |

## spec.json 형식

```json
{
  "version": 1,
  "key": "FE1-1845",
  "kind": "ab_test",
  "title": "구글 원탭 로그인 노출 실험",
  "liveDate": "2026-10-22",
  "liveDateSource": "릴리즈 노트",
  "startAt": "2026-10-22 12:00:00",
  "deviceTypes": ["PC_WEB", "MOBILE_WEB"],
  "events": [
    { "name": "원탭 대상", "category": "구글원탭", "action": "대상", "meaning": "실험군 배정. 라벨이 A 또는 B" }
  ],
  "daily": ["원탭 대상"],
  "metric": { "name": "로그인·가입 전환율", "direction": "up" },
  "ab": { "assign": "원탭 대상", "control": "A", "treatment": "B", "ratio": [1, 1], "conversion": ["로그인완료", "회원가입완료"] },
  "funnel": { "steps": ["원탭 노출요청", "원탭 클릭"] },
  "continuations": [{ "name": "클릭 뒤 로그인", "from": "원탭 클릭", "to": "로그인완료", "withinHours": 1 }],
  "beforeAfter": { "unit": "devices", "numerator": "…", "denominator": "…" },
  "valueChange": { "event": "…", "values": [""] },
  "reason": "측정 불가 사유(kind 가 not_measurable 일 때만)",
  "notes": "명세를 만든 근거 요약"
}
```

| 칸 | 필수 | 뜻 |
|---|---|---|
| `kind` | 항상 | `ab_test`, `new_events`, `before_after`, `value_change`, `not_measurable` 중 하나 |
| `liveDate`, `liveDateSource` | `not_measurable` 이 아니면 | 라이브 배포일과 그 출처(`릴리즈 노트` 또는 `Jira`) |
| `startAt` | `not_measurable` 이 아니면 | 집계 시작 시각(한국 시간 `YYYY-MM-DD HH:mm:ss`). 배포 당일 시험 시간대를 피해서 정한다 |
| `deviceTypes` | 아니오 | 기본값 `["PC_WEB", "MOBILE_WEB"]` |
| `events[]` | `not_measurable` 이 아니면 | 이벤트 하나 = `name`(명세 안의 이름), `category`, `action`(선택), `label`(선택), `meaning` |
| `daily` | `not_measurable` 이 아니면 | 일별 건수를 셀 이벤트 이름 목록. 하나 이상 |
| `metric` | `new_events` 가 아니면 | 큰 숫자의 이름과 좋아지는 방향(`up` 또는 `down`) |
| `ab` | `ab_test` 일 때 | `assign` 이벤트의 라벨로 실험군을 나눈다. `conversion` 이벤트 중 하나라도 배정 뒤에 찍히면 전환 |
| `funnel` | 선택 | 단계별 기기 수 |
| `continuations` | 선택 | `from` 을 처음 한 기기 중 `withinHours` 시간 안에 `to` 를 한 기기 비율. 실험(`ab_test`)이 아니면 모든 항목의 `from` 이 같아야 한다 |
| `beforeAfter` | `before_after` 일 때 | `unit`(`devices` 또는 `events`), 분자 이벤트, 분모 이벤트 |
| `valueChange` | `value_change` 일 때 | 이벤트 하나와, 비율을 볼 라벨 값 목록(빈 값은 `""`) |
| `reason` | `not_measurable` 일 때 | 왜 측정할 수 없는지 |

다른 칸이 가리키는 이벤트 이름은 모두 `events[]` 에 있어야 한다. `category` 하나로 끝나는 이벤트(예: `로그인완료`)도 `events[]` 에 따로 적는다.

## 메타 파일

모든 경로는 `$ORCHESTRATION_META/{키}/data/` 기준이다.

| 경로 | 누가 쓰나 | 내용 |
|---|---|---|
| `spec.json` | `spec` 명령의 세션 | 측정 명세 |
| `runs/{회차 아이디}/window.json` | `window.mjs new` | 회차 기간과 지문(제외 규칙과 명세 내용으로 만든 짧은 값) |
| `runs/{회차 아이디}/queries/{이름}.sql` | `render-sql.mjs render` | 실행할 SQL |
| `runs/{회차 아이디}/results/{이름}.json` | `run` 명령의 세션 | 연결 도구가 돌려준 응답 원문 |
| `runs/{회차 아이디}/stats.json` | `stats.mjs run` | 이 회차 계산 결과 |
| `summary.json` | `stats.mjs run`, `stats.mjs oneline` | 모든 회차를 합친 결과. 대시보드가 읽는다 |
| `report.md` | `run` 명령의 세션 | 합친 결과의 해석. 매 회차 새로 쓴다 |

회차를 합치는 규칙은 스크립트에 들어 있다. 일별 건수는 더해도 되므로 이어 붙이고, 비율은 더하면 틀리므로 매 회차 `startAt` 부터 다시 센다. 제외 규칙이나 명세가 바뀌면(지문이 달라지면) 일별 건수도 `startAt` 부터 다시 센다.
