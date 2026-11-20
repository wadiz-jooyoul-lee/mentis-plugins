---
name: dobby-app-release
description: 완성된 앱 오더(wadiz-android · wadiz-ios · wadiz-multiplatform)를 주차 출시 브랜치에 넣는 스킬. 리액트 네이티브 모듈이 있으면 모듈 PR 을 release/{버전} 으로 내 자동 리뷰를 반영하고 사람 승인을 받아 머지한 뒤, 출시 브랜치 푸시로 발행된 모듈 태그(YY.W.N)를 확인한다. 이어서 두 앱 작업 폴더에서 모듈 버전(안드로이드 rnVersion, iOS Package.swift·Package.resolved 두 곳)을 앱 출시 브랜치 값보다 높을 때만 올리고, 네이티브 변경과 함께 앱마다 release/{버전}.0 으로 PR 을 내 자동 리뷰를 반영하고 빌드 검사를 확인한 뒤 사람 승인을 받아 머지한다. 머지 뒤 QA 배포 작업이 성공했는지 보고 상태 문서 '## 앱 출시' 표에 저장소마다 PR·버전을 적는다. 안드로이드만, iOS 만 고친 오더는 모듈 단계를 건너뛴다. 출시 라인이 이미 나갔으면(main 에 합쳐짐) 멈추고 다음 라인을 묻는다. 머지마다 사람 승인이 필요해 대화형으로만 실행한다. 사용법 /dobby-app-release {키}.
---

# dobby-app-release

완성된 앱 오더를 **주차 출시 브랜치에 넣는다.** 리액트 네이티브 모듈은 출시 브랜치에 머지되면 발행이 끝이다. 앱은 출시 브랜치에 머지되면 QA 배포가 돈다.

```
라인 확인 → (모듈 PR → 리뷰 반영 → 승인·머지 → 발행 확인) → 두 앱 모듈 버전 올리기 → 앱 PR → 리뷰 반영·빌드 검사 → 승인·머지 → QA 배포 확인 → 기록
```

진행 상황과 결과는 **한국어와 존댓말**로 쓴다.

## 설정

작업 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md` 의 "설정 절차"를 그대로 따른다**(config.env 는 읽기만). 헬퍼는 `${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh` 의 `dobby_*` 를 bash 로 불러 쓴다.

## 지키는 것

- ⛔ **머지는 매번 사람에게 묻는다.** `AskUserQuestion` 으로 "{저장소} #{PR} 을 {출시 브랜치} 에 머지할까요?" 를 묻고, 승인을 받은 뒤 `dobby_app_merge` 로만 머지한다. `gh pr merge` 를 직접 부르지 않는다. 훅은 출시 브랜치로 가는 직접 머지를 막지 않지만, 직접 머지는 헬퍼가 하는 확인(이 오더의 PR 인지, 출시된 라인인지, 충돌·변경 요청)을 건너뛴다.
- ⛔ **출시 브랜치를 이 스킬이 만들지 않는다.** 없으면 멈추고 알린다. 만드는 일은 설계 때 사람 승인을 받아 한다.
- ⛔ main · develop 으로 PR 을 내거나 머지하지 않는다. 강제 푸시하지 않는다.
- 커밋은 `dobby_commit_push` 로만 한다(저장소마다 제목 형식을 검사한다).

## 0. 읽을 것과 멈출 조건

1. 상태 문서(`$ORCHESTRATION_META/{키}/status.md`)의 단계, 작업 폴더 표, 기준 브랜치를 읽는다. 설계 문서(`design.md`) 머리의 `- **출시 버전**:` 줄을 읽는다.
2. 아래면 멈추고 이유를 알린다.

| 상황 | 알릴 말 |
|---|---|
| 단계가 `완성` 이나 `해결` 이 아님 | "아직 완성 전입니다(지금 {단계}). /do {키} 로 이어 가세요" |
| 작업 폴더 표에 앱 저장소가 없음 | "앱 오더가 아닙니다" |
| 기준 브랜치가 출시 브랜치가 아님(예: `develop`), 또는 wadiz-multiplatform 만 있고 앱 작업 폴더가 없음 | "새 출시 흐름 전에 만든 오더입니다. 출시 브랜치 PR 과 QA 배포는 사람이 직접 하고, 끝나면 /dobby-resolve {키} 로 해결 처리하세요" |
| 출시 버전 줄이 없음 | 상태 문서 기준 브랜치(`release/26.48`, `release/26.48.0`)에서 버전을 읽는다. 그것도 없으면 사람에게 묻는다 |
| 커밋하지 않은 변경이 있음 | "{저장소} 작업 폴더에 커밋하지 않은 변경이 있습니다" |

3. **라인 확인**: `dobby_release_line {버전} {작업 폴더 표의 앱 저장소들}`
   - 모두 `있음` 이면 진행한다.
   - `출시됨` 이 있으면 멈추고 묻는다. "{버전} 은 이미 출시됐습니다. {다음 버전}(으)로 옮길까요?" 다음 버전은 `dobby_release_line` 인자 없이 낸 추천 버전이다. 옮기기로 하면 작업 폴더 표의 저장소마다 상태 문서 `- **기준 브랜치**:` 줄의 값을 새 출시 브랜치로 바꾼다(모듈 `release/{새 버전}`, 앱 `release/{새 버전}.0`). 버전 올림 헬퍼가 이 줄을 읽어 합치고 비교하기 때문이다. 이후 단계의 출시 브랜치도 새 버전으로 쓰고, PR 의 커밋 목록에 이 오더 커밋이 아닌 것이 섞이면 멈추고 사람에게 묻는다.
   - `없음` 이면 멈추고 알린다.

## 1. 오더 모양

| 작업 폴더 표 | 할 단계 |
|---|---|
| wadiz-multiplatform 이 있음 | 2(모듈) → 3(버전 올리기) → 4(앱) |
| wadiz-android 나 wadiz-ios 만 | 4(앱)만 |

## 2. 모듈 PR 과 발행 (리액트 네이티브 오더)

1. **PR 열기**: 모듈 작업 브랜치가 `origin/release/{버전}` 보다 앞선 커밋이 있는지 본다. 없으면 이미 들어간 것이므로 3으로 간다. 이때 **모듈 버전**은 작업 브랜치 끝 커밋을 담은 첫 태그다. `git -C $ORCHESTRATION_REPOS_ROOT/wadiz-multiplatform fetch -q --tags origin` 으로 태그를 받은 뒤 `git -C $ORCHESTRATION_REPOS_ROOT/wadiz-multiplatform tag --contains origin/{작업 브랜치} --list '{버전}.*' | sort -V | head -1`. 표에는 `dobby_app_release_record {키} wadiz-multiplatform release/{버전} "이미 반영" - {모듈 버전}` 을 적는다.
   ```bash
   gh pr create --repo wadiz-app/wadiz-multiplatform --base release/{버전} --head {작업 브랜치} \
     --title "{키} {종류}: {무엇을 했는가}" --body-file {본문 파일} --reviewer wadiz-app/fe1-team
   ```
   - 제목은 모듈 저장소 커밋 형식과 같다(종류는 feat·fix 등).
   - 모듈 저장소에는 리뷰어 자동 지정 파일(`CODEOWNERS`)이 없다. `--reviewer` 를 붙여야 자동 리뷰가 돈다.
   - 본문은 저장소 `.github/pull_request_template.md` 가 있으면 그 틀을 채운다. 설계 문서의 목적과 바꾼 것, 기기 시험 결과(회차와 통과 수)를 적는다. 오케스트레이션 내부 용어는 쓰지 않는다.
   - `dobby_app_release_record {키} wadiz-multiplatform release/{버전} "PR 열림" "#{번호}"`
2. **리뷰 반영**: 아래 "리뷰 반영" 절을 따른다.
3. **머지**: 사람에게 묻고 승인을 받으면 `dobby_app_merge {키} wadiz-multiplatform {번호}`.
4. **발행 확인**: 머지로 출시 브랜치에 푸시가 일어나 `build.yml` 이 새 버전을 발행한다.
   ```bash
   gh pr view {번호} --repo wadiz-app/wadiz-multiplatform --json mergeCommit --jq .mergeCommit.oid   # 머지 커밋
   gh run list --repo wadiz-app/wadiz-multiplatform --workflow build.yml --branch release/{버전} --limit 10 --json databaseId,status,conclusion,headSha
   ```
   - 발행 작업은 한 줄로 서서 돈다. 최근 10개 중 `headSha` 가 머지 커밋인 실행을 찾는다. 그 실행이 `success` 가 될 때까지 기다린다(30초 간격, 15분 상한). 실패하면 멈추고 실행 주소를 알린다.
   - 새 태그는 `git -C $ORCHESTRATION_REPOS_ROOT/wadiz-multiplatform fetch -q --tags origin` 뒤 `git tag --contains {머지 커밋} --list '{버전}.*' | sort -V | head -1` 이다. 이 태그가 이 오더의 **모듈 버전**이다.
   - `dobby_app_release_record {키} wadiz-multiplatform release/{버전} "발행 확인" "#{번호}" {모듈 버전}`

## 3. 두 앱의 모듈 버전 올리기 (리액트 네이티브 오더)

```bash
dobby_app_pin_rn {키} {모듈 버전}
```

- 헬퍼가 앱 출시 브랜치를 작업 브랜치에 합친 뒤 지금 값과 비교한다. **내 버전이 높을 때만** 바꾼다.
- `바꿈` 줄이 나온 앱은 커밋하고 푸시한다.
  - 안드로이드: `dobby_commit_push {작업 폴더} {브랜치} "{키}-{이슈-제목}"` 꼴(본문에 "- 리액트 네이티브 모듈을 {모듈 버전} 으로 올림").
  - iOS: `dobby_commit_push {작업 폴더} {브랜치} "{키} RN 모듈 핀을 {모듈 버전} 으로 올린다"`.
- `그대로 …(이번 변경 포함)` 이면 그 앱은 버전 커밋 없이 넘어간다. 네이티브 변경도 없으면 그 앱은 PR 을 내지 않고 `dobby_app_release_record {키} {저장소} release/{버전}.0 "버전 그대로" - {앱 값}` 만 적는다.
- `그대로 …(확인 못 함)` 이면 멈추고 사람에게 묻는다. 앱이 더 높은 버전을 쓰는데 그 버전에 이번 변경이 들어 있는지 모른다는 뜻이다.
- 반환 1(충돌, 태그 없음 등)이면 출력 줄을 알리고 멈춘다.

## 4. 앱 PR (작업 폴더 표의 앱마다)

3에서 「버전 그대로」를 적은 앱은 이 절을 건너뛴다.

1. **PR 열기**: 작업 브랜치가 `origin/release/{버전}.0` 보다 앞선 커밋이 없으면 PR 을 내지 않고 `dobby_app_release_record {키} {저장소} release/{버전}.0 "이미 반영" -` 를 적는다. 다음 할 일은 작업 폴더의 저장소마다 끝 단계 행이 있어야 해결 차례로 바뀌기 때문이다.
   ```bash
   gh pr create --repo wadiz-app/{저장소} --base release/{버전}.0 --head {작업 브랜치} \
     --title "[{키}] {Jira 제목}" --body-file {본문 파일}
   ```
   - 본문은 저장소 `.github/pull_request_template.md` 의 절을 채운다. 안드로이드는 「작업제목」(Jira 링크), 「작업사항」, 「코파일럿 지침」이다. iOS 는 「변경된 내용」, 「이슈 번호 및 링크」, 「리뷰요청 전 Checklist」, 「코파일럿 지침」이다.
   - 리액트 네이티브 오더면 작업사항에 "리액트 네이티브 모듈 {옛 값} → {모듈 버전}" 과 모듈 PR 주소를 적는다.
   - iOS 는 시험하지 않았다는 것을 적는다: "iOS 는 로컬 시험 없이 PR 빌드 검사로 확인합니다".
   - `dobby_app_release_record {키} {저장소} release/{버전}.0 "PR 열림" "#{번호}"`
2. **리뷰 반영**: 아래 "리뷰 반영" 절을 따른다.
3. **검사 확인**: `gh pr checks {번호} --repo wadiz-app/{저장소}` 가 모두 통과해야 한다. iOS 는 `pr_build_check.yml`(앱 빌드 검사), 안드로이드는 `pr-changed-module-test.yml` 이 돈다. 실패하면 원인을 읽고 이 오더의 변경 때문이면 고쳐 푸시한다. 이 오더와 무관한 실패면 멈추고 알린다.
4. **머지**: 사람에게 묻고 승인을 받으면 `dobby_app_merge {키} {저장소} {번호}`.
5. **QA 배포 확인**: 머지로 도는 작업이 성공했는지 본다.

   | 저장소 | 작업 | 올라간 버전을 읽는 곳 |
   |---|---|---|
   | wadiz-android | `merge_build.yml`(머지 빌드 QA 배포) | 출시 브랜치의 `버전 자동 업데이트` 커밋이 바꾼 `version.properties`(MAJOR·MINOR·PATCH 와 QA_VERSION) |
   | wadiz-ios | `release_branch_merge_deploy.yml` | 출시 브랜치의 `Bump up …` 커밋 |

   ```bash
   gh pr view {번호} --repo wadiz-app/{저장소} --json mergedAt --jq .mergedAt   # 머지 시각
   gh run list --repo wadiz-app/{저장소} --workflow {작업 파일} --event pull_request --limit 20 --json databaseId,status,conclusion,headBranch,headSha,createdAt,url
   ```
   - 이 작업은 PR 이 닫힐 때 돈다. 그래서 실행의 `headBranch` 는 출시 브랜치가 아니라 PR 을 보낸 작업 브랜치다. `--branch release/…` 로 거르면 하나도 나오지 않는다.
   - `headBranch` 가 이 오더의 작업 브랜치이고 머지 시각과 같거나 뒤에 만들어진 실행을 본다(실제 간격은 3~5초다). 30초 간격으로 다시 조회해 끝날 때까지 기다린다. 상한은 안드로이드 20분, iOS 40분이다(iOS 빌드가 더 오래 걸린다).
   - `success` 면 `dobby_app_release_record {키} {저장소} release/{버전}.0 "QA 배포 확인" "#{번호}" {올라간 버전}`.
   - `cancelled` 일 때
     - 같은 출시 브랜치로 뒤이어 머지된 다른 PR 의 실행 때문에 취소된 것이다. iOS 작업은 같은 출시 브랜치의 앞 실행을 취소한다(`cancel-in-progress: true`). 안드로이드 작업(`reusable-qa-deploy.yml`)은 출시 브랜치마다 실행 하나와 대기 하나만 두어, 새 실행이 오면 기다리던 실행이 취소된다.
     - 두 앱 모두 같은 규칙으로 판정한다. 취소된 실행보다 뒤에 만들어진 실행을 오래된 것부터 차례로 본다. `skipped`(머지 없이 닫힌 PR)는 건너뛴다. 실행마다 `gh pr list --repo wadiz-app/{저장소} --head {그 실행의 headBranch} --base release/{버전}.0 --state merged --json number,headRefOid --jq '.[]|select(.headRefOid=="{그 실행의 headSha}")|.number'` 를 조회해 결과가 있는 첫 실행을 고른다. 실행의 `headSha` 는 그 PR 의 끝 커밋과 같다. 브랜치 이름만 보면 `i18n-sync` 처럼 매주 여러 출시 라인으로 머지되는 브랜치가 예전 PR 로 잘못 맞으므로 끝 커밋까지 맞춘다.
     - 고른 실행으로 같은 방식으로 판정한다. 두 작업 모두 출시 브랜치의 최신 상태를 받아 빌드하므로 내 머지 커밋도 담는다. 조회한 실행 안에서 고를 실행이 없으면 상한까지 다시 조회한다.
   - 상한까지 끝나지 않으면 `"QA 배포 중"` 으로 적고 실행 주소를 알린다. 다시 실행하면 이 단계부터 잇는다.
   - `failure` 면 `"막힘"` 으로 적고 실행 주소를 알린다. 다시 돌리지 않는다.

## 리뷰 반영

PR 을 열면 자동 코드 리뷰가 1~2분 안에 달린다. 사람 계정으로 올라오고 본문 끝에 "Generated by Claude Code" 가 있다.

1. `dobby_ship_review_wait {작업 폴더} {번호}` 로 기다린다. `timeout` 이면 리뷰 없이 진행할지 사람에게 묻는다. `arrived` 가 나오면 30초 뒤에 읽는다. iOS 는 자동 리뷰가 두 계정으로 거의 동시에 달려(실측 18초 차이) 하나만 읽고 끝나지 않게 하기 위해서다.
2. 리뷰 본문(`gh pr view {번호} --repo {저장소} --json reviews`)과 줄 단위 지적(`gh api repos/{저장소}/pulls/{번호}/comments`)을 모두 읽는다. 승인이어도 본문을 읽는다.
3. 지적마다 판단한다.
   - 고칠 것: 작업 폴더에서 고치고, 저장소 검사(안드로이드 `dobby_android_check`, 모듈 `dobby_rn_check`)를 통과시킨다. 고칠 지적이 여러 개면 모두 고쳐 한 번에 커밋하고 **한 번만 푸시한다.** **그 푸시 바로 앞에** 본문이 있는 리뷰 수를 세어 기억해 둔다: `gh pr view {번호} --repo {저장소} --json reviews --jq '[.reviews[]|select((.body // "")|length > 0)]|length'`. 줄 단위 지적에 단 답글은 본문 없는 리뷰로 쌓이므로 세지 않는다. 그다음 `dobby_commit_push` 로 푸시한다. 자동 리뷰는 푸시 뒤 1~2분 안에 달리므로, 답글을 다 단 뒤에 세면 새 리뷰가 이미 들어가 있을 수 있다.
   - 고치지 않을 것: 이유를 정한다(설계 범위 밖, 의도된 동작 등).
4. 줄 단위 지적에는 그 지적에 답글을 단다. 팀 방식과 같게 쓴다.
   ```bash
   gh api repos/{저장소}/pulls/{번호}/comments/{지적 id}/replies -f body="반영했습니다({커밋 앞 10자리}). {무엇을 했는지}"
   ```
   고치지 않은 지적은 `반영하지 않았습니다. {이유}` 로 답한다. 본문에만 있는 지적은 `gh pr comment` 로 한 번에 답한다.
5. 고쳐 푸시했으면 새 리뷰를 한 번 더 기다려 2~4를 반복한다(최대 두 번). 이미 달린 리뷰 때문에 바로 돌아오지 않도록, 3에서 푸시 바로 앞에 센 수를 넘긴다: `dobby_ship_review_wait {작업 폴더} {번호} 540 {푸시 전 리뷰 수}`. 헬퍼도 이 인자를 받으면 본문이 있는 리뷰만 센다. `timeout` 이면 새 리뷰 없이 진행할지 사람에게 묻는다. 그 뒤에도 고칠 지적이 남으면 멈추고 사람에게 묻는다.
6. `dobby_app_release_record {키} {저장소} {출시 브랜치} "리뷰 반영" "#{번호}"`

## 5. 보고

저장소마다 한 줄로 알린다: PR 주소, 머지 여부, 모듈 버전 또는 앱 빌드 버전, QA 배포 결과. iOS 는 "로컬 시험 없음, PR 빌드 검사 통과" 를 함께 적는다. 상태 문서 `## 앱 출시` 표가 같은 내용을 담는다.
