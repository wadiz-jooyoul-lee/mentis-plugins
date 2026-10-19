---
name: dobby-stage
description: 정기배포 날 stage 에 올라간 내 이슈를 확인하는 스킬. 오늘(또는 지정한 날) 정기배포 릴리즈 노트에서 개발 담당자가 나인 행을 찾고, 행마다 오더 메타(status.md·test-plan.md)를 읽어 무엇을 바꿨는지 파악한 뒤, 그 변경이 stage 에 들어갔는지 읽기로만 확인한다(wadiz-frontend 는 브랜치 끝 커밋이 origin/stage 에 포함되는지와 stage 빌드 성공, com.wadiz.web 은 stage CI 와 argocd 동기화 상태). 이어서 이슈마다 핵심 시험 2~3개를 스킬이 골라 https://stage.wadiz.io 에서 chrome-devtools 로 바로 실행한다. stage 는 라이브 데이터를 쓰므로 결제·알림 신청·찜·팔로우·쿠폰 받기처럼 데이터를 바꾸는 시나리오는 처음부터 고르지 않고, 새 코드가 stage 번들에는 있고 라이브 번들에는 없는지 비교하는 시험으로 대신한 뒤 보고에 "stage 에서 하지 않은 시험"으로 따로 적는다. 결과는 오더 메타에 시험 회차(test-runs/{시각}/result.md)와 배포 표(stage 행 '검증 완료' 또는 '검증 중')로 남기고, 모두 통과한 행은 릴리즈 노트의 stage 배포확인 칸을 자동으로 체크한다(보류가 있는 행은 묻고, 실패한 행은 체크하지 않는다). 체크는 twg 부분 수정으로 그 칸만 바꾸고 미리 보기와 저장 뒤 다시 읽기로 두 번 검증한다. stage 머지·배포·argocd 동기화·live 칸·다른 사람 행·Jira 는 건드리지 않는다. 로그인·동기화처럼 사람이 해야 하는 일이 있어 대화형으로만 실행한다. 사용법 /dobby-stage [화|목] [{키} ...].
---

# dobby-stage

정기배포 날 **stage 에 올라간 내 이슈**가 제대로 들어갔는지 확인하고, 통과하면 **릴리즈 노트 stage 칸을 체크**한다.

```
릴리즈 노트에서 내 행 찾기 → 메타 읽기 → stage 반영 확인(읽기만) → 이슈마다 핵심 시험 2~3개
→ 메타에 회차·배포 표 기록 → 통과한 행 stage 칸 체크(미리 보기·저장 뒤 검증) → 보고 → 정리
```

진행 상황과 결과는 **한국어와 존댓말**로 쓴다.

## 설정 (첫 실행 시 확인)

작업 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md` 의 "설정 절차"를 그대로 따른다**(config.env 는 읽기만). 이하 메타 경로는 `$ORCHESTRATION_META` 기준이고, 헬퍼는 `${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh` 의 `dobby_*` 를 **bash 로** 불러 쓴다.

릴리즈 노트를 다루는 스크립트는 `${CLAUDE_PLUGIN_ROOT}/skills/dobby-stage/scripts/stage_note.py` 다(아래 `NOTE`). 임시 파일은 세션의 scratchpad 폴더 아래 `stage-note/` 에 둔다(아래 `$W`).

## 사용법

```
/dobby-stage [화|목] [{키} ...]
```

- 요일을 빼면 오늘 요일로 정한다. 오늘이 화·목이 아니면 묻는다.
- 키를 주면 그 이슈의 행만 본다. 빼면 내 행 전부를 본다.

## 1. 릴리즈 노트에서 내 행 찾기

1. 페이지 제목은 `{YYYY}-{N}W WEB Release Note` 다. 주차는 ISO 기준(`date +%G`, `date +%V`)으로 센다. ServiceDev 공간의 부모 페이지 17599528968 아래에서 찾는다.
   ```bash
   twg confluence search query --cql 'space = "ServiceDev" and ancestor = 17599528968 and title = "{YYYY}-{N}W WEB Release Note"' -o json --output-file $W/find.json
   jq -r '.data.results[0].content.id' $W/find.json
   ```
   twg 는 `--output-file` 없이 부르면 결과를 요약 글로 내므로 jq 로 읽을 때는 꼭 붙인다.
2. 본문과 판 번호를 받는다. 본문은 `.data.body.value`, 판 번호는 `.data.snapshotToken` 이다.
   ```bash
   twg confluence content get {페이지ID} --detail full --format html --include-metadata -o json --output-file $W/page.json
   jq -r '.data.body.value' $W/page.json > $W/before.html
   ```
3. 내 계정 ID 를 얻어 내 행을 뽑는다. 개발 담당자 칸(멘션)의 계정 ID 로 가른다.
   ```bash
   twg whoami -o json --output-file $W/who.json
   ME=$(jq -r '.data.accountId' $W/who.json)
   python3 $NOTE mine $W/before.html 화 "$ME"
   ```
   결과는 행마다 번호, 행 ID(localId), 이슈 키, 서비스, 브랜치, stage 칸 체크 여부다. 이미 체크된 행도 시험은 한다(체크만 건너뛴다).
4. 내 행이 없으면 그렇게 알리고 끝낸다.

## 2. 메타 읽기

이슈마다 `$ORCHESTRATION_META/{키}/` 에서 읽는다.

| 파일 | 읽는 것 |
|---|---|
| `status.md` | `## 워크트리 / 브랜치`(저장소·브랜치), `## 배포`(rc 검증 환경), `## 닫히는 조건 항목` |
| `test-plan.md` | 시나리오와 사전 준비(콘솔 스크립트, 시험 데이터) |
| 마지막 `test-runs/*/result.md` | rc 에서의 실제 값. stage 기대값의 기준이 된다 |

메타가 없는 이슈는 릴리즈 노트의 브랜치와 `git diff` 로 시험을 고르고, 기록 단계(5)는 건너뛰었다고 보고한다.

## 3. stage 반영 확인 (읽기만)

| 저장소 | 확인 방법 | 들어간 것으로 보는 조건 |
|---|---|---|
| wadiz-frontend | `git fetch origin stage` 후 `git merge-base --is-ancestor origin/{브랜치} origin/stage` | 종료 코드 0, 그리고 그 뒤 stage CI/CD(static·global·global-account·studio 중 해당 서비스)가 성공 |
| com.wadiz.web | `gh run list -R wadiz-web/com.wadiz.web --workflow 'web - CI - stage'` 와 `argocd app get argo/web-stage-web-server --grpc-web` | CI 성공, argocd Synced·Healthy, 배포된 커밋이 브랜치를 포함 |

- argocd 세션이 없거나(Unauthenticated) 아직 OutOfSync 면 **동기화하지 않는다.** 사람에게 동기화 여부를 묻고 답을 기다린다.
- 반영되지 않은 이슈는 시험하지 않는다. 보고에 "stage 미반영"으로 적는다.

## 4. 이슈마다 핵심 시험 2~3개

스킬이 골라 바로 실행한다(사람에게 고르게 하지 않는다). chrome-devtools 로 새 탭을 열어 `https://stage.wadiz.io` 주소로 바꿔 시험한다.

**고르는 기준**

1. 이번 변경이 직접 바꾼 화면이나 동작을 하나 이상 넣는다.
2. 화면이 틀(옛 static 인지 global 인지)을 갈아탄 변경이면 틀 판별을 넣는다.
   ```js
   [...document.querySelectorAll('script[type="module"][src]')].map(s => s.src)  // global/korea-main.js 면 global
   ```
3. 동작으로 확인하기 어려우면 **번들 비교**로 대신한다. 새 코드의 글자가 stage 번들에는 있고 라이브(`www.wadiz.io`) 번들에는 없는지 본다.
   - 번들 목록은 `performance.getEntriesByType('resource')` 의 `.js` 를 쓴다.
   - global 번들은 `cdn-static.stage.wadiz.io/global/js/main.*.js`, 옛 static 번들은 `cdn-static.stage.wadiz.io/main/main.js` 다.
   - 옛 static 번들은 한글을 **대문자** `\uXXXX` 로 담는다. 소문자로만 찾으면 없다고 잘못 본다.
   - 압축된 코드는 이름이 바뀌므로 `/\.isIntersecting\|\|[\w$]+\.intersectionRatio>0/` 처럼 이름 자리를 `[\w$]+` 로 둔 패턴으로 찾는다.

**고르지 않는 것** — stage 는 clive 기반이라 **라이브 데이터**를 쓴다. 아래는 처음부터 빼고 번들 비교로 대신한다.

- 결제, 알림 신청, 찜, 팔로우, 쿠폰 받기, 글쓰기처럼 데이터를 만들거나 바꾸는 시나리오

**로그인** — 계정은 라이브 계정이다. 로그인이 필요한데 되어 있지 않으면 사람에게 그 탭에서 직접 로그인해 달라고 부탁하고 기다린다. 비밀번호를 묻거나 대신 넣지 않는다.

**기대값이 rc 와 다를 때** — 바로 실패로 적지 않는다. 그 차이가 이번 변경(diff) 때문인지 코드로 확인한다. 이번 변경과 무관한 기존 동작(예: 서버의 기존 이동 규칙)이면 통과로 적고 근거에 그 코드 위치를 남긴다. 이번 변경 때문이면 실패다.

## 5. 메타에 기록

이슈마다 bash 로 헬퍼를 불러 남긴다.

```bash
DIR=$(dobby_testrun_new {키} {시험 수} stage)   # result.md 시나리오 표를 깔아 준다
```

- result.md 의 표 칸을 채운다. 판정 칸에는 반드시 표식을 붙인다: `✅ 통과`, `❌ 실패`, `⏭️ 보류`, `⚠️ 확인 필요`. 표식이 없으면 대시보드에서 빈칸이 된다.
- 근거 칸에는 실제로 본 값(문구, 개수, 주소, 번들 파일 이름과 찾은 패턴)을 쓴다. 파일 이름만 쓰면 `dobby_testrun_lint` 가 거부한다.
- 고르지 않은 시험(데이터를 바꾸는 것)은 표에 넣지 않고 본문의 `## stage 에서 하지 않은 시험` 절에 이유와 함께 적는다.

```bash
dobby_testrun_lint "$DIR"
dobby_testrun_update {키} "$(basename "$DIR")" 완료 "{성공}/{실패}/{보류}"     # 실패가 있으면 상태는 '완료(이슈 있음)'
dobby_ship_stage {키} {저장소} stage "검증 완료"                              # 실패면 "검증 중" 과 비고에 실패 시험
dobby_event {키} "stage 확인: 성공 {n} · 실패 {n} · 보류 {n}"
```

한 이슈가 두 저장소면 `dobby_ship_stage` 를 저장소마다 부른다.

## 6. 릴리즈 노트 stage 칸 체크

| 행의 결과 | 하는 일 |
|---|---|
| 모두 통과 | 묻지 않고 체크한다 |
| 보류가 있음 | 보류한 시험과 이유를 보여 주고 체크할지 묻는다 |
| 실패가 있음 | 체크하지 않는다 |
| 이미 체크됨 | 건너뛴다 |

1. **다시 읽는다.** 시험하는 동안 다른 사람이 고쳤을 수 있으므로 1-2 를 다시 해 새 `before.html` 과 판 번호를 얻는다.
2. **수정 파일을 만든다.** 대상 행의 stage 칸 체크박스만 바꾼 행 전체가 들어간다. 체크박스가 1개가 아니거나 칸을 하나로 집지 못하면 스크립트가 멈춘다. 그때는 손대지 않고 보고한다.
   ```bash
   python3 $NOTE build $W/before.html 화 $W/edits.json {행ID} ...
   ```
3. **미리 보기로 검증한다.**
   ```bash
   twg confluence content update {페이지ID} --snapshot-token "{판}" --edits-file $W/edits.json --ack-body-formats --dry-run -o json --output-file $W/dry.json
   jq -r '.data.body.value' $W/dry.json > $W/dry.html
   python3 $NOTE verify $W/before.html $W/dry.html {행ID} ...
   ```
   `ok` 가 아니면 저장하지 않는다. 미리 보기 본문은 HTML 을 다시 써서 돌려주므로 원문 비교는 쓰지 않는다. 스크립트는 칸마다 보이는 글자와 체크 상태로 비교한다.
4. **저장한다.**
   ```bash
   twg confluence content update {페이지ID} --snapshot-token "{판}" --edits-file $W/edits.json --ack-body-formats --version-message "stage 배포확인 체크" -y -o json --output-file $W/saved.json
   ```
   `snapshot_stale`(그 사이 다른 사람이 고침)이면 1 부터 다시 한다. 두 번 연속이면 멈추고 알린다.
5. **저장 뒤 다시 읽어 검증한다.** 1-2 로 받아 `after.html` 을 만들고 `verify before.html after.html` 을 다시 돌린다. 바뀐 곳이 대상 행의 stage 칸뿐이고, 없어지거나 생긴 행이 없고, 표 밖 글자가 같아야 한다.

## 7. 보고

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
stage 확인 · {배포일}({요일}) 정기배포

| 행 | 이슈 | 저장소 | stage 반영 | 시험 | 결과 | stage 칸 |
|---|---|---|---|---|---|---|
| 9 | FE1-2177 | wadiz-frontend | 들어감 (stage CI 성공) | 커뮤니티 메일 링크 | ✅ 2개, 빈 링크 0개 | 체크함 |
| 20 | FE1-2138 | wadiz-frontend | 들어감 | 수정 코드 번들 비교 | ✅ stage 에만 있음 | 체크함 |

stage 에서 하지 않은 시험: (이슈, 시험, 이유 — 예: 알림 신청이 라이브 데이터에 남음)
사람이 해야 할 일: (예: com.wadiz.web argocd 동기화, 보류 행 확인. 없으면 "없음")
기록한 곳: 각 오더의 시험 회차와 배포 표
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 8. 정리

- 이 스킬이 연 브라우저 탭을 닫는다.
- `$W` 의 임시 파일(본문, 수정 파일, 내려받은 번들)을 지운다.

## 하지 않는 것

- **stage 머지와 배포, argocd 동기화를 하지 않는다.** 사람이 한다.
- **live 칸과 다른 칸은 건드리지 않는다.** stage 칸만 체크한다.
- **다른 사람의 행은 고치지 않는다.**
- **stage 에서 데이터를 바꾸지 않는다.** 라이브 데이터다.
- Jira 와 `status.md` 의 현재 단계는 바꾸지 않는다.
- **자동 실행(`claude -p`, run.sh)에서 부르지 않는다.** 로그인과 동기화 확인에 사람이 필요하다.
