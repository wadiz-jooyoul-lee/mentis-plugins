---
name: dobby-release
description: 오더의 이슈를 정기배포 릴리즈 노트에 올리고, 올린 사실을 오더 메타에 남기는 스킬. 등록 자체는 wadiz-client 플러그인의 update-release-note 스킬을 merge-first 모드로 불러서 하고(빈 행 찾기·번호 맞추기·release/v{날짜} 브랜치로 PR 만들기·머지 묻기는 전부 그 스킬의 규칙. 쓸 내용을 먼저 정하고 → 릴리스 브랜치로 머지한 뒤 → 머지된 행은 테스트한 환경(rc1·rc4)·PASS·release 반영 칸을 체크해 → 한 번에 저장한다. 머지를 건너뛰면 체크 없이 작성만 한다), 이 스킬은 그 앞뒤만 맡는다 — 앞에서는 오더 메타의 저장소·브랜치로 입력을 만들어 주고, 뒤에서는 페이지를 다시 읽고 PR 상태를 조회해 사실로 확인한 뒤 status.md 의 `## 릴리즈 노트` 표에 (배포일, 저장소)마다 한 줄로 적는다. 대시보드는 이 표를 읽어 오더 화면에 등록 여부를 보여 준다. 등록이 페이지에서 확인된 이슈는 Jira 의 라이브 배포일을 그 배포일로 적고 상태를 '해결됨'으로 바꾼다. update-release-note 가 배포일·채울 내용·머지를 사람에게 묻기 때문에 사람이 대화형으로 실행해야 하고 자동 실행에는 넣지 않는다. 코드·배포는 건드리지 않는다. 등록한 행 내용은 오더 메타에 저장해 두고, 키 없이 실행하면 등록 점검을 할지 묻는다 — 점검은 배포일이 남은 등록이 페이지에 아직 있는지 보고, 다른 사람의 브라우저 편집으로 사라진 행은 사람에게 물어 빈 행에 다시 넣거나(직접 뺀 것이면) 기록을 지운다. 사용법 /dobby-release [{키} ...] (키를 빼면 등록 점검 또는 현재 브랜치 이슈 등록을 묻는다).
---

# dobby-release

오더의 이슈를 **정기배포 릴리즈 노트**에 올리고, 올린 사실을 **오더 메타에 남긴 뒤**, **Jira 이슈의 라이브 배포일을 배포일로 적고 '해결됨'으로 바꾼다.**

```
메타에서 저장소·브랜치·테스트한 환경 읽기 → update-release-note merge-first 실행(사람과 대화) → 페이지·PR 다시 확인 → 메타에 기록 → Jira 라이브 배포일·해결됨 → 보고
```

update-release-note 안에서의 순서는 이렇다.

```
쓸 내용 정하기(승인) → 릴리스 브랜치로 PR·머지 → 머지된 행은 검증 환경·PASS·release 체크를 넣어 → 페이지에 한 번에 반영
                              └ 머지를 건너뛰면 체크 없이 작성만 한다
```

⛔ **등록 규칙을 여기서 다시 쓰지 않는다.** 등록은 `wadiz-client:update-release-note` 를 그대로 부른다. 그 스킬은 다른 팀과 함께 쓰는 것이라, 규칙을 이 문서에 베끼면 그쪽이 바뀔 때 두 곳이 어긋난다. 이 스킬이 맡는 것은 **입력 만들기**와 **결과 기록**뿐이다.

진행 상황과 결과는 **한국어와 존댓말**로 쓴다.

## 설정 (첫 실행 시 확인)

작업 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md` 의 "설정 절차"를 그대로 따른다**(config.env 는 읽기만). 이하 메타 경로는 `$ORCHESTRATION_META` 기준이고, 헬퍼는 `${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh` 의 `dobby_*` 를 쓴다.

## 사용법

```
/dobby-release [{키} ...]
```

- 키를 여러 개 주면 **릴리즈 노트의 다른 행**으로 올린다(키 하나에 행 하나).
- 키를 빼면 먼저 `AskUserQuestion` 으로 묻는다. 선택지는 **등록 점검**(7절)과 **현재 브랜치 이슈 등록**이다.
  - 등록 점검을 고르면 7절만 하고 끝낸다.
  - 현재 브랜치 이슈 등록을 고르면 현재 브랜치 이름에서 키를 찾는다. 찾지 못하면 묻는다.

## 0. 먼저 볼 것

1. **`update-release-note` 가 설치돼 있나** — 사용할 수 있는 스킬 목록에 `wadiz-client:update-release-note` 가 없으면 멈추고 알린다. 대신 등록하지 않는다.
   ```
   wadiz-client 플러그인이 없어 릴리즈 노트를 올릴 수 없습니다.
   /plugin 에서 wadiz-claude-plugins 의 wadiz-client 를 설치한 뒤 다시 실행해 주세요.
   ```
   설치된 그 스킬이 `merge-first` 를 아는지도 본다. 모르는 옛 판이면 체크 없이 저장한 뒤에 머지하므로 멈추고 업데이트를 안내한다.
   ```bash
   grep -l merge-first $(ls -d ~/.claude/plugins/cache/*/wadiz-client/*/skills/update-release-note/SKILL.md | sort -V | tail -1) \
     || echo "wadiz-client 를 1.4.2 이상으로 업데이트해 주세요 (/plugin)"
   ```
2. **키마다 메타가 있나** — `$ORCHESTRATION_META/{키}/status.md` 가 없으면 그 키는 빼고, 뺐다고 알린다. 메타가 없는 이슈는 기록할 곳이 없으므로 `update-release-note` 를 직접 쓰라고 안내한다.

## 1. 입력 만들기

키마다 `status.md` 의 `## 워크트리 / 브랜치` 표에서 저장소와 브랜치를 읽는다.

```markdown
## 워크트리 / 브랜치
| repo | 브랜치 | 경로 |
|------|--------|------|
| com.wadiz.web | bugfix/FE1-2140 | /Users/.../com.wadiz.web-FE1-2140 |
```

`update-release-note` 의 입력 형식(`{키}: {저장소}/{브랜치} {저장소}/{브랜치}`)으로 한 줄씩 만든다. 저장소가 둘이면 같은 줄에 공백으로 잇는다.

```
FE1-2140: com.wadiz.web/bugfix/FE1-2140
FE1-2141: wadiz-frontend/feature/FE1-2141 com.wadiz.web/feature/FE1-2141
```

**테스트한 환경** — 같은 `status.md` 의 `## 배포` 표에서 단계가 `검증 완료` 인 행의 환경 중 `rc1`·`rc4` 를 모은다. 이 단계는 dobby-test 가 실패 0건으로 마감했을 때만 적는다.

```markdown
## 배포
| 저장소 | 환경 | 단계 | PR | 빌드 | 갱신 | 비고 |
|---|---|---|---|---|---|---|
| wadiz-frontend | rc4 | 검증 완료 | #30101 | … | 2026-10-19 07:38 |  |
```

- 모은 환경을 대문자로 바꿔 `RC1`, `RC4` 순서로 쉼표로 잇고, 그 키의 줄 끝에 `[검증 {값}]` 으로 붙인다(예 `[검증 RC4]`, 둘 다면 `[검증 RC1, RC4]`).
- 단계에 `⚠` 가 붙은 행, `dev`·`stage` 행은 세지 않는다.
- 하나도 없으면 붙이지 않는다. 그러면 머지돼도 release 칸만 체크된다. 테스트 통과를 확인하지 못한 환경을 체크하지 않기 위해서다.

맨 앞 줄에 `merge-first` 를 넣는다.

```
merge-first
FE1-2140: com.wadiz.web/bugfix/FE1-2140 [검증 RC4]
FE1-2141: wadiz-frontend/feature/FE1-2141 com.wadiz.web/feature/FE1-2141 [검증 RC1, RC4]
```

- 표가 없거나 비어 있으면 그 키는 브랜치 없이 `FE1-2140` 만 넘긴다. 브랜치는 `update-release-note` 가 이슈 유형으로 만든다.
- **브랜치가 원격에 올라가 있는지** 미리 본다(`git ls-remote --heads origin {브랜치}`, 그 워크트리에서). 없으면 릴리스 PR 을 만들 수 없으므로, 사람에게 알리고 그대로 진행할지 묻는다. 오더가 아직 통합 전이면 푸시가 안 됐을 수 있다.

## 2. 등록 — `update-release-note` 를 부른다

```
Skill: wadiz-client:update-release-note
args:  (1에서 만든 줄들)
```

그 스킬의 절차를 **처음부터 끝까지 그대로** 따른다. 배포일 확인, 채울 내용 승인, 머지 여부는 그 스킬이 사람에게 묻는다. 이 스킬이 대신 답하거나 건너뛰지 않는다.

merge-first 모드라서 그 스킬은 PR 을 만들고 머지를 물은 **뒤에** 페이지에 저장한다. 머지된 행에만 체크가 들어가고, 머지를 건너뛴 행은 체크 없이 저장된다. 체크 규칙(어느 칸을 언제)은 그 스킬의 것이다.

그 스킬이 끝나면 아래 값을 그 스킬의 보고에서 옮겨 둔다. 3단계에서 사실로 다시 확인한다.

| 값 | 어디서 |
|---|---|
| 배포일 | 1단계에서 확인받은 날짜 (`YYYY-MM-DD`) |
| 페이지 번호 | 2단계 페이지 조회에서 찾은 번호 |
| 키마다 행 번호 | 저장한 행의 번호 칸 |
| 저장소마다 PR 번호와 결과 | 8·9단계 결과 (머지함 · 머지 안 함 · 충돌 · 건너뜀) |
| 키마다 넣은 체크 | 저장한 계획의 `checks` (검증 환경 값 · PASS · release, 또는 없음) |

사람이 등록을 그만두면(배포일이나 승인 단계에서 취소) 아무것도 기록하지 않고 끝낸다.

## 3. 사실 확인

보고만 믿고 적지 않는다. 기록하기 전에 다시 읽는다.

**① 페이지에 정말 올라갔나** — `update-release-note` 와 같은 방법으로 본문을 받아 그 스킬의 스크립트로 검사한다.

```bash
S=$(ls -d ~/.claude/plugins/cache/*/wadiz-client/*/skills/update-release-note/scripts/release_row.py | sort -V | tail -1)
twg confluence content get {페이지번호} --detail full --format html --include-metadata -o json --output-file {임시}/page.json
jq -r .data.body.value {임시}/page.json > {임시}/after.html
python3 "$S" inspect {임시}/after.html {화|목} {키} [{키} ...]
```

`keys.{키}.alreadyListed` 가 `true` 여야 한다. `false` 면 그 키는 기록하지 않고 "등록이 확인되지 않았다"고 보고한다.

**편집 초안**도 같은 방법으로 본다. 명령에 `--draft` 를 붙여 받은 본문을 `inspect` 한다. 초안에 없으면 브라우저 편집 화면에서 누가 게시할 때 행이 사라진다. 기록과 Jira 단계는 그대로 하고, 보고의 `초안` 칸에 "없음 — 등록 점검으로 넣어 주세요"라고 적는다.

머지된 키는 그 행에 체크가 들어갔는지도 본다. `after.html` 에서 그 키가 든 행의 검증 환경 · RC 검증 결과 · release 칸에 `type="checkbox" checked` 가 있는지 확인하고, 보고의 `체크` 칸에 본 그대로 적는다.

**② PR 상태** — 저장소마다 조회한다. 저장소 이름은 `update-release-note` 8단계 표의 GitHub 저장소(`wadiz-fe/wadiz-frontend`, `wadiz-web/com.wadiz.web`)를 쓴다.

```bash
gh pr list -R {GitHub 저장소} --head {브랜치} --base release/v{YYYYMMDD} --state all \
  --json number,state,mergeable -q '.[0]'
```

| 조회 결과 | 머지 칸 |
|---|---|
| `state` 가 `MERGED` | `머지됨` |
| `state` 가 `OPEN` 이고 `mergeable` 이 `CONFLICTING` | `충돌` |
| `state` 가 `OPEN` (그 밖) | `머지 안 함` |
| PR 이 없음 (그 스킬이 건너뜀) | `건너뜀`, PR 칸은 `-` |
| 조회 실패 | `확인 못 함` |

## 4. 기록

키와 저장소마다 한 번씩 부른다.

```bash
dobby_release_note {키} {배포일} {저장소} {브랜치} {행번호} {#PR번호|-} {머지} \
  "https://wadiz.atlassian.net/wiki/spaces/ServiceDev/pages/{페이지번호}"
dobby_event {키} "릴리즈 노트 등록 — {배포일} 배포 {행번호}행, {저장소} 릴리스 PR {#번호} {머지}"
```

- `{저장소}` 는 짧은 이름(`wadiz-frontend`, `com.wadiz.web`)이다. 메타의 다른 표와 맞춘다.
- 같은 배포일·저장소로 다시 부르면 그 줄을 고친다. 나중에 머지만 따로 했을 때 이 스킬을 다시 돌리면 머지 칸이 갱신된다.
- 헬퍼가 거부하면(날짜 형식·머지 칸 어휘) 값을 고쳐 다시 부른다. 표를 손으로 고치지 않는다.

### 4-1. 행 내용 저장

릴리즈 노트 행은 등록 뒤에 다른 사람의 브라우저 편집으로 사라질 수 있다. 7절 등록 점검이 다시 넣을 수 있게, 3단계 ①에서 확인한 키마다 페이지의 행 내용을 저장한다.

```bash
export RELEASE_ROW="$S"
mkdir -p "$ORCHESTRATION_META/{키}/release-note"
python3 "${CLAUDE_PLUGIN_ROOT}/reference/release-note-row.py" extract {임시}/after.html {화|목} {키} \
  > "$ORCHESTRATION_META/{키}/release-note/{배포일}.json"
```

- 저장 파일은 update-release-note 의 `build` 가 받는 계획 파일 모양이다. 서비스, 기능, 담당 팀, Jira 링크와 브랜치, 넣은 체크가 들어 있다.
- 꺼내기가 실패하면(행을 못 찾음 등) 그 파일은 만들지 않고 보고에 적는다. 등록 기록과 Jira 단계는 그대로 진행한다.

## 5. Jira 라이브 배포일을 적고 상태를 '해결됨'으로

**3단계 ①에서 페이지 등록이 확인된 키만** 바꾼다. 확인되지 않은 키는 건드리지 않는다. 릴리스 PR 의 머지 여부는 따지지 않는다. 릴리즈 노트에 올라갔다는 것이 이 이슈의 개발이 끝났다는 표시이기 때문이다.

키마다 `twg` 로 한다(사이트 `wadiz.atlassian.net`, 명령은 `${CLAUDE_PLUGIN_ROOT}/reference/jira-twg.md`).

### 5-1. 라이브 배포일

라이브 배포일 칸(`customfield_10217`, 값 형식 `YYYY-MM-DD`, 2026-10-19 FE1-2140 으로 확인)에 이 릴리즈 노트의 배포일을 적는다. 상태가 이미 '해결됨'이나 '종료'여도 적는다. 상태 전환과 달리 되돌리는 일이 아니기 때문이다.

1. `twg jira workitem get {키} --fields customfield_10217,status` 로 지금 값을 본다. 이미 같은 날짜면 바꾸지 않는다.
2. 다르거나 비어 있으면 `twg jira workitem update --id {키} --field customfield_10217={배포일}` 로 넣는다. 다른 날짜가 있어도 이번 배포일로 바꾼다. 다음 정기배포로 미뤄 다시 올린 경우가 그렇다.
3. 다시 읽어 그 날짜인지 확인한다. 실패하면 이유를 보고하고, 상태 전환은 그대로 진행한다.
4. 바꿨으면 이벤트 로그에 남긴다.
   ```bash
   dobby_event {키} "Jira 라이브 배포일 {배포일} 로 변경 — 릴리즈 노트 등록 확인 뒤"
   ```

### 5-2. 상태를 '해결됨'으로

1. 5-1 에서 받은 상태를 본다. 이미 `해결됨` 이거나 `종료` 면 바꾸지 않고 "이미 {상태}"로 보고한다. 되돌리는 전환이 되기 때문이다.
2. `twg jira workitem transitions query --id {키}` 로 전환 목록을 받아, **도착 상태(`toName`) 가 `해결됨`** 인 전환을 고른다. 전환 번호를 외워 쓰지 않는다. 이슈 유형이나 프로젝트마다 워크플로가 다를 수 있다.
   - FE1 프로젝트에서 확인한 값: 전환 이름 `Resolved`, 번호 `41`, 입력 화면 없음(2026-10-14, FE1-2140).
3. 그 전환이 목록에 없으면 바꾸지 않고, 이유와 함께 "Jira 에서 직접 바꿔 주세요"라고 보고한다.
4. `twg jira workitem transition --id {키} --transition-id {번호}` 로 바꾼 뒤 `twg jira workitem get {키} --fields status` 로 다시 읽어 `해결됨` 인지 확인한다. 전환이 입력 칸(해결 방법 등)을 요구해 실패하면 억지로 채우지 않고 실패를 보고한다.
5. 바꿨으면 이벤트 로그에 남긴다.
   ```bash
   dobby_event {키} "Jira 상태 해결됨으로 변경 — 릴리즈 노트 {배포일} 배포 등록 확인 뒤"
   ```

`status.md` 의 `## 현재 단계` 는 바꾸지 않는다. 오더 메타의 해결 표시는 `dobby-resolve` 가 근거(리뷰·테스트 결과)를 확인하고 하는 일이다.

## 6. 보고

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
릴리즈 노트 등록 · {배포일}({요일}) 배포

| 이슈 | 행 | 저장소 | 릴리스 PR | 머지 | 체크 | 초안 | 라이브 배포일 | Jira |
|---|---|---|---|---|---|---|---|---|
| FE1-2140 | 7 | com.wadiz.web | #11180 | 머지됨 | RC4 · PASS · release | 있음 | 2026-10-15 로 변경 | 해결됨으로 변경 |
| FE1-2141 | 8 | wadiz-frontend | #30120 | 머지 안 함 | 없음 (머지 전이라 작성만) | 있음 | 이미 2026-10-15 | 해결됨으로 변경 |

기록한 곳: 각 오더 상태 문서의 '릴리즈 노트' 표 (대시보드 오더 화면에 표시됩니다)
확인되지 않아 기록하지 않은 것: (없으면 "없음")
Jira 를 바꾸지 못한 것: (이슈와 이유. 없으면 "없음")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 7. 등록 점검

키 없이 실행해 **등록 점검**을 골랐을 때만 한다. 등록한 행이 페이지에 아직 있는지 보고, 사라진 행은 사람에게 물어 다시 넣는다.

왜 필요한가: 브라우저 편집 화면은 게시본이 아니라 여러 사람이 함께 고치는 **편집 초안**을 연다. 게시본에만 저장된 행은 편집 초안에 없어서, 그 화면에서 누가 게시하면 내 행이 통째로 빠진다(2026-11 여러 번 확인). 초안에도 넣어 두면 열려 있는 편집 화면에도 바로 나타나 사라지지 않는다(2026-11-11 확인). 옛 판으로 등록한 행은 초안에 없을 수 있다.

### 7-1. 대상 모으기

```bash
dobby_release_note_pending
```

배포일이 오늘 이후인 기록을 모든 오더에서 모아 한 줄에 하나씩 낸다. 칸은 키, 배포일, 저장소, 브랜치, 행, PR, 머지, 페이지 주소다. 같은 키·배포일의 여러 저장소 줄은 페이지에서 한 행이므로 하나로 묶는다. 하나도 없으면 "점검할 등록이 없습니다"라고 알리고 끝낸다.

### 7-2. 페이지에서 확인

페이지(주소 끝 번호)마다 한 번 읽는다. 요일은 배포일의 요일(화·목)이다.

```bash
S=$(ls -d ~/.claude/plugins/cache/*/wadiz-client/*/skills/update-release-note/scripts/release_row.py | sort -V | tail -1)
twg confluence content get {페이지번호} --detail full --format html --include-metadata -o json --output-file {임시}/page.json
jq -r .data.snapshotToken {임시}/page.json
jq -r .data.body.value {임시}/page.json > {임시}/before.html
python3 "$S" inspect {임시}/before.html {화|목} {키} [{키} ...]
# 편집 초안
twg confluence content get {페이지번호} --draft --detail full --format html --include-metadata -o json --output-file {임시}/draft.json
jq -r .data.snapshotToken {임시}/draft.json
jq -r .data.body.value {임시}/draft.json > {임시}/draft-before.html
python3 "$S" inspect {임시}/draft-before.html {화|목} {키} [{키} ...]
```

키마다 이렇게 가른다.

| 게시본 | 편집 초안 | 판정 | 할 일 |
|---|---|---|---|
| 있음 | 있음 | 있음 | 저장 파일(`release-note/{배포일}.json`)이 없으면 4-1 처럼 지금 만든다. 꺼낸 `number` 가 기록의 행 번호와 다르면 7-4 처럼 기록과 PR 본문의 행 번호를 고친다. |
| 있음 | 없음 | 초안 누락 | 저장 파일 처리는 위와 같다. 그다음 7-3 에서 묻는다. |
| 없음 | (상관없음) | 사라짐 | 7-3 에서 묻는다. |

### 7-3. 사라진 키 묻기

결과 표(이슈, 배포일, 기록의 행, 판정, 저장 파일 유무)를 먼저 보여 준다. 그다음 사라진 키와 초안 누락 키마다 `AskUserQuestion` 으로 묻는다.

- **사라짐:** 선택지는 **다시 넣기**와 **넣지 않음 (직접 뺐음)** 이다.
- **초안 누락:** 선택지는 **초안에 넣기**와 **넣지 않음** 이다. 넣지 않으면 기록은 그대로 두고 보고에 "초안 누락"으로 남긴다.

**다시 넣기**

저장 파일이 없으면 다시 넣을 수 없다. "update-release-note 로 새로 등록해 주세요"라고 안내하고 넘어간다.

저장 파일이 있으면 update-release-note 의 9.2절과 같은 방식으로 넣는다. 이미 머지된 브랜치라 PR 을 새로 만들 수 없으므로 그 스킬 전체를 부르지 않고 행 스크립트만 쓴다.

1. 페이지를 다시 읽는다(7-2 명령). 묻는 동안 다른 사람이 고쳤을 수 있다.
2. 채울 자리를 만든다.
   ```bash
   python3 "$S" build {임시}/before.html {화|목} "$ORCHESTRATION_META/{키}/release-note/{배포일}.json" {임시}/edits.json > {임시}/manifest.json
   ```
3. 미리보기로 검증한다. 저장하지 않는다. `verify` 가 실패하면 저장하지 않고 멈춘다.
   ```bash
   twg confluence content update {페이지번호} --snapshot-token "{판}" --edits-file {임시}/edits.json \
     --ack-body-formats --dry-run -o json --output-file {임시}/dry.json
   jq -r .data.body.value {임시}/dry.json > {임시}/dry.html
   python3 "$S" verify {임시}/before.html {임시}/dry.html {임시}/manifest.json
   ```
4. 넣을 자리(`manifest.json` 의 `filled[].newNumber` 또는 `added[].number`)와 행 글자(`rows`)를 보여 주고 한 번 더 확인받은 뒤 저장한다.
   ```bash
   twg confluence content update {페이지번호} --snapshot-token "{판}" --edits-file {임시}/edits.json \
     --ack-body-formats --version-message "{키} {요일}요일 정기 배포 재등록" -y -o json --output-file {임시}/update.json
   ```
   `snapshot_stale` 로 거절되면 1번부터 한 번 더 한다. 두 번째도 거절되면 멈추고 알린다.
5. 다시 읽어 `inspect` 로 키가 있는지 확인한다. 확인되면 7-4 로 행 번호를 고치고 이벤트를 남긴다.
   ```bash
   dobby_event {키} "릴리즈 노트 재등록 — {배포일} 배포 {새 행번호}행 (덮어써져 사라진 행을 다시 넣음)"
   ```
6. 아래 **초안에 넣기**를 이어서 한다. 게시본에 다시 넣은 행이 또 사라지지 않게 하기 위해서다.

**초안에 넣기**

저장 파일로 편집 초안에 같은 행을 넣는다. 다시 넣기 뒤에 할 때는 게시본에 넣은 행과 같은 자리여야 한다.

1. 편집 초안을 다시 읽는다(7-2 의 초안 명령). 판 번호는 `d1:N` 모양이다.
2. 채울 자리를 만든다.
   ```bash
   python3 "$S" build {임시}/draft-before.html {화|목} "$ORCHESTRATION_META/{키}/release-note/{배포일}.json" {임시}/draft-edits.json > {임시}/draft-manifest.json
   ```
   넣을 자리(`filled[].newNumber` 또는 `added[].number`)가 게시본의 행 번호와 다르면 저장하지 않고 두 자리를 보여 준 뒤 멈춘다.
3. 미리보기로 검증한다. `verify` 가 실패하면 저장하지 않고 멈춘다.
   ```bash
   twg confluence content update {페이지번호} --draft --snapshot-token "{초안 판}" --edits-file {임시}/draft-edits.json \
     --ack-body-formats --dry-run -o json --output-file {임시}/draft-dry.json
   jq -r .data.body.value {임시}/draft-dry.json > {임시}/draft-dry.html
   python3 "$S" verify {임시}/draft-before.html {임시}/draft-dry.html {임시}/draft-manifest.json
   ```
4. 넣을 자리와 행 글자를 보여 주고 확인받은 뒤 **초안만** 저장한다. 다시 넣기에서 이미 확인받았으면 다시 묻지 않는다.
   ```bash
   twg confluence content update {페이지번호} --draft --snapshot-token "{초안 판}" --edits-file {임시}/draft-edits.json \
     --ack-body-formats -y -o json --output-file {임시}/draft-update.json
   ```
   `snapshot_stale` 로 거절되면 1번부터 한 번 더 한다. 두 번째도 거절되면 멈추고 알린다.
5. 초안을 다시 읽어 `inspect` 로 키가 있는지 확인한다. 게시본도 다시 읽어 판 번호가 그대로인지 본다. 확인되면 이벤트를 남긴다.
   ```bash
   dobby_event {키} "릴리즈 노트 편집 초안에 행 넣음 — {배포일} 배포 {행번호}행 (브라우저 편집으로 사라지지 않게)"
   ```

**넣지 않음 (직접 뺐음)**

기록 줄을 지운다. 다음 점검부터 대상이 아니다. 페이지와 Jira 는 건드리지 않는다.

```bash
dobby_release_note_drop {키} {배포일}
dobby_event {키} "릴리즈 노트 등록 기록 삭제 — {배포일} 배포에서 뺀 것으로 확인받음"
```

### 7-4. 행 번호 고치기

기록의 행 번호가 페이지와 다르면 둘 다 고친다.

- **오더 기록:** 그 배포일의 저장소 줄마다 `dobby_release_note` 를 새 행 번호로 다시 부른다. 나머지 칸은 기록 값 그대로 넘긴다.
- **릴리스 PR 본문:** PR 칸이 `#번호` 인 줄마다 본문의 `등록 위치` 줄을 고친다.
  ```bash
  gh pr view {번호} -R {GitHub 저장소} --json body -q .body > {임시}/pr-body.md
  sed -i '' 's/정기 배포 [0-9]*번 행/정기 배포 {새 행번호}번 행/' {임시}/pr-body.md
  gh pr edit {번호} -R {GitHub 저장소} --body-file {임시}/pr-body.md
  ```
  `등록 위치` 줄이 없는 본문이면 고치지 않고 보고에 적는다.

### 7-5. 보고

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
릴리즈 노트 등록 점검 · {오늘}

| 이슈 | 배포일 | 판정 | 처리 | 행 |
|---|---|---|---|---|
| FE1-2366 | 2026-11-10 | 있음 | 행 번호 기록 고침 | 15 → 21 |
| FE1-2367 | 2026-11-10 | 사라짐 | 다시 넣음 | 7 → 33 |
| FE1-2400 | 2026-11-12 | 사라짐 | 기록 삭제 (직접 뺌) | - |
| FE1-2372 | 2026-11-12 | 초안 누락 | 초안에 넣음 | 13 |

다시 넣지 못한 것: (이슈와 이유. 없으면 "없음")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 하지 않는 것

- **등록 규칙을 바꾸거나 건너뛰지 않는다.** `update-release-note` 가 묻는 것은 사람이 답한다.
- **자동 실행(`claude -p`, run.sh)에서 부르지 않는다.** 사람의 확인이 필요한 스킬이다.
- **확인하지 못한 것을 기록하지 않는다.** 페이지에서 키가 안 보이면 그 키는 적지 않고, Jira 상태도 바꾸지 않는다.
- 코드와 배포는 건드리지 않는다. `status.md` 의 단계도 바꾸지 않는다.
- Jira 는 라이브 배포일을 적고 상태를 '해결됨'으로 바꾸는 것만 한다. 담당자, 해결 버전, 댓글 같은 다른 칸은 고치지 않는다.
- **등록 점검은 사람에게 묻지 않고 다시 넣지 않는다.** 사람이 일부러 뺀 행과 덮어써져 사라진 행은 페이지만으로 구별되지 않는다.
- **편집 초안의 판 번호(`d1:N`)로 게시하지 않는다.** 그러면 다른 사람이 쓰고 아직 게시하지 않은 글까지 함께 게시된다(2026-11-11 확인). 초안에는 `--draft` 로 저장만 한다.
- **등록 점검은 남의 행을 고치지 않는다.** 내 행을 덮어쓴 다른 사람의 행은 그대로 두고 빈 행에 다시 넣는다.
