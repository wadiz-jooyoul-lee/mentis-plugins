#!/usr/bin/env bash
# dobby-qa 작업 세션 기동 — 폴링 세션이 편입 버그를 직접 고치지 않고 새 프로세스에 맡긴다.
#
# 한 번 = `claude -p "/dobby-qa {루트키} work"` 한 번. 수정·리뷰·배포·검증·Jira 보고 기록이
# 폴링 세션 문맥에 쌓이지 않게 하려는 것이다. 띄우기만 하고 바로 돌아온다(끝나길 기다리지 않는다).
#
# 사용법: work.sh {루트키}
#   출력 한 줄: started {pid} | running {pid}
#
# 잠금: qa/work.pid. 작업 폴더(bugfix/{루트키}-QA)가 하나라 작업 세션은 동시에 하나만 돈다.
# MCP: 크롬 도구 하나만 붙인다(run.sh 와 같은 근거). 그래서 작업 세션에는 슬랙이 없다 — 알림은 폴링 세션이 보낸다.
set -uo pipefail

die() { printf 'dobby-qa 작업 세션 기동 실패: %s\n' "$1" >&2; exit 1; }

KEY="${1:-}"; [ -n "$KEY" ] || die "루트키를 주세요. 예: work.sh FE1-1234"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f ~/.config/go-dobby/config.env ] || die "go-dobby 초기 설정이 없습니다. 먼저 /dobby-init 을 실행하세요"
# shellcheck disable=SC1090
source ~/.config/go-dobby/config.env
# shellcheck disable=SC1091
source "$HERE/../../reference/dobby-lib.sh" >/dev/null 2>&1
dobby_load_config >/dev/null || die "설정을 읽지 못했습니다(/dobby-init 확인)"
command -v jq >/dev/null || die "jq 가 필요합니다(brew install jq)"

Q="$ORCHESTRATION_META/$KEY/qa"
mkdir -p "$Q"
PID_FILE="$Q/work.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  printf 'running %s\n' "$(cat "$PID_FILE")"; exit 0
fi

mcp=()
MCP_CFG="${TMPDIR:-/tmp}/dobby-mcp-$KEY-qa.json"
PROFILE="$HOME/.cache/dobby-chrome/$KEY-qa"
if jq -e '.mcpServers["chrome-devtools"]' ~/.claude.json >/dev/null 2>&1 \
   && jq --arg p "$PROFILE" '{mcpServers: {"chrome-devtools": (.mcpServers["chrome-devtools"]
        | .args = ([(.args // [])[] | select(. != "--isolated")] + ["--userDataDir", $p]))}}' ~/.claude.json >"$MCP_CFG" 2>/dev/null; then
  mcp=(--strict-mcp-config --mcp-config "$MCP_CFG")
fi

CONSENT="이 실행은 사용자가 /dobby-qa $KEY 로 시작한 QA 루프의 작업 세션이다. 사람이 지켜보지 않는다. \
dobby-qa 절차에 적힌 bugfix/$KEY-QA 커밋·푸시, 루트 브랜치 머지, dev·rc1·rc4 의 PR·머지·빌드는 이미 동의를 받았으니 묻지 말고 진행한다. \
stage·cloud_live 는 이 동의에 들어가지 않는다. 사람 판단이 필요하면 묻지 말고 그 버그만 보류해 결과 파일에 적는다."

cd "$ORCHESTRATION_WORKSPACE" 2>/dev/null || cd "$HOME"
nohup bash -c '
  out="$(claude -p "/dobby-qa $1 work" --append-system-prompt "$2" "${@:5}" --permission-mode auto --output-format json 2>/dev/null)"
  sid="$(printf "%s" "$out" | jq -r ".session_id // empty" 2>/dev/null)"
  printf "%s\n" "${sid:-알 수 없음}" >"$(dirname "$3")/work-session.txt"
  rm -rf "$4"; rm -f "$3"
' _ "$KEY" "$CONSENT" "$PID_FILE" "$PROFILE" ${mcp[@]+"${mcp[@]}"} >/dev/null 2>&1 &
printf '%s\n' "$!" >"$PID_FILE"
printf 'started %s\n' "$!"
