#!/usr/bin/env bash
# go-dobby 오피스 알림 훅 — PostToolUse(Edit|Write|Bash)
# 오더 세션이 도구를 쓸 때마다 "지금 하는 일" 한 줄을 오피스로 보낸다. 절대 막지 않는다(항상 exit 0)

set -u
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
IN="$(cat 2>/dev/null)" || exit 0

CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0
URL="${ORCHESTRATION_OFFICE_INBOX:-http://127.0.0.1:6898/dobby}"
[ "$URL" = off ] && exit 0
META="${ORCHESTRATION_META_PATH:-${ORCHESTRATION_WORKSPACE:-$HOME/work/dobby-workspace}/meta}"

SID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$IN" | jq -r '.cwd // empty' 2>/dev/null)"
TOOL="$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null)"
[ -n "$SID" ] || exit 0

# 오더 키: 상태 문서에 이 세션 아이디가 적힌 오더, 없으면 작업 폴더 이름의 키
KEY="$(grep -l -- "$SID" "$META"/*/status.md 2>/dev/null | head -1 | xargs -I{} dirname {} | xargs -I{} basename {})"
if [ -z "$KEY" ]; then
  KEY="$(printf '%s' "$CWD" | grep -oE '/subtree/[^/]+-([A-Za-z][A-Za-z0-9]*-[0-9]+|TASK-[A-Za-z0-9-]+)' | grep -oE '([A-Za-z][A-Za-z0-9]*-[0-9]+|TASK-[A-Za-z0-9-]+)$' | head -1)"
fi
[ -n "$KEY" ] && [ -f "$META/$KEY/status.md" ] || exit 0

case "$TOOL" in
  Edit|Write) WHAT="$TOOL $(printf '%s' "$IN" | jq -r '.tool_input.file_path // empty' | xargs basename 2>/dev/null)" ;;
  Bash) WHAT="Bash $(printf '%s' "$IN" | jq -r '.tool_input.description // .tool_input.command // empty' | head -1 | cut -c1-60)" ;;
  *) exit 0 ;;
esac

BODY="$(jq -nc --arg key "$KEY" --arg session "$SID" --arg text "$WHAT" '{kind:"doing",key:$key,session:$session,text:$text}')"
( curl -s -o /dev/null --max-time 1 -X POST -H 'content-type: application/json' --data-binary "$BODY" "$URL" >/dev/null 2>&1 & ) 2>/dev/null
exit 0
