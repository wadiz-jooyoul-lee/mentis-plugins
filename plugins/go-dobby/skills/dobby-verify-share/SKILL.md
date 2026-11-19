---
name: dobby-verify-share
description: 오더의 설계된 테스트 케이스(test-plan.md)와 회차 결과(test-runs/*/result.md)를 대시보드 검증 탭과 같은 모양의 페이지로 만들어 claude.ai 아티팩트로 게시하고, 그 링크와 환경별 요약 표를 Jira 이슈 코멘트로 다는 대화형 스킬. 환경(dev·rc4·stage 등)마다 여러 회차를 합쳐 항목별 최종 판정 하나만 보여 주고, 회차 목록은 넣지 않는다. 페이지에는 설계된 테스트 케이스, 환경별 현황표, 환경 탭(판정 카드·닫히는 조건·확인한 항목)이 들어간다. 숫자는 대시보드와 같은 계산 코드(스킬 폴더의 lib/)로 세고 손으로 세지 않는다. 링크는 artifact-share.md 에 슬러그 verify 로 남겨 대시보드 아티팩트 탭에도 보인다. 다시 실행하면 같은 링크와 같은 코멘트를 고친다. 헤드리스에서는 Artifact 도구가 없어 사용자가 대화형으로 실행한다. 사용법 /dobby-verify-share {키} [envs=dev,rc4,stage] [comment=no].
---

# dobby-verify-share

오더의 **검증 결과를 한 페이지로 게시**하고 **Jira 코멘트로 알리는** 대화형 스킬이다.

```
테스트 계획 + 회차 결과 → 환경별 최종 판정으로 합침 → 페이지(HTML) → 아티팩트 게시
   → artifact-share.md 에 링크 저장 → Jira 이슈에 링크와 요약 표 코멘트
```

## 설정 (첫 실행 시 확인)
작업 시작 전 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 **읽기만** 한다(config.env 없으면 `/dobby-init` 먼저). 이하 메타 경로는 `$ORCHESTRATION_META` 기준.

## 입력
`/dobby-verify-share {키} [envs=dev,rc4,stage] [comment=no]`

| 인자 | 뜻 | 없으면 |
|---|---|---|
| `{키}` | 이슈 키 또는 `TASK-{slug}`. 대상 폴더 `$ORCHESTRATION_META/{키}/` | 필수 |
| `envs=` | 페이지에 넣을 환경. 쉼표로 나눈다 | 회차가 있는 환경 전부 |
| `comment=no` | Jira 코멘트를 달지 않는다 | 코멘트를 단다. `TASK-` 키는 Jira 이슈가 없으므로 늘 건너뛴다 |

## 사전 조건
- `$ORCHESTRATION_META/{키}/test-runs/` 에 회차가 하나 이상 있어야 한다. 없으면 "먼저 검증을 돌려 회차를 만들라"고 알리고 멈춘다.
- `test-plan.md` 가 없으면 설계된 테스트 케이스 칸이 비어서 나온다. 멈추지 않는다.
- `node` 가 있어야 한다. 없으면 멈추고 알린다.

## 절차

### 1. 페이지 만들기 (스크립트로만)

```bash
SK="${CLAUDE_PLUGIN_ROOT}/skills/dobby-verify-share"
O="$ORCHESTRATION_META/{키}"
node "$SK/build.mjs" "$O" "$O/artifacts/verify.html" {envs 값, 없으면 생략}
```

- 표준 출력에 환경별 요약 JSON 한 줄이 나온다. 이 값을 3번 코멘트와 5번 보고에 그대로 쓴다. **숫자를 다시 세거나 바꾸지 않는다.**
- 종료 코드 3은 회차 없음, 4는 고른 환경의 회차 없음이다. 오류 문구를 그대로 보여 주고 멈춘다.
- HTML 을 손으로 고치지 않는다. 모양을 바꿔야 하면 `template.html` 을 고친다.
- 페이지 맨 위 이슈 번호에는 `$JIRA_BASE_URL/browse/{키}` 링크가 걸린다. config.env 를 source 한 셸에서 돌려야 이 값이 들어간다. `TASK-` 키는 링크 없이 글자만 둔다.
- 처음 열리는 환경 탭은 rc4 다. rc4 회차가 없으면 첫 환경 탭이 열린다.

계산 방식(참고):
- 회차마다 `result.md` 의 `환경` 줄로 환경을 가른다.
- 환경 안에서 같은 항목을 여러 회차가 봤으면 대시보드와 같은 규칙으로 최종 판정 하나를 낸다.
- 닫히는 조건은 `status.md` 의 `## 닫히는 조건 항목` 표를 읽는다.

### 2. 게시 전 검사
1. **도구 이야기 검사**: `dobby_tooling_lint "$O/artifacts/verify.html"`. 걸리면 그 줄은 근거 문서(테스트 계획·회차 결과)에서 온 것이다. 걸린 줄을 보여 주고 게시해도 되는지 사용자에게 묻는다.
2. **비밀 값 검사**: `grep -niE 'password|비밀번호|token=|secret' "$O/artifacts/verify.html"` 로 실제 비밀번호나 토큰 값이 들어 있는지 본다. 값이 보이면 그 줄을 보여 주고 게시해도 되는지 묻는다. 변수 이름만 적힌 줄(예: `TEST_LOGIN_PW`)은 괜찮다.

### 3. 아티팩트 게시
- 슬러그는 늘 `verify` 다.
- `$O/artifact-share.md` 의 `## 아티팩트` 표에 `verify` 행이 **있으면 갱신**이다. 그 행의 URL 을 Artifact 도구 `url` 인자로 넘겨 같은 링크를 고친다.
- **없으면 신규**다. `url` 없이 게시한다. `icon` 은 `checklist`.
- `description` 은 "{키} 설계된 테스트 케이스와 {환경 목록} 환경별 최종 검증 결과, 닫히는 조건 충족 현황" 형식의 한 문장.
- ⛔ 다른 슬러그 행의 URL 로는 절대 게시하지 않는다. 다른 페이지를 덮어써 그 링크가 죽는다.

### 4. 링크 저장 (헬퍼로만)
- 신규: `dobby_artifact_add {키} verify "검증 결과" {URL}`
- 갱신: `dobby_artifact_touch {키} verify "{무엇이 바뀌었나. 예: stage 회차 반영}"`

### 5. Jira 코멘트
`comment=no` 이거나 키가 `TASK-` 이면 건너뛴다. 명령은 `${CLAUDE_PLUGIN_ROOT}/reference/jira-twg.md` 의 명령표를 따른다. MCP 는 쓰지 않는다.

1. **본문 쓰기**: 1번 JSON 으로 아래 틀을 채워 `$O/artifacts/verify-comment.md` 에 쓴다.

   ```markdown
   ### 검증 결과 정리

   설계된 테스트 케이스와 환경별 최종 검증 결과를 한 페이지로 정리했습니다.

   - 링크: [{키} 검증 결과]({URL})
   - 환경마다 여러 번 시험한 결과를 합쳐, 항목마다 최종 판정 하나만 보여 줍니다.

   | 환경 | 확인 항목 | 통과 | 실패 | 보류 | 닫히는 조건 |
   |---|---|---|---|---|---|
   | {env} | {items}가지 | {pass} | {fail} | {skip} | {conditions}가지 중 {met}가지 확인 |

   - {설명 줄}
   ```

   - 닫히는 조건이 0가지인 환경은 그 칸에 `—` 를 쓴다. 전부 확인했으면 `{conditions}가지 모두 확인` 으로 쓴다.
   - **설명 줄**은 실패나 보류가 있는 환경, 닫히는 조건이 덜 채워진 환경마다 한 줄씩 쓴다. 이유는 회차 결과 문서에 적힌 것만 옮긴다. 이유를 찾지 못하면 항목 번호(`notPassed`)만 적는다. 지어내지 않는다.
   - 마크다운 링크(`[글](주소)`)로 적는다. 주소만 적으면 Jira 에서 눌리지 않는 글자로 들어간다.
2. **같은 코멘트가 있는지 보기**: 코멘트 목록을 파일로 받아 본문에 이 URL 이 들어 있는 코멘트를 찾는다. 있으면 그 코멘트를 **고치고**, 없으면 **새로 단다**.
3. **되읽어 확인**: 다시 목록을 받아 그 코멘트의 문서 구조에 `table` 1개와 링크 표시(`"type":"link"`, `href` 가 URL)가 있는지 본다. 없으면 본문을 고쳐 다시 올린다(최대 2회).

### 6. 보고
- 게시하거나 고친 링크, 환경별 요약 표, Jira 코멘트 번호를 보여 준다.
- 아티팩트는 기본 **비공개**다. 다른 사람이 보려면 사용자가 페이지의 공유 메뉴에서 공유해야 한다고 알린다. Jira 코멘트를 본 사람도 공유 전에는 열 수 없다.

## 비파괴
- 만들거나 고치는 것은 `artifacts/verify.html`, `artifacts/verify-comment.md`, `artifact-share.md` 의 `verify` 행, 그 이슈의 코멘트 하나뿐이다.
- 회차 결과, 테스트 계획, 상태 문서, 다른 슬러그의 행과 원고, Jira 의 다른 칸은 건드리지 않는다.

## 주의
- **대화형 전용**: 헤드리스에서는 Artifact 도구와 claude.ai 인증이 없어 실패한다.
- **계산 코드 출처**: `lib/parseReport.mjs`, `lib/testSummary.mjs`, `lib/testPlan.mjs` 는 대시보드 `src/lib/` 의 같은 이름 파일에서 타입 표기만 지워 옮긴 것이다. 대시보드 계산이 바뀌면 같이 옮긴다.
- `lib/marked.min.js` 는 마크다운을 화면 글로 바꾸는 도구(marked 12.0.2, MIT)다. 아티팩트가 외부 주소에서 스크립트를 받지 않도록 페이지 안에 넣는다.
