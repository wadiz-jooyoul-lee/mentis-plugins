#!/usr/bin/env bash
# go-dobby 스폰 훅 — PreToolUse(Agent|Task)
#
# 목적: "스폰했는데 상태표에 행이 없는" 유령 에이전트를 원천 차단한다(C4).
#   기존에는 오케스트레이터가 dobby_agent_add를 손으로 쳐야 했고, 잊으면 조용히 유령이 남았다
#   (사례 FE1-1301: impl-fe-r6). 스폰은 절대 잊을 수 없으므로, 스폰 시점에 등록을 붙인다.
#
# 동작
#   1) 이 세션이 진행 중인 오더를 status.md의 세션 ID로 역추적한다 → 오더 키를 자동으로 안다.
#      (오더 세션이 아니면 아무것도 하지 않고 통과 — 일반 Agent 사용에 영향 없음)
#   2) description에서 슬러그를 읽는다: "{슬러그}: 설명" 또는 "{슬러그}#{라운드}: 설명"
#   3) 상태표에 그 행이 없으면 dobby_agent_add로 자동 등록하고 통과시킨다.
#   4) 오더 세션인데 슬러그 형식이 없으면 거절하고 형식을 알려준다.
#      (검사 제외가 필요하면 description 앞에 [skip-dobby] 를 붙인다)

set -u
command -v jq >/dev/null 2>&1 || exit 0
IN="$(cat 2>/dev/null)" || exit 0

TOOL="$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

DESC="$(printf '%s' "$IN" | jq -r '.tool_input.description // empty' 2>/dev/null)"
SID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SID" ] || exit 0
case "$DESC" in "[skip-dobby]"*) exit 0 ;; esac

CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0
: "${ORCHESTRATION_WORKSPACE:=$HOME/work/dobby-workspace}"
META="${ORCHESTRATION_META_PATH:-$ORCHESTRATION_WORKSPACE/meta}"
[ -d "$META" ] || exit 0

deny() { # $1=규칙ID $2=사유
  jq -n --arg r "go-dobby 훅 [$1] $2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# ── 1) 세션 ID로 이 세션이 맡은 오더 찾기 ────────────────────────────
KEY=""; n=0
for f in "$META"/*/status.md; do
  [ -f "$f" ] || continue
  if grep -q "$SID" "$f" 2>/dev/null; then KEY="$(basename "$(dirname "$f")")"; n=$((n+1)); fi
done
[ "$n" -eq 1 ] || exit 0   # 오더 세션이 아니거나 여러 오더가 걸리면 개입하지 않는다

# ── 2) description에서 슬러그·라운드 추출 ────────────────────────────
SLUG="$(printf '%s' "$DESC" | sed -nE 's/^([A-Za-z][A-Za-z0-9_.-]*)(#[0-9]+)?[[:space:]]*:.*/\1/p')"
RND="$(printf '%s' "$DESC" | sed -nE 's/^[A-Za-z][A-Za-z0-9_.-]*#([0-9]+)[[:space:]]*:.*/\1/p')"
REST="$(printf '%s' "$DESC" | sed -E 's/^[A-Za-z][A-Za-z0-9_.-]*(#[0-9]+)?[[:space:]]*:[[:space:]]*//')"

if [ -z "$SLUG" ]; then
  deny "G10" "오더 $KEY 진행 중인 세션의 스폰입니다. description을 '{슬러그}: {한 줄 설명}' 형식으로 쓰세요
  (재라운드면 '{슬러그}#{라운드}: …', 예: 'review-fe#6: 관심사 태그 제거 리뷰').
  상태표 등록·로그 기록이 이 형식에서 자동으로 이뤄집니다. 오더와 무관한 스폰이면 '[skip-dobby] …'."
fi

# 라운드 접미 슬러그는 유령의 원인 — 형식으로 유도한다
case "$SLUG" in
  *-r[0-9]|*-r[0-9][0-9]|*-round[0-9]|*-round[0-9][0-9])
    base="$(printf '%s' "$SLUG" | sed -E 's/-(r|round)[0-9]+$//')"
    rn="$(printf '%s' "$SLUG" | sed -E 's/.*-(r|round)([0-9]+)$/\2/')"
    deny "G10" "라운드 접미 슬러그 '$SLUG'는 유령 에이전트를 만듭니다. '${base}#${rn}: {설명}' 형식으로 쓰세요."
    ;;
esac

# 역할·상태를 슬러그로 추정(사람이 나중에 다듬을 수 있게 최소값만)
case "$SLUG" in
  review*|*-review*) NAME="리뷰어"; STATE="리뷰" ;;
  analy*|audit*|explore*) NAME="분석"; STATE="분석" ;;
  produce*|doc*) NAME="산출자"; STATE="구현" ;;
  *) NAME="개발자"; STATE="구현" ;;
esac
# ── G11: 설계 게이트 — 구현 단계(P4 이후)의 개발자 스폰은 design.md가 있어야 한다 ────
# P1 분석 스폰은 단계가 아직 착수/분석이라 걸리지 않는다(분석→구현이 같은 슬러그여도 안전).
# 산출자·리뷰어·비개발(산출물/작업정리) 오더는 대상이 아니다. 과거 오더의 P8 재개도 잡히며,
# 그때는 deny 안내대로 현 상태 캡처(design.md)를 먼저 만들면 된다.
if [ "$NAME" = "개발자" ] && [ ! -f "$META/$KEY/design.md" ]; then
  SF="$META/$KEY/status.md"
  PH="$(sed -nE 's/^- \*\*단계\*\*: *(.*)$/\1/p' "$SF" 2>/dev/null | head -1)"
  KIND="$(sed -nE 's/^- \*\*종류\*\*: *(.*)$/\1/p' "$SF" 2>/dev/null | head -1)"
  case "$PH" in
    구현*|리뷰*|테스트*|통합*)
      case "$KIND" in
        *산출*|*정리*) : ;;   # 비개발 오더는 설계 문서 대상이 아님
        *)
          deny "G11" "설계 문서 없이 구현 스폰 불가 — 오더 $KEY 에 design.md가 없습니다.
  먼저 설계를 만들고(/dobby-design $KEY — P3.5, 이미 진행 중인 작업의 편입·재개면 현 상태 캡처로 생성) 다시 스폰하세요.
  구현 에이전트는 착수 직후 dobby_design_ack $KEY {슬러그} 로 읽은 설계 버전을 서명합니다."
          ;;
      esac
      ;;
  esac
fi

# ── 3) 상태표에 없으면 자동 등록 ──────────────────────────────────────
OF="$META/$KEY/orchestration.md"
[ -f "$OF" ] || exit 0
if awk -v s="$SLUG" -F'|' '
      /^## /{ins=($0~/에이전트 상태표/)}
      ins&&/^\|/{gsub(/^[ \t]+|[ \t]+$/,"",$2); if($2==s) f=1}
      END{exit(f?0:1)}' "$OF"; then
  exit 0   # 이미 등록됨
fi




LIB=""
for c in "$HOME/.config/go-dobby/hooks/dobby-lib.sh" \
         "$(ls -1d "$HOME"/.claude/plugins/cache/*/go-dobby/*/reference/dobby-lib.sh 2>/dev/null | sort -V | tail -1)"; do
  [ -n "$c" ] && [ -f "$c" ] && LIB="$c" && break
done
[ -n "$LIB" ] || exit 0   # 헬퍼를 못 찾으면 막지 않고 통과(스폰이 우선)

# shellcheck disable=SC1090
( . "$CFG" >/dev/null 2>&1; . "$LIB" >/dev/null 2>&1
  # 메타 경로(ORCHESTRATION_META)는 dobby_load_config가 만든다 — 빠뜨리면 헬퍼가 조용히 실패한다
  dobby_load_config >/dev/null 2>&1
  dobby_agent_add "$KEY" "$SLUG" "$NAME" "${REST:-$DESC}" "$STATE" ${RND:+"$RND"} >/dev/null 2>&1 ) || true
exit 0
