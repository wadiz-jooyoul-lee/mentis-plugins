#!/usr/bin/env bash
# go-dobby 입력 검사 훅 — UserPromptSubmit
#
#   G19: 문맥이 큰 세션에서 go-dobby 명령(/do, /dobby-*)을 새로 시작하지 못하게 막는다.
#        세션이 길수록 호출 한 번이 그때까지 쌓인 문맥을 통째로 다시 읽는다.
#        (실측 2026-10-19: 문맥 52만 세션에서 이어 한 릴리즈 1회가 1,801만 토큰. 다른 세션의 같은 일은 약 450만)
#   G20: /do 가 "이 세션을 닫아 주세요"로 끝난 뒤 들어온 일반 요청에 경고만 붙인다(막지 않음).
#
# 끄기: config.env 에 DOBBY_PROMPT_GUARD=off. 기준값: DOBBY_PROMPT_GUARD_CTX(기본 250000).
# 이 기준은 run.sh 의 이어 쓰기 상한 DOBBY_REUSE_MAX_CTX(120000)보다 커야 한다.
# 그래야 자동 실행이 --resume 으로 이어 쓰는 세션을 이 훅이 막지 않는다.
set -u
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0
CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0
[ "${DOBBY_PROMPT_GUARD:-on}" = off ] && exit 0
MAX="${DOBBY_PROMPT_GUARD_CTX:-250000}"

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty')"
TR="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
[ -n "$TR" ] && [ -f "$TR" ] || exit 0   # 새 세션은 기록 파일이 없다 — 검사할 것이 없다

# 마지막 응답의 문맥 크기(입력 + 캐시 읽기 + 캐시 쓰기). 기록은 늦게 써질 수 있어 한 번 전 값일 수 있다.
TAIL="$(tail -n 400 "$TR")"
CTX="$(printf '%s\n' "$TAIL" | jq -R 'fromjson? | select(.type=="assistant") | .message.usage // empty
  | (.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0)' 2>/dev/null | tail -1)"
CTX="${CTX:-0}"

case "$PROMPT" in
  /do\ *|/do|/go-dobby:*|/dobby-*)
    if [ "$CTX" -ge "$MAX" ]; then
      jq -n --arg r "go-dobby 훅 [G19] 이 세션의 문맥이 약 $((CTX / 1000))천 토큰입니다(기준 $((MAX / 1000))천). 여기서 새 단계를 시작하면 호출마다 이 문맥을 다시 읽어 비용이 몇 배로 늘어납니다. /clear 로 세션을 비우거나 새 터미널에서 같은 명령을 다시 입력해 주세요." \
        '{decision:"block", reason:$r}'
    fi
    exit 0 ;;
  /*) exit 0 ;;
esac

# 직전 응답이 /do 의 세션 닫기 안내였는가 (공통 규칙 "세션을 닫는 법" 의 고정 문구)
LAST="$(printf '%s\n' "$TAIL" | jq -R -c 'fromjson? | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tail -1)"
case "$LAST" in
  *"이 세션을 닫아 주세요"*)
    jq -n --arg m "[go-dobby] 이 세션의 /do 단계는 끝났습니다(문맥 약 $((CTX / 1000))천 토큰). 오더와 무관한 일은 새 세션에서 하면 호출마다 이만큼 덜 읽습니다." \
      --arg c "직전 /do 단계는 끝났다. 이 요청이 그 오더의 수정 지시면 /do 의 변경 접수로 받는다. 오더와 무관한 일이면 하기 전에 새 세션에서 하도록 한 줄로 권한다." \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}' ;;
esac
exit 0
