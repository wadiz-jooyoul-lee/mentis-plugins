#!/usr/bin/env bash
# go-dobby 스폰 훅 — PostToolUse(Agent|Task)
#
# 목적: agent-logs.json 기록을 사람 손에서 뗀다.
#   기존에는 스폰 결과의 output_file을 오케스트레이터가 dobby_log로 손수 적었고, 그 과정에서
#   라운드 인자를 빠뜨려 새 슬러그로 우회하는 사고가 났다(FE1-1301: impl-fe-r6).
#   PostToolUse는 tool_response.outputFile을 그대로 넘겨주므로 자동 기록이 가능하다(검증 완료).
#
# 동작: 오더 세션이면 description의 슬러그로 dobby_log 실행. 절대 차단하지 않는다(항상 exit 0).
#   경로는 심볼릭 링크(/tmp/claude-*/…/tasks/*.output) 대신 실체(~/.claude/projects/…)로 적는다
#   — tmp가 정리되면 링크가 끊기기 때문.

set -u
command -v jq >/dev/null 2>&1 || exit 0
IN="$(cat 2>/dev/null)" || exit 0

TOOL="$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

DESC="$(printf '%s' "$IN" | jq -r '.tool_input.description // empty' 2>/dev/null)"
SID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
OUT="$(printf '%s' "$IN" | jq -r '.tool_response.outputFile // empty' 2>/dev/null)"
[ -n "$SID" ] && [ -n "$OUT" ] || exit 0
case "$DESC" in "[skip-dobby]"*) exit 0 ;; esac

CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0
: "${ORCHESTRATION_WORKSPACE:=$HOME/work/dobby-workspace}"
META="${ORCHESTRATION_META_PATH:-$ORCHESTRATION_WORKSPACE/meta}"
[ -d "$META" ] || exit 0

KEY=""; n=0
for f in "$META"/*/status.md; do
  [ -f "$f" ] || continue
  if grep -q "$SID" "$f" 2>/dev/null; then KEY="$(basename "$(dirname "$f")")"; n=$((n+1)); fi
done
[ "$n" -eq 1 ] || exit 0

SLUG="$(printf '%s' "$DESC" | sed -nE 's/^([A-Za-z][A-Za-z0-9_.-]*)(#[0-9]+)?[[:space:]]*:.*/\1/p')"
RND="$(printf '%s' "$DESC" | sed -nE 's/^[A-Za-z][A-Za-z0-9_.-]*#([0-9]+)[[:space:]]*:.*/\1/p')"
[ -n "$SLUG" ] || exit 0

# 심볼릭 링크 → 실체 경로(끊기지 않는 경로를 기록한다)
REAL="$OUT"
if [ -L "$OUT" ]; then
  t="$(readlink "$OUT" 2>/dev/null)"
  case "$t" in /*) [ -f "$t" ] && REAL="$t" ;; esac
fi

LIB=""
for c in "$HOME/.config/go-dobby/hooks/dobby-lib.sh" \
         "$(ls -1d "$HOME"/.claude/plugins/cache/*/go-dobby/*/reference/dobby-lib.sh 2>/dev/null | sort -V | tail -1)"; do
  [ -n "$c" ] && [ -f "$c" ] && LIB="$c" && break
done
[ -n "$LIB" ] || exit 0

# shellcheck disable=SC1090
( . "$CFG" >/dev/null 2>&1; . "$LIB" >/dev/null 2>&1
  # 메타 경로(ORCHESTRATION_META)는 dobby_load_config가 만든다 — 빠뜨리면 헬퍼가 조용히 실패한다
  dobby_load_config >/dev/null 2>&1
  if [ -n "$RND" ]; then dobby_log "$KEY" "$SLUG" "$REAL" "round-$RND" >/dev/null 2>&1
  else dobby_log "$KEY" "$SLUG" "$REAL" >/dev/null 2>&1; fi ) || true
exit 0
