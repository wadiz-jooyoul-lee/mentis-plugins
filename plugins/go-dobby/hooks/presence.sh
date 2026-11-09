#!/usr/bin/env bash
# go-dobby 작업 표시 훅 — UserPromptSubmit·Stop·SessionEnd. 오더를 잡은 세션의 표시 상태를 대화 차례마다 고친다.
# 표시는 dobby-lib.sh 의 _presence_claim 이 만든다. 이 훅은 만들지 않는다. 절대 막지 않는다(항상 exit 0)

set -u
command -v jq >/dev/null 2>&1 || exit 0
IN="$(cat 2>/dev/null)" || exit 0

CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0
META="${ORCHESTRATION_META_PATH:-${ORCHESTRATION_WORKSPACE:-$HOME/work/dobby-workspace}/meta}"

SID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SID" ] || exit 0
F="$META/.presence/$SID.json"
[ -f "$F" ] || exit 0

set_state() {
  jq --arg s "$1" --arg t "$(date '+%Y-%m-%d %H:%M')" '.state = $s | .since = $t' "$F" > "$F.tmp" 2>/dev/null \
    && mv "$F.tmp" "$F"
}

case "$(printf '%s' "$IN" | jq -r '.hook_event_name // empty')" in
  UserPromptSubmit) set_state working ;;
  Stop)
    if printf '%s' "$IN" | jq -r '.last_assistant_message // empty' | grep -q '이 세션을 닫아 주세요'; then
      set_state done
    elif [ "$(printf '%s' "$IN" | jq '.background_tasks // [] | length')" -gt 0 ]; then
      set_state working   # 백그라운드 작업이 끝나면 세션이 다시 깨어난다
    else
      set_state waiting
    fi ;;
  SessionEnd) rm -f "$F" ;;
esac
exit 0
