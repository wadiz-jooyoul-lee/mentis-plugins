#!/usr/bin/env bash
# go-dobby 안전 훅 — PreToolUse(Bash) 디스패처
#
# 스킬 문서의 ⛔ 규칙 중 "파괴·금지" 3종을 코드로 강제한다. 스킬 프롬프트가 어겨져도
# 여기서 마지막으로 막는 방어선이다(dobby-lib.sh 헬퍼를 안 거치고 생 명령을 칠 때 대비).
#   G1: 정식 배포 베이스($ORCHESTRATION_DEFAULT_BASE, 기본 master)로의 push·merge·PR 금지
#       (dobby-order C1 — master 반영은 사용자가 직접)
#   G5: dobby 워크스페이스 안에서 subtree/ 밖 폴더 제거 금지 (dobby-end 안전 경계)
#   G6: 메타 폴더($ORCHESTRATION_META) 삭제 금지 (비파괴 원칙 — 생명주기 기록 보존)
#
# 동작: stdin으로 받은 tool_input.command를 검사해, 위반이면 JSON(permissionDecision: deny)
#       으로 차단 사유를 돌려준다. 그 외에는 조용히 통과(exit 0). go-dobby 설정이 없는
#       환경(config.env 없음)에서는 아무것도 하지 않는다.

set -u

# ── 입력 파싱 (jq 없거나 파싱 실패면 개입하지 않음) ─────────────────────
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$CMD" ] || exit 0
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"

# ── go-dobby 설정 로드 (읽기 전용 · 없으면 미사용 환경이므로 통과) ──────
CFG="$HOME/.config/go-dobby/config.env"
[ -f "$CFG" ] || exit 0
# shellcheck disable=SC1090
. "$CFG" 2>/dev/null || exit 0
: "${ORCHESTRATION_WORKSPACE:=$HOME/work/dobby-workspace}"
: "${ORCHESTRATION_DEFAULT_BASE:=master}"
: "${ORCHESTRATION_REPOS_ROOT:=$HOME/work/repos}"
ORCHESTRATION_META="${ORCHESTRATION_META_PATH:-$ORCHESTRATION_WORKSPACE/meta}"

# ── 경로 비교용 정규화 사본 ─────────────────────────────────────────────
# 훅이 받는 명령 문자열은 셸이 "아직 펼치지 않은 원문"이다. 그래서 `~/work/...`나
# `$ORCHESTRATION_META/...`로 쓴 경로는 실경로와 글자가 달라 grep 비교가 전부 빗나간다.
# (실제로 G6이 이 구멍으로 뚫려 `rm -rf ~/work/orchestration-meta/{키}`가 통과했다.)
# 아래 사본은 물결표·환경변수 표기를 실경로로 펼친 것이며, 경로를 보는 규칙(G5·G6·
# in_dobby_scope)은 $CMD 대신 이것을 쓴다. 명령 "문법"을 보는 규칙(G1·G12)은 $CMD 그대로.
# 치환 순서 주의: 접두가 겹치는 변수는 긴 이름을 먼저 바꾼다(META_PATH → META).
CMDX="$(printf '%s' "$CMD" | sed \
  -e "s|[\$]{ORCHESTRATION_META_PATH}|$ORCHESTRATION_META|g" \
  -e "s|[\$]ORCHESTRATION_META_PATH|$ORCHESTRATION_META|g" \
  -e "s|[\$]{ORCHESTRATION_META}|$ORCHESTRATION_META|g" \
  -e "s|[\$]ORCHESTRATION_META|$ORCHESTRATION_META|g" \
  -e "s|[\$]{ORCHESTRATION_WORKSPACE}|$ORCHESTRATION_WORKSPACE|g" \
  -e "s|[\$]ORCHESTRATION_WORKSPACE|$ORCHESTRATION_WORKSPACE|g" \
  -e "s|[\$]{ORCHESTRATION_REPOS_ROOT}|$ORCHESTRATION_REPOS_ROOT|g" \
  -e "s|[\$]ORCHESTRATION_REPOS_ROOT|$ORCHESTRATION_REPOS_ROOT|g" \
  -e "s|[\$]{HOME}|$HOME|g" \
  -e "s|[\$]HOME|$HOME|g" \
  -e "s|~/|$HOME/|g")" || CMDX="$CMD"

# 차단 응답: 규칙 ID + 사유를 JSON으로 내보내고 종료 (exit 0 + deny JSON)
deny() {
  jq -n --arg r "go-dobby 훅 [$1] $2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# dobby 작업 맥락인가: cwd 또는 명령 문자열이 워크스페이스/저장소 루트를 가리키는가
in_dobby_scope() {
  case "$CWD" in
    "$ORCHESTRATION_WORKSPACE"*|"$ORCHESTRATION_REPOS_ROOT"*) return 0 ;;
  esac
  case "$CMDX" in
    *"$ORCHESTRATION_WORKSPACE"*|*"$ORCHESTRATION_REPOS_ROOT"*) return 0 ;;
  esac
  return 1
}

# ── G12. 설계 문서(design.md) 셸 덮어쓰기 금지 ──────────────────────────
# design.md는 사용자가 대시보드·편집기로 직접 고치는 유일한 메타 파일이다. 다른 메타처럼
# cat >·sed -i 로 덮어쓰면 사용자 수정본이 조용히 사라진다(config.env 사고와 같은 유형).
# 이미 있는 파일의 덮어쓰기만 막는다: 최초 생성(파일 없음)·append(>>)는 통과.
# 정당한 재생성은 dobby_design_backup(백업) 후 Write 도구로 쓰거나 DOBBY_FORCE=1.
case "$CMD" in
  *design.md*)
    if [ "${DOBBY_FORCE:-0}" != "1" ] && ! printf '%s' "$CMD" | grep -q "DOBBY_FORCE=1"; then
      TGT="$(printf '%s' "$CMD" | grep -oE "[^ '\"]*design\.md" | head -1)"
      case "$TGT" in /*) : ;; *) TGT="${CWD:+$CWD/}$TGT" ;; esac
      if [ -f "$TGT" ]; then
        if printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)(cat|tee|printf|echo)[^|;&]*[^>]>[[:space:]]*[^>][^|;&]*design\.md|sed[[:space:]]+-i[^|;&]*design\.md|perl[[:space:]]+-i[^|;&]*design\.md'; then
          deny G12 "design.md는 사용자가 직접 수정하는 문서라 셸로 덮어쓸 수 없다. 재생성이 필요하면 dobby_design_backup {키} 로 백업한 뒤 Write 도구로 쓰거나, 사용자가 시킨 경우에만 DOBBY_FORCE=1 로 우회하라."
        fi
      fi
    fi
    ;;
esac

# ── G6. 메타 폴더 삭제 금지 (가장 구체적인 규칙부터) ────────────────────
# dobby-end조차 메타는 지우지 않는다(워크트리만 제거). rm 계열이 메타 경로를 노리면 차단.
# 비교는 정규화 사본($CMDX)으로 한다 — 원문 $CMD는 `~`·`$HOME`이 안 펼쳐져 빗나간다.
# 예외 하나: 휴지통($ORCHESTRATION_META/.discarded/) 아래만 제거를 허용한다. dobby-discard가
# 폐기 조건(워크트리 없음·미푸시 0·코드 산출물 없음·아티팩트 미게시)을 검사하고 압축 백업을
# 만든 뒤 옮겨 둔 것이라, 그것을 비우는 것은 기록 파괴가 아니다. 메타 경로가 여러 개 섞이면
# 전부 휴지통 아래일 때만 통과시킨다(하나라도 살아 있는 오더면 차단).
case "$CMD" in
  *rm\ *|*rmdir\ *)
    if printf '%s' "$CMDX" | grep -qF "$ORCHESTRATION_META"; then
      NMETA="$(printf '%s' "$CMDX" | grep -oF "$ORCHESTRATION_META" | wc -l | tr -d ' ')"
      NTRASH="$(printf '%s' "$CMDX" | grep -oF "$ORCHESTRATION_META/.discarded/" | wc -l | tr -d ' ')"
      if [ "${NTRASH:-0}" -eq 0 ] || [ "${NMETA:-0}" -ne "${NTRASH:-0}" ]; then
        deny G6 "메타 폴더($ORCHESTRATION_META)는 삭제 금지다. 오더 기록은 생명주기 원본이라 dobby-end도 워크트리만 제거하고 메타는 보존한다. 필요 없는 오더를 없애려면 /dobby-discard {키} 로 폐기하라(조건 검사·백업 후 휴지통으로 옮긴다)."
      fi
    fi
    # cwd가 메타 안이면 상대경로 rm도 같은 폴더를 노린다(`cd {메타}/{키} && rm -rf .`).
    case "$CWD" in
      "$ORCHESTRATION_META"/.discarded/*) : ;;
      "$ORCHESTRATION_META"|"$ORCHESTRATION_META"/*)
        deny G6 "현재 폴더가 메타($ORCHESTRATION_META) 안이라 rm 대상이 오더 기록일 수 있다. 메타 안에서는 삭제하지 않는다. 필요 없는 오더는 /dobby-discard {키} 로 폐기하라." ;;
    esac
    ;;
esac

# ── G5. subtree 밖 파괴 금지 (dobby-end 안전 경계) ──────────────────────
# 워크트리 정리는 $ORCHESTRATION_WORKSPACE/subtree/ 하위만 대상이다.
# (1) git worktree remove 대상이 워크스페이스 안인데 subtree/ 밖이면 차단
# (2) rm -r(f) 대상이 워크스페이스 안인데 subtree/ 밖이거나, 원본 소스 루트를 노리면 차단
case "$CMD" in
  *worktree\ remove*)
    if printf '%s' "$CMDX" | grep -qF "$ORCHESTRATION_WORKSPACE" \
       && ! printf '%s' "$CMDX" | grep -qF "$ORCHESTRATION_WORKSPACE/subtree/"; then
      deny G5 "워크트리 제거는 $ORCHESTRATION_WORKSPACE/subtree/ 하위만 허용된다(dobby-end 안전 경계). 대상 경로를 확인하라."
    fi
    ;;
  *rm\ -r*|*rm\ -f*)
    # 메타가 워크스페이스 안에 있는 설정이면(예: WORKSPACE=$HOME/work, META=$HOME/work/
    # orchestration-meta) 휴지통도 이 규칙 관할에 들어온다. 폐기 휴지통은 G6이 이미
    # "전부 휴지통 아래일 때만" 통과시키는 좁은 예외를 검사했으므로 여기서도 허용한다.
    if printf '%s' "$CMDX" | grep -qF "$ORCHESTRATION_WORKSPACE" \
       && ! printf '%s' "$CMDX" | grep -qF "$ORCHESTRATION_WORKSPACE/subtree/" \
       && ! printf '%s' "$CMDX" | grep -qF "$ORCHESTRATION_META/.discarded/"; then
      deny G5 "rm 대상이 dobby 워크스페이스 안인데 subtree/ 밖이다. 워크스페이스 정리는 subtree/ 하위만 허용된다(dobby-end 안전 경계)."
    fi
    if printf '%s' "$CMDX" | grep -qE "rm[^|;&]*[[:space:]]${ORCHESTRATION_REPOS_ROOT}(/[^[:space:]]*)?([[:space:]]|$)"; then
      deny G5 "원본 소스 저장소($ORCHESTRATION_REPOS_ROOT)는 rm 대상이 될 수 없다. go-dobby는 워크트리(subtree/)에서만 작업한다."
    fi
    ;;
esac

# ── G1. 정식 배포 베이스로의 push·merge·PR 금지 ─────────────────────────
# dobby 작업 맥락에서만 적용한다(다른 프로젝트의 정상 워크플로에 개입하지 않기 위해).
if in_dobby_scope; then
  BASE="$ORCHESTRATION_DEFAULT_BASE"

  # (1) git push ... <base> / HEAD:<base> — 베이스 브랜치로의 직접 push
  if printf '%s' "$CMD" | grep -qE "git[^|;&]*[[:space:]]push[^|;&]*[[:space:]:]${BASE}([[:space:]]|$)"; then
    deny G1 "정식 배포 베이스($BASE)로의 push는 금지다(dobby-order C1). 자기 브랜치(bugfix/·feature/)에만 푸시하고, $BASE 반영은 사용자가 직접 PR로 한다."
  fi

  # (2) gh pr create --base <base> / -B <base> — 베이스 대상 PR 생성
  if printf '%s' "$CMD" | grep -qE "gh[[:space:]]+pr[[:space:]]+create" \
     && printf '%s' "$CMD" | grep -qE "(--base|-B)[[:space:]=]+${BASE}([[:space:]]|$)"; then
    deny G1 "정식 배포 베이스($BASE)로의 PR 생성은 금지다(dobby-order C1). $BASE 반영은 사용자가 직접 한다."
  fi

  # (3) gh pr merge — dobby 흐름의 브랜치 통합은 git(dobby_merge_root)으로만 한다
  if printf '%s' "$CMD" | grep -qE "gh[[:space:]]+pr[[:space:]]+merge"; then
    deny G1 "gh pr merge는 dobby 흐름에서 금지다. 에이전트→루트 통합은 dobby_merge_root(git merge)로, $BASE 머지는 사용자가 직접 한다."
  fi

  # (4) git merge — 현재 체크아웃이 베이스 브랜치면 베이스로의 머지이므로 차단
  if printf '%s' "$CMD" | grep -qE "git[^|;&]*[[:space:]]merge([[:space:]]|$)" && [ -n "$CWD" ]; then
    CUR="$(git -C "$CWD" branch --show-current 2>/dev/null || true)"
    if [ "$CUR" = "$BASE" ]; then
      deny G1 "현재 브랜치가 정식 배포 베이스($BASE)다. 베이스로의 머지는 금지(dobby-order C1) — 루트/에이전트 브랜치에서 작업하라."
    fi
  fi
fi

exit 0
