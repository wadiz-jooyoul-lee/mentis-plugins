# Jira 는 twg 로 다룬다 (go-dobby 공통)

Jira 조회와 쓰기는 MCP 대신 `twg` 명령으로 한다. MCP 보다 결과가 훨씬 작다.
(상태 전환: MCP 호출 2번 약 1만 2천 자, twg 1번 57자. 2026-10-19 FE1-2197 실측)

⛔ 조회 명령에는 **반드시 결과를 줄이는 옵션을 붙인다.** 옵션 없는 `get` 은 2만 6천 자, 이슈 2개 `bulk-get` 은 17만 자다.
옵션이 없으면 안전 훅(G18)이 막는다.

⛔ `--select` 는 **`--fields` 와 함께** 쓴다. `--select` 경로가 틀리면 조용히 무시되고 전체 결과(12만 자)가 나온다.
`--fields` 가 있으면 틀려도 그 칸만큼(2천 자 안팎)만 나온다.

`dobby_jira_*` 헬퍼는 `source "${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh"` 뒤에 부른다.

## 명령표

| 할 일 | 명령 | 결과 |
|---|---|---|
| 제목·상태·유형·상위·레이블 | `twg jira workitem get {키} --fields summary,status,issuetype,parent,labels` | 약 1.6천 자 |
| 설명 본문 | `dobby_jira_desc {키}` (화면) 또는 `dobby_jira_desc {키} {파일}` | 마크다운. FE1-2140 1,872자 |
| 칸 몇 개 확인 | `twg jira workitem get {키} --fields customfield_10015,labels` | 1천 자 안팎 |
| 진행 중으로 전환 | `dobby_jira_start_transition {키}` | `changed`·`already`·`done`·`failed` 한 낱말 |
| 다른 상태로 전환 | `twg jira workitem transitions query --id {키}` 로 도착 상태 번호를 보고 `twg jira workitem transition --id {키} --transition-id {번호}` | 552자 + 57자 |
| 칸 값 바꾸기 | `twg jira workitem update --id {키} --field {칸}={값}` (비우기는 `--field {칸}=null`) | 43자 |
| 레이블 더하기 | `twg jira workitem update --id {키} --add-labels {a},{b}` | 19자. 결과에 레이블이 안 나오므로 다시 조회해 확인 |
| 코멘트 목록 | `twg jira workitem comment query --issue-id {키} -o json --output-summary none --output-file {파일}` 뒤 파일에서 필요한 것만 `jq` 로 읽는다 | 코멘트 1개에 약 1.9천 자 |
| 코멘트 달기 | `twg jira workitem comment create --issue-id {키} --body-format markdown --body "…" -o json --output-summary none --select data.id` | 388자. 번호는 `.data.id` |
| 코멘트 고치기 | `twg jira workitem comment update --id {코멘트 번호} --issue-id {키} --body-format markdown --body "…"` | |
| 설명 고치기 | `twg jira workitem update --id {키} --description-format markdown --description "…"` | |
| JQL 검색 | `twg jira workitem query --jql "…" --fields summary,status,assignee --limit 20` | 이슈 수에 비례 |
| 첨부 목록 | `twg jira workitem attachment query --issue-id {키}` | |
| 첨부 받기 | `twg jira workitem attachment download --attachment-id {번호} --output-path {파일}` | |

전환 목록은 도착 상태가 분류(해야 할 일, 진행 중, 완료)별로 묶여 나온다. JSON 으로 받으면 `.data.transitions[]` 에 `id`, `toName`, `category` 가 있다.

## 레이블은 더하기만 한다

`--add-labels` 는 기존 레이블을 지우지 않는다. "기존 + 새것" 목록을 만들어 통째로 넣을 필요가 없다.

## 실패하면

twg 가 없거나 인증이 안 되면 `twg auth status` 결과를 보고에 적고 멈춘다. MCP 로 되돌아가지 않는다.
