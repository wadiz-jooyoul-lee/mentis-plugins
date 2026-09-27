#!/bin/bash
# go-dobby 안전 훅 — PreToolUse(Edit|Write)
#
# 저장소가 금지한 코드를 **쓰는 순간** 막는다. 커밋(dobby_repo_lint)이나 리뷰(dobby_blocking)
# 에서 잡으면 이미 다 짜 놓은 뒤라 되돌리는 비용이 크다. 여기서 막으면 그 자리에서 다른 걸 쓴다.
#
# 규칙표는 dobby-lib.sh 의 `_repo_rules` 하나를 공유한다 — 한 군데만 고치면
# 쓰기(이 훅)·커밋(dobby_repo_lint) 둘 다 따라온다.
#
# 검사 대상은 **새로 들어가는 글자**뿐이다.
#   Edit  → new_string
#   Write → content 중 **기존 파일에 없던 줄**(파일을 통째로 다시 쓸 때 옛 줄까지 잡지 않게)
#
# jq 가 없거나, 설정이 없거나, git 저장소가 아니거나, 그 저장소에 규칙이 없으면 조용히 통과한다.
set -u

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$FILE" ] || exit 0

CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0

deny() {
  jq -n --arg r "go-dobby 훅 [G14] $1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# ── 어느 저장소인가 ─────────────────────────────────────────────────────
# 새 파일은 폴더째 없을 수 있다 — 있는 조상 폴더까지 거슬러 올라간다.
# (이 가드가 없으면 새 폴더에 만드는 파일은 검사 없이 통과한다. 시험에서 잡혔다.)
DIR="$(dirname "$FILE")"
while [ ! -d "$DIR" ] && [ "$DIR" != "/" ] && [ -n "$DIR" ]; do
  DIR="$(dirname "$DIR")"
done
[ -d "$DIR" ] || exit 0
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] || exit 0
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
[ -n "$REPO" ] || exit 0

# ── 규칙표 (dobby-lib.sh 와 공유) ───────────────────────────────────────
LIB="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/reference/dobby-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck disable=SC1090
. "$LIB" >/dev/null 2>&1 || exit 0
command -v _repo_rules >/dev/null 2>&1 || exit 0
RULES="$(_repo_rules "$REPO" 2>/dev/null)"
[ -n "$RULES" ] || exit 0

# 규칙의 경로 조건은 저장소 루트 기준 상대 경로로 판정한다.
REL="${FILE#"$ROOT"/}"

# ── 새로 들어가는 글자만 뽑는다 ─────────────────────────────────────────
NEW=""
case "$TOOL" in
  Edit)
    NEW="$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)"
    ;;
  Write)
    CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)"
    if [ -f "$FILE" ]; then
      # 파일을 통째로 다시 쓸 때 원래 있던 줄까지 잡으면 오탐이다. 없던 줄만 본다.
      NEW="$(printf '%s\n' "$CONTENT" | grep -vxF -f "$FILE" 2>/dev/null)" || NEW="$CONTENT"
    else
      NEW="$CONTENT"
    fi
    ;;
  *) exit 0 ;;
esac
[ -n "$NEW" ] || exit 0

# ── 대조 ────────────────────────────────────────────────────────────────
# 규칙 한 줄: 정규식|경로조건|제외1|제외2|제외3|설명   (`-` 는 "적용 안 함")
# 규칙표 쪽에서 정규식에 `|` 를 쓰지 않기로 했다(쓰면 여기서 필드가 잘못 잘린다).
while IFS='|' read -r PAT SCOPE EX1 EX2 EX3 MSG; do
  [ -n "${PAT:-}" ] || continue
  [ "$SCOPE" = "-" ] || printf '%s' "$REL" | grep -qE "$SCOPE" || continue
  for EX in "$EX1" "$EX2" "$EX3"; do
    [ "$EX" = "-" ] && continue
    case "$REL" in *"$EX"*) continue 2 ;; esac
  done
  if printf '%s' "$NEW" | grep -qE "$PAT"; then
    deny "$REL — $MSG"
  fi
done <<EOF
$RULES
EOF

exit 0
