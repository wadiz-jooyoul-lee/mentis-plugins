#!/usr/bin/env bash
# /do 자동 실행 장치 — 설계가 확정된 오더를 단계마다 새 세션으로 끝까지 돌린다.
#
# 한 단계 = `claude -p "/do {키}"` 한 번. 실행이 끝나면 프로세스가 사라지므로
# 사람이 /clear 할 일이 없다. 단계가 끝날 때마다 세션 아이디를 이벤트 로그에 남긴다
# (세션 안에서도 dobby_session_log 가 상태 문서의 '## 지난 세션' 표에 남긴다).
#
# 사용법:
#   run.sh {키} [--mode {권한모드}] [--max {최대 세션 수}] [--with-test] [--approve-commit]
#     --mode       claude 의 --permission-mode 값. 기본 auto.
#     --max        이번 실행에서 띄울 세션 수 상한. 기본 10, auto 배포 오더는 20. 열린 회차를 잇는 검증 묶음 세션은 하나씩 더한다.
#     --with-test  통합 뒤 검증까지 돈다. 기본은 통합에서 멈춘다(검증은 배포가 끝난 뒤에야 의미가 있다). TASK- 작업에는 듣지 않는다.
#     --approve-commit  사람이 커밋·푸시를 미리 승인한 실행. 세션마다 그 승인을 지시로 덧붙여 통합 세션이 묻고 멈추지 않게 한다.
#
# auto 배포 오더: 상태 문서에 `- **자동 배포 환경**: {env}` 줄이 있으면(설계 세션이 `/do {키} auto env=` 로 적는다)
# 통합에서 멈추지 않고 배포 세션 → 검증 세션까지 간다. 리뷰봇·빌드는 세션이 아니라 이 셸이 기다리고,
# 배포 승인 지시를 세션마다 덧붙이며, 멈출 때는 이벤트 로그에 남겨 대시보드가 알린다(설계: auto-mode.md).
#
# 세션 이어 쓰기: 기본은 단계마다 새 세션이다. 다음 일이 '수정'이고, 직전 세션의 마지막 문맥이
# DOBBY_REUSE_MAX_CTX 이하이며(dobby-lib.sh), 직전 호출 뒤 DOBBY_REUSE_MAX_GAP 초가 지나지 않았을 때만 직전 세션을
# `claude -p --resume` 으로 이어 쓴다(근거: session-reuse.md).
#
# MCP: 세션마다 크롬 도구 하나만 붙인다(--strict-mcp-config).
#
# 역할별 모델: ~/.config/go-dobby/role-models.json 에 {"developer": "claude-opus-5-5", ...} 가 있으면 차례 담당자의 역할 모델을
# `claude -p --model` 로 넘긴다. 담당자 슬러그로 역할을 가른다(analysis-agent 기획자, review-agent 리뷰어, deploy-agent 배포담당,
# test-agent 테스터, 나머지 개발자). 파일이 없거나 그 역할 값이 없으면 --model 없이 기본 모델로 돈다.
#
# 다음 할 일: 차례마다 dobby_v2_step 이 정한다(/do 세션·훅과 같은 판정). 설계·설계 확인·판단 답 차례면 사람이 할 일이라 멈춘다.
# 단계 밖 변경: 차례마다 dobby_v2_drift_apply 로 /do 밖에서 바뀐 설계·코드를 먼저 본다. 설계가 바뀌었으면 멈추고,
# 코드만 바뀌었으면 리뷰부터 잇는다. 이 셸이 띄운 세션이 끝나면 기준점을 남긴다(dobby_v2_checkpoint).
#
# 진행 표시: 상태 문서에 `- **자동 실행**:` 줄을 둔다. 실행 중에는 pid·시작 시각·세션 수를, 끝나면 "끝 — 이유" 또는
# "멈춤 — 이유" 를 적는다. 세션이 상태를 정리하지 않고 끝나면 dobby_v2_reconcile 이 작업중 행을 대기로 돌린다.
#
# 멈추는 경우:
#   dobby-order 가 만든 메타 · 설계 미확정 · 판단 답 차례(보류) · 통합 완료(--with-test 없고 auto 배포 오더도 아닐 때)
#   · TASK- 작업의 PR 머지 차례 · 검증 전부 통과 · 배포 표의 막힘(⚠)
#   · 끝난 오더 · 모르는 단계값 · 단계 밖 설계 변경
# 부탁(ask.json)이 열리면 끝내지 않고 셸에서 기다린다 — argocd 로그인 풀림, 리뷰봇·빌드 30분 지연, 세션이 남긴 부탁.
#   대시보드 카드에서 답하면 이어 가고, "멈추기"·8시간 무응답·기다리는 사이 사람이 손대면 끝낸다.
#   · 세션이 끝났는데 아무것도 바뀌지 않음(사람 판단이 필요해 스킬이 멈춘 것) · 세션 오류 · 상한 도달
set -uo pipefail

die() { END_NOTE="자동 실행 중단: $1"; END_KIND=멈춤; printf '%s\n' "$END_NOTE" >&2; exit "${2:-1}"; }
finish() { END_NOTE="$1"; END_KIND=끝; echo "$END_NOTE"; exit 0; }
END_KIND=멈춤

KEY="${1:-}"; [ -n "$KEY" ] && shift || die "오더 키를 주세요. 예: run.sh FE1-1234"
MODE=auto; MAX=""; WITH_TEST=0; APPROVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    --with-test) WITH_TEST=1; shift ;;
    --approve-commit) APPROVE=1; shift ;;
    *) die "모르는 인자: $1" ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f ~/.config/go-dobby/config.env ] || die "go-dobby 초기 설정이 없습니다. 먼저 /dobby-init 을 실행하세요"
# shellcheck disable=SC1090
source ~/.config/go-dobby/config.env
# shellcheck disable=SC1091
source "$HERE/../../reference/dobby-lib.sh" >/dev/null 2>&1
dobby_load_config >/dev/null || die "설정을 읽지 못했습니다(/dobby-init 확인)"
command -v jq >/dev/null || die "jq 가 필요합니다(brew install jq)"

D="$ORCHESTRATION_META/$KEY"
[ -f "$D/status.md" ] || die "$KEY 의 메타가 없습니다. 먼저 터미널에서 /do $KEY 로 설계를 확정하세요"

phase() { sed -nE 's/^- \*\*단계\*\*: *(.*)$/\1/p' "$D/status.md" | head -1; }
# v2 오더의 표지는 '## 지난 세션' 표다(설계 세션이 1-1 에서 dobby_session_log 로 만든다).
# 없으면 dobby-order 가 만든 메타다 — 두 스킬이 한 오더를 번갈아 맡지 않는다.
grep -q '^## 지난 세션' "$D/status.md" || [ "$(phase)" = 착수 ] \
  || die "$KEY 는 dobby-order 로 진행한 오더입니다. dobby-order 로 이어가거나 /dobby-migrate-v2 $KEY 로 옮기세요"
# 터미널 세션이 이 오더를 작업 중이면(작업 표시) 겹쳐 돌지 않는다.
[ "$(_v2_presence "$KEY")" = working ] \
  && die "터미널 세션이 $KEY 를 작업 중입니다. 그 세션이 끝난 뒤 다시 실행하세요(작업 표시: $ORCHESTRATION_META/.presence)"

AUTO_ENV="$(dobby_v2_env "$KEY")"
[ -n "$MAX" ] || { [ -n "$AUTO_ENV" ] && MAX=20 || MAX=10; }
# auto 배포 오더는 멈출 때 사람에게 알린다. 사람이 지켜보지 않는 실행이기 때문이다.
stop() {
  if [ -n "$AUTO_ENV" ]; then dobby_v2_notify "$KEY" "자동 실행 멈춤 — $1" >/dev/null
  else dobby_event "$KEY" "자동 실행 멈춤 — $1" 2>/dev/null; fi
  die "$1"
}

ask_open() { [ -f "$D/ask.json" ] && [ -z "$(jq -r '.answer.value // empty' "$D/ask.json" 2>/dev/null)" ]; }
# 열린 부탁에 답이 오거나 확인이 통과할 때까지 기다린다. 답이 오면 0 을 돌려주고, 아니면 여기서 끝낸다.
wait_ask() {
  printf '사람의 답을 기다립니다 — %s · %s\n' "$(jq -r .title "$D/ask.json")" "$(date '+%H:%M')"
  case "$(dobby_v2_ask_wait "$KEY")" in
    answered|passed) printf '답을 받아 이어 갑니다 · %s\n' "$(date '+%H:%M')"; return 0 ;;
    stop)    die "부탁 카드에서 멈추기를 골랐습니다" ;;
    changed) die "기다리는 사이 설계·코드가 바뀌었거나 터미널 세션이 이 오더를 잡아 끝냈습니다" ;;
    *)       stop "부탁에 8시간 동안 답이 없었습니다. 대시보드 카드를 보고 /do $KEY 로 이어 가세요" ;;
  esac
}
# 리뷰봇·빌드가 30분을 넘으면 더 기다릴지 묻는다. "30분 더 기다리기"면 그 대상의 한도를 30분 늘린다.
ext_tgt=""; ext_lim=0
ask_delay() {
  dobby_v2_ask "$KEY" choice "$1" "$2" "$3" "30분 더 기다리기,멈추기" >/dev/null
  wait_ask
  dobby_v2_ask_close "$KEY" "30분 더"
  ext_tgt="$tgt"; ext_lim=$(( el + 1800 ))
}

# 세션 한 번이 무엇이든 남겼는지 보는 지문 — 단계, 리뷰·검증 폴더 목록, 주요 문서의 수정 시각, 배포 표.
fingerprint() {
  {
    phase
    sed -n '/^## 배포[[:space:]]*$/,/^## /p' "$D/status.md"
    find "$D/reviews" "$D/test-runs" 2>/dev/null | sort
    for f in design.md design-ack.json implementation.md outcome.md; do
      [ -f "$D/$f" ] && stat -f '%m %N' "$D/$f" 2>/dev/null
    done
    for f in "$D"/test-runs/*/result.md; do
      [ -f "$f" ] && stat -f '%m %N' "$f" 2>/dev/null
    done
  } | shasum | cut -c1-12
}

WT="$(_order_worktree "$KEY")"
[ -n "$WT" ] && [ -d "$WT" ] || WT="$PWD"

# 자동 실행 세션에는 크롬 도구 MCP 하나만 붙인다. 검증 단계만 브라우저를 쓰고 나머지 단계는 MCP 를 쓰지 않는다.
# 연결 도구까지 다 붙으면 첫 호출 문맥이 42,648, 크롬 도구만이면 35,454 다(2026-10-19 실측). 근거: token-diet.md 작업 C.
# --strict-mcp-config 는 claude.ai 연결 도구(슬랙·메일)도 뺀다.
# 크롬 도구 설정은 사람마다 경로가 달라 ~/.claude.json 에서 그대로 옮겨 온다. 없으면 제한 없이 실행한다.
# 브라우저 프로필은 오더마다 하나다. 검증 묶음 세션끼리 로그인이 이어지고, 동시에 도는 다른 오더와는 부딪히지 않는다.
mcp=()
MCP_CFG="${TMPDIR:-/tmp}/dobby-mcp-$KEY.json"
PROFILE="$HOME/.cache/dobby-chrome/$KEY"
# 사무실에 이 실행을 작업 단위 하나로 알린다. 끝날 때(멈춤·오류·완료 모두) 서류철이 캐비닛으로 간다
UBY=auto; [ -n "$AUTO_ENV" ] && UBY=full
dobby_unit_start "$KEY" "$UBY" "$UBY:$$"
STARTED="$(date '+%m-%d %H:%M')"
mark() { _dobby_locked "$KEY" _v2_set_line "$KEY" "자동 실행" "실행 중 · pid $$ · 시작 $STARTED · 세션 $1"; }
mark 0
trap 'rm -rf "$PROFILE"; _dobby_locked "$KEY" _v2_set_line "$KEY" "자동 실행" "$END_KIND — ${END_NOTE:-자동 실행이 끝났습니다}"; dobby_v2_reconcile "$KEY"; dobby_unit_end "$KEY" "$UBY" "${END_NOTE:-자동 실행이 끝났습니다}" "$UBY:$$"' EXIT
if jq -e '.mcpServers["chrome-devtools"]' ~/.claude.json >/dev/null 2>&1 \
   && jq --arg p "$PROFILE" '{mcpServers: {"chrome-devtools": (.mcpServers["chrome-devtools"]
        | .args = ([(.args // [])[] | select(. != "--isolated")] + ["--userDataDir", $p]))}}' ~/.claude.json >"$MCP_CFG" 2>/dev/null; then
  mcp=(--strict-mcp-config --mcp-config "$MCP_CFG")
else
  dobby_event "$KEY" "자동 실행 MCP 제한 못 함 — ~/.claude.json 에 chrome-devtools 설정이 없어 모든 MCP 를 붙인 채 실행" 2>/dev/null
fi

CONSENT="이 실행은 사용자가 커밋과 푸시를 미리 승인한 자동 실행이다(대시보드 '자동 실행' 확인 창 또는 --approve-commit). \
/do 통합 단계에서 오더 작업 브랜치에 커밋하고 푸시하는 것은 이미 동의를 받았으니 다시 묻지 말고 진행한다. \
정식 배포 브랜치로의 PR·머지·배포는 이 승인에 들어가지 않는다."
SHIP_CONSENT="이 실행은 사용자가 $AUTO_ENV 배포를 미리 승인한 자동 실행이다. dev·rc1·rc4 의 머지·빌드·argocd sync 는 \
이미 동의를 받았으니 다시 묻지 말고 진행한다. stage·cloud_live 는 이 승인에 들어가지 않는다. \
리뷰봇이나 빌드를 세션 안에서 기다리지 않는다. \`## 배포\` 표에 \`리뷰 대기\`·\`배포 대기\` 를 적고 세션을 끝낸다."
sys=""
[ "$APPROVE" = 1 ] && sys="$CONSENT"
[ -n "$AUTO_ENV" ] && sys="${sys:+$sys
}$SHIP_CONSENT"
extra=(); [ -n "$sys" ] && extra=(--append-system-prompt "$sys")

ROLE_MODELS="$HOME/.config/go-dobby/role-models.json"
role_model() {
  local role=developer
  case "$1" in analysis-agent) role=planner ;; review-agent) role=reviewer ;; deploy-agent) role=deployer ;; test-agent) role=tester ;; esac
  [ -f "$ROLE_MODELS" ] && jq -r --arg r "$role" '.[$r] // empty | strings | select(test("^claude-[a-z0-9-]+$"))' "$ROLE_MODELS" 2>/dev/null
}

n=0; sid=""; noted=""
while :; do
  ask_open && wait_ask
  [ "$(dobby_v2_drift_apply "$KEY")" = design ] \
    && stop "단계 밖에서 설계 문서가 바뀌었습니다. 터미널에서 /do $KEY 로 바뀐 설계를 확인해 주세요"
  ph="$(phase)"
  # 자동 배포 오더의 배포 차례 — 리뷰봇·빌드는 세션이 아니라 이 셸이 기다린다.
  if [ -n "$AUTO_ENV" ] && [ "$ph" = 배포 ]; then
    dobby_ship_reopen "$KEY" >/dev/null
    # 결과를 먼저 받고 나눈다. `IFS=… read <<<"$(…)"` 로 쓰면 괄호 안 함수까지 탭 구분자를 물려받는다.
    nx="$(dobby_v2_ship_next "$KEY")"
    IFS=$'\t' read -r what repo tgt since <<<"$nx"
    el=$(( $(date +%s) - $(_v2_epoch "${since:-}" || date +%s) ))
    case "$what" in
      blocked)
        # argocd 로그인이 풀려 막혔으면 사람에게 로그인을 부탁하고, 로그인되면 막힘 표시를 지우고 이어 간다.
        asrv="$(_ship_argo_server "$AUTO_ENV")"
        if [ "$repo" = com.wadiz.web ] && [ -n "$asrv" ] \
           && ! argocd account get-user-info --server "$asrv" --grpc-web 2>/dev/null | grep -q 'Logged In: *true'; then
          dobby_v2_ask "$KEY" action "argocd 로그인이 필요합니다 ($AUTO_ENV)" \
            "com.wadiz.web 을 $AUTO_ENV 에 동기화하려는데 argocd 로그인이 풀려 있습니다. 회사 통합 로그인(SSO)이라 대신 할 수 없습니다" \
            "터미널에서 실행: argocd login $asrv --sso --grpc-web" \
            "argocd account get-user-info --server $asrv --grpc-web | grep -q 'Logged In: *true'" >/dev/null
          wait_ask
          bst="$(_v2_ship_row "$KEY" "$repo" "$AUTO_ENV" | cut -d$'\037' -f1)"
          CLAUDE_CODE_SESSION_ID= dobby_ship_stage "$KEY" "$repo" "$AUTO_ENV" "${bst% ⚠}" >/dev/null   # 셸 기록이라 작업 표시를 잡지 않는다
          continue
        fi
        dobby_agent_state "$KEY" deploy-agent 막힘 "" "배포 막힘 — $repo $AUTO_ENV: $tgt" "상태 문서 배포 표의 비고를 보고 처리한 뒤 /do $KEY" >/dev/null
        stop "배포가 막혔습니다($repo $AUTO_ENV): $tgt. 상태 문서 '## 배포' 표의 비고를 보고 처리한 뒤 /do $KEY 로 이어 가세요" ;;
      wait-review)
        lim=1800; [ "$ext_tgt" = "$tgt" ] && lim=$ext_lim
        [ "$el" -lt "$lim" ] || { ask_delay "리뷰봇 리뷰가 $((el / 60))분째 없습니다 ($repo $AUTO_ENV PR $tgt)" \
          "자동 코드리뷰가 와야 머지로 넘어갑니다" "PR 에 리뷰어(wadiz-fe/fe1-team)가 붙었는지 확인해 주세요"; continue; }
        if [ "$el" -ge 600 ] && [ "$noted" != "$tgt" ]; then
          dobby_v2_notify "$KEY" "리뷰 지연 — $repo $AUTO_ENV PR $tgt 에 리뷰봇 리뷰가 10분째 없습니다. 30분까지 기다립니다." >/dev/null
          noted="$tgt"
        fi
        dobby_v2_wait_mark "$KEY" "$repo" wait-review "$tgt" $((el / 60))
        printf '리뷰봇 리뷰를 기다립니다(%s PR %s, %d분째) · %s\n' "$repo" "$tgt" $((el / 60)) "$(date '+%H:%M')"
        sleep 120; continue ;;
      wait-build)
        lim=1800; [ "$ext_tgt" = "$tgt" ] && lim=$ext_lim
        [ "$el" -lt "$lim" ] || { ask_delay "빌드가 $((el / 60))분째 끝나지 않았습니다 ($repo $AUTO_ENV run $tgt)" \
          "빌드가 끝나야 배포 확인으로 넘어갑니다" "터미널에서 확인: gh run view $tgt"; continue; }
        dobby_v2_wait_mark "$KEY" "$repo" wait-build "$tgt" $((el / 60))
        printf '빌드를 기다립니다(%s run %s, %d분째) · %s\n' "$repo" "$tgt" $((el / 60)) "$(date '+%H:%M')"
        sleep 60; continue ;;
    esac
  fi
  st="$(dobby_v2_step "$KEY")"
  IFS=$'\t' read -r stg slug desc _ <<<"$st"
  case "$stg" in
    멈춤)
      case "$slug" in
        검증을\ 전부\ 통과*|끝난\ 오더*|PR\ 이\ 머지*|PR\ 머지\ 차례*) finish "$slug" ;;
      esac
      stop "$slug" ;;
    설계)
      [ "$ph" = 보류 ] && stop "판단이 필요해 멈춰 있습니다. 설계 문서 '확인이 필요했던 것'을 보고 터미널에서 /do $KEY 로 답해 주세요"
      stop "설계가 끝나지 않았습니다. 터미널에서 /do $KEY 로 설계를 확정하세요" ;;
    설계확인) stop "설계가 확정되지 않았습니다. 터미널에서 /do $KEY 로 설계를 보고 답해 주세요" ;;
    구현|리뷰|수정|통합|배포|실패분석) ;;
    검증)
      # 배포 확인 전(단계 배포)이면 검증은 배포 뒤에야 의미가 있다. 사람이 배포를 마쳐 단계가 검증이면 돈다.
      if [ -z "$AUTO_ENV" ] && [ "$WITH_TEST" != 1 ] && [ "$ph" = 배포 ]; then
        finish "통합까지 끝났습니다. 배포한 뒤 run.sh $KEY --with-test 또는 /do $KEY 로 검증하세요."
      fi
      # 열린 회차를 잇는 세션은 다음 검증 묶음이다. 묶음마다 세션 하나라 상한에 하나씩 더해 센다.
      _testrun_open "$KEY" >/dev/null && MAX=$((MAX + 1)) ;;
    *) stop "다음 할 일을 정하지 못했습니다: ${st:-빈 값}" ;;
  esac
  [ "$n" -lt "$MAX" ] || stop "세션 상한(${MAX}개)에 닿았습니다. 상태 문서를 확인하세요"

  n=$((n + 1))
  before="$(fingerprint)"
  resume=(); how="새 세션"
  if [ -n "$sid" ] && [ "$stg" = 수정 ]; then
    if r="$(dobby_v2_reuse_ok "$KEY" "$sid")"; then
      resume=(--resume "$sid"); how="직전 세션 이어 쓰기(문맥 ${r%%$'\t'*}, ${r##*$'\t'}초 전)"
    else
      how="새 세션(직전 세션이 이어 쓰기 기준을 넘음)"
    fi
  fi
  model=(); m="$(role_model "$slug")"; [ -n "$m" ] && model=(--model "$m")
  mark "$n"
  printf '\n━━ %s · 세션 %d · %s 차례(%s) · %s · 모델 %s · %s\n' "$KEY" "$n" "$stg" "$desc" "$how" "${m:-기본}" "$(date '+%H:%M')"
  out="$(cd "$WT" && claude -p ${resume[@]+"${resume[@]}"} "/do $KEY" ${extra[@]+"${extra[@]}"} ${mcp[@]+"${mcp[@]}"} ${model[@]+"${model[@]}"} --permission-mode "$MODE" --output-format json 2>/dev/null)"
  code=$?
  sid="$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)"
  err="$(printf '%s' "$out" | jq -r '.is_error // false' 2>/dev/null)"
  printf '%s\n' "$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)"
  denied="$(printf '%s' "$out" | jq -r '.permission_denials[]?.tool_input.command // empty' 2>/dev/null)"
  [ -n "$denied" ] && printf '권한이 막혀 실행하지 못한 명령:\n%s\n' "$denied"

  dobby_v2_reconcile "$KEY"
  dobby_event "$KEY" "자동 실행 세션 $n 종료 — $stg 차례, 지금 단계 $(phase), ${how}, 세션 ${sid:-알 수 없음}" 2>/dev/null
  printf '━━ 세션 %d 끝 · 세션 아이디 %s · 지금 단계 %s\n' "$n" "${sid:-알 수 없음}" "$(phase)"

  [ "$code" -eq 0 ] && [ "$err" != "true" ] || stop "세션이 오류로 끝났습니다(종료 코드 $code). 복기: claude --resume ${sid:-?}"
  # 세션이 부탁을 남기고 끝났으면 멈추지 않는다 — 다음 차례 맨 앞에서 답을 기다린다.
  ask_open && { dobby_v2_checkpoint "$KEY" >/dev/null 2>&1; continue; }
  [ "$(fingerprint)" != "$before" ] || stop "세션이 아무것도 바꾸지 못했습니다. 사람 판단이 필요해 멈췄을 수 있습니다. 복기: cd $WT && claude --resume ${sid:-?}"
  dobby_v2_checkpoint "$KEY" >/dev/null 2>&1
done
