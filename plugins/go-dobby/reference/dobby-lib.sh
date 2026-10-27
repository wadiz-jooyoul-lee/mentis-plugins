#!/usr/bin/env bash
# go-dobby 공용 헬퍼 — 오케스트레이션의 "판단이 필요 없는 결정론적 단계"(git·파일·메타 갱신)를
# 함수로 고정해 매번 동일하게 실행하고, 상태 파일 전체 통독을 없애 토큰을 아낀다.
#
# ⛔ 이 스크립트는 기계적 작업만 한다. 분석·구현·리뷰·문서 "내용"은 절대 만들지 않는다
#    (그건 LLM 몫). 값(이름/설명/커밋 메시지 등)은 전부 인자로 받는다.
# ⛔ config.env는 읽기 전용(수정은 dobby-init 전용).
# 의존성: bash, git, awk, jq(선택 — agent-logs). 사용법: `source dobby-lib.sh` 후 dobby_* 호출.
#
# 시각은 테스트 재현을 위해 DOBBY_NOW / DOBBY_TS 로 덮어쓸 수 있다.

_now() { printf '%s' "${DOBBY_NOW:-$(date '+%Y-%m-%d %H:%M')}"; }
_ts()  { printf '%s' "${DOBBY_TS:-$(date '+%Y%m%d-%H%M%S')}"; }
_die() { printf 'dobby-lib: %s\n' "$*" >&2; return 1; }

# 이 파일이 있는 폴더 — 옆에 둔 스크립트(dobby-meta-backup.sh)를 부를 때 쓴다.
# 설치 위치가 플러그인 캐시(버전별 폴더)라 절대 경로를 박을 수 없다.
DOBBY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || DOBBY_LIB_DIR=""

# ── 상태 어휘 정본(대시보드 파서와 동일 규칙) ─────────────────────────
# 상태 표기가 스킬·실행마다 흔들리지 않도록, 값을 적는 함수(dobby_phase·dobby_agent_state·
# dobby_agent_add)가 들어온 단어를 아래 정본으로 자동 교정한다. 규칙·순서는 대시보드
# (parseOrchestration.ts normAgentState / parseOrderStatus.ts phaseKey)와 정확히 일치시켜,
# 기록 파일 자체가 항상 대시보드가 읽는 값과 같게 유지한다.
#   · 에이전트 상태(orchestration.md 상태표): 대기·분석·구현·리뷰·완료 (5)
#   · 오더 단계(status.md 현재 단계):         착수·분석·구현·리뷰·통합·검증·해결·종료 (8)
# 막지 않고 조용히 접되(파이프라인 비차단), 교정이 일어나면 stderr에 경고 한 줄을 남긴다.
DOBBY_STATES="대기 분석 구현 리뷰 완료"
DOBBY_PHASES="착수 분석 구현 리뷰 통합 검증 해결 종료"

_trim() { printf '%s' "${1//\*/}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# dobby_norm_state VALUE — 에이전트 상태값을 5정본으로 접는다(정본이면 그대로).
dobby_norm_state() {
  local s out; s="$(_trim "$1")"
  case "$s" in
    *완료*|*재통합*) out=완료 ;;
    *수정*|*반영*)   out=구현 ;;
    *리뷰*)          out=리뷰 ;;
    *산출*|*구현*)   out=구현 ;;
    *분석*|*진행*)   out=분석 ;;
    *대기*)          out=대기 ;;
    *)               out="${s%%[(（]*}"; out="$(_trim "$out")"; out="${out:-미상}" ;;
  esac
  [ "$out" != "$s" ] && printf 'dobby-lib: 상태값 교정 "%s" → "%s"\n' "$s" "$out" >&2
  printf '%s' "$out"
}

# dobby_norm_phase VALUE — 오더 단계값을 8정본으로 접는다(모르는 값은 원문 유지).
dobby_norm_phase() {
  local s out; s="$(_trim "$1")"
  case "$s" in
    *종료*)        out=종료 ;;
    *해결*)        out=해결 ;;
    *검증*)        out=검증 ;;
    *통합*)        out=통합 ;;
    *리뷰*|*수정*) out=리뷰 ;;
    *구현*|*산출*) out=구현 ;;
    *분석*)        out=분석 ;;
    *착수*)        out=착수 ;;
    *)             out="$s" ;;
  esac
  [ -n "$s" ] && [ "$out" != "$s" ] && printf 'dobby-lib: 단계값 교정 "%s" → "%s"\n' "$s" "$out" >&2
  printf '%s' "$out"
}

# ── 환경 로드 (읽기 전용) ─────────────────────────────────────────────
dobby_load_config() {
  local cfg="$HOME/.config/go-dobby/config.env"
  if [ ! -f "$cfg" ]; then
    printf 'go-dobby 설정이 없습니다. 먼저 /dobby-init 을 실행하세요.\n' >&2
    return 3
  fi
  # shellcheck disable=SC1090
  . "$cfg"
  : "${ORCHESTRATION_WORKSPACE:=$HOME/work/dobby-workspace}"
  : "${ORCHESTRATION_DEFAULT_BASE:=master}"
  : "${ORCHESTRATION_REPOS_ROOT:=$HOME/work/repos}"
  export ORCHESTRATION_META="${ORCHESTRATION_META_PATH:-$ORCHESTRATION_WORKSPACE/meta}"
  dobby_check_deps
}

# dobby_check_deps — 최초 실행 시 jq 확인. 없으면 설치 가이드 안내(하드 실패 아님).
# jq는 agent-logs.json 병합(dobby_log)에 쓴다 — JSON은 파서로 안전하게 다뤄야 하므로(awk 손파싱은
# 인라인 {}·compact·따옴표에서 깨져 데이터가 사라진다) jq를 쓴다.
dobby_check_deps() {
  command -v jq >/dev/null 2>&1 && return 0
  {
    printf '⚠️ go-dobby: jq 가 필요합니다 — agent-logs.json 기록(dobby_log)에 씁니다.\n'
    case "$(uname -s)" in
      Darwin) printf '   설치: brew install jq\n' ;;
      Linux)  printf '   설치: sudo apt-get install -y jq   (또는 sudo yum install jq / dnf install jq)\n' ;;
      *)      printf '   설치: https://jqlang.github.io/jq/download/ 참고\n' ;;
    esac
    printf '   설치 후 다시 실행하세요.\n'
  } >&2
  return 0
}

_meta() { printf '%s' "${ORCHESTRATION_META:?ORCHESTRATION_META 미설정 — dobby_load_config 먼저}"; }
_order_dir() { printf '%s/%s' "$(_meta)" "$1"; }

# dobby_docs_search "키워드1|키워드2|..."  — 착수 시(Explore·코드 분석 전) 참고 문서 위치를 빠르게 잡는다.
# $ORCHESTRATION_DOCS_ROOT(없으면 $ORCHESTRATION_REPOS_ROOT/docs)에서 키워드로 grep해 관련 문서 경로만 출력(내용 X, 최대 20개).
# 히트 없거나 루트가 없으면 조용히 빈 출력(0 반환) — 그대로 코드 분석으로 진행하면 된다.
dobby_docs_search() {
  local kw="$1" root
  root="${ORCHESTRATION_DOCS_ROOT:-${ORCHESTRATION_REPOS_ROOT:-$HOME/work/repos}/docs}"
  [ -n "$kw" ] || return 0
  # 루트 폴더 부재(미설정/오설정)면 stderr로 보이게 알린다 — 정상 no-hit(폴더 있음+0건)와 구분.
  # stdout은 빈 채로, exit 0(흐름은 그대로 코드 분석 진행). 오설정이 조용히 묻히지 않게.
  if [ ! -d "$root" ]; then
    printf 'dobby-lib: docs 루트 없음(%s) — 착수 docs 검색 건너뜀. ORCHESTRATION_DOCS_ROOT 확인 권장\n' "$root" >&2
    return 0
  fi
  grep -rilE "$kw" "$root" 2>/dev/null | head -20
}

# dobby_docs_gate KEY "kw1|kw2"  — 착수 docs 게이트(차단·강제). DOCS_ROOT에서 관련 문서를 찾아
# $META/{key}/docs-refs.md에 결과를 기록하고, 히트 경로를 stdout으로 반환한다.
# ⛔ 이 파일이 있어야 Explore/분석으로 넘어갈 수 있다. 히트가 있으면 오케스트레이터는 그 문서를 '먼저' 읽는다.
# 루트 없음/히트 없음도 "확인함"으로 파일에 남겨(조용한 스킵 방지) 게이트를 통과시킨다.
# 다시 부르면 검색 결과는 새로 쓰되, 워크트리를 만들 때 붙은 '## 워크트리 규약 — {repo}' 절은 그대로 옮겨 둔다.
# 그 절은 워크트리를 새로 만들 때만 붙고(_docs_refs_worktree), 기존 워크트리를 다시 쓸 때는 다시 붙지 않기 때문이다.
dobby_docs_gate() {
  local key="$1" kw="$2" f root hits keep=""
  f="$(_order_dir "$key")/docs-refs.md"; mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && keep="$(awk '/^## /{k=(index($0,"## 워크트리 규약 — ")==1)} k' "$f")"
  root="${ORCHESTRATION_DOCS_ROOT:-${ORCHESTRATION_REPOS_ROOT:-$HOME/work/repos}/docs}"
  {
    printf '# %s — 착수 docs 확인\n\n' "$key"
    printf -- '- **검색 루트**: %s\n' "$root"
    printf -- '- **키워드**: %s\n\n' "$kw"
  } > "$f"
  if [ ! -d "$root" ]; then
    printf '## 결과\n- DOCS_ROOT 없음 — docs 없이 코드 분석 진행(설정 확인 권장)\n' >> "$f"
    printf 'dobby-lib: docs 루트 없음(%s) — docs 없이 진행\n' "$root" >&2
  else
    hits="$(dobby_docs_search "$kw")"
    if [ -z "$hits" ]; then
      printf '## 결과\n- 히트 없음 — 관련 문서 없음, 코드 분석 진행\n' >> "$f"
    else
      { printf '## 결과 (먼저 읽을 문서)\n'; printf '%s\n' "$hits" | sed 's/^/- /'; } >> "$f"
    fi
  fi
  [ -n "$keep" ] && printf '\n%s\n' "$keep" >> "$f"
  [ -n "$hits" ] && printf '%s\n' "$hits"
  return 0
}

# ── 메타 스캐폴딩 ─────────────────────────────────────────────────────
# dobby_scaffold_meta KEY [TITLE]  — 폴더 + 골격 status.md(없을 때만)
dobby_scaffold_meta() {
  local key="$1" title="${2:-$1}" kw="${3:-}" dir; dir="$(_order_dir "$key")"
  mkdir -p "$dir/agents" "$dir/reviews" || return 1
  if [ ! -f "$dir/status.md" ]; then
    cat > "$dir/status.md" <<EOF
# $key

## 이슈/작업
- **제목**: $title

## 현재 단계
- **단계**: 착수
- **갱신**: $(_now)
EOF
  fi
  # ⛔ docs 게이트 자동 실행(C): 진입 첫 필수 헬퍼에서 키워드가 주어지면 docs-refs.md를
  # 즉시 생성해, Explore·분석·팬아웃보다 먼저 문서 확인이 이뤄지도록 강제한다.
  # (키워드 미전달 시엔 파일이 안 생기고, 이후 dobby_setup_worktree(B)에서 차단된다.)
  if [ -n "$kw" ]; then
    local hits; hits="$(dobby_docs_gate "$key" "$kw")"
    [ -n "$hits" ] && printf 'dobby-lib: docs 게이트 히트 — 팬아웃/Explore 전에 먼저 읽으세요:\n%s\n' "$hits" >&2
  fi
}

# dobby_ensure_board KEY — orchestration.md 골격(상태표 헤더 + 이벤트 로그) 없을 때만
dobby_ensure_board() {
  local key="$1" f; f="$(_order_dir "$key")/orchestration.md"
  [ -f "$f" ] && grep -q '^## 에이전트 상태표' "$f" && return 0
  mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then printf '# %s 오케스트레이션\n\n' "$key" > "$f"; fi
  cat >> "$f" <<'EOF'
## 에이전트 상태표
| 슬러그 | 이름 | 설명 | 상태 | 라운드 | 착수 | 갱신 |
|--------|------|------|------|--------|------|------|

## 이벤트 로그
EOF
}

# ── 상태표(orchestration.md) ─────────────────────────────────────────
# dobby_agent_add KEY SLUG NAME DESC STATE [ROUND] — 행 append(있으면 무시). 활성상태면 착수=now.
dobby_agent_add() {
  local key="$1" slug="$2" name="$3" desc="$4" st rd="${6:-1}"
  st="$(dobby_norm_state "$5")"
  local f now; f="$(_order_dir "$key")/orchestration.md"; now="$(_now)"
  dobby_ensure_board "$key"
  # 이미 존재하면 no-op
  awk -F'|' -v s="$slug" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^\|/ && t($2)==s {found=1} END{exit(found?0:1)}' "$f" && return 0
  local at=""; case "$st" in 분석|구현|리뷰) at="$now";; esac
  local row="| $slug | $name | $desc | $st | $rd | $at | $now |"
  awk -v row="$row" '
    /^## 에이전트 상태표/ {inblk=1; print; next}
    inblk==1 && /^\|/ {print; seen=1; next}
    inblk==1 && seen==1 && ins==0 {print row; ins=1; inblk=0; print; next}
    {print}
    END{ if(inblk==1 && seen==1 && ins==0) print row }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# _board_role OFILE SLUG — 상태표에서 그 슬러그의 '이름(롤)' 칸을 출력(없으면 빈 문자열).
_board_role() {
  awk -F'|' -v want="$2" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/\*/,"",x);return x}
    /^## /{ins=($0~/에이전트 상태표/)?1:0;hdr=0;next}
    ins==1 && /^\|/{
      if(hdr==0){for(i=1;i<=NF;i++){c=t($i);if(c=="슬러그"||c=="에이전트")cs=i;else if(c=="이름")cn=i}
                 if(cs)hdr=1;next}
      if(cs && cn && t($cs)==want){print t($cn);exit}
    }' "$1" 2>/dev/null
}

# dobby_agent_state KEY SLUG STATE [ROUND] [DESC] — 그 행 상태/갱신(+라운드·설명을 주면 그 칸도) 수정. 비활성→활성 진입 시 착수 갱신.
dobby_agent_state() {
  local key="$1" slug="$2" st rd="${4:-}" desc="${5:-}"
  st="$(dobby_norm_state "$3")"
  local f now; f="$(_order_dir "$key")/orchestration.md"; now="$(_now)"

  # ── G13: 설계 게이트 — 개발자가 '구현'으로 전이할 때 design.md가 없으면 거부 ──
  # 스폰 훅(G11)은 Agent 도구 호출만 잡는다. 그런데 go-dobby의 기본 경로는 **분석 에이전트가
  # 그대로 구현으로 이어가는 것**(dobby-order C9, SendMessage)이라 새 스폰이 없고, 훅이 발화할
  # 기회 자체가 없다(사례 FE1-1732: 설계 없이 구현·리뷰·통합까지 완주). 상태를 '구현'으로 바꾸는
  # 이 함수는 어느 경로든 반드시 지나므로 여기서 막는다.
  # 제외: 비개발 오더(산출물·작업정리), 리뷰어·산출자 역할. 우회는 DOBBY_FORCE=1.
  if [ "$st" = "구현" ] && [ "${DOBBY_FORCE:-0}" != "1" ] && [ ! -f "$(_order_dir "$key")/design.md" ]; then
    local _kind _role
    _kind="$(sed -nE 's/^- \*\*종류\*\*: *(.*)$/\1/p' "$(_order_dir "$key")/status.md" 2>/dev/null | head -1)"
    _role="$(_board_role "$f" "$slug")"
    case "$_kind" in
      *산출*|*정리*) : ;;                       # 비개발 오더는 설계 문서 대상이 아님
      *)
        case "$_role" in
          *리뷰*|*산출*) : ;;                   # 리뷰어·산출자는 대상 아님
          *)
            _die "설계 문서 없이 '구현' 전이 불가 — $key 에 design.md가 없습니다.
  P3.5에서 설계를 확정한 뒤 구현으로 넘어갑니다(/dobby-design $key — 이미 진행 중이면 현 상태 캡처로 생성).
  구현 에이전트는 착수 직후 dobby_design_ack $key $slug 로 읽은 설계 버전을 서명합니다.
  (정말 예외라면 DOBBY_FORCE=1 로 우회)"
            return 1
            ;;
        esac
        ;;
    esac
  fi
  # 헤더 인식형: `## 에이전트 상태표` 헤더에서 상태/라운드/착수/갱신 컬럼 위치를 찾아 그 칸만 수정한다.
  # (오더마다 상태표 스키마가 달라 컬럼 위치를 하드코딩하면 엉뚱한 칸을 덮어써 표가 깨진다.)
  awk -F'|' -v OFS='|' -v slug="$slug" -v st="$st" -v rd="$rd" -v now="$now" -v desc="$desc" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    BEGIN{ins=0;hdr=0;ci_slug=0;ci_st=0;ci_rd=0;ci_start=0;ci_up=0;ci_desc=0}
    /^## / { ins=($0 ~ /에이전트 상태표/)?1:0; hdr=0; print; next }
    ins==1 && /^\|/ {
      if (hdr==0) {
        for(i=1;i<=NF;i++){c=t($i)
          if(c=="슬러그")ci_slug=i; else if(c=="상태")ci_st=i
          else if(c=="라운드")ci_rd=i; else if(c=="착수")ci_start=i; else if(c=="갱신")ci_up=i
          else if(c=="설명")ci_desc=i}
        if(ci_slug>0 && ci_st>0) hdr=1
        print; next
      }
      issep=1; for(i=2;i<NF;i++){c=t($i); if(c!="" && c !~ /^-+$/){issep=0;break}}
      if(issep){print;next}
      if(t($(ci_slug))==slug){
        old=t($(ci_st)); ost=(ci_start>0)?t($(ci_start)):"x"
        active=(st=="분석"||st=="구현"||st=="리뷰"||st=="검증")
        if(ci_start>0 && active && (old=="대기"||old=="완료"||old==""||ost=="")) $(ci_start)=" " now " "
        $(ci_st)=" " st " "
        if(ci_rd>0 && rd!="") $(ci_rd)=" " rd " "
        if(ci_desc>0 && desc!="") $(ci_desc)=" " desc " "
        if(ci_up>0) $(ci_up)=" " now " "
      }
      print; next
    }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  # 상태 전이는 타임라인 사건 → 전이할 때마다 이벤트 자동 기록(밀도 일관화, 끄기: DOBBY_AUTO_EVENT=0)
  _dobby_autoevent "$key" "$slug → $st${rd:+ (라운드 $rd)}"
}

# dobby_event KEY TEXT — 이벤트 로그에 `- {now} TEXT` append(섹션 없으면 만든다).
dobby_event() {
  local key="$1" text="$2" f line; f="$(_order_dir "$key")/orchestration.md"
  [ -f "$f" ] || dobby_ensure_board "$key"
  grep -q '^## 이벤트 로그' "$f" || printf '\n## 이벤트 로그\n' >> "$f"
  line="$(printf -- '- %s %s' "$(_now)" "$text")"
  awk -v line="$line" '
    /^## 이벤트 로그/ {inlog=1; print; next}
    inlog==1 && /^## / {print line; inlog=0; print; next}
    {print}
    END{ if(inlog==1) print line }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ── agent-logs.json ──────────────────────────────────────────────────
# dobby_log KEY SLUG PATH [ROUND] — 스폰 로그 경로 기록(jq로 안전 병합).
# 라운드 있으면 {슬러그:{round-N:경로}}로 중첩, 없으면 {슬러그:"경로"}. jq가 없으면 설치 가이드 후 건너뜀.
dobby_log() {
  local key="$1" slug="$2" p="$3" rd="${4:-}"
  local f; f="$(_order_dir "$key")/agent-logs.json"
  command -v jq >/dev/null 2>&1 || { dobby_check_deps; _die "jq 없음 — agent-logs 기록 생략"; return 1; }
  [ -f "$f" ] || echo '{}' > "$f"

  # ⛔ 라운드 접미 슬러그 금지(유령 에이전트의 원점 — 사례 FE1-1301 impl-fe-r6).
  #    상태표엔 impl-fe 라운드 6으로 적고 로그만 impl-fe-r6로 새면 보드에 없는 행이 생긴다.
  if [ "${DOBBY_FORCE:-0}" != "1" ] && printf '%s' "$slug" | grep -qE -- '-(r|round[-_]?)[0-9]+$'; then
    local b r
    b="$(printf '%s' "$slug" | sed -E 's/-(r|round[-_]?)([0-9]+)$//')"
    r="$(printf '%s' "$slug" | sed -E 's/.*-(r|round[-_]?)([0-9]+)$/\2/')"
    _die "라운드 접미 슬러그 금지 '$slug' — 같은 슬러그의 하위 키로: dobby_log $key $b '$p' round-$r"
    return 1
  fi

  local t old
  t="$(jq -r --arg s "$slug" 'if has($s) then (.[$s]|type) else "null" end' "$f" 2>/dev/null)" || t="null"

  if [ "$t" = "string" ]; then
    old="$(jq -r --arg s "$slug" '.[$s]' "$f" 2>/dev/null)"
    [ "$old" = "$p" ] && return 0                      # 같은 경로 재기록은 멱등 no-op
    # ⛔ 문자열 값에 라운드를 더하려 하면 jq가 실패해 조용히 아무것도 안 남는다.
    #    기존 기록을 잃지 않도록 {impl: 기존, round-N: 새것} 객체로 승격한다.
    #    라운드를 안 줬으면 round-2로 이어 붙인다(덮어써서 유실시키지 않는다).
    jq --arg s "$slug" --arg o "$old" --arg r "${rd:-round-2}" --arg p "$p" \
       '.[$s] = {"impl": $o, ($r): $p}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  elif [ "$t" = "object" ]; then
    if [ -z "$rd" ]; then                              # 라운드 미지정 → 다음 번호로 이어 붙임
      rd="round-$(jq -r --arg s "$slug" '[.[$s]|keys[]|capture("^round-(?<n>[0-9]+)$").n|tonumber] | (max // 1) + 1' "$f" 2>/dev/null)"
    fi
    jq --arg s "$slug" --arg r "$rd" --arg p "$p" '.[$s] += {($r): $p}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    if [ -n "$rd" ]; then
      jq --arg s "$slug" --arg r "$rd" --arg p "$p" '.[$s] = {($r): $p}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
      jq --arg s "$slug" --arg p "$p" '.[$s] = $p' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  fi
}

# ── status.md 단계 ───────────────────────────────────────────────────
# dobby_phase KEY PHASE — 현재 단계/갱신 갱신.
dobby_phase() {
  local key="$1" ph f now; ph="$(dobby_norm_phase "$2")"
  f="$(_order_dir "$key")/status.md"; now="$(_now)"
  [ -f "$f" ] || return 1
  awk -v ph="$ph" -v now="$now" '
    /^## / { insec = ($0 ~ /현재 단계/) }
    {
      if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*단계\*\*/) { print "- **단계**: " ph; next }
      if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*갱신\*\*/) { print "- **갱신**: " now; next }
      print
    }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  _dobby_autoevent "$key" "단계 → $ph"
}

# ── 리뷰/검증 경로 ───────────────────────────────────────────────────
# dobby_review_path KEY ROUND SLUG — reviews/round-N/{slug}.md 경로(폴더 생성) stdout.
dobby_review_path() {
  local dir; dir="$(_order_dir "$1")/reviews/round-$2"; mkdir -p "$dir"
  printf '%s/%s.md' "$dir" "$3"
}
# _order_phase KEY — status.md `## 현재 단계`의 `- **단계**:` 값. 없으면 빈 문자열.
_order_phase() {
  local f
  f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 0
  grep -m1 -E '^[ \t]*-[ \t]*\*\*단계\*\*' "$f" 2>/dev/null \
    | sed -E 's/.*[:：][ \t]*//; s/[*`]//g; s/[ \t]+$//'
}

# _order_worktree KEY — status.md '## 워크트리 / 브랜치' 표의 첫 경로(물결표 펼침). 없으면 빈 문자열.
_order_worktree() {
  local f p
  f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 0
  p="$(awk '
    /^## /{ins=(index($0,"워크트리")>0)?1:0; next}
    ins==1 && /^\|/{
      n=split($0,a,"|"); v=a[4]; gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/`/,"",v)
      if(v!="" && v!="경로" && v !~ /^-+$/){print v; exit}
    }' "$f")"
  printf '%s' "${p/#\~/$HOME}"
}

# _touches_public_surface WORKTREE — 이번 변경이 **바깥에 보이는 면**을 건드렸는가(0=그렇다).
# export 가 붙은 줄이 추가·수정됐으면 소비처가 영향을 받을 수 있다는 뜻이다.
# 리뷰는 미커밋 변경 대상이므로(C1) 워킹트리와 스테이지를 함께 본다.
_touches_public_surface() {
  local wt="$1" d f
  [ -d "$wt" ] || return 1
  d="$( { git -C "$wt" diff -U0; git -C "$wt" diff --cached -U0; } 2>/dev/null )"
  printf '%s' "$d" | grep -qE '^[+-][^+-].*\bexport\b' && return 0
  # ⛔ 새로 만든 파일은 아직 추적되지 않아 diff 에 안 나온다. 내용을 직접 본다.
  # (시험에서 잡힌 구멍이다 — 새 파일이 export 를 통째로 들고 와도 그냥 통과했다.)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE '\bexport\b' "$wt/$f" 2>/dev/null && return 0
  done <<EOF
$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null)
EOF
  return 1
}


# dobby_blocking KEY ROUND — reviews/round-N/*.md에서 카드 헤더(`## [blocker|major] …`)를 세어
# blocking 수를 stdout으로 낸다(P6→통합 전이 판정용). 카드 형식이 하나도 없는 리뷰 파일이 있으면
# stderr에 경고를 남긴다 — 그 파일만은 직접 읽어 판정하라(폴백: 형식 미준수가 통과로 오인되지 않게).
dobby_blocking() {
  local key="$1" rd="$2" dir n=0 f c
  dir="$(_order_dir "$key")/reviews/round-$rd"
  if [ ! -d "$dir" ]; then
    printf 'dobby-lib: 리뷰 폴더 없음(%s) — blocking 판정 불가\n' "$dir" >&2
    printf '0'; return 0
  fi
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    # 카드 헤더가 없으면 **blocking 1건으로 센다**(예전에는 경고만 하고 0을 더했다).
    #
    # 왜 바꿨나(실측): 병합 요청 자동리뷰를 받아 적은 파일이 118줄·131줄로 꼼꼼했는데
    # `## 1. …` + 표라서 0건으로 집계됐다. 라운드가 "깨끗함"으로 닫히고, 그 안의 실제 지적이
    # blocking 판정·대시보드 카드·회고 집계에서 통째로 사라졌다(FE1-1943·FE1-1983).
    # 경고는 읽히지 않는다. 라운드가 안 닫히게 해야 고친다 — 머리글만 바꾸면 바로 닫힌다.
    if ! grep -qE '^## \[(blocker|major|minor|nit)\]' "$f"; then
      printf 'dobby-lib: ⛔ %s 에 심각도 카드 헤더(## [blocker|major|minor|nit] …)가 없어 집계되지 않습니다 — blocking 1건으로 셉니다. 각 지적의 머리글을 카드로 바꾸세요(본문은 그대로 두면 됩니다).\n' "$(basename "$f")" >&2
      n=$((n + 1))
      continue
    fi
    c="$(grep -cE '^## \[(blocker|major)\]' "$f" 2>/dev/null)" || c=0
    n=$((n + c))
  done

  # ⛔ 소비처 확인 절 요구 — 바깥에 보이는 면(export)을 건드렸을 때만.
  #
  # 왜(실측 FE1-1953): `placeholderData` 로 `data` 는 채웠지만 `isFetched` 는 못 바꾸는데,
  # 호출부 2곳이 `isFetched` 로 렌더를 갈라 **이 변경이 막으려던 카드 재생성이 PC 홈에서는
  # 그대로 남았다**. 우리 리뷰 4라운드 32건이 전부 놓쳤고 병합 요청 자동리뷰가 잡았다 —
  # 호출부가 diff 밖이라 diff 만 보면 안 보인다. "회귀(소비처 영향)를 보라"는 글은 있었다.
  # 그래서 **적었는지**를 센다. 적으려면 실제로 찾아봐야 한다.
  #
  # 문서만 고친 라운드에는 요구하지 않는다(export 변경이 없으면 건너뛴다).
  local wt; wt="$(_order_worktree "$key")"
  if [ -n "$wt" ] && _touches_public_surface "$wt"; then
    if ! grep -qlE '^##+[ ]*확인한 소비처' "$dir"/*.md 2>/dev/null; then
      printf 'dobby-lib: ⛔ 이번 변경이 export 를 건드렸는데 리뷰에 `## 확인한 소비처` 가 없습니다 — blocking 1건으로 셉니다. 바뀐 심볼을 쓰는 곳을 전수 grep 해 몇 곳이며 어떤 영향인지 적으세요(없으면 "소비처 없음"이라고 적습니다).\n' >&2
      n=$((n + 1))
    fi
  fi

  printf '%s' "$n"
}

# dobby_testrun_new KEY [총시나리오수] [환경] — 회차를 자동 계산(기존 test-runs/ 폴더 수 + 1)하고
# test-runs/{ts}/ + result.md 골격을 만든 뒤, status.md '## 테스트 실행 이력' 표에
# 이번 회차 행(상태 테스트중·집계 0/0/0)을 추가한다. 폴더 경로 stdout.
# (집계 칸의 "(전체 N)"은 참고 표기 — 대시보드는 앞 숫자 3개(성공/실패/skip)만 읽는다.)
# 환경(dev·rc4 등)은 result.md 머리의 `- **환경**:` 줄로 들어간다 — 대시보드 검증 탭의 환경 칸.
dobby_testrun_new() {
  local key="$1" total="${2:-}" env="${3:-}" n dir sf now
  n="$(find "$(_order_dir "$key")/test-runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  n=$((n + 1))
  dir="$(_order_dir "$key")/test-runs/$(_ts)"; mkdir -p "$dir"
  # 시나리오 표는 **여기서 완성해 준다**. 스킬이 표를 직접 지으면 회차마다 머리글이 달라져
  # (실측 75회차에 20가지 넘음) 대시보드가 칸을 못 읽는다. 머리글·구분선·빈 행까지 깔아 두고
  # 스킬은 칸만 채우게 한다. 마커는 대시보드가 이 표를 정확히 집게 하는 표시다.
  if [ ! -f "$dir/result.md" ]; then
    {
      printf '# %s 테스트 결과 — 회차 %s\n\n' "$key" "$n"
      # 환경도 **여기서 깔아 준다**. 스킬이 본문 아무 데나 적던 때는 회차 77개 중 39개만
      # 환경이 남아(절반) 대시보드 환경 칸이 비었다. 비어 있어도 줄은 남겨 채우게 한다.
      printf -- '- **환경**: %s\n\n(진행 중)\n\n' "$env"
      printf '## 시나리오별 결과\n\n<!-- dobby:scenarios -->\n'
      # `조건` 칸은 이 시나리오가 확인하는 해결 조건 번호(C1 등, status.md '## 닫히는 조건 항목').
      # 이 칸이 있어야 대시보드가 "조건 N개 중 M개 확인"을 스스로 말할 수 있다.
      printf '| # | 조건 | 페이지 / URL | 확인 항목 | 기대 | 실제 | 판정 | 근거 |\n'
      printf '|---|---|---|---|---|---|---|---|\n'
      if [ -n "$total" ] && [ "$total" -eq "$total" ] 2>/dev/null; then
        i=1; while [ "$i" -le "$total" ]; do printf '| S%s |  |  |  |  |  |  |  |\n' "$i"; i=$((i+1)); done
      fi
    } > "$dir/result.md"
  fi
  sf="$(_order_dir "$key")/status.md"; now="$(_now)"
  if [ -f "$sf" ]; then
    _table_row_append "$sf" "테스트 실행 이력" \
      "| 회차 | 시작 | 상태 | 성공/실패/skip | 폴더 |" "|------|------|------|----------------|------|" \
      "| $n | $now | 테스트중 | 0/0/0${total:+ (전체 $total)} | $dir |"
  fi
  _testrun_board "$key" 테스트중
  printf '%s' "$dir"
}

# _testrun_board KEY 회차상태 — 검증 동안 개발자 카드를 테스터(`검증`)로 보이게 한다. 개발자 행이 없으면 아무것도 안 한다.
# 테스트중은 갱신 시각만 새로 고친다(시나리오마다 불려 이벤트를 남기지 않는다). 실패·중단은 다음이 수정이라 대기.
_testrun_board() {
  local o dev; o="$(_order_dir "$1")/orchestration.md"
  dev="$(_board_dev_slug "$o")"; [ -n "$dev" ] || return 0
  case "$2" in
    테스트중)
      if [ "$(_board_rows "$o" | awk -F'\t' -v s="$dev" '$1==s{print $2; exit}')" = 검증 ]; then
        DOBBY_AUTO_EVENT=0 dobby_agent_state "$1" "$dev" 검증
      else
        dobby_agent_state "$1" "$dev" 검증
      fi ;;
    완료) dobby_agent_state "$1" "$dev" 완료 ;;
    *)    dobby_agent_state "$1" "$dev" 대기 ;;
  esac >/dev/null
}

# dobby_testrun_update KEY 폴더시각 상태 [성공/실패/skip] — 이력 표에서 폴더 칸에 그 시각이 포함된
# 행의 상태·집계만 수정한다(통독 없음). 상태 예: 테스트중·완료·완료(이슈 있음)·중단. 집계 예: "3/1/0".
dobby_testrun_update() {
  local key="$1" ts="$2" st="$3" counts="${4:-}" sf
  sf="$(_order_dir "$key")/status.md"
  [ -f "$sf" ] || return 1
  awk -F'|' -v OFS='|' -v ts="$ts" -v st="$st" -v counts="$counts" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    BEGIN{ins=0;hdr=0;ci_st=0;ci_c=0}
    /^## /{ins=(index($0,"테스트 실행 이력")>0)?1:0; hdr=0; print; next}
    ins==1 && /^\|/ {
      if(hdr==0){
        for(i=1;i<=NF;i++){c=t($i)
          if(c=="상태")ci_st=i
          else if(index(c,"성공")>0||index(c,"집계")>0)ci_c=i}
        if(ci_st>0)hdr=1
        print; next
      }
      if(index($0,ts)>0 && ci_st>0){
        $(ci_st)=" " st " "
        if(ci_c>0 && counts!="") $(ci_c)=" " counts " "
      }
      print; next
    }
    {print}
  ' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
  _testrun_board "$key" "$st"
}

# ── 정기배포 stage 검증 목록 — $META/RELEASE-{날짜}/stage.md (대시보드 릴리즈 화면) ──
# 이슈와 회차 경로만 적는다. TC 결과는 회차 result.md 에만 있다. 폴더 이름이 키 형식이라 메타 백업에 담긴다.
_release_file() { printf '%s/RELEASE-%s/stage.md' "$(_meta)" "$1"; }

# _release_field FILE 이름 값 — `- **이름**:` 줄의 값을 바꾼다.
_release_field() {
  awk -v k="$2" -v v="$3" 'index($0, "- **" k "**:") == 1 { print "- **" k "**: " v; next } { print }' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# dobby_release_init 날짜 요일 [페이지주소] — 목록 파일을 만든다. 이미 있으면 상태만 '진행 중'으로 되돌린다.
dobby_release_init() {
  local d="$1" wd="$2" page="${3:-}" f
  printf '%s' "$d" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { _die "쓰임: dobby_release_init YYYY-MM-DD 요일 [페이지주소]"; return 1; }
  f="$(_release_file "$d")"
  if [ -f "$f" ]; then
    _release_field "$f" "상태" "진행 중"; _release_field "$f" "끝" ""
    [ -n "$page" ] && _release_field "$f" "릴리즈 노트" "$page"
    printf '%s' "$f"; return 0
  fi
  mkdir -p "$(dirname "$f")"
  {
    printf '# %s(%s) 정기배포 stage 검증\n\n' "$d" "$wd"
    printf -- '- **배포일**: %s\n- **요일**: %s\n- **릴리즈 노트**: %s\n- **상태**: 진행 중\n- **시작**: %s\n- **끝**: \n\n' \
      "$d" "$wd" "$page" "$(_now)"
    printf '## 이슈\n\n<!-- dobby:release-issues -->\n'
    printf '| 행 | 이슈 | 저장소 | stage 반영 | 회차 | stage 칸 | 비고 |\n|---|---|---|---|---|---|---|\n'
  } > "$f"
  printf '%s' "$f"
}

# dobby_release_row 날짜 행 이슈 [저장소] [반영] [회차] [stage칸] [비고] — 이슈 행을 더하거나 고친다.
# 빈 값은 그 칸을 그대로 둔다(지우려면 '-'). 회차는 절대 경로를 받아 메타 기준 상대 경로로 적는다.
dobby_release_row() {
  local d="$1" row="$2" key="$3" rp="${4:-}" refl="${5:-}" run="${6:-}" chk="${7:-}" note="${8:-}" f
  f="$(_release_file "$d")"
  [ -f "$f" ] || { _die "목록 파일이 없다 — dobby_release_init 먼저: $f"; return 1; }
  [ -n "$key" ] || { _die "쓰임: dobby_release_row 날짜 행 이슈 [저장소] [반영] [회차] [stage칸] [비고]"; return 1; }
  run="${run#"$(_meta)/"}"
  awk -v row="$row" -v key="$key" -v rp="$rp" -v refl="$refl" -v run="$run" -v chk="$chk" -v note="$note" '
    function t(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    function pick(new, old) { return new == "" ? old : (new == "-" ? "" : new) }
    function emit(c) { printf "| %s | %s | %s | %s | %s | %s | %s |\n", pick(row, c[2]), key, pick(rp, c[4]), pick(refl, c[5]), pick(run, c[6]), pick(chk, c[7]), pick(note, c[8]); done = 1 }
    /<!-- dobby:release-issues -->/ { intab = 1; print; next }
    intab && /^\|/ {
      n = split($0, c, "|"); for (i = 1; i <= n; i++) c[i] = t(c[i])
      if (c[3] == key) { emit(c); next }
      print; next
    }
    intab && !/^\|/ { if (!done) { split("", e); emit(e) } intab = 0 }
    { print }
    END { if (intab && !done) { split("", e); emit(e) } }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dobby_release_done 날짜 — 상태를 '완료'로 바꾸고 끝 시각을 적는다.
dobby_release_done() {
  local f
  f="$(_release_file "$1")"
  [ -f "$f" ] || { _die "목록 파일이 없다: $f"; return 1; }
  _release_field "$f" "상태" "완료"; _release_field "$f" "끝" "$(_now)"
}

# ── 검증 묶음 — 한 회차를 묶음으로 나눠 세션마다 묶음 하나씩 돈다 ──────────
# _testrun_open KEY — 이력 표의 마지막 회차가 '테스트중'이면 그 폴더를 낸다. 아니면 출력 없이 1.
_testrun_open() {
  local dir
  dir="$(awk -F'|' '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## /{ins=(index($0,"테스트 실행 이력")>0)?1:0; next}
    ins && /^\|/ && $2 !~ /회차|---/ {st=t($4); d=t($6)}
    END{if(st=="테스트중") print d}' "$(_order_dir "$1")/status.md" 2>/dev/null)"
  [ -n "$dir" ] && [ -d "$dir" ] && printf '%s' "$dir"
}

# dobby_testrun_current KEY [총시나리오수] [환경] — 열린 회차('테스트중')가 있으면 그 폴더를, 없으면 새 회차를 연다.
dobby_testrun_current() {
  _testrun_open "$1" || dobby_testrun_new "$@"
}

# _testplan_batches KEY — "묶음<TAB>S1,S2,…" 줄들. `## 검증 묶음` 표를 따르고, 표에 없는 시나리오는 4개씩 덧붙인다.
_testplan_batches() {
  local p n=0 rest="" i=0 s
  p="$(_order_dir "$1")/test-plan.md"
  [ -f "$p" ] || return 1
  local tbl; tbl="$(awk -F'|' '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## /{ins=(t(substr($0,4))=="검증 묶음"); next}
    ins && /^\|/ && t($2) !~ /^(묶음|-+)$/ {s=t($3); gsub(/[ \t]/,"",s); print t($2) "\t" s}' "$p")"
  [ -n "$tbl" ] && { printf '%s\n' "$tbl"; n="$(printf '%s\n' "$tbl" | wc -l | tr -d ' ')"; }
  for s in $(sed -nE 's/^## (S[0-9]+)\..*/\1/p' "$p"); do
    printf '%s\n' "$tbl" | cut -f2 | tr ',' '\n' | grep -qx "$s" && continue
    rest="${rest:+$rest,}$s"; i=$((i + 1))
    [ "$i" -eq 4 ] && { n=$((n + 1)); printf 'V%s\t%s\n' "$n" "$rest"; rest=""; i=0; }
  done
  [ -n "$rest" ] && printf 'V%s\t%s\n' "$((n + 1))" "$rest"
  return 0
}

# dobby_verify_next KEY — 판정이 빈 시나리오가 든 첫 묶음 "묶음<TAB>S1,S2"(빈 것만). 다 찼으면 done.
# 열린 회차가 없으면 전부 빈 것으로 보고 첫 묶음을 낸다.
dobby_verify_next() {
  local key="$1" run judged="" name list s left
  run="$(_testrun_open "$key")"
  [ -n "$run" ] && judged=" $(awk -F'|' '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /dobby:scenarios/{m=1; next}
    m && /^\|/ { if(!h){for(i=2;i<NF;i++) if(t($i)=="판정") j=i; h=1; next}
      id=t($2); if(id ~ /^S[0-9]+$/ && j && t($j)!="") print id; next }
    m && h {m=0}' "$run/result.md" | tr '\n' ' ')"
  while IFS=$'\t' read -r name list; do
    left=""
    for s in ${list//,/ }; do
      case "$judged" in *" $s "*) ;; *) left="${left:+$left,}$s" ;; esac
    done
    [ -n "$left" ] && { printf '%s\t%s\n' "$name" "$left"; return 0; }
  done <<<"$(_testplan_batches "$key")"
  printf 'done\n'
}

# dobby_testplan_slice KEY S1,S2 — 테스트 계획에서 제목·사전 준비·영향 번들과 그 시나리오 절만 낸다.
dobby_testplan_slice() {
  awk -v want=",${2// /}," '
    /^## /{ h=substr($0,4); id=h; sub(/\..*/,"",id)
      keep = (h ~ /^(사전 준비|영향 번들)/) || (id ~ /^S[0-9]+$/ && index(want, "," id ",") > 0) }
    NR==1 || keep' "$(_order_dir "$1")/test-plan.md"
}

# ── 워크트리/커밋/통합 ───────────────────────────────────────────────
# dobby_setup_worktree REPO KEY PREFIX BASE — 워크트리 생성(재사용 시 그대로) + origin push. 경로 stdout.
# _table_row_append FILE 섹션제목 헤더행 구분행 ROW — 그 `## 섹션`의 표 마지막 행 뒤에 ROW를 붙인다.
# 섹션·표가 없으면 만들고, 섹션이 문서 중간이어도(뒤에 다른 ## 섹션·`## 해결` 등) 표 안에 정확히 삽입한다.
_table_row_append() {
  local f="$1" sec="$2" hdr="$3" sep="$4" row="$5"
  if ! grep -qF "## $sec" "$f"; then
    printf '\n## %s\n%s\n%s\n%s\n' "$sec" "$hdr" "$sep" "$row" >> "$f"
    return 0
  fi
  awk -v sec="$sec" -v hdr="$hdr" -v sep="$sep" -v row="$row" '
    BEGIN{ins=0}
    ins==0 && substr($0,1,3)=="## " && index($0,sec)>0 {inblk=1; print; next}
    inblk==1 && /^\|/ {print; seen=1; next}
    inblk==1 && (seen==1 || substr($0,1,3)=="## ") {
      if(seen==0){print hdr; print sep}
      print row; ins=1; inblk=0; print; next
    }
    {print}
    END{ if(inblk==1 && ins==0){ if(seen==0){print hdr; print sep} print row } }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# _wt_row_exists FILE REPO BRANCH — '## 워크트리 …' 표에 (repo, 브랜치) 행이 이미 있으면 0(있음).
# ⛔ (repo, 브랜치) 쌍으로 본다: 멀티 repo 오더는 저장소가 달라도 브랜치명이 같을 수 있고(예 FE·BE 모두
# feature/{키}), 브랜치 문자열만 비교하면 두 번째 저장소 행이 조용히 누락된다. 또 이 표 밖(옛 `## 에이전트`
# 표 등)에 같은 브랜치가 적혀 있어도 중복으로 오판하지 않도록 이 섹션 안만 검사한다.
_wt_row_exists() {
  awk -v want_repo="$2" -v want_br="$3" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/`|\*/,"",x);return x}
    /^## /{ins=(index($0,"워크트리")>0)?1:0; hdr=0; next}
    ins==1 && /^\|/{
      n=split($0,a,"|")
      if(hdr==0){for(i=1;i<=n;i++){c=t(a[i]); if(c=="repo")cr=i; if(c=="브랜치")cb=i}
        if(cr&&cb)hdr=1; next}
      issep=1; for(i=2;i<n;i++){c=a[i];gsub(/[ \t-]/,"",c);if(c!=""){issep=0;break}}
      if(issep)next
      if(t(a[cr])==want_repo && t(a[cb])==want_br){found=1}
    }
    END{exit(found?0:1)}' "$1"
}

# dobby_record_branch KEY REPO BRANCH [워크트리경로] — status.md '## 워크트리 / 브랜치' 표에 행을 중복 없이 남긴다.
# 대시보드 계약: parseWorktrees는 `| repo | 브랜치 | 경로 |` 표를 읽고(경로 칸 필수), 경로 실존 여부로
# 워크트리 정리(worktreeRemoved)를 판정하며 prTargets가 브랜치를 읽는다 — 경로까지 꼭 넘겨라.
dobby_record_branch() {
  local key="$1" repo="$2" branch="$3" wt="${4:-}" sf
  sf="$(_order_dir "$key")/status.md"
  [ -f "$sf" ] || return 0
  _wt_row_exists "$sf" "$repo" "$branch" && return 0
  _table_row_append "$sf" "워크트리 / 브랜치" \
    "| repo | 브랜치 | 경로 |" "|------|--------|------|" \
    "| $repo | $branch | $wt |"
}

# dobby_set_title KEY "제목"  — status.md '## 이슈/작업'의 '- **제목**:' 줄을 실제 제목으로 갱신(in-place).
# 골격 생성 시 넣은 임시 제목(이슈 키 등)을 조회 후 실제 요약으로 덮어쓰는 용도. dobby-start 경유 여부와 무관하게 호출.
dobby_set_title() {
  local key="$1" title="$2" f
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || return 0
  [ -n "$title" ] || return 0
  awk -v t="$title" '
    /^##/ { insec = ($0 ~ /이슈\/작업/) }
    { if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*제목\*\*/) { print "- **제목**: " t; next } print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dobby_set_scope KEY "한 줄" — status.md '## 이슈/작업'에 '- **닫히는 조건**: …'를 upsert(범위 경계).
# "이 오더가 어디까지 하면 끝인가"를 착수 때 한 줄로 못박는 값. 있으면 갱신, 없으면 '- **제목**:' 바로 뒤에 삽입.
# dobby-order P8이 후속 요청을 이 값과 대조해 "같은 오더 편입 vs 새 오더 분리"를 판단한다.
dobby_set_scope() {
  local key="$1" scope="$2" f
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || return 0
  [ -n "$scope" ] || return 0
  awk -v s="$scope" '
    /^##/ { insec = ($0 ~ /이슈\/작업/) }
    {
      if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*닫히는 조건\*\*/) { if (!done) { print "- **닫히는 조건**: " s; done=1 } next }
      print
      if (insec && !done && $0 ~ /^[ \t]*-[ \t]*\*\*제목\*\*/) { print "- **닫히는 조건**: " s; done=1 }
    }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dobby_add_condition KEY "조건 한 줄" — status.md '## 닫히는 조건 항목' 표에 C{n} 행을 붙인다(번호 자동).
# 한 줄짜리 `닫히는 조건`을 **확인할 수 있는 단위로 쪼갠 것**이다. 테스트 시나리오가 이 번호를 달고
# (result.md `조건` 칸), 대시보드 검증 탭이 "조건 N개 중 M개 확인"을 이 표와 대조해 말한다.
# ⛔ 한 줄을 기계로 쪼개지 않는다 — `고아 훅/쿼리키/tsconfig 정리`처럼 구분 기호가 뜻 안에도 들어가
#    잘못 잘린다. P1에서 사람이 한 번 나눠 부르는 쪽이 정확하다.
# 범위가 넓어지면(P8) 같은 방식으로 한 줄 더 부르면 된다 — 기존 번호는 그대로 둔다.
dobby_add_condition() {
  local key="$1" text="$2" f n
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || return 0
  [ -n "$text" ] || return 0
  n="$(awk '/^## /{ins=(index($0,"닫히는 조건 항목")>0)?1:0; next}
            ins==1 && /^\| *C[0-9]+ *\|/{c++}
            END{print c+0}' "$f")"
  n=$((n + 1))
  _table_row_append "$f" "닫히는 조건 항목" \
    "| # | 조건 |" "|----|------|" \
    "| C$n | $text |"
  printf 'C%s' "$n"
}

# dobby_append KEY FILE "블록"  — 오더 메타의 append-only 문서(decisions.md 등)에 블록을 '읽기 없이' 뒤에 붙인다.
# 기존 내용을 다시 읽거나 재작성하지 않아 토큰이 안 든다. FILE은 오더 폴더 기준 파일명.
dobby_append() {
  local key="$1" file="$2" block="$3" f
  f="$(_order_dir "$key")/$file"; mkdir -p "$(dirname "$f")"
  printf '%s\n' "$block" >> "$f"
}

dobby_setup_worktree() {
  # $5(rootkey, 선택): docs 게이트를 검사할 루트 키. 에이전트 워크트리(에이전트키≠루트키)면
  # 루트 키를 넘겨 루트의 docs-refs.md를 검사한다. 미지정 시 $2(=K=1이면 루트=에이전트).
  local repo="$1" key="$2" prefix="$3" base="$4" gate_key="${5:-$2}"
  local src="$ORCHESTRATION_REPOS_ROOT/$repo" wt branch
  wt="$ORCHESTRATION_WORKSPACE/subtree/$repo-$key"; branch="$prefix/$key"
  [ -d "$src/.git" ] || git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || { _die "소스 repo 없음: $src"; return 1; }
  mkdir -p "$ORCHESTRATION_WORKSPACE/subtree"
  if git -C "$src" worktree list --porcelain 2>/dev/null | grep -qx "worktree $wt"; then dobby_record_branch "$key" "$repo" "$branch" "$wt"; printf '%s' "$wt"; return 0; fi
  # ⛔ docs 게이트 차단(B): 새 워크트리 생성 전, 루트의 docs-refs.md가 없으면 중단한다.
  # docs 게이트를 안 돌리면 구현할 워크트리를 못 만들므로 게이트가 물리적으로 강제된다.
  # (기존 워크트리 재사용 경로는 위에서 이미 return — 과거 오더는 차단하지 않는다.)
  if [ ! -f "$(_order_dir "$gate_key")/docs-refs.md" ]; then
    _die "docs 게이트 미통과 — 워크트리 생성 차단: $(_order_dir "$gate_key")/docs-refs.md 없음. 먼저 'dobby_docs_gate $gate_key \"키워드1|키워드2\"'(또는 dobby_scaffold_meta에 키워드 인자)를 실행해 문서를 확인하세요."
    return 1
  fi
  # 로컬 base 는 낡았을 수 있어 항상 원격을 받아 origin/base 에서 딴다. 로컬에만 있는 커밋이 있을 때만 로컬을 쓴다.
  local start
  git -C "$src" fetch -q origin "$base" >&2 2>/dev/null \
    || printf 'dobby-lib: ⚠️ origin/%s 를 받아 오지 못했다 — 마지막으로 받은 원격 기준으로 만든다.\n' "$base" >&2
  if git -C "$src" show-ref --verify --quiet "refs/remotes/origin/$base"; then
    start="origin/$base"
    if git -C "$src" show-ref --verify --quiet "refs/heads/$base" \
       && [ "$(git -C "$src" rev-list --count "origin/$base..$base" 2>/dev/null)" != "0" ]; then
      start="$base"
      printf 'dobby-lib: ⚠️ 로컬 %s 에 원격에 없는 커밋이 있어 로컬 %s 에서 딴다.\n' "$base" "$base" >&2
    fi
  elif git -C "$src" show-ref --verify --quiet "refs/heads/$base"; then
    start="$base"
  else
    _die "기준 브랜치 $base 가 로컬에도 origin 에도 없다"; return 1
  fi
  git -C "$src" worktree add -b "$branch" "$wt" "$start" >&2 || { _die "worktree add 실패($start)"; return 1; }
  git -C "$wt" push -u origin "$branch" >&2 2>/dev/null || true
  dobby_record_branch "$key" "$repo" "$branch" "$wt"
  _docs_refs_worktree "$gate_key" "$repo" "$wt"
  printf '%s' "$wt"
}

# _wt_row FILE REPO — '## 워크트리 …' 표에서 그 저장소의 첫 행을 "브랜치<TAB>경로" 로 준다. 없으면 빈 값.
# 브랜치 칸 뒤에 붙은 설명 괄호("feature/X (feature/Y 에서 분기)")는 떼고 준다.
_wt_row() {
  awk -v want="$2" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/`|\*/,"",x);return x}
    /^## /{ins=(index($0,"워크트리")>0)?1:0; hdr=0; next}
    ins==1 && /^\|/{
      n=split($0,a,"|")
      if(hdr==0){for(i=1;i<=n;i++){c=t(a[i]); if(c=="repo")cr=i; if(c=="브랜치")cb=i; if(c=="경로")cp=i}
        if(cr&&cb&&cp)hdr=1; next}
      if(t(a[cr])!=want)next
      b=t(a[cb]); sub(/[ \t]*\(.*$/,"",b); p=t(a[cp])
      if(b!="" && p!=""){print b "\t" p; exit}
    }' "$1"
}

# dobby_ensure_worktree REPO KEY PREFIX BASE — 워크트리가 있으면 그대로 쓰고, 없으면 만든다. 경로를 stdout 으로 준다.
# /do 용이다. dobby_setup_worktree 는 dobby-order·dobby-qa 가 쓰므로 고치지 않고, 그 앞에서 막힐 곳만 먼저 처리한다.
#   ① 상태 문서에 이 저장소의 행이 이미 있으면 그 브랜치·경로를 쓴다(새 이름을 조립하지 않는다).
#   ② 폴더가 지워졌고 브랜치가 남아 있으면 -b 없이 그 브랜치로 되살린다(로컬에 없으면 origin 에서 받아 온다).
#      dobby_setup_worktree 는 이때 "a branch named … already exists" 로 실패한다.
#   ③ git 에 등록되지 않은 폴더가 그 자리에 있으면 지우지 않고 멈춘다(사람이 둔 파일일 수 있다).
#   ④ 새로 기록하는 브랜치는 워크트리의 실제 브랜치다.
#   그 밖(행도 없고 브랜치도 없음)은 dobby_setup_worktree 로 새로 만든다 — docs 게이트·base·푸시가 그대로 적용된다.
dobby_ensure_worktree() {
  local repo="$1" key="$2" prefix="$3" base="$4"
  local src="$ORCHESTRATION_REPOS_ROOT/$repo" sf rec="" wt branch
  sf="$(_order_dir "$key")/status.md"
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || { _die "소스 repo 없음: $src"; return 1; }
  git -C "$src" worktree prune 2>/dev/null
  [ -f "$sf" ] && rec="$(_wt_row "$sf" "$repo")"
  if [ -n "$rec" ]; then
    branch="${rec%%$'\t'*}"; wt="${rec#*$'\t'}"; wt="${wt/#\~/$HOME}"
  else
    branch="$prefix/$key"; wt="$ORCHESTRATION_WORKSPACE/subtree/$repo-$key"
  fi
  if git -C "$src" worktree list --porcelain | grep -qx "worktree $wt"; then
    branch="$(git -C "$wt" branch --show-current)"
  elif [ -e "$wt" ]; then
    _die "$wt 폴더가 있지만 git 워크트리로 등록되어 있지 않다 — 지우지 않고 멈춘다. 안을 확인한 뒤 옮기거나 지우세요"; return 1
  elif git -C "$src" show-ref --verify --quiet "refs/heads/$branch" \
       || git -C "$src" fetch origin "$branch:$branch" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$wt")"
    git -C "$src" worktree add "$wt" "$branch" >&2 || { _die "worktree add 실패($branch)"; return 1; }
    _docs_refs_worktree "$key" "$repo" "$wt"
  elif [ -n "$rec" ]; then
    _die "상태 문서의 브랜치 $branch 가 $src 에도 origin 에도 없다 — 브랜치 이름을 확인하세요"; return 1
  else
    dobby_setup_worktree "$repo" "$key" "$prefix" "$base"; return
  fi
  [ -n "$rec" ] || dobby_record_branch "$key" "$repo" "$branch" "$wt"
  printf '%s' "$wt"
}

# _docs_refs_worktree GATE_KEY REPO WORKTREE — 워크트리의 **코딩 규약 문서 경로**를 docs-refs.md에 적는다.
#
# 왜 필요한가: docs 게이트(dobby_docs_gate)는 `$ORCHESTRATION_DOCS_ROOT`(도서관)를 키워드로 뒤지는데,
# **레이어·의존 규칙은 거기 없고 코드 저장소에 있다**(wadiz-frontend는 `packages/README.md`와
# 계층형 `CLAUDE.md` 18개). 그래서 기능 키워드로 검색해도 구조 규약은 영원히 안 걸린다
# (사례 FE1-1732: 이미지 로딩 정본을 상위 계층에 두어 의존 방향이 뒤집혔고, PR 리뷰에서 지적돼
#  호출부 21곳의 import를 다시 고쳤다. `packages/README.md` 한 번 읽었으면 없었을 재작업이다).
#
# 키워드를 늘리는 방식은 쓰지 않는다 — `구조|의존` 계열은 도서관 127개 문서 중 95개를 히트해
# 변별력이 없고, `dobby_docs_search`의 `head -20` 캡 때문에 정작 필요한 기능 문서를 밀어낸다.
#
# ⚠️ 이 함수는 **목록만 만든다.** 읽는 것은 구현 에이전트 몫이다(FE1-1732의 실패는 목록 부재가
#    아니라 미독이었다). 그래서 안내 문구를 함께 적는다.
_docs_refs_worktree() {
  local gate_key="$1" repo="$2" wt="$3"
  local f; f="$(_order_dir "$gate_key")/docs-refs.md"
  [ -f "$f" ] || return 0
  [ -d "$wt" ] || return 0
  # 워크트리마다(FE·BE 등) 다시 불리므로 같은 repo 절은 한 번만 적는다.
  grep -qF "## 워크트리 규약 — $repo" "$f" 2>/dev/null && return 0
  local hits
  # 무엇을 모으나 (실측으로 정한 조합 — wadiz-frontend 기준 22개·572바이트·0.12초):
  #  ① `CLAUDE.md`는 **깊이 제한 없이** 전부 — 깊이로 자르면 정작 수정 대상 폴더의 규약을 놓친다
  #     (`packages/features/src/support-share/CLAUDE.md`는 깊이 5이고 FE1-1809가 고친 폴더다.
  #      깊이 3·4는 둘 다 18개 중 15개만 잡았다).
  #  ② `README.md`는 **상위 2단계까지만** — 레이어 규칙이 있는 `packages/README.md`는 담되,
  #     깊이를 풀면 모듈별 README가 63개까지 불어나 목록이 소음이 된다.
  hits="$( { find "$wt" -type f -name 'CLAUDE.md' \
               -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null
             find "$wt" -mindepth 1 -maxdepth 2 -type f -name 'README.md' \
               -not -path '*/node_modules/*' 2>/dev/null; } \
          | sed "s|^$wt/||" | sort -u)"
  [ -n "$hits" ] || return 0
  {
    printf '\n## 워크트리 규약 — %s\n' "$repo"
    printf -- '- 새 파일·폴더의 **위치를 정하기 전에** 아래 중 대상 경로에 해당하는 것을 직접 읽는다.\n'
    printf -- '  상위 계층에 정본을 두면 하위 계층이 그것을 참조해 **의존 방향이 뒤집힌다**.\n'
    printf -- '- 읽고 고른 위치와 근거를 `implementation.md` 핵심 설계 결정에 한 줄로 남긴다.\n\n'
    printf '%s\n' "$hits" | sed 's/^/- `/; s/$/`/'
  } >> "$f"
}

# dobby_commit_push WORKTREE BRANCH MSG — 리뷰 통과 후 커밋(--no-verify)·푸시.
# ⛔ 메시지 게이트(코드 강제): 오케스트레이션 내부 용어·금지 서명이 메시지에 있으면 커밋 전에 거부한다
# (P5 루브릭 D를 코드로 강제 — "지시 준수"에 의존하지 않음). 정말 필요한 예외만 DOBBY_FORCE=1 로 우회.
dobby_commit_push() {
  local wt="$1" br="$2" msg="$3"
  if [ "${DOBBY_FORCE:-0}" != "1" ]; then
    if printf '%s' "$msg" | grep -qEi 'round-[0-9]|리뷰 반영|리뷰 피드백|슬러그|Co-Authored-By|Generated with'; then
      _die "커밋 메시지에 내부 용어/금지 서명 감지 — 그 수정이 '코드에 한 일'로 다시 쓰세요(우회: DOBBY_FORCE=1): $msg"
      return 1
    fi
  fi
  git -C "$wt" add -A >&2 || return 1
  # 저장소 고유 금지 규칙(이번에 **추가된 줄**만) — 위반이 있으면 커밋하지 않는다.
  # 리뷰어 프롬프트에 적어 두는 것으로는 안 지켜져, 나가는 길목에서 막는다.
  if [ "${DOBBY_FORCE:-0}" != "1" ]; then
    dobby_repo_lint "$wt" --cached || {
      _die "저장소 규칙 위반이 있어 커밋하지 않는다. 위를 고치고 다시 하라(우회: DOBBY_FORCE=1)."
      return 1
    }
  fi
  git -C "$wt" commit --no-verify -m "$msg" >&2 || return 1
  git -C "$wt" push origin "$br" >&2 2>/dev/null || git -C "$wt" push -u origin "$br" >&2
}

# dobby_merge_root WORKTREE ROOTBRANCH AGENTBRANCH — 에이전트 브랜치 → 루트 머지·푸시.
dobby_merge_root() {
  local wt="$1" root="$2" agent="$3"
  git -C "$wt" checkout "$root" >&2 || return 1
  git -C "$wt" merge --no-ff "$agent" >&2 || return 1
  git -C "$wt" push origin "$root" >&2 2>/dev/null || true
}

# ── 해결/정리 ────────────────────────────────────────────────────────
# dobby_resolve KEY [undo] — 단계 해결↔통합 + ## 해결 골격 + 미완료 에이전트 일괄 완료(비파괴).
dobby_resolve() {
  local key="$1" undo="${2:-}" f now; f="$(_order_dir "$key")/status.md"; now="$(_now)"
  if [ "$undo" = "undo" ]; then
    dobby_phase "$key" "통합"
    # ## 해결 섹션 제거
    awk '/^## 해결/{skip=1; next} /^## /{if(skip)skip=0} !skip{print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    dobby_event "$key" "해결 취소 — 해결 표시 해제"
    return 0
  fi
  dobby_phase "$key" "해결"
  # 상태표 미완료 에이전트 → 완료
  local of; of="$(_order_dir "$key")/orchestration.md"
  if [ -f "$of" ]; then
    awk -F'|' -v OFS='|' -v now="$now" '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
      BEGIN{ins=0;hdr=0;ci_slug=0;ci_st=0;ci_up=0}
      /^## / { ins=($0 ~ /에이전트 상태표/)?1:0; hdr=0; print; next }
      ins==1 && /^\|/ {
        if (hdr==0) {
          for(i=1;i<=NF;i++){c=t($i)
            if(c=="슬러그")ci_slug=i; else if(c=="상태")ci_st=i; else if(c=="갱신")ci_up=i}
          if(ci_st>0) hdr=1
          print; next
        }
        issep=1; for(i=2;i<NF;i++){c=t($i); if(c!="" && c !~ /^-+$/){issep=0;break}}
        if(issep){print;next}
        cur=t($(ci_st))
        if(cur!="" && cur!="완료"){ $(ci_st)=" 완료 "; if(ci_up>0) $(ci_up)=" " now " " }
        print; next
      }
      { print }
    ' "$of" > "$of.tmp" && mv "$of.tmp" "$of"
  fi
  grep -q '^## 해결' "$f" || cat >> "$f" <<EOF

## 해결
- **처리 일시**: $now
- **근거**: 리뷰 round-{n}(blocking 0) · 테스트 {YYYY-MM-DD HH:MM} {env} 회차 {i}(성공 {x}/실패 0/skip {z}) · 통합 커밋 {해시7}  ← ⛔ {} 를 실제 값으로 채울 것(못 채우면 해결 금지). 마지막 검증 이후 변경이 있으면 뒤에 " · ⚠️ 미검증 변경: {건수}건({날짜} 이후)" 추가
- **비고**: 워크트리·메타 유지. 추가 수정 시 dobby-order P8 재개.
EOF
  dobby_event "$key" "해결 표시 — status 해결"
  _dobby_meta_backup "$key"
}

# _dobby_meta_backup KEY — 해결 시점에 메타 폴더를 압축 백업(분리 실행).
#   ⛔ 반드시 백그라운드로 띄우고 출력은 파일로 돌린다: 대시보드의 "해결 처리" 버튼은
#      execFileSync 로 이 함수를 동기 대기하므로(jobs.ts startResolve), 인라인으로 압축하면
#      버튼이 그만큼 멈추고, 자식이 부모의 stdout 파이프를 물고 있으면 부모가 반환하지 못한다.
#   DOBBY_META_BACKUP=0 으로 끌 수 있다(테스트·복구 시).
_dobby_meta_backup() {
  [ "${DOBBY_META_BACKUP:-1}" = "1" ] || return 0
  local bk="$DOBBY_LIB_DIR/dobby-meta-backup.sh" dest
  [ -f "$bk" ] || return 0
  dest="${ORCHESTRATION_BACKUP_DIR:-$HOME/claude-projects-backup/orchestration}"
  mkdir -p "$dest" 2>/dev/null || return 0
  nohup bash "$bk" "$1" >>"$dest/backup-run.log" 2>&1 &
  return 0
}

# ── 정리(dobby-end) 기계적 조각 ──────────────────────────────────────
# 판정("제거해도 되나")은 LLM 몫: (status.md 단계 == 해결) AND (dobby_wt_unpushed == 0).
# 아래 함수는 세기·저장·제거만 한다.

# dobby_subtree_list — subtree 폴더별 "경로<TAB>키" stdout(키는 폴더명 끝의 이슈/작업 키).
dobby_subtree_list() {
  local base="$ORCHESTRATION_WORKSPACE/subtree" d name key
  [ -d "$base" ] || return 0
  # find 사용 — 매칭 없는 glob("$base"/*/)이 zsh에서 오류(no matches found)로 중단되는 것을 피한다.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    key="$(printf '%s' "$name" | grep -oE '[A-Z][A-Za-z0-9]*-[0-9]+|TASK-[A-Za-z0-9-]+' | tail -1)"
    printf '%s\t%s\n' "$d" "$key"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# dobby_wt_unpushed WORKTREE — origin에 안 올라간 커밋 수 stdout(모르면 '?' → 안전하지 않음으로 취급).
dobby_wt_unpushed() {
  local wt="$1" n br
  n="$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null)" || n=""
  if [ -z "$n" ]; then
    br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    n="$(git -C "$wt" rev-list --count "origin/$br..HEAD" 2>/dev/null)" || n=""
  fi
  printf '%s' "${n:-?}"
}

# dobby_end_snapshot KEY WORKTREE BASE — 제거 전 코드 변경분을 code-changes/에 파일로 저장. 폴더 stdout.
dobby_end_snapshot() {
  local key="$1" wt="$2" base="$3" dir repo ref
  dir="$(_order_dir "$key")/code-changes"; mkdir -p "$dir"
  repo="$(basename "$wt")"; repo="${repo%-$key}"; repo="${repo%-$key-*}"
  ref="$base"; git -C "$wt" rev-parse --verify -q "origin/$base" >/dev/null 2>&1 && ref="origin/$base"
  git -C "$wt" log --oneline "$ref..HEAD" > "$dir/$repo.commits" 2>/dev/null || true
  git -C "$wt" diff "$ref...HEAD" > "$dir/$repo.diff" 2>/dev/null || true
  printf '%s' "$dir"
}

# dobby_end_remove SRCREPO WORKTREE — 워크트리 제거(브랜치는 보존). 거부 시 --force(해결 이슈만).
# ⛔ rm -rf 등 파괴적 삭제는 하지 않는다(사용자 동의 후 수동).
dobby_end_remove() {
  local src="$1" wt="$2"
  git -C "$src" worktree remove "$wt" 2>/dev/null && return 0
  git -C "$src" worktree remove --force "$wt"
}

# ── 작명·콘텐츠 스캐폴딩 헬퍼 ────────────────────────────────────────
# 슬러그·요약 문서 구조·카드 블록을 스킬·실행마다 다르게 쓰지 않도록 형식을 고정한다.
# (값·본문 "내용"은 여전히 LLM이 채운다 — 여기선 틀과 경계만 보장한다.)

# _slug_taken OFILE SLUG — orchestration.md 상태표 슬러그 칸에 SLUG가 이미 있으면 0(있음).
_slug_taken() {
  awk -v want="$2" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/\*/,"",x);return x}
    /^## /{ins=($0 ~ /에이전트 상태표/)?1:0;hdr=0;next}
    ins==1 && /^\|/{
      n=split($0,a,"|")
      if(hdr==0){for(i=1;i<=n;i++){c=t(a[i]);if(c=="슬러그"||c=="에이전트")cs=i}if(cs)hdr=1;next}
      if(cs && t(a[cs])==want){found=1}
    }
    END{exit(found?0:1)}' "$1"
}

# dobby_slug KEY "원하는 이름" — 슬러그를 안전한 영문 kebab로 정리하고, 상태표의 기존 슬러그와
# 겹치면 -2·-3…으로 고유화해 stdout으로 돌려준다. 슬러그는 agents/·reviews/·agent-logs.json·
# avatars.json의 조인 키라 공백·/·특수문자가 들어가면 매칭이 깨진다. 영문/숫자/하이픈만 남긴다.
# 정리 후 비면(예: 한글만) 'agent'로 대체하고 경고한다.
dobby_slug() {
  local key="$1" want="$2" base slug n=2 of
  base="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$base" ]; then
    base="agent"
    printf 'dobby-lib: 슬러그로 쓸 영문이 없어 "%s"→"agent"로 대체(영문 kebab 권장)\n' "$want" >&2
  fi
  slug="$base"; of="$(_order_dir "$key")/orchestration.md"
  if [ -f "$of" ]; then
    while _slug_taken "$of" "$slug"; do slug="$base-$n"; n=$((n+1)); done
  fi
  printf '%s' "$slug"
}

# dobby_scaffold_doc KEY analysis|implementation|produce|design|outcome [슬러그] — 요약 문서에 고정 섹션 틀을
# 깐다(없을 때만·비파괴). 세 문서의 목차를 통일해 구조가 스킬·실행마다 달라지는 것을 막는다.
# AI는 각 헤더 아래 내용만 채운다. 슬러그를 주면 fan-out 파일명({type}-{slug}.md).
dobby_scaffold_doc() {
  local key="$1" type="$2" slug="${3:-}" dir f fname="$2"
  dir="$(_order_dir "$key")"; mkdir -p "$dir"
  [ -n "$slug" ] && fname="$type-$slug"
  f="$dir/$fname.md"
  [ -f "$f" ] && return 0
  case "$type" in
    analysis) cat > "$f" <<EOF
# $key 분석${slug:+ · $slug}

## 원인
(원인 위치 \`파일:라인\`)

## 활성 경로
(실제 실행되는 코드 경로 증명)

## 이 앱에 없는 것
(레거시·별도 번들 앱이면 필수 — i18n 초기화 여부 / same-origin 도달 API 경로 / 공용 패키지 컴포넌트 사용 가능 여부. 일반 앱이면 "해당 없음")

## 수정 설계
(어디를 어떻게 — 대안 포함)

## 대안·더 단순한 방법

## 미해결·확인 필요
EOF
      ;;
    implementation) cat > "$f" <<EOF
# $key 구현${slug:+ · $slug}

## 건드린 파일

## 핵심 설계 결정

## 경계·공용 파일 처리

## 미해결

## 커밋·브랜치
EOF
      ;;
    produce) cat > "$f" <<EOF
# $key 산출${slug:+ · $slug}

## 산출 대상

## 구성

## 핵심 결정

## 근거·출처

## 미해결
EOF
      ;;
    design) cat > "$f" <<EOF
# $key 설계${slug:+ · $slug}
> 구현 전 설계 — 이 문서를 수정하면 구현이 수정본을 따른다 (대시보드 "설계/결과" 탭에서 편집 가능)
> 1부는 사실(지금 코드가 이렇다), 2부는 판단(그래서 이렇게 바꾼다). 같은 말을 두 번 쓰지 않는다.

## 한 장 요약
| | |
|---|---|
| 무엇이 문제인가 | (한 문장) |
| 무엇을 고치는가 | (한 문장) |
| 고치면 어떻게 되는가 | (한 문장) |

# 1부 · 지금 어떻게 동작하나

## 관련 파일
(고칠 파일과 읽어야 할 파일의 경로를 전부 — 생략·말줄임 금지)

## 현재 동작
(실제 코드를 보여 주고 무슨 일을 하는지 쉬운 말로. 흐름이 있으면 그림으로)

## 문제가 되는 코드와 원인
(문제를 만드는 코드를 직접 보여 주고, 왜 그렇게 되는지 — 증상이 아니라 원인)

# 2부 · 무엇을 어떻게 고치나

## 고칠 코드
(파일마다 아래 네 줄 형식을 그대로 반복한다)

### {경로/파일} ({n}번째 줄 근처)

지금
\`\`\`
(바뀌는 줄 주변 5줄까지)
\`\`\`

고친 뒤
\`\`\`
(바뀌는 줄 주변 5줄까지)
\`\`\`

왜 — (쉬운 말로 한두 문장)

## 결정과 근거
| 결정한 것 | 고른 답 | 왜 | 검토한 대안 |
|---|---|---|---|

## 닫히는 조건
(status.md의 닫히는 조건 그대로)

## 예상 파급
(side-effects.md 요약)

## 확인이 필요했던 것
(대화형이면 사용자에게 물은 것과 답 / 자율이면 스스로 정한 결정과 그 이유 — 이유 없는 결정 금지)

## 확인하지 못한 것
(모르는 채 남은 것. 없으면 "없음")

## 용어
(이 문서에 나온 전문용어: 쉬운 뜻)
EOF
      ;;
    outcome) cat > "$f" <<EOF
# $key 구현 결과
> 설계한 내용이 실제로 어떻게 구현됐는지 — 아티팩트 문서의 1차 근거 (쉬운 용어, 줄임말·내부 용어 금지)

## 한 줄 요약
(무엇이 만들어졌는지 한 문장)

## 설계 대비 결과
| 설계 항목 | 구현 결과 | 설계와 달라진 점 |
|---|---|---|

## 구현 내용
(구성요소별 — 무엇을 하는가 / 어디에 \`경로/파일\` / 어떻게 동작하는가)

## 동작 흐름
(단계별로)

## 용어
(용어: 쉬운 뜻)
EOF
      ;;
    *) _die "dobby_scaffold_doc: 알 수 없는 종류 '$type' (analysis|implementation|produce|design|outcome)"; return 2 ;;
  esac
}

# dobby_card KEY FILE "제목행" "본문" — 카드형 문서(decisions.md·side-effects.md·test-guide.md)에
# `## 제목행` 블록을 앞뒤 빈 줄과 함께 append한다(읽기 없이). 대시보드가 `## ` 단위로 카드를
# 쪼개므로 이 경계만 지키면 카드가 안 깨진다. 본문의 필드 라벨은 자유(파서가 요구하지 않음).
dobby_card() {
  local key="$1" file="$2" header="$3" body="$4"
  dobby_append "$key" "$file" "$(printf '\n## %s\n\n%s\n' "$header" "$body")"
}

# ── 설계 문서(design.md) 리비전·확인 서명 ────────────────────────────
# "구현이 설계를 다시 읽었는가"는 관측 불가 → "읽어야만 알 수 있는 값(내용 해시)을 적었는가"로 바꾼다.
# 사용자가 설계를 고치면 rev가 바뀌고, 옛 rev로 서명한 구현은 dobby_lint(#17)가 치명으로 잡는다.

# dobby_design_rev KEY — design.md 내용 sha256 앞 8자리. 파일 없으면 빈 문자열.
dobby_design_rev() {
  local f; f="$(_order_dir "$1")/design.md"
  [ -f "$f" ] || return 0
  shasum -a 256 "$f" 2>/dev/null | cut -c1-8
}

# dobby_design_ack KEY SLUG — 지금 rev를 "이 슬러그가 확인한 설계 버전"으로 기록(design-ack.json).
# 구현 에이전트가 착수 직후·P8 재개 직후 호출한다. rev를 stdout으로 돌려준다.
dobby_design_ack() {
  local key="$1" slug="$2" rev f
  rev="$(dobby_design_rev "$key")"
  [ -n "$rev" ] || { _die "design.md 없음 — 먼저 설계 문서를 만드세요(/dobby-design $key)"; return 1; }
  f="$(_order_dir "$key")/design-ack.json"
  [ -f "$f" ] || printf '{}' > "$f"
  jq --arg s "$slug" --arg r "$rev" '.[$s] = $r' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  case "$slug" in 사용자|auto) _v2_takeover_clear "$key" ;; esac   # /do 이어받기 설계 확정
  printf '%s' "$rev"
}

# dobby_design_backup KEY — regen 전 백업(design.md → design.md.bak). 사용자 수정본 유실 방지.
dobby_design_backup() {
  local f; f="$(_order_dir "$1")/design.md"
  [ -f "$f" ] && cp "$f" "$f.bak"
  return 0
}

# ── 클로드 아티팩트 기록 (artifact-share.md) ─────────────────────────
# 한 오더가 여러 아티팩트를 게시할 수 있다(구현 결과·회고 요약 등). 그래서 링크를 **표 한 줄씩**
# 쌓고, 슬러그로 신규/갱신을 가른다. 슬러그는 게시 원고 파일명과 짝이다 — artifacts/{슬러그}.html
#
# 예전 형식(불릿 `- **링크**: …` 한 건)도 그대로 남는다 — 대시보드 파서가 둘 다 읽으므로
# 끝난 오더의 파일을 건드리지 않는다(비파괴). 그 오더를 다시 게시하면 아래 함수가
# `## 아티팩트` 표를 새로 만들어 자연히 표 형식으로 넘어간다.

# dobby_artifact_share_path KEY — artifact-share.md 경로. 없으면 머리말만 만들어 둔다.
dobby_artifact_share_path() {
  local key="$1" f
  f="$(_order_dir "$key")/artifact-share.md"
  [ -f "$f" ] || printf '# %s 아티팩트 공유\n' "$key" > "$f"
  printf '%s' "$f"
}

# dobby_artifact_add KEY SLUG TITLE URL — '## 아티팩트' 표에 행을 추가한다.
# 같은 슬러그 행이 이미 있으면 **아무것도 하지 않고 1을 반환**한다(갱신은 dobby_artifact_touch).
# ⛔ 슬러그가 다른 아티팩트를 기존 URL로 덮어쓰지 마라 — 이전 링크가 죽는다.
dobby_artifact_add() {
  local key="$1" slug="$2" title="$3" url="$4" f now
  [ -n "$key" ] && [ -n "$slug" ] && [ -n "$url" ] || {
    _die "dobby_artifact_add: KEY SLUG TITLE URL 필요"; return 2; }
  printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9-]*$' || {
    _die "dobby_artifact_add: 슬러그는 소문자·숫자·하이픈만 (받은 값: $slug)"; return 2; }
  f="$(dobby_artifact_share_path "$key")"
  if _artifact_row_exists "$f" "$slug"; then
    printf 'dobby-lib: %s 아티팩트 "%s" 행이 이미 있습니다 — 갱신은 dobby_artifact_touch\n' \
      "$key" "$slug" >&2
    return 1
  fi
  now="$(_now)"
  _table_row_append "$f" "아티팩트" \
    "| 슬러그 | 제목 | 링크 | 생성 | 갱신 |" \
    "|--------|------|------|------|------|" \
    "| $slug | ${title:-$slug} | $url | $now |  |"
}

# dobby_artifact_touch KEY SLUG [NOTE] — 그 슬러그 행의 '갱신' 칸만 현재 시각으로 고친다.
# NOTE를 주면 `2026-09-07 10:40 (설명)` 형태로 적는다(기존 파일 관례와 동일).
dobby_artifact_touch() {
  local key="$1" slug="$2" note="${3:-}" f now val
  f="$(_order_dir "$key")/artifact-share.md"
  [ -f "$f" ] || { _die "dobby_artifact_touch: $f 없음"; return 2; }
  _artifact_row_exists "$f" "$slug" || {
    _die "dobby_artifact_touch: 슬러그 '$slug' 행이 없습니다 — 신규는 dobby_artifact_add"; return 1; }
  now="$(_now)"; val="$now"; [ -n "$note" ] && val="$now ($note)"
  # 헤더에서 '슬러그'·'갱신' 칼럼 위치를 찾아 그 칸만 수정한다(스키마 하드코딩 금지 —
  # dobby_agent_state와 같은 방식).
  awk -F'|' -v OFS='|' -v slug="$slug" -v val="$val" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## / { ins=(index($0,"아티팩트")>0)?1:0; hdr=0; print; next }
    ins==1 && /^\|/ {
      if (hdr==0) {
        for(i=1;i<=NF;i++){c=t($i); if(c=="슬러그")cs=i; else if(c=="갱신")cu=i}
        if(cs>0 && cu>0) hdr=1
        print; next
      }
      issep=1; for(i=2;i<NF;i++){c=t($i); if(c!="" && c !~ /^-+$/){issep=0;break}}
      if(issep){print;next}
      if(t($(cs))==slug && cu>0) $(cu)=" " val " "
      print; next
    }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# _artifact_row_exists FILE SLUG — '## 아티팩트' 표에 그 슬러그 행이 있으면 0.
# ⛔ 이 섹션 안만 본다 — 파일 다른 곳(레거시 불릿·설명문)에 같은 낱말이 있어도 오판하지 않게.
_artifact_row_exists() {
  local f="$1" slug="$2"
  [ -f "$f" ] || return 1
  awk -F'|' -v slug="$slug" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## / { ins=(index($0,"아티팩트")>0)?1:0; next }
    ins==1 && /^\|/ { if(t($2)==slug){found=1; exit} }
    END{ exit(found?0:1) }
  ' "$f"
}

# dobby_terms_lint FILE — 아티팩트로 나갈 문서(outcome.md 등)의 내부 용어·줄임말 검출.
# 검출 줄을 "줄번호:내용"으로 출력하고 1을 반환(없으면 0). 이슈 키(FE-1234·FE1-1234)는 제외.
# dobby-share가 게시 전에 부르고, dobby_lint #13이 치명으로 집계한다.
dobby_terms_lint() {
  local f="$1" hits
  [ -f "$f" ] || return 0
  hits="$(grep -nE '(\bFE\b|\bBE\b)([^0-9-]|$)|round-[0-9]|\bP[0-9]([^0-9A-Za-z]|$)|blocking *= *[0-9]|\bK *= *[0-9]|\b(impl|review)-[a-z]+' "$f" 2>/dev/null)"
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

# dobby_tooling_lint FILE — 공개 아티팩트에 들어가면 안 되는 **도구 이야기** 검출.
# 검출 줄을 "줄번호:내용"으로 출력하고 1을 반환(없으면 0). dobby-artifact가 게시 전에 부른다.
#
# 왜: 아티팩트를 읽는 사람은 이 도구를 쓰지 않는다. 도구 사정(스킬 이름·메타 파일·진행 구조)은
# 이슈가 요구한 것을 만든 이야기가 아니라 이 도구를 쓰다 생긴 뒤처리이며, 읽는 사람에게는 소음이다
# (dobby_lint #21과 같은 철학).
#
# ⛔ '대시보드'를 단독으로 넣지 마라 — 업무로 다루는 일반 대시보드를 가리키는 정상 문장이
#    걸린다(기존 explainer.md·outcome.md 145개로 실측: '대시보드' 1건이 전부 오탐이었고,
#    실제로 잡아야 할 것은 dobby 24곳·워크트리 6곳이었다). 이 도구는 'mentis'로만 건다.
#
# dobby_lint #21은 orchestration.md·status.md 를 패턴에서 뺐지만(그 검사 대상인 explainer.md가
# 머리에 "근거: …"로 그 이름을 정상 인용해 28개가 통째로 오탐), 여기서는 **일부러 넣는다** —
# 검사 대상이 다르다. 공개 아티팩트에서 그 파일 이름을 인용하는 것은 정상 인용이 아니라
# 도구가 새어 나간 것이다. 같은 145개에 돌리면 그 28건이 더 걸리는데, 아티팩트 기준으로는
# 전부 빼야 할 줄이다.
dobby_tooling_lint() {
  local f="$1" hits
  [ -f "$f" ] || return 0
  hits="$(grep -niE 'dobby|도비|mentis|오케스트레이션 메타|워크트리|에이전트 상태표|칸반|슬러그|artifact-share|design-ack|orchestration\.md|status\.md|explainer\.md' "$f" 2>/dev/null)"
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

# ── 아바타 소감(avatar-quips) 결정론 조각 ────────────────────────────
# 소감 "내용"은 LLM 몫. 여기서는 서명(sig) 계산·직전 소감 추출·JSON 병합만 한다.

# _board_rows OFILE — 상태표에서 "슬러그<TAB>상태<TAB>라운드"를 줄 단위로 출력(구분선 제외).
_board_rows() {
  awk '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/\*/,"",x);return x}
    /^## /{ins=(index($0,"에이전트 상태표")>0)?1:0; hdr=0; next}
    ins==1 && /^\|/{
      n=split($0,a,"|")
      if(hdr==0){for(i=1;i<=n;i++){c=t(a[i]);if(c=="슬러그"||c=="에이전트")cs=i;if(c=="상태")ct=i;if(c=="라운드")cr=i}
        if(cs&&ct)hdr=1; next}
      issep=1; for(i=2;i<n;i++){c=a[i];gsub(/[ \t-]/,"",c);if(c!=""){issep=0;break}}
      if(issep)next
      s=t(a[cs]); st=t(a[ct]); rd=(cr>0)?t(a[cr]):""
      if(s!="")print s "\t" st "\t" rd
    }' "$1"
}

# dobby_quips_sig KEY SLUG — 소감 재생성 서명(sig)을 계산해 stdout으로 낸다(직접 암산 금지).
# ⛔ 대시보드 공식과 정확히 일치(orchestration.ts agentSigs/orchestratorSig):
#  · 일반 슬러그: "<상태>#<라운드>"  (deliverables/{슬러그}.md 또는 폴더가 있으면 상태=완료 보정)
#  · __orchestrator__: "<모든 에이전트 상태를 정렬해 | 조인>#r<최대 라운드>" (정렬은 코드포인트 순 = LC_ALL=C)
dobby_quips_sig() {
  local key="$1" slug="$2" of dir rows
  of="$(_order_dir "$key")/orchestration.md"; dir="$(_order_dir "$key")"
  [ -f "$of" ] || { _die "orchestration.md 없음: $of"; return 1; }
  rows="$(_board_rows "$of")"
  if [ "$slug" = "__orchestrator__" ]; then
    local states maxr
    states="$(printf '%s\n' "$rows" | awk -F'\t' 'NF{print $2}' | LC_ALL=C sort | paste -sd'|' -)"
    maxr="$(printf '%s\n' "$rows" | awk -F'\t' '$3 ~ /^[0-9]+$/ {if($3+0>m)m=$3+0} END{print m+0}')"
    printf '%s#r%s' "$states" "$maxr"
    return 0
  fi
  local st rd
  st="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$slug" '$1==s{print $2; exit}')"
  rd="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$slug" '$1==s{print $3; exit}')"
  { [ -e "$dir/deliverables/$slug.md" ] || [ -d "$dir/deliverables/$slug" ]; } && st="완료"
  printf '%s#%s' "$st" "$rd"
}

# dobby_quips_last KEY — 기존 소감 파일에서 슬러그별 "직전 board 소감"만 "슬러그<TAB>텍스트"로 추린다.
# 같은 상태여도 직전과 다른 뉘앙스로 쓰기 위한 최소 신호 — 히스토리 전체 통독을 대체한다
# (⛔ 품질 신호는 유지하고 토큰만 줄이는 함수. 이 신호 없이 쓰면 소감이 매번 비슷해진다).
dobby_quips_last() {
  local f="$(_meta)/.mentis-quips/$1.json"
  [ -f "$f" ] || return 0
  command -v jq >/dev/null 2>&1 || { dobby_check_deps; return 0; }
  jq -r '. as $r | (($r.board // {}) | keys[]) as $s
         | (($r.board[$s]) | if type == "array" then (.[-1] // {}) else . end) as $b
         | ((((($r.history // {})[$s] // []) | last | .text?) // $b.text // "") ) as $t
         | $s + "\t" + $t' "$f" 2>/dev/null
}

# dobby_quips_merge KEY 새소감JSON파일 — 새 소감(대상 슬러그만 담김)을 기존 {키}.json에 병합하고
# board 소감을 history에 append한 뒤 원자적으로(tmp→rename) 저장한다. 다른 슬러그의 기존 값은 보존.
# 새 파일 스키마: { "agents":{슬러그:{sig}}, "board":{...}, "changes":{...}, "reviews":{...} } (있는 것만).
# board/changes/reviews 의 값은 소감 하나(객체)여도 되고 여러 개(배열)여도 된다 — 대시보드가 둘 다 읽는다.
# history 에는 배열이면 맨 앞 소감을 한 줄 남긴다. state는 agents[슬러그].sig의 `#` 앞부분에서 얻는다.
# 시각은 DOBBY_ISO로 덮어쓰기 가능.
dobby_quips_merge() {
  local key="$1" newf="$2" dir f now
  command -v jq >/dev/null 2>&1 || { dobby_check_deps; _die "jq 없음 — quips 병합 불가"; return 1; }
  [ -f "$newf" ] || { _die "새 소감 파일 없음: $newf"; return 1; }
  dir="$(_meta)/.mentis-quips"; f="$dir/$key.json"; mkdir -p "$dir"
  [ -f "$f" ] || echo '{}' > "$f"
  now="${DOBBY_ISO:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
  jq --slurpfile nv "$newf" --arg at "$now" '
    ($nv[0]) as $n
    | .generatedAt = $at
    | .agents  = ((.agents  // {}) + ($n.agents  // {}))
    | .board   = ((.board   // {}) + ($n.board   // {}))
    | .changes = ((.changes // {}) + ($n.changes // {}))
    | .reviews = ((.reviews // {}) + ($n.reviews // {}))
    | .history = (reduce (($n.board // {}) | keys[]) as $s ((.history // {});
        (($n.board[$s]) | if type == "array" then .[0] else . end) as $q
        | .[$s] = ((.[$s] // []) + [{
          at: $at,
          state: (((($n.agents // {})[$s].sig) // "") | split("#")[0]),
          mood: $q.mood,
          text: $q.text }])))
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ── 메타 검사기(대시보드 계약 점검) ──────────────────────────────────
# dobby_lint KEY [strict] — 완성된 오더 메타가 대시보드 파서 계약에 맞는지 점검한다.
#   기본  : 문제를 목록으로 알려주고 항상 0으로 끝난다(비차단 — 기존과 동일).
#   strict: 치명 오류(⛔ = 대시보드에서 조용히 사라짐) 개수를 반환한다(0이면 통과).
#           → 단계 전이 게이트(dobby_gate)가 이 반환값으로 진행/차단을 정한다.
# 치명(⛔): 필수 파일 부재 · 상태표 --- 구분선 부재 · 상태 5정본 위반 · 슬러그 위생 위반.
# 경고(⚠): 오더 키 형식 · 단계값(쓸 때 자동교정) · 고아 파일 · 이벤트 날짜 · mermaid · 분기-산출 정합성 ·
#          이름(롤) 어휘 · 단계-산출물 정합 · agent-logs 하위 키 정본 · 틀 자리표시 잔존.
dobby_lint() {
  local key="$1" strict="${2:-}" dir w=0 e=0
  [ -n "$key" ] || { _die "dobby_lint: KEY 필요 (사용법: dobby_lint FE1-1234 [strict])"; return 2; }
  dir="$(_order_dir "$key")"
  local sf="$dir/status.md" of="$dir/orchestration.md"
  _w() { printf '⚠ %s\n' "$*"; w=$((w+1)); }
  _e() { printf '⛔ %s\n' "$*"; e=$((e+1)); }

  printf '── dobby_lint %s%s ──\n' "$key" "${strict:+ (strict)}"

  # 1) 오더 키 형식(대시보드 목록 인식 조건) — 경고
  printf '%s' "$key" | grep -qE '^([A-Za-z][A-Za-z0-9]*-[0-9]+|TASK-[A-Za-z0-9-]+)$' \
    || _w "오더 키 형식 벗어남 \"$key\" — 대시보드 목록에서 안 보일 수 있음(FE1-1234·TASK-slug 형식)"

  [ -d "$dir" ] || { _die "dobby_lint: 폴더 없음 $dir"; return 2; }

  # 2) 필수 파일: status.md 또는 orchestration.md 중 하나는 있어야 목록에 뜬다 — 치명
  [ -f "$sf" ] || [ -f "$of" ] \
    || _e "status.md·orchestration.md 둘 다 없음 — 대시보드 목록에서 사라짐"

  # 3) 오더 단계 정본(status.md 현재 단계) — 경고(쓸 때 dobby_phase가 자동교정)
  if [ -f "$sf" ]; then
    local praw pnorm
    praw="$(grep -m1 '\*\*단계\*\*' "$sf" 2>/dev/null | sed -E 's/.*\*\*단계\*\*[[:space:]]*[:：][[:space:]]*//; s/[[:space:]]*$//; s/\*//g')"
    if [ -n "$praw" ]; then
      case " $DOBBY_PHASES " in
        *" $praw "*) printf '✓ 단계값 8정본 OK (%s)\n' "$praw" ;;
        *) pnorm="$(dobby_norm_phase "$praw" 2>/dev/null)"; _w "단계값 '$praw' 정본 아님 — '$pnorm' 권장(헬퍼 dobby_phase 사용)" ;;
      esac
    fi
  fi

  # 4) 에이전트 상태표(orchestration.md): 표 구분선·상태 정본·슬러그 위생·조인
  local slugset=" " state_bad=0
  if [ -f "$of" ]; then
    # 4a) 표 --- 구분선(없으면 대시보드가 표로 인식 못 함) — 치명
    if grep -q '^## 에이전트 상태표' "$of"; then
      awk '/^## 에이전트 상태표/{ins=1;next} /^## /{ins=0} ins&&/^\|[- |]+\|[[:space:]]*$/{f=1} END{exit(f?0:1)}' "$of" \
        || _e "orchestration.md: 상태표에 --- 구분선 없음 — 대시보드가 표로 인식 못 함(헤더 아래 |---|---| 줄 필요)"
    fi
    # 4b) 슬러그<TAB>상태 추출
    local rows slug st
    rows="$(awk '
      /^## /{ins=($0 ~ /에이전트 상태표/)?1:0; hdr=0; next}
      ins==1 && /^\|/{
        n=split($0,a,"|")
        if(hdr==0){for(i=1;i<=n;i++){c=a[i];gsub(/^[ \t]+|[ \t]+$/,"",c);gsub(/\*/,"",c);if(c=="슬러그"||c=="에이전트")cs=i;if(c=="상태")ct=i}
          if(cs&&ct)hdr=1; next}
        issep=1; for(i=2;i<n;i++){c=a[i];gsub(/[ \t-]/,"",c);if(c!=""){issep=0;break}}
        if(issep)next
        slug=a[cs];st=a[ct];gsub(/^[ \t]+|[ \t]+$/,"",slug);gsub(/^[ \t]+|[ \t]+$/,"",st);gsub(/\*/,"",st)
        if(slug!="")print slug "\t" st
      }' "$of" 2>/dev/null)"
    while IFS="$(printf '\t')" read -r slug st; do
      [ -n "$slug" ] || continue
      slugset="$slugset$slug "
      case "$slug" in *" "*|*/*|*"*"*|*"("*) _e "슬러그 '$slug' 공백/특수문자 포함 — 계약·리뷰·로그·아바타 매칭 실패 위험" ;; esac
      case " $DOBBY_STATES " in *" $st "*) : ;; *) _e "상태값 '$st'(슬러그 $slug) 5정본 아님 — 대기·분석·구현·리뷰·완료 중 하나"; state_bad=1 ;; esac
    done <<EOF
$rows
EOF
    [ "$state_bad" = 0 ] && [ "$slugset" != " " ] && printf '✓ 상태값 5정본 OK\n'
  fi

  # 5) 슬러그 조인: 리뷰·계약 파일이 상태표 슬러그와 맞는지(고아 파일 탐지)
  # find 사용 — 매칭 없는 glob이 zsh에서 오류(no matches found)로 중단되는 것을 피한다.
  local fpath b
  while IFS= read -r fpath; do
    [ -n "$fpath" ] || continue
    b="$(basename "$fpath" .md)"
    case "$slugset" in *" $b "*) : ;; *) _w "${fpath#"$dir"/} 있으나 상태표에 슬러그 '$b' 없음 — 리뷰가 에이전트에 안 붙음" ;; esac
  done < <(find "$dir/reviews" -type f -name '*.md' 2>/dev/null)
  while IFS= read -r fpath; do
    [ -n "$fpath" ] || continue
    b="$(basename "$fpath" .md)"
    case "$b" in *review*|*리뷰*) continue ;; esac
    case "$slugset" in *" $b "*) : ;; *) _w "agents/$b.md 계약 있으나 상태표에 슬러그 '$b' 없음 — 표에 행을 추가하세요" ;; esac
  done < <(find "$dir/agents" -type f -name '*.md' 2>/dev/null)

  # 6) 이벤트 로그 날짜 형식(`- YYYY-MM-DD …`가 아니면 타임라인에서 누락)
  if [ -f "$of" ]; then
    local bad_ev
    bad_ev="$(awk '/^## 이벤트 로그/{ins=1;next} /^## /{ins=0} ins&&/^- /&&!/^- [0-9]{4}-[0-9]{2}-[0-9]{2}/{n++} END{print n+0}' "$of")"
    [ "${bad_ev:-0}" -gt 0 ] 2>/dev/null && _w "이벤트 로그 ${bad_ev}줄이 '- YYYY-MM-DD …' 형식이 아님 — 타임라인에서 누락됨"
  fi

  # 7) mermaid 라벨 따옴표(explainer.md 등): 특수문자 라벨이 따옴표 밖이면 렌더 실패
  for fpath in "$dir"/explainer.md "$dir"/retro.md; do
    [ -f "$fpath" ] || continue
    local badm
    badm="$(awk '/^```mermaid/{m=1;next} /^```/{m=0} m&&/\[[^]"]*[(\/][^]"]*\]/{n++} END{print n+0}' "$fpath")"
    [ "${badm:-0}" -gt 0 ] 2>/dev/null && _w "$(basename "$fpath") mermaid 라벨 ${badm}곳이 따옴표 없이 ( 또는 / 포함 — 'Syntax error'로 안 그려질 수 있음([\"라벨(x)\"]로)"
  done

  # 8) 분기-산출 정합성(status.md '종류'와 실제 산출 파일이 맞나) — 경고
  # find 사용 — 매칭 없는 glob이 zsh에서 오류(no matches found)로 중단되는 것을 피한다.
  if [ -f "$sf" ]; then
    local kind
    kind="$(grep -m1 '\*\*종류\*\*' "$sf" 2>/dev/null | sed -E 's/.*\*\*종류\*\*[[:space:]]*[:：][[:space:]]*//; s/[[:space:]]*$//; s/\*//g')"
    case "$kind" in
      *산출*) find "$dir" -maxdepth 1 -type f -name 'implementation*.md' 2>/dev/null | grep -q . \
        && _w "종류=산출물인데 implementation*.md 있음 — 비소스는 produce.md여야 함(분기 불일치)" ;;
    esac
    case "$kind" in
      *정리*) [ -f "$dir/explainer.md" ] \
        || _w "종류=작업정리인데 explainer.md 없음 — '작업 내용' 탭이 빈다" ;;
    esac
  fi

  # 9) 이름(롤) 어휘: 분석|개발자|산출자|리뷰어 (+ `·영역` 구분, `/` 겸직 — 예 분석/개발자·개발자·FE) — 경고
  if [ -f "$of" ]; then
    local names nm
    names="$(awk '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/\*/,"",x);return x}
      /^## /{ins=(index($0,"에이전트 상태표")>0)?1:0; hdr=0; next}
      ins==1 && /^\|/{
        n=split($0,a,"|")
        if(hdr==0){for(i=1;i<=n;i++){c=t(a[i]);if(c=="이름")ci=i}
          if(!ci){print "__NO_NAME_COL__"; exit} hdr=1; next}
        issep=1; for(i=2;i<n;i++){c=a[i];gsub(/[ \t-]/,"",c);if(c!=""){issep=0;break}}
        if(issep)next
        v=t(a[ci]); if(v!="")print v
      }' "$of")"
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      if [ "$nm" = "__NO_NAME_COL__" ]; then _w "상태표에 이름 컬럼 없음 — 고정 스키마(슬러그·이름·설명·상태·라운드·착수·갱신) 확인"; continue; fi
      printf '%s' "$nm" | grep -qE '^(분석|개발자|산출자|리뷰어)([·/].+)?$' \
        || _w "이름 '$nm' 롤 정본 아님 — 분석·개발자·산출자·리뷰어(+·영역, /겸직 예 분석/개발자) 중에서"
    done <<EOF
$names
EOF
  fi

  # 10) 단계-산출물 정합: 구현/산출 요약이 있는데 단계가 아직 착수면 갱신 누락 — 경고
  if [ -n "${praw:-}" ] && [ "$praw" = "착수" ]; then
    find "$dir" -maxdepth 1 -type f \( -name 'implementation*.md' -o -name 'produce*.md' \) 2>/dev/null | grep -q . \
      && _w "구현/산출 요약이 있는데 단계가 '착수' — dobby_phase로 단계를 올리세요"
  fi

  # 11) agent-logs.json 하위 키 정본: round-N(라운드) · analysis|impl(단계)만 — 경고
  local alog="$dir/agent-logs.json" badk
  if [ -f "$alog" ] && command -v jq >/dev/null 2>&1; then
    badk="$(jq -r '[to_entries[] | select(.value|type=="object") | .value | keys[]
                    | select(test("^(round-[0-9]+|analysis|impl)$")|not)] | unique | join(", ")' "$alog" 2>/dev/null)"
    [ -n "$badk" ] && _w "agent-logs.json 하위 키 '$badk' — 정본은 round-N(또는 analysis·impl). 새 슬러그·임의 키 금지"
  fi

  # 12) 틀 자리표시 잔존: 스캐폴드 틀 문구가 안 채워진 채 남으면 대시보드에 그대로 노출됨 — 경고
  local ph f2
  while IFS= read -r f2; do
    [ -n "$f2" ] || continue
    ph="$(grep -cE '^\((원인 위치|실제 실행되는 코드 경로 증명|어디를 어떻게|한 문단|무엇이 만들어졌는지|구성요소별|status.md의 닫히는 조건)' "$f2" 2>/dev/null)" || ph=0
    [ "${ph:-0}" -gt 0 ] 2>/dev/null && _w "$(basename "$f2") 틀 자리표시 ${ph}곳이 안 채워짐 — 헤더 아래 내용을 채우세요"
  done < <(find "$dir" -maxdepth 1 -type f \( -name 'analysis*.md' -o -name 'implementation*.md' -o -name 'produce*.md' -o -name 'design.md' -o -name 'outcome.md' \) 2>/dev/null)

  # 13) outcome.md 내부 용어·줄임말 — 치명(아티팩트 원고의 1차 근거라 밖으로 새면 못 되돌림)
  if [ -f "$dir/outcome.md" ]; then
    local terms
    terms="$(dobby_terms_lint "$dir/outcome.md")" || \
      _e "outcome.md 내부 용어·줄임말 $(printf '%s' "$terms" | grep -c .)곳 — FE/BE→프론트엔드/백엔드, round-N·P숫자·슬러그·blocking=·K= 금지: $(printf '%s' "$terms" | head -3 | tr '\n' ' ')"
  fi

  # 14) design.md 결정 표에 '왜'가 빈 행 — 치명(자율 모드가 컨펌을 건너뛰는 대가는 이유 기록)
  if [ -f "$dir/design.md" ]; then
    local badrow
    badrow="$(awk -F'|' '
      /^## /{ins=($0~/결정과 근거/); n=0; next}
      ins && /^\|/ { n++; if(n<=2) next;                # 헤더·구분선 제외
        w=$4; gsub(/^[ \t]+|[ \t]+$/,"",w);
        if(w=="") bad++ }
      END{print bad+0}' "$dir/design.md")"
    [ "${badrow:-0}" -gt 0 ] 2>/dev/null && _e "design.md 결정과 근거 표에 '왜'가 빈 행 ${badrow}건 — 이유 없는 결정 금지(스스로 정했으면 근거를 적는다)"
  fi

  # 15) outcome.md 재작업 경위 서술 — 경고(결과만 적는 문서. 경위는 lessons·retro 몫)
  if [ -f "$dir/outcome.md" ]; then
    local hist
    hist="$(grep -cE '라운드 ?[0-9]|리뷰(에서|를) |리뷰 지적|리뷰 반영|처음에는|처음엔 |되돌렸|재작업' "$dir/outcome.md" 2>/dev/null)" || hist=0
    [ "${hist:-0}" -gt 0 ] 2>/dev/null && _w "outcome.md에 재작업 경위 서술 ${hist}곳 — 이 문서는 결과만, 과정은 회고(retro.md)에"
  fi

  # 16) 단계=해결(개발 오더)인데 outcome.md 없음 — 경고(P7에서 인라인 생성 누락)
  if [ -f "$sf" ] && [ ! -f "$dir/outcome.md" ]; then
    local ph16 kind16
    ph16="$(sed -nE 's/^- \*\*단계\*\*: *(.*)$/\1/p' "$sf" | head -1)"
    kind16="$(sed -nE 's/^- \*\*종류\*\*: *(.*)$/\1/p' "$sf" | head -1)"
    case "$ph16" in 해결*|종료*) case "$kind16" in *개발*) _w "단계가 해결인데 outcome.md 없음 — P7 통합 후 구현 결과를 남기세요(/dobby-design $key outcome)";; esac;; esac
  fi

  # 17) 설계 확인 서명(design-ack)이 현재 설계와 불일치 — 치명(설계가 바뀐 뒤 구현이 옛 버전 기준)
  if [ -f "$dir/design.md" ] && [ -f "$dir/design-ack.json" ]; then
    local cur17 stale17
    cur17="$(dobby_design_rev "$key")"
    stale17="$(jq -r --arg c "$cur17" 'to_entries[] | select(.value != $c) | .key' "$dir/design-ack.json" 2>/dev/null | tr '\n' ' ')"
    [ -n "${stale17% }" ] && _e "설계가 바뀌었는데 옛 버전으로 서명된 에이전트: ${stale17}— design.md를 다시 읽고 dobby_design_ack 재실행"
  fi

  # 18) 계약 없는 구현 롤 행 — 경고
  # 검사 5는 반대 방향(파일은 있는데 표에 없는 고아 파일)만 본다. 이쪽은 "표에 있는데 계약이 없는" 쪽.
  # ⛔ 계약제를 채택한 오더(agents/에 계약이 1개 이상)에서만 발화한다. P4-L(경량)·P4-C(편입)·
  #    P4-W(작업정리)의 인라인 에이전트는 **스펙상 계약 파일이 없다**(dobby_bootstrap_inline은
  #    dobby_agent_add만 한다). 무조건 검사하면 그 오더들에 해소 방법이 없는 영구 경고가 달려
  #    "경고는 무시해도 된다"를 학습시킨다. (실측: 무조건 29/71건 → 조건부 5/71건)
  if [ -f "$of" ] && find "$dir/agents" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -q .; then
    local miss18="" s18
    while IFS= read -r s18; do
      [ -n "$s18" ] || continue
      [ -f "$dir/agents/$s18.md" ] || miss18="$miss18 $s18"
    done < <(_board_impl_slugs "$of")
    [ -n "$miss18" ] && _w "계약 없는 구현 롤:${miss18} — agents/{슬러그}.md 가 없습니다(같은 오더의 다른 슬러그는 계약이 있어 누락으로 보입니다)"
  fi

  # 19) 라운드 상한 초과인데 에스컬레이션 기록 없음 — 경고
  # dobby-order P6이 "최대 라운드 기본 3, 초과 시 사용자 에스컬레이션"을 규정하는데 강제 수단이
  # 없어 지켜지지 않는다(실측: 라운드 4~10까지 간 오더 10건 전부 에스컬레이션 기록 0건.
  # 사례 FE1-1803 라운드 6·3일 — 사용자는 끝난 뒤 회고로 알았다).
  # 라운드가 길어지는 것 자체가 문제가 아니라 **사용자가 모르는 채 길어지는 것**이 문제다.
  if [ -f "$of" ]; then
    local maxr19
    maxr19="$(_board_impl_slugs "$of" round | awk '$1+0>m{m=$1+0} END{print m+0}')"
    if [ "${maxr19:-0}" -ge 4 ] 2>/dev/null; then
      grep -qE '에스컬레|라운드 상한|상한 초과|사용자에게 확인|사용자 확인' "$of" \
        || _w "구현 라운드 ${maxr19}회인데 에스컬레이션 기록 없음 — P6은 최대 라운드 3 초과 시 사용자 확인을 요구합니다. 계속 돌리기 전에 남은 지적의 성격(코드 결함인지 문서 동기화인지)을 사용자에게 알리세요"
    fi
  fi

  # 20) design.md 내부 용어·줄임말 — 경고
  # design.md는 P3.5에서 **사용자가 읽고 승인하는 유일한 문서**다(승인 게이트 1회). 오케스트레이션
  # 내부 용어가 섞이면 읽는 사람이 무엇을 승인하는지 모른 채 넘기게 된다.
  # outcome.md(#13)와 달리 경고인 이유: design.md에는 코드 조각이 그대로 들어가고(코드 전후 대비가
  # 이 문서의 핵심이다), 코드 안의 실제 식별자가 약어 패턴에 걸려 오탐이 나기 때문이다.
  # 치명으로 잡으면 정상 문서가 게이트에서 막힌다.
  if [ -f "$dir/design.md" ]; then
    local terms20
    terms20="$(dobby_terms_lint "$dir/design.md")" || \
      _w "design.md 내부 용어·줄임말 $(printf '%s' "$terms20" | grep -c .)곳 — 사용자가 읽고 승인하는 문서입니다. FE/BE→프론트엔드/백엔드, round-N→N차 검토, P숫자→단계 이름, 슬러그→담당 이름으로 풀어 쓰세요(코드 안 식별자 인용이면 그대로 두어도 됩니다): $(printf '%s' "$terms20" | head -3 | tr '\n' ' ')"
  fi

  # 21) 산출물 문서에 메타 보정 흔적 — 경고 (dobby-order C10)
  # 규칙을 못 지켜 틀어진 기록을 바로잡은 일(빠진 문서 뒤늦게 작성·형식 복원·재서명·검사 통과)은
  # 개발 내용이 아니다. 이슈가 요구한 것을 만든 게 아니라 이 도구를 쓰다 생긴 뒤처리이며,
  # 문서를 읽는 사람에게는 소음이다. 기록은 orchestration.md 이벤트 로그 한 줄이면 된다.
  # ⛔ 패턴에 orchestration.md·status.md 를 넣지 않는다 — explainer.md 머리의 "근거: …" 출처
  #    표기가 그 이름을 정상적으로 인용해 28개 파일이 통째로 오탐이 된다(실측).
  #    아래 패턴은 메타 작업에만 나오는 것들이라 206개 파일 중 1건만 잡았다(오탐 0).
  local meta21="" f21 hit21
  for f21 in "$dir"/outcome.md "$dir"/explainer.md "$dir"/produce.md "$dir"/implementation*.md; do
    [ -f "$f21" ] || continue
    hit21="$(grep -cE 'dobby_[a-z_]+|artifact-share|design-ack|메타 (보정|정정|복원|누락)|산출물 보강|표기 규약' "$f21" 2>/dev/null)" || hit21=0
    [ "${hit21:-0}" -gt 0 ] 2>/dev/null && meta21="$meta21 $(basename "$f21")(${hit21})"
  done
  [ -n "$meta21" ] && _w "산출물 문서에 메타 보정 흔적:${meta21} — 메타를 바로잡은 일은 개발 내용이 아닙니다(C10). 해당 줄을 지우고 orchestration.md 이벤트 로그에만 남기세요"

  # 22) 닫히는 조건을 쪼개지 않음 — 치명 (dobby-order P1)
  # 한 줄짜리 닫히는 조건은 사람만 읽는다. 쪼개 두어야 dobby-test 가 result.md 조건 칸에
  # 번호를 적고 대시보드가 "조건 3가지 중 3가지 확인"을 스스로 센다.
  # 실측: 오더 125개 중 조건을 쪼갠 것이 12개(10%)뿐이라 나머지 113개는 검증 탭이
  # 끝까지 "사람이 판단하세요"에서 멈춰 있었다.
  if [ -f "$sf" ]; then
    local nc22
    nc22="$(dobby_conditions "$key" 2>/dev/null | grep -c .)" || nc22=0
    [ "${nc22:-0}" -eq 0 ] \
      && _e "status.md 에 '## 닫히는 조건 항목' 표가 없음 — 닫히는 조건 한 줄을 확인 가능한 단위로 쪼개 \`dobby_add_condition $key \"{한 줄}\"\` 로 넣으세요(보통 2~5개). 없으면 무엇을 끝내야 하는지 기계가 셀 수 없어 검증이 '사람이 판단하세요'에서 멈춥니다"
  fi

  printf '(치명 %d, 경고 %d)\n' "$e" "$w"
  [ -n "$strict" ] && return "$e"
  return 0
}

# _board_impl_slugs BOARD_FILE [round] — 상태표에서 **구현 롤**(이름에 개발자·산출자) 행만 골라
# 슬러그(기본) 또는 라운드 값(round)을 한 줄씩 낸다. 컬럼 위치는 헤더에서 찾는다(스키마 하드코딩 금지).
_board_impl_slugs() {
  local f="$1" what="${2:-slug}"
  awk -F'|' -v what="$what" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/\*/,"",x);return x}
    /^## /{ins=(index($0,"에이전트 상태표")>0)?1:0; hdr=0; next}
    ins==1 && /^\|/{
      if(hdr==0){
        for(i=1;i<=NF;i++){c=t($i)
          if(c=="슬러그")cs=i; else if(c=="이름")cn=i; else if(c=="라운드")cr=i}
        if(cs&&cn) hdr=1
        next
      }
      s=t($cs); n=t($cn); r=(cr?t($cr):"")
      if(s !~ /^[a-z0-9][a-z0-9-]+$/) next          # 구분선·헤더·날짜 칸을 걸러냄
      if(n !~ /개발자|산출자/) next                  # 리뷰어·Explore·감사는 대상 아님
      if(what=="round"){ if(r ~ /^[0-9]+$/) print r; else print 0 }
      else print s
    }' "$f"
}

# ── 진입 부트스트랩 · 분류 · 세션 (스킬 중복 기술을 함수 하나로) ──────────
# 스킬마다 제각각 적던 "제목·종류·세션·docs 게이트"를 진입 즉시 1회 호출로 모은다.
# 판단(제목/종류/키워드)만 AI가 인자로 넘기고, 파일에 '어떻게 적히나'는 전부 여기서 고정한다.

# dobby_set_kind KEY 개발|산출물|작업정리 — status.md '## 현재 단계'에 '- **종류**:' 한 줄(정본으로 접음).
# 대시보드 파서(parseOrderStatus.ts)는 /개발/·/산출/·/작업\s*정리|정리/로 부분 일치하므로 공백 유무는 무관.
# 대시보드가 이 값으로 개발/비개발 집계·상세 탭 구성을 정한다.
dobby_set_kind() {
  local key="$1" kind f; kind="$(_trim "$2")"
  case "$kind" in
    *개발*)         kind=개발 ;;
    *산출*|*비소스*) kind=산출물 ;;
    *정리*)         kind="작업 정리" ;;
  esac
  f="$(_order_dir "$key")/status.md"; [ -f "$f" ] || return 1
  if grep -q '\*\*종류\*\*' "$f"; then          # 이미 있으면 그 줄만 교체
    awk -v k="$kind" '
      /^## / { insec = ($0 ~ /현재 단계/) }
      { if (insec && $0 ~ /\*\*종류\*\*/) { print "- **종류**: " k; next } print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else                                          # 없으면 '단계' 줄 바로 아래 삽입
    awk -v k="$kind" '
      /^## / { insec = ($0 ~ /현재 단계/) }
      { print; if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*단계\*\*/) print "- **종류**: " k }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 세션 ID — ⛔ **추정하지 않는다.** Claude Code 가 내려 주는 값을 그대로 쓴다.
#
# 예전에는 cwd 의 프로젝트 폴더에서 `ls -t | head -1` 로 "가장 최근에 수정된 전사 = 내 세션"
# 이라고 **가정**했다. `~/work/dobby-playground` 처럼 여러 오더가 공유하는 폴더에서는 이게
# 틀린다 — 그 순간 남의 세션이 더 최근일 수 있고, 특히 **오래 떠 있는 세션**은 계속 기록되어
# 자주 이긴다.
#
# 실측(오더 전수 검사): 10건이 남의 세션을 가리키고 있었다 —
#   FE-8218 · FE1-1523 · FE1-1574 · FE1-1576 · FE1-1830 ·
#   FE1-1912 · FE1-1969 · FE1-1983 · FE1-2134 · TASK-local-rc4-debug
# FE1-2134 는 TASK-toss-research 의 세션(9/15~10/12 내내 살아 있던 것)을 가리켰다. 그 전사에
# `FE1-2134` 는 0번, `toss` 는 353번 나온다. 대시보드 '이어가기'를 누르면 남의 세션이 열렸다.
# ─────────────────────────────────────────────────────────────────────────────

# _session_id [CWD] — 지금 돌고 있는 세션의 ID.
#   ① CLAUDE_CODE_SESSION_ID (정본) ② 없으면 옛 추정으로 떨어진다(구버전 CLI 대비)
_session_id() {
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf '%s' "$CLAUDE_CODE_SESSION_ID"; return 0; fi
  local cwd="${1:-$PWD}" enc
  enc="$(printf '%s' "$cwd" | sed 's#[/.]#-#g')"          # 인코딩cwd: '/'·'.' → '-'
  basename "$(ls -t "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null | head -1)" .jsonl 2>/dev/null
}

# _session_transcript [세션ID] — 그 세션의 전사 파일 경로. 없으면 빈 값.
# ⛔ cwd 로 폴더를 짐작하지 않고 **ID 로 찾는다** — 세션의 cwd 와 넘겨받은 cwd 가 다를 수 있다.
_session_transcript() {
  local sid="${1:-$(_session_id)}"
  [ -n "$sid" ] || return 0
  find "$HOME/.claude/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1
}

# dobby_set_session KEY [CWD] — status.md '## 세션'에 세션 ID·경로 기록(대시보드 '이어가기'의 근거).
# 세션 ID는 손으로 적지 않는다 — _session_id 가 준 값을 그대로 쓴다.
dobby_set_session() {
  local key="$1" cwd="${2:-$(pwd)}" f sid
  f="$(_order_dir "$key")/status.md"; [ -f "$f" ] || return 1
  sid="$(_session_id "$cwd")"
  [ -n "$sid" ] || { printf 'dobby-lib: 세션 ID 를 알 수 없다(CLAUDE_CODE_SESSION_ID 없음) — 세션 기록 건너뜀\n' >&2; return 0; }
  grep -q '^## 세션' "$f" && return 0                     # 이미 있으면 유지(비파괴)
  cat >> "$f" <<EOF

## 세션
- **세션 ID**: $sid
- **작업 경로**: $cwd
EOF
}

# dobby_session_log KEY SLUG SUBKEY STEP [CWD] — 세션을 단계마다 새로 여는 오더(/do)의 세션 기록.
#   ① status.md '## 세션' 의 세션 ID·작업 경로를 **지금 세션으로 바꾼다**(대시보드 '이어가기'가 최신 세션을 연다).
#      dobby_set_session 은 이미 있으면 두지만, 이 함수는 단계마다 갈아 끼운다.
#   ② status.md '## 지난 세션' 표에 한 줄을 더한다(시각·단계·세션 아이디·작업 경로) — 나중에 claude --resume 으로 복기.
#      표 머리는 '세션 아이디'로 쓴다. '세션 ID:' 꼴은 대시보드가 최신 세션으로 읽으므로 이 표에 쓰지 않는다.
#   ③ agent-logs.json 의 {SLUG:{SUBKEY: 전사 경로}} 로 남겨 대시보드 콘솔에서 단계별 기록을 연다.
#   같은 세션·같은 단계로 두 번 불러도 표에 한 줄만 남는다.
#   '## 세션' 에 다른 세션이 적혀 있고 표에 아직 없으면, 덮어쓰기 전에 그 세션을 '이전 세션' 줄로 먼저 옮긴다
#   (dobby-order 로 시작한 오더의 원래 세션을 잃지 않게). 시각 칸은 그 대화 기록 파일의 마지막 수정 시각이다.
dobby_session_log() {
  local key="$1" slug="$2" sub="$3" step="$4" cwd="${5:-$(pwd)}" f sid tr old oldcwd oldtr oldt
  f="$(_order_dir "$key")/status.md"; [ -f "$f" ] || return 1
  sid="$(_session_id "$cwd")"
  [ -n "$sid" ] || { printf 'dobby-lib: 세션 ID 를 알 수 없다(CLAUDE_CODE_SESSION_ID 없음) — 세션 기록 건너뜀\n' >&2; return 0; }
  old="$(_session_field "$f" '세션 ID')"; oldcwd="$(_session_field "$f" '작업 경로')"
  if [ -n "$old" ] && [ "$old" != "$sid" ] && ! grep -qF "\`$old\`" "$f"; then
    oldtr="$(_session_transcript "$old")"
    [ -n "$oldtr" ] && oldt="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$oldtr" 2>/dev/null)"
    _past_session_add "$f" "| ${oldt:-(기록 전)} | 이전 세션 | \`$old\` | $oldcwd |"
  fi
  if grep -q '^## 세션' "$f"; then
    awk -v sid="$sid" -v cwd="$cwd" '
      /^## /{ins=($0 ~ /^## 세션[[:space:]]*$/)?1:0}
      ins==1 && /^- \*\*세션 ID\*\*:/{print "- **세션 ID**: " sid; next}
      ins==1 && /^- \*\*작업 경로\*\*:/{print "- **작업 경로**: " cwd; next}
      {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    dobby_set_session "$key" "$cwd"
  fi
  grep -q "| $step | \`$sid\` |" "$f" || _past_session_add "$f" "| $(_now) | $step | \`$sid\` | $cwd |"
  tr="$(_session_transcript "$sid")"
  [ -n "$tr" ] && dobby_log "$key" "$slug" "$tr" "$sub"
  return 0
}

# _session_field FILE 이름 — status.md '## 세션' 절의 '- **이름**: 값' 의 값(백틱 제거). 없으면 빈 값.
_session_field() {
  awk -v k="$2" '
    /^## /{ins=($0 ~ /^## 세션[[:space:]]*$/)?1:0; next}
    ins==1 && index($0, "- **" k "**:")==1 {sub(/^[^:]*:[ \t]*/,""); gsub(/`/,""); gsub(/[ \t]+$/,""); print; exit}' "$1"
}

# _past_session_add FILE ROW — '## 지난 세션' 표 끝에 한 줄을 붙인다(표가 없으면 만든다).
_past_session_add() {
  local f="$1" row="$2"
  grep -q '^## 지난 세션' "$f" || printf '\n## 지난 세션\n| 시각 | 단계 | 세션 아이디 | 작업 경로 |\n|---|---|---|---|\n' >> "$f"
  awk -v row="$row" '
    /^## 지난 세션/ {inb=1; print; next}
    inb==1 && /^\|/ {print; next}
    inb==1 {print row; inb=0; print; next}
    {print}
    END{ if(inb==1) print row }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ── dobby-order → /do 전환 (dobby-migrate-v2 스킬이 쓴다) ──────────────
# _board_dev_slug OFILE — 상태표에서 이름이 "개발자" 인 첫 행의 슬러그. 없으면 "분석/개발자"(나누기 전 오더), 그것도 없으면 빈 값.
_board_dev_slug() {
  local s st r want
  [ -f "$1" ] || return 0
  for want in "개발자" "분석/개발자"; do
    while IFS=$'\t' read -r s st r; do
      [ "$(_board_role "$1" "$s")" = "$want" ] && { printf '%s' "$s"; return 0; }
    done < <(_board_rows "$1")
  done
}

# dobby_split_dev KEY [check] — /do 오더의 "분석/개발자" 카드를 분석(analysis-agent)과 개발자 두 장으로 나눈다.
# 설계 쪽 세션 기록(design·takeover·change-*·answer-*)은 분석 카드로 옮긴다. check 면 바꾸지 않고 할 일만 낸다.
dobby_split_dev() {
  local key="$1" mode="${2:-}" d o f lg dev="" st ph ast dst moved desc s r
  d="$(_order_dir "$key")"; o="$d/orchestration.md"; f="$d/status.md"; lg="$d/agent-logs.json"
  [ -f "$o" ] || { printf '건너뜀\t보드 없음\n'; return 1; }
  grep -q '^## 지난 세션' "$f" 2>/dev/null || { printf '건너뜀\t/do 오더가 아님\n'; return 1; }
  while IFS=$'\t' read -r s st r; do
    [ "$(_board_role "$o" "$s")" = "분석/개발자" ] && { dev="$s"; break; }
  done < <(_board_rows "$o")
  [ -n "$dev" ] || { printf '건너뜀\t분석/개발자 카드 없음\n'; return 1; }
  pgrep -f "run\.sh'? '?$key'?( |\$)" >/dev/null && { printf '건너뜀\t자동 실행 중\n'; return 1; }
  st="$(_board_rows "$o" | awk -F'\t' -v s="$dev" '$1==s{print $2; exit}')"
  ph="$(_order_phase "$key")"
  case "$ph" in 착수|분석) ast="$st"; dst=대기 ;; *) ast=완료; dst="$st" ;; esac
  moved="$(jq -r --arg s "$dev" '(.[$s] // {}) | if type == "object" then [keys[] | select(test("^(design|takeover|change-|answer-)"))] | join(",") else "" end' "$lg" 2>/dev/null)"
  if [ "$mode" = check ]; then
    printf '대상\t단계=%s 분석=%s 개발자(%s)=%s→%s 옮길기록=%s\n' "$ph" "$ast" "$dev" "$st" "$dst" "${moved:-없음}"
    return 0
  fi
  cp "$o" "$o.before-split"; [ -f "$lg" ] && cp "$lg" "$lg.before-split"
  desc="$(awk -F'|' -v want="$dev" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## /{ins=($0~/에이전트 상태표/)?1:0;hdr=0;next}
    ins==1 && /^\|/{ if(hdr==0){for(i=1;i<=NF;i++){c=t($i);if(c=="슬러그")cs=i;else if(c=="설명")cd=i}; hdr=1; next}
      if(cs && cd && t($cs)==want){print t($cd);exit} }' "$o")"
  dobby_agent_add "$key" analysis-agent "분석" "${desc:-설계}" "$ast" 0
  awk -F'|' -v OFS='|' -v want="$dev" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## /{ins=($0~/에이전트 상태표/)?1:0;hdr=0;print;next}
    ins==1 && /^\|/{ if(hdr==0){for(i=1;i<=NF;i++){c=t($i);if(c=="슬러그")cs=i;else if(c=="이름")cn=i}; hdr=1; print; next}
      if(cs && cn && t($cs)==want) $(cn)=" 개발자 " }
    {print}' "$o" > "$o.tmp" && mv "$o.tmp" "$o"
  [ "$dst" = "$st" ] || DOBBY_AUTO_EVENT=0 dobby_agent_state "$key" "$dev" "$dst"
  if [ -n "$moved" ]; then
    jq --arg s "$dev" '
      (.[$s] | with_entries(select(.key | test("^(design|takeover|change-|answer-)")))) as $m
      | .["analysis-agent"] = ((.["analysis-agent"] // {}) + $m)
      | .[$s] |= with_entries(select(.key | test("^(design|takeover|change-|answer-)") | not))' "$lg" > "$lg.tmp" && mv "$lg.tmp" "$lg"
  fi
  dobby_event "$key" "분석/개발자 카드를 분석과 개발자로 나눔 — 설계 쪽 세션 기록을 분석 카드로 옮김"
}

# _review_last_round KEY — reviews/round-N 중 가장 큰 N. 없으면 0.
_review_last_round() {
  local d n=0 x; d="$(_order_dir "$1")/reviews"
  for x in "$d"/round-*; do [ -d "$x" ] || continue; x="${x##*round-}"; [ "$x" -gt "$n" ] 2>/dev/null && n="$x"; done
  printf '%s' "$n"
}

# _v2_takeover_pending KEY — 상태 문서에 '이어받기' 표시가 있으면 0. 표시는 dobby_migrate_v2_apply 가 남기고,
# 사람(또는 auto)이 이어받기 설계를 확정할 때 dobby_design_ack 가 지운다. /do 단계 판정과 run.sh 가 본다.
_v2_takeover_pending() {
  grep -q '^- \*\*이어받기\*\*:' "$(_order_dir "$1")/status.md" 2>/dev/null
}

# _v2_takeover_mark KEY 문구 — '## 현재 단계' 의 단계 줄 아래에 이어받기 표시를 넣는다(있으면 바꾼다).
_v2_takeover_mark() {
  local f; f="$(_order_dir "$1")/status.md"; [ -f "$f" ] || return 1
  awk -v m="- **이어받기**: $2" '
    /^## / { insec = ($0 ~ /현재 단계/) }
    insec && /^- \*\*이어받기\*\*:/ { next }
    { print; if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*단계\*\*/) print m }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# _v2_takeover_clear KEY — 이어받기 표시를 지운다.
_v2_takeover_clear() {
  local f; f="$(_order_dir "$1")/status.md"; [ -f "$f" ] || return 0
  _v2_takeover_pending "$1" || return 0
  awk '!/^- \*\*이어받기\*\*:/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dobby_migrate_v2_check KEY — dobby-order 로 진행하던 오더를 v2 로 옮길 수 있는지 보고, 옮긴 뒤 /do 가 무엇을 하는지 알려 준다.
# 아무것도 고치지 않는다. "항목<TAB>값" 줄로 낸다. 0 = 옮길 수 있음, 1 = 옮길 수 없음('불가' 줄에 이유).
#   진행 중(분석·구현·리뷰)인 오더는 끝났는지를 여기서 판정하지 않는다. 전환이 이어받기 표시를 남기면
#   /do 가 기존 설계와 작업 브랜치를 보고 끝난 것과 남은 것을 가른 뒤 남은 작업을 설계한다.
dobby_migrate_v2_check() {
  local key="$1" d f o ph dev rd blk n s st r active=""
  d="$(_order_dir "$key")"; f="$d/status.md"; o="$d/orchestration.md"
  [ -f "$f" ] || { printf '불가\t메타가 없다(%s)\n' "$d"; return 1; }
  ph="$(_order_phase "$key")"
  printf '단계\t%s\n' "${ph:-빈 값}"
  grep -q '^## 지난 세션' "$f" && { printf '불가\t이미 v2 오더다 — /do %s 로 이어간다\n' "$key"; return 1; }
  case "$ph" in
    착수) printf '불가\t착수 단계라 옮길 것이 없다 — /do %s 로 처음부터 시작한다\n' "$key"; return 1 ;;
    분석|구현|리뷰|통합|검증) ;;
    *) printf '불가\t%s 단계는 옮기지 않는다(끝났거나 보류 중이거나 모르는 값)\n' "${ph:-빈 값}"; return 1 ;;
  esac
  if [ ! -f "$d/design.md" ] && [ "$ph" != 분석 ]; then
    printf '불가\t설계 문서 없이 %s 단계까지 왔다 — v2 의 뒷세션은 설계 문서를 기준으로 일하므로 dobby-order 로 마무리한다\n' "$ph"; return 1
  fi
  dev="$(_board_dev_slug "$o")"
  printf '개발담당\t%s\n' "${dev:-없음(전환 때 v2-dev 행을 만든다)}"
  if [ -f "$o" ]; then
    while IFS=$'\t' read -r s st r; do
      case "$st" in 분석|구현|리뷰) active="$active $s($st)" ;; esac
    done < <(_board_rows "$o")
  fi
  printf '진행중행\t%s\n' "${active# }"
  rd="$(_review_last_round "$key")"
  if [ "$rd" -gt 0 ]; then
    n="$(find "$d/reviews/round-$rd" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" -gt 0 ]; then blk="$(dobby_blocking "$key" "$rd" 2>/dev/null)"; else blk="결과 없음"; fi
    printf '마지막리뷰\t%s차 · 파일 %s개 · 막는 지적 %s\n' "$rd" "$n" "$blk"
  else
    printf '마지막리뷰\t없음\n'
  fi
  case "$ph" in
    분석|구현|리뷰)
      if [ -f "$d/design.md" ]; then
        printf '다음\t이어받기 설계 — /do 가 기존 설계와 작업 브랜치를 보고 끝난 것과 남은 것을 가른 뒤, 남은 작업을 설계해 확정받는다\n'
      else
        printf '다음\t설계 — 설계 문서가 없어 /do 가 분석 문서부터 다시 설계한다\n'
      fi ;;
    통합) printf '다음\t검증 — 배포가 끝난 뒤에 /do 를 실행한다\n' ;;
    검증) printf '다음\t검증 결과에 따라 수정 또는 끝\n' ;;
  esac
  case "$ph" in 통합|검증)
    [ -f "$d/test-plan.md" ] || printf '필요\t테스트 계획 — test-plan.md (검증 세션은 이 문서 하나만 읽는다)\n' ;;
  esac
  return 0
}

# dobby_migrate_v2_apply KEY — 전환의 기계적인 부분을 한다. 문서 "내용"은 쓰지 않는다.
#   ① 상태 문서의 워크트리를 확인하고, 지워졌으면 남은 브랜치로 되살린다(dobby_ensure_worktree). 새 브랜치는 만들지 않는다.
#   ② 개발 담당 행이 없으면 v2-dev 행을 만든다.
#   ③ dobby_session_log 로 '## 지난 세션' 표를 만든다 — v2 오더의 표지다. 원래 세션은 '이전 세션' 줄로 옮겨진다.
#   ④ 진행 중(분석·구현·리뷰) 행을 대기로 돌린다 — 세션 사이 빈 시간에 보드가 정체로 경고하지 않게.
#   ⑤ 분석·구현·리뷰 단계이고 설계 문서가 있으면 단계를 '분석' 으로 두고 이어받기 표시를 남긴다.
#      dobby-order 의 '구현' 은 "구현 중", v2 의 '구현' 은 "구현 끝" 이라 그대로 두면 남은 일을 건너뛴다.
#      끝난 것과 남은 것은 /do 의 이어받기 설계가 작업 브랜치를 보고 가른다.
#   첫 워크트리 경로를 stdout 으로 준다.
dobby_migrate_v2_apply() {
  local key="$1" d f o ph dev repo wt="" p s st r
  dobby_migrate_v2_check "$key" >/dev/null || { _die "옮길 수 없는 오더다 — dobby_migrate_v2_check $key 로 이유를 확인"; return 1; }
  d="$(_order_dir "$key")"; f="$d/status.md"; o="$d/orchestration.md"; ph="$(_order_phase "$key")"
  for repo in $(awk '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/`|\*/,"",x);return x}
      /^## /{ins=(index($0,"워크트리")>0)?1:0; hdr=0; next}
      ins==1 && /^\|/{ n=split($0,a,"|")
        if(hdr==0){for(i=1;i<=n;i++){if(t(a[i])=="repo")cr=i}; if(cr)hdr=1; next}
        v=t(a[cr]); if(v!="" && v !~ /^-+$/ && !(v in seen)){seen[v]=1; print v} }' "$f"); do
    p="$(dobby_ensure_worktree "$repo" "$key" feature "${ORCHESTRATION_DEFAULT_BASE:-master}")" || return 1
    [ -n "$wt" ] || wt="$p"
  done
  dev="$(_board_dev_slug "$o")"
  [ -n "$dev" ] || { dev=v2-dev; dobby_agent_add "$key" "$dev" "개발자" "v2 전환으로 만든 개발 담당 행" 대기; }
  dobby_session_log "$key" "$dev" migrate "v2 전환" "${wt:-$PWD}"
  if [ -f "$o" ]; then
    while IFS=$'\t' read -r s st r; do
      case "$st" in 분석|구현|리뷰) dobby_agent_state "$key" "$s" 대기 ;; esac
    done < <(_board_rows "$o")
  fi
  case "$ph" in 분석|구현|리뷰)
    if [ -f "$d/design.md" ]; then
      [ "$ph" = 분석 ] || dobby_phase "$key" 분석
      _v2_takeover_mark "$key" "설계 필요 (전환 전 단계 $ph)"
    fi ;;
  esac
  dobby_event "$key" "/do 로 전환 — 전환 전 단계 $ph, 지금 단계 $(_order_phase "$key")$(_v2_takeover_pending "$key" && printf ', 이어받기 설계 대기')"
  printf '%s' "${wt:-$PWD}"
}

# dobby_session_lint [KEY] — 적힌 세션 ID 가 **그 오더의 세션이 맞는지** 검사한다.
#
# 판정 기준은 하나다: **그 전사에 오더 키가 한 번이라도 나오는가.** 나오지 않으면 남의 세션이다.
# 중복(여러 오더가 같은 ID)만으로는 오류가 아니다 — 한 세션이 오더 둘을 실제로 처리하기도 한다.
#
# 키를 주면 그 오더만, 안 주면 전부 본다. 문제가 있으면 1을 반환한다.
#   OK       전사에 키가 있다
#   WRONG    전사는 있는데 키가 없다 — **남의 세션이다. 이어가기를 누르면 엉뚱한 세션이 열린다**
#   MISSING  전사 파일이 없다 — 지워졌거나 ID 가 틀렸다
#   NONE     세션 ID 가 안 적혀 있다(검사 대상 아님)
#   WORKTREE 워크트리 폴더는 있는데 '## 워크트리 / 브랜치' 표에 없다 — 대시보드가 코드 위치를 모른다
#   CWD      세션 cwd 가 **이 오더의 워크트리가 아닌 다른 체크아웃**이다
#            → 이어가기가 딴 브랜치가 걸린 폴더로 데려간다(실측 FE1-1301: cwd 가 메인 저장소였고
#              그 저장소는 feature/FE1-1883 에 체크아웃돼 있었다. 코드는 subtree 워크트리에 있었다)
dobby_session_lint() {
  local only="${1:-}" root d k s sid tr bad=0 wtdir found top w cwd
  root="$(_meta)"
  [ -d "$root" ] || { _die "메타 루트가 없다: $root"; return 1; }
  wtdir="${ORCHESTRATION_WORKSPACE:-$HOME/work}/subtree"
  for d in "$root"/*/; do
    k="$(basename "$d")"
    case "$k" in .*) continue ;; esac
    [ -z "$only" ] || [ "$k" = "$only" ] || continue
    s="$d/status.md"; [ -f "$s" ] || continue

    # ── 워크트리 폴더는 있는데 표에 없나 ────────────────────────────────
    # 표가 없으면 대시보드가 코드 위치를 모르고, 사라진 워크트리 복원 안내도 못 한다.
    # ⛔ glob 을 쓰지 않는다 — zsh 는 맞는 게 없으면 `no matches found` 로 **함수를 죽인다**
    #    (실측: 전수 검사가 첫 오더에서 멈췄다). find 는 없으면 그냥 빈 값이다.
    found="$(find "$wtdir" -maxdepth 1 -type d -name "*-$k" 2>/dev/null | tr '\n' ' ')"
    found="${found% }"
    if [ -n "$found" ] && ! grep -q '^##[[:space:]]*워크트리' "$s"; then
      printf 'WORKTREE %-22s 표 없음 — 실제 폴더:%s\n' "$k" "$found"
      printf '         → dobby_record_branch %s {repo} {브랜치} {경로}\n' "$k"
      bad=$((bad + 1))
    fi

    sid="$(grep -oE '세션 ID[^0-9a-f]*[0-9a-f-]{36}' "$s" 2>/dev/null | grep -oE '[0-9a-f-]{36}' | head -1)"
    [ -n "$sid" ] || continue

    # ── 세션 cwd 가 이 오더의 워크트리가 아닌 **다른 체크아웃**인가 ──────
    # playground 처럼 git 저장소가 아닌 폴더는 괜찮다(오케스트레이터 자리). 문제는
    # "다른 브랜치가 걸린 저장소"다 — 거기로 이동하면 이 오더와 무관한 코드가 열린다.
    cwd="$(sed -nE 's#^[[:space:]]*-[[:space:]]*\*\*작업 경로\*\*[[:space:]]*[:：][[:space:]]*(.+)$#\1#p' "$s" | head -1)"
    cwd="${cwd%"${cwd##*[![:space:]]}"}"
    if [ -n "$found" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
      top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
      if [ -n "$top" ] && ! _ship_has "$top" "$found"; then
        # ⛔ 실패로 세지 않는다. 전사는 **그 폴더에 묶여** 있어서 작업 경로를 워크트리로
        #    바꾸면 그 세션을 --resume 으로 못 연다. 고칠 수 있는 결함이 아니라 **알려 줄 사실**이다.
        #    워크트리 표만 있으면 대시보드가 "코드는 여기 있다"를 보여 줄 수 있다.
        printf 'CWD      %-22s %s\n' "$k" "$cwd"
        printf '         저장소 %s 는 지금 [%s] — 이 오더 워크트리가 아니다\n' \
          "$top" "$(git -C "$top" branch --show-current 2>/dev/null)"
        printf '         이어가기는 그 폴더로 연다(전사가 거기 묶여 있다). 코드는 여기 있다:%s\n' "$found"
      fi
    fi

    tr="$(_session_transcript "$sid")"
    if [ -z "$tr" ]; then
      printf 'MISSING  %-22s %s  (전사 파일 없음)\n' "$k" "$sid"; bad=$((bad + 1)); continue
    fi
    if LC_ALL=C grep -qm1 -- "$k" "$tr" 2>/dev/null; then
      [ -n "$only" ] && printf 'OK       %-22s %s\n' "$k" "$sid"
    else
      printf 'WRONG    %-22s %s  (전사에 %s 가 한 번도 안 나온다 — 남의 세션)\n' "$k" "$sid" "$k"
      bad=$((bad + 1))
    fi
  done
  if [ "$bad" -gt 0 ]; then
    printf '\n세션 기록에 문제가 있는 오더 %s건 — 대시보드 이어가기가 엉뚱한 곳으로 간다.\n' "$bad" >&2
    printf '  WRONG    남의 세션이다. 키가 든 전사 중 dobby-order 를 부른 것이 오케스트레이터다:\n' >&2
    printf '             grep -rl {키} ~/.claude/projects/*/*.jsonl | xargs ls -lat | head\n' >&2
    printf '           못 찾으면 ID 를 지운다 — **틀린 ID 보다 없는 편이 낫다.**\n' >&2
    printf '  WORKTREE 표를 채운다: dobby_record_branch {키} {repo} {브랜치} {경로}\n' >&2
    printf '  CWD      는 결함이 아니라 안내다(실패로 세지 않는다) — 전사가 그 폴더에 묶여 있어\n' >&2
    printf '           경로를 바꾸면 --resume 이 세션을 못 찾는다. 워크트리 표로 코드 위치를 알린다.\n' >&2
    return 1
  fi
  [ -n "$only" ] || printf '세션 기록 이상 없음\n'
}

# dobby_bootstrap KEY TITLE KIND "kw1|kw2" [CWD] — 진입 즉시 1회. 폴더·골격·제목·종류·세션·docs 게이트를 한 번에.
# ⛔ Jira 상태 전환은 MCP(판단)라 여기 없다 — 부트스트랩 직후 오케스트레이터가 이어서 한다.
dobby_bootstrap() {
  local key="$1" title="$2" kind="$3" kw="${4:-}" cwd="${5:-$(pwd)}"
  dobby_scaffold_meta "$key" "$title" "$kw"     # 폴더+골격 status.md+docs 게이트
  dobby_set_title    "$key" "$title"            # 임시 제목 → 실제 제목
  [ -n "$kind" ] && dobby_set_kind "$key" "$kind"
  dobby_set_session  "$key" "$cwd"
}

# dobby_bootstrap_inline KEY "제목" 종류 슬러그 "이름" "설명" [상태] [CWD]
# 인라인 분기(P4-L light·P4-C continue·P4-W 작업정리)의 대시보드 호환 메타를 한 번에 깐다
# (빠지면 상세 페이지가 조용히 빈다): dobby_bootstrap(골격+제목+종류+세션) 위에
# orchestration.md 보드+에이전트 1행 · agent-logs(슬러그→메인 세션 전사)까지 추가한다.
# 상태 기본 `구현`(작업 정리는 `완료`로 넘긴다). analysis/implementation/explainer "내용"은 LLM 몫.
dobby_bootstrap_inline() {
  local key="$1" title="$2" kind="$3" slug="$4" name="$5" desc="$6" st="${7:-구현}" cwd="${8:-$PWD}"
  dobby_bootstrap "$key" "$title" "$kind" "" "$cwd" || return 1
  dobby_ensure_board "$key"
  dobby_agent_add "$key" "$slug" "$name" "$desc" "$st"
  # ⛔ 여기도 `ls -t` 로 추정하면 안 된다 — 대시보드 콘솔 탭이 **남의 세션**을 띄운다
  #    (실측 FE1-2134: agent-logs 의 inline 이 TASK-toss-research 전사를 가리켰다).
  local tr
  tr="$(_session_transcript "$(_session_id "$cwd")")"
  if [ -n "$tr" ]; then dobby_log "$key" "$slug" "$tr"
  else printf 'dobby-lib: 메인 세션 전사 없음 — agent-logs 기록 생략(콘솔 탭이 비게 됨)\n' >&2; fi
}

# ── 자동 이벤트(상태/단계 전이 시) ──────────────────────────────────
# _dobby_autoevent KEY TEXT — 전이 때마다 이벤트를 남겨 타임라인 밀도를 일관화한다.
#   · 보드(orchestration.md)가 아직 없으면 조용히 건너뛴다(부트스트랩 중 조기 생성 방지).
#   · DOBBY_AUTO_EVENT=0 으로 끌 수 있다(복구·테스트 시).
_dobby_autoevent() {
  [ "${DOBBY_AUTO_EVENT:-1}" = 0 ] && return 0
  [ -f "$(_order_dir "$1")/orchestration.md" ] || return 0
  dobby_event "$1" "$2"
}

# ── 자동 복구 · 단계 전이 게이트 ─────────────────────────────────────
# dobby_repair KEY — 손으로 어긋나게 적힌 메타를 헬퍼로 '다시 찍어' 정규화(비파괴, 내용 보존).
#   흔한 형식 오류(단계·상태 비정본, 상태표 헤더/구분선 누락, 골격 부재)는 대부분 여기서 자동 복구된다.
dobby_repair() {
  local key="$1" dir sf of; dir="$(_order_dir "$key")"
  sf="$dir/status.md"; of="$dir/orchestration.md"
  [ ! -f "$sf" ] && [ ! -f "$of" ] && dobby_scaffold_meta "$key"          # 골격 부재 → 재생성
  [ -f "$of" ] && dobby_ensure_board "$key"                               # 상태표 헤더·구분선 보정
  if [ -f "$sf" ]; then                                                   # 단계값 재정규화(예: 검증완료→검증)
    local praw
    praw="$(grep -m1 '\*\*단계\*\*' "$sf" 2>/dev/null | sed -E 's/.*\*\*단계\*\*[[:space:]]*[:：][[:space:]]*//; s/[[:space:]]*$//; s/\*//g')"
    [ -n "$praw" ] && DOBBY_AUTO_EVENT=0 dobby_phase "$key" "$praw"
  fi
  if [ -f "$of" ]; then                                                   # 상태표 상태 칸 재정규화(각 행 다시 찍기)
    local rows slug st
    rows="$(awk '
      /^## /{ins=($0 ~ /에이전트 상태표/)?1:0; hdr=0; next}
      ins==1 && /^\|/{
        n=split($0,a,"|")
        if(hdr==0){for(i=1;i<=n;i++){c=a[i];gsub(/^[ \t]+|[ \t]+$/,"",c);gsub(/\*/,"",c);if(c=="슬러그"||c=="에이전트")cs=i;if(c=="상태")ct=i}
          if(cs&&ct)hdr=1; next}
        issep=1; for(i=2;i<n;i++){c=a[i];gsub(/[ \t-]/,"",c);if(c!=""){issep=0;break}}
        if(issep)next
        slug=a[cs];st=a[ct];gsub(/^[ \t]+|[ \t]+$/,"",slug);gsub(/^[ \t]+|[ \t]+$/,"",st);gsub(/\*/,"",st)
        if(slug!="")print slug "\t" st
      }' "$of" 2>/dev/null)"
    while IFS="$(printf '\t')" read -r slug st; do
      [ -n "$slug" ] || continue
      case " $DOBBY_STATES " in *" $st "*) : ;; *) DOBBY_AUTO_EVENT=0 dobby_agent_state "$key" "$slug" "$st" ;; esac
    done <<EOF
$rows
EOF
  fi
}

# dobby_gate KEY NEXTPHASE [MODE]  MODE: interactive(기본) | auto
#   검사 → (실패) 자동 복구 → 재검사 → interactive면 멈춤(비0) / auto면 기록하고 계속(0).
#   대화형(모드 A)은 interactive, 자율(모드 B/Workflow)은 auto로 호출한다.
dobby_gate() {
  local key="$1" next="${2:-}" mode="${3:-interactive}"
  dobby_lint "$key" strict >/dev/null 2>&1 && return 0                    # 통과
  printf 'dobby-lib: %s 게이트(%s) 형식 오류 — 자동 복구 시도\n' "$key" "$next" >&2
  dobby_repair "$key"
  dobby_lint "$key" strict >/dev/null 2>&1 && { printf 'dobby-lib: %s 자동 복구 완료 — 통과\n' "$key" >&2; return 0; }
  if [ "$mode" = auto ]; then                                            # 자율: 멈추지 않고 기록만
    dobby_event  "$key" "게이트($next): 자동복구 후에도 형식 오류 — 계속 진행(검토 필요)"
    dobby_append "$key" "needs-attention.md" "$(printf -- '- %s [%s→%s] 자동복구 실패 — dobby_lint %s strict 로 확인' "$(_now)" "$key" "$next" "$key")"
    printf 'dobby-lib: %s 자율 통과(오류는 needs-attention.md에 기록)\n' "$key" >&2
    return 0
  fi
  printf '\n⛔ 게이트 멈춤 (%s → %s): 아래 치명 오류를 고쳐야 다음 단계로 갑니다\n' "$key" "$next" >&2
  dobby_lint "$key" strict >&2
  return 1
}

# ── 폐기(dobby-discard) — 필요 없는 오더를 절차대로 없앤다 ────────────
# 착수만 하고 접은 오더, 잘못 만든 키, 다른 오더로 흡수된 오더가 보드에 남아 소음이 된다.
# 그렇다고 rm 으로 지우면 G6이 막는다 — 막는 게 맞다. 메타는 종료된 작업의 유일한 기록이라
# "지워도 되는지"를 사람이 눈으로 판단할 수 없기 때문이다. 그래서 폐기는 두 단계로 나눈다.
#
#   1) 검사(dobby_discard_check): 산출물이 하나라도 있으면 거부한다. 추정하지 않고 전부
#      파일·git에서 읽는다 — 단계·워크트리·미푸시 커밋·code-changes diff·게시 아티팩트·
#      리뷰·에이전트 요약.
#   2) 이동(dobby_discard): 압축 백업을 만든 뒤 휴지통($ORCHESTRATION_META/.discarded/)으로
#      옮긴다. 지우는 것이 아니라 옮기는 것이라 되돌릴 수 있고(dobby_discard_undo),
#      대시보드 보드에서는 사라진다(대시보드가 점으로 시작하는 폴더를 건너뛴다 —
#      orchestration.ts listOrderKeys 의 !d.name.startsWith(".")).
#
# 영구 삭제(dobby_discard_purge)는 휴지통 안만 대상이고, 사용자 확인 없이는 돌지 않는다.

_discard_dir() { printf '%s/.discarded' "$(_meta)"; }

# dobby_discard_check KEY — 폐기해도 되는지 검사. 위반을 한 줄씩 stdout에 내고 1을 반환.
#   위반이 0건이면 아무것도 내지 않고 0. ⛔ 이 함수가 0을 주기 전에는 옮기지 않는다.
dobby_discard_check() {
  local key="$1" dir phase wt n sub bad=0
  [ -n "$key" ] || { _die 'dobby_discard_check KEY — 키가 필요하다'; return 1; }
  dir="$(_order_dir "$key")"
  [ -d "$dir" ] || { printf -- '- 오더 폴더가 없다: %s\n' "$dir"; return 1; }

  # 1) 해결·종료까지 간 오더는 남겨야 하는 기록이다(폐기 대상이 아니다).
  if [ -f "$dir/status.md" ]; then
    phase="$(_trim "$(grep -m1 '^- \*\*단계\*\*:' "$dir/status.md" 2>/dev/null | sed 's/^[^:]*: *//')")"
    case "$phase" in
      해결|종료) printf -- '- 단계가 "%s"다 — 정상 완료한 오더는 폐기하지 않는다(기록 보존).\n' "$phase"; bad=1 ;;
    esac
  fi

  # 2) 워크트리가 살아 있으면 미커밋·미푸시 코드를 잃을 수 있다.
  #    한 오더가 저장소·슬러그별로 워크트리를 여러 개 가질 수 있으므로 한 줄씩 본다
  #    (한 변수에 몰아 담으면 dobby_wt_unpushed 가 여러 경로를 한 인자로 받아 '?'를 낸다).
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    n="$(dobby_wt_unpushed "$wt")"
    if [ "$n" = "0" ]; then
      printf -- '- 워크트리가 아직 있다: %s — 먼저 /dobby-end 로 정리하라(미푸시 커밋은 없다).\n' "$wt"
    else
      printf -- '- 워크트리가 아직 있다: %s — origin에 없는 커밋이 %s개다. 잃으면 되돌릴 수 없다.\n' "$wt" "$n"
    fi
    bad=1
  done < <(dobby_subtree_list 2>/dev/null | awk -F'\t' -v k="$key" '$2==k{print $1}')

  # 3) 코드 변경 기록(dobby-end가 남긴 diff)이 있으면 실제로 일한 오더다.
  if [ -d "$dir/code-changes" ]; then
    n="$(find "$dir/code-changes" -name '*.diff' -size +0 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n:-0}" -gt 0 ] && { printf -- '- 코드 변경 기록이 %s건 있다(code-changes/*.diff) — 워크트리를 지운 뒤에는 이것이 유일한 코드 원본이다.\n' "$n"; bad=1; }
  fi

  # 4) 아티팩트가 게시돼 있으면 공개 링크가 근거 문서를 잃는다(되돌릴 수 없다).
  if [ -f "$dir/artifact-share.md" ]; then
    n="$(grep -c 'https\?://' "$dir/artifact-share.md" 2>/dev/null)" || n=0
    [ "${n:-0}" -gt 0 ] && { printf -- '- 게시된 아티팩트가 %s건이다(artifact-share.md) — 링크가 살아 있는 동안 근거를 없애지 않는다.\n' "$n"; bad=1; }
  fi

  # 5) 리뷰·에이전트 요약이 있으면 라운드를 돈 오더다.
  for sub in reviews agents; do
    [ -d "$dir/$sub" ] || continue
    n="$(find "$dir/$sub" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n:-0}" -gt 0 ] && { printf -- '- %s/ 에 기록이 %s건 있다 — 실제로 진행한 오더다.\n' "$sub" "$n"; bad=1; }
  done

  [ "$bad" -eq 0 ] || return 1
  return 0
}

# dobby_discard KEY "사유" — 검사 통과 시 압축 백업을 만든 뒤 휴지통으로 옮긴다. 새 경로 stdout.
#   ⛔ dobby_discard_check 를 통과하지 않으면 아무것도 하지 않는다(조건을 무르는 판단은 사용자 몫).
#   백업은 여기서 "동기로" 돈다 — dobby_resolve 와 다른 점이다. 저 쪽은 대시보드 버튼이
#   동기 대기하므로 분리 실행해야 하지만, 여기는 다음 줄에서 폴더를 옮기기 때문에
#   백그라운드로 띄우면 압축이 사라진 폴더를 읽어 아카이브가 깨진다.
dobby_discard() {
  local key="$1" why="${2:-}" dir trash dest bk bkdest
  [ -n "$key" ] || { _die 'dobby_discard KEY "사유" — 키가 필요하다'; return 1; }
  dir="$(_order_dir "$key")"
  [ -d "$dir" ] || { _die "오더 폴더가 없다: $dir"; return 1; }
  if ! dobby_discard_check "$key" >/dev/null 2>&1; then
    _die "폐기 조건 미충족 — 'dobby_discard_check $key' 로 사유를 확인하라"
    return 1
  fi

  bk="$DOBBY_LIB_DIR/dobby-meta-backup.sh"
  if [ "${DOBBY_META_BACKUP:-1}" = "1" ] && [ -f "$bk" ]; then
    bkdest="${ORCHESTRATION_BACKUP_DIR:-$HOME/claude-projects-backup/orchestration}"
    mkdir -p "$bkdest" 2>/dev/null
    bash "$bk" "$key" >>"$bkdest/backup-run.log" 2>&1 \
      || printf 'dobby-lib: 압축 백업 실패 — 휴지통 이동만 진행한다(되돌리기는 dobby_discard_undo %s)\n' "$key" >&2
  fi

  # 왜 없앴는지를 폴더 안에 남긴다 — 나중에 휴지통을 열었을 때 유일한 단서다.
  cat >> "$dir/discard-reason.md" <<EOF
# $key 폐기 기록
- **일시**: $(_now)
- **사유**: ${why:-미기재}
- **원래 경로**: $dir
- **되돌리기**: dobby_discard_undo $key
EOF

  trash="$(_discard_dir)"; mkdir -p "$trash" || return 1
  dest="$trash/$key--$(_ts)"
  mv "$dir" "$dest" || { _die "이동 실패: $dir → $dest"; return 1; }
  printf '%s\n' "$dest"
}

# dobby_discard_list — 휴지통 목록 "경로<TAB>키<TAB>폐기시각" stdout(오래된 것부터).
dobby_discard_list() {
  local trash d name; trash="$(_discard_dir)"
  [ -d "$trash" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    printf '%s\t%s\t%s\n' "$d" "${name%--*}" "${name##*--}"
  done < <(find "$trash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
}

# dobby_discard_undo KEY — 휴지통에서 원래 자리로 되돌린다(같은 키가 여럿이면 가장 최근 것).
dobby_discard_undo() {
  local key="$1" src dir
  [ -n "$key" ] || { _die 'dobby_discard_undo KEY — 키가 필요하다'; return 1; }
  src="$(dobby_discard_list | awk -F'\t' -v k="$key" '$2==k{print $1}' | tail -1)"
  [ -n "$src" ] || { _die "휴지통에 $key 가 없다 — dobby_discard_list 로 확인하라"; return 1; }
  dir="$(_order_dir "$key")"
  [ -e "$dir" ] && { _die "원래 자리에 이미 폴더가 있다: $dir"; return 1; }
  mv "$src" "$dir" || { _die "복원 실패: $src → $dir"; return 1; }
  # 폐기 기록은 지우지 않고 되돌린 사실을 덧붙인다(비파괴 — 이력이 남는다).
  printf -- '- **되돌림**: %s\n' "$(_now)" >> "$dir/discard-reason.md"
  printf '%s\n' "$dir"
}

# dobby_discard_purge KEY — 휴지통 안의 그 오더를 영구 삭제.
#   ⛔ 사용자가 명시적으로 지시할 때만. 확인 없이 돌지 않도록 DOBBY_DISCARD_PURGE_OK=1 을 요구한다.
#   대상이 휴지통 밖이면 무조건 거부한다(경로 사고 방지).
dobby_discard_purge() {
  local key="$1" src trash
  [ -n "$key" ] || { _die 'dobby_discard_purge KEY — 키가 필요하다'; return 1; }
  [ "${DOBBY_DISCARD_PURGE_OK:-0}" = "1" ] || {
    _die "영구 삭제는 사용자 확인이 필요하다 — 확인을 받았으면 DOBBY_DISCARD_PURGE_OK=1 을 붙여 다시 실행하라"; return 1; }
  trash="$(_discard_dir)"
  src="$(dobby_discard_list | awk -F'\t' -v k="$key" '$2==k{print $1}' | tail -1)"
  [ -n "$src" ] || { _die "휴지통에 $key 가 없다"; return 1; }
  case "$src" in
    "$trash"/*) : ;;
    *) _die "휴지통 밖 경로는 삭제하지 않는다: $src"; return 1 ;;
  esac
  rm -rf "$src" || { _die "삭제 실패: $src"; return 1; }
  printf '삭제: %s\n' "$src"
}

# ─────────────────────────────────────────────────────────────────────────────
# dobby-ship — 배포(PR → 리뷰 → 머지 → 빌드 → 배포 확인) 헬퍼
#
# 스킬 문서에 "⛔ …하지 마라"라고 적어 둔 것은 지켜지지 않는다(실측: 시나리오 표 머리글이
# 회차 75개에 20가지 넘게 나왔다). 지켜야 하는 것은 **거부하는 함수**로 내린다.
# 훅(pre-bash.sh G1)은 생 명령을 막는 마지막 방어선이고, 여기는 정상 경로다.
# ─────────────────────────────────────────────────────────────────────────────

# 배포을 시작할 수 있는 현재 단계(status.md `- **단계**:`).
#
# 정본은 착수·분석·구현·리뷰·통합·검증·해결·종료 여덟이다(dobby-start status.md 스키마).
# ⛔ `완료` 는 **에이전트 상태표**의 값이지 단계가 아니다 — P7 설명의 "구현 에이전트 상태를
#    `완료`로 갱신한다"를 단계로 잘못 읽기 쉽다. 실제 메타에 `완료` 로 적힌 오더가 4개 있어
#    받아는 주되, 정본으로 쓰지 않는다.
# dobby-order 가 끝나는 지점이 `통합` 이므로 그것이 기본 진입 조건이다.
DOBBY_SHIP_PHASES="통합 검증 해결 종료 완료"

# 배포을 맡는 저장소. **여기 없는 저장소는 이 스킬이 다루지 않는다.**
#
# 환경 브랜치 이름·리뷰봇 유무·빌드 방식·배포 방식이 저장소마다 다르다. 한 틀로 돌리면
# 조용히 틀린 일을 하므로, 다른 자리는 전부 아래 네 함수(_ship_branch·_ship_reviewbot·
# _ship_argo_server·_ship_argo_app)로 갈라 둔다.
DOBBY_SHIP_REPOS="wadiz-frontend com.wadiz.web"

# 배포이 갈 수 있는 **논리 환경**. clive(=cloud_live)는 없다 — dobby-order C1.
#
# ⛔ 논리 환경과 **브랜치 이름은 다르다.** 표·헬퍼 인자는 언제나 논리 환경(dev·rc1·rc4·stage)을
#    쓰고, 실제 브랜치는 _ship_branch 가 저장소마다 옮긴다. 이렇게 해야 저장소가 둘인 오더에서
#    `## 배포` 표의 두 행이 같은 환경으로 맞물려 순서(G-A·G-B)를 셀 수 있다.
DOBBY_SHIP_ENVS="dev rc1 rc4 stage"
# 그중 스킬이 직접 머지해도 되는 환경. stage 는 빠져 있다 — 스테이지 반영은 사람이 시점을 고른다.
DOBBY_SHIP_MERGE_ENVS="dev rc1 rc4"

_ship_has() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 저장소마다 다른 네 가지 — 여기서만 갈린다
#
#   저장소           환경→브랜치            리뷰봇  빌드            배포
#   wadiz-frontend   그대로                 있음    수동(번들별)    빌드가 곧 배포
#   com.wadiz.web    dev→cloud_dev, 나머지  없음    자동(머지 push) argocd sync 가 따로 필요
#                    그대로
# ─────────────────────────────────────────────────────────────────────────────

# _ship_branch 저장소 환경 — 그 저장소에서 이 논리 환경이 가리키는 브랜치. 없으면 빈 값.
#
# 실측(2026-10-07 git ls-remote): 두 저장소 모두 dev·rc1·rc4·stage·cloud_live 를 갖지만
# com.wadiz.web 의 개발 환경만 `cloud_dev` 다(그냥 `dev` 는 쓰지 않는 옛 브랜치다).
_ship_branch() {
  case "$1" in
    wadiz-frontend) _ship_has "$2" "$DOBBY_SHIP_ENVS" && printf '%s' "$2" ;;
    com.wadiz.web)
      case "$2" in
        dev) printf 'cloud_dev' ;;
        rc1|rc4|stage) printf '%s' "$2" ;;
      esac ;;
  esac
}

# _ship_reviewbot 저장소 — 자동 코드리뷰가 도는 저장소면 0.
#
# wadiz-frontend 만 `[event] Claude Code Review` 가 돈다(대상 브랜치 rc[0-9]·stage·cloud_live).
# com.wadiz.web 은 실측(2026-10-07) 최근 머지 PR 5건 모두 reviews·reviewRequests 가 0건이고
# 등록된 `Copilot code review` 워크플로도 마지막 실행이 2026-03-24 로 멈춰 있다. 여기에
# 리뷰어를 붙이면 **오지 않을 리뷰를 10분 기다린다**(게다가 wadiz-fe/fe1-team 은 조직이 달라
# 붙지도 않는다 — com.wadiz.web 은 wadiz-web 조직이다).
_ship_reviewbot() { [ "$1" = wadiz-frontend ]; }

# _ship_argo_server 환경 / _ship_argo_app 환경 — com.wadiz.web 의 argocd 대상.
#
# 실측 2026-10-07 `argocd app list -o name`:
#   argocd.dev.wadiz.io  argo/web-dev-web-server   (project web-dev,  SYNCPOLICY Manual)
#   argocd.rc4.wadiz.io  argo/web-rc1-web-server   (project web-rc1,  SYNCPOLICY Manual)
#   argocd.rc4.wadiz.io  argo/web-rc4-web-server   (project web-rc4,  SYNCPOLICY Manual)
#   argocd.wadiz.io      argo/web-stage-web-server (argo-deploy 스킬 실측 — stage 는 사람 몫)
#
# ⛔ **네 환경 모두 자동 동기화가 꺼져 있다(Manual).** CI 가 gitops 의 이미지 태그를 고쳐도
#    sync 하지 않으면 영원히 배포되지 않는다. 실측: 조회 시점에 web-rc1-web-server 가
#    OutOfSync 였다(머지·CI 는 됐는데 아무도 sync 하지 않은 상태).
# ⛔ **서버 두 곳에 동시에 로그인해 둘 수 없다.** CLI 가 OIDC 클라이언트를 하나만 쓰는지,
#    다른 서버에 로그인하면 앞서 받은 토큰이 끊긴다(실측 2026-10-07: rc4 로그인 → dev 로그인
#    뒤 rc4 가 "Refresh token is invalid or has already been claimed by another client").
#    한 오더는 환경 하나로 나가므로 문제가 되지 않지만, 끊겼을 때 **조용히 실패하지 않도록**
#    dobby_ship_argo 가 sync 전에 세션을 먼저 확인한다
#    (`argocd account get-user-info --server {서버}` 가 서버마다 바르게 갈라 준다 — 실측 확인).
# 앱 이름은 `web-{gitops 환경}-web-server` 이고, gitops 환경은 브랜치에서 `cloud_` 를 뗀 값이다
# (app-web-ci.yml 의 preparation 잡). 그래서 dev 만 cloud_dev → dev 로 되돌아온다.
_ship_argo_server() {
  case "$1" in
    dev)   printf 'argocd.dev.wadiz.io' ;;
    rc1)   printf 'argocd.rc4.wadiz.io' ;;
    rc4)   printf 'argocd.rc4.wadiz.io' ;;
    stage) printf 'argocd.wadiz.io' ;;
  esac
}
_ship_argo_app() {
  _ship_has "$1" "$DOBBY_SHIP_ENVS" || return 1
  printf 'argo/web-%s-web-server' "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# 단계 서열 — 저장소 사이의 순서(G-A·G-B)를 세는 기준
#
# 사용자 요구: com.wadiz.web 은 **wadiz-frontend 가 머지된 뒤에** 머지하고,
#              **wadiz-frontend 배포가 끝난 뒤에** argocd 로 배포한다.
# 글로 적으면 지켜지지 않으므로 FE 행의 단계를 숫자로 바꿔 **거부로** 강제한다.
# ─────────────────────────────────────────────────────────────────────────────

# _ship_rank 단계 → 0~7. 모르는 값과 `리뷰 취소`(머지 없이 닫힘)는 -1.
_ship_rank() {
  case "$1" in
    "PR 생성")   printf 0 ;;
    "리뷰 대기") printf 1 ;;
    "리뷰 반영 "[0-9]*회차) printf 1 ;;
    "머지 대기") printf 2 ;;
    "빌드 대기") printf 3 ;;   # ← 머지가 끝난 자리. G-A 는 이 이상을 요구한다
    "배포 대기") printf 4 ;;
    "배포 확인") printf 5 ;;   # ← 배포가 끝난 자리. G-B 는 이 이상을 요구한다
    "검증 중")   printf 6 ;;
    "검증 완료") printf 7 ;;
    *) printf -- -1 ;;
  esac
}
DOBBY_SHIP_RANK_MERGED=3
DOBBY_SHIP_RANK_DEPLOYED=5

# _ship_row_rank KEY 저장소 환경 — `## 배포` 표에서 그 행의 서열. **행이 없으면 빈 값**(게이트 끔).
_ship_row_rank() {
  local f st
  f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 0
  st="$(_ship_row_stage "$1" "$2" "$3")"
  [ -n "$st" ] || return 0
  _ship_rank "$st"
}

# _ship_row_stage KEY 저장소 환경 — 그 행의 단계 원문(⚠ 는 떼고). 행이 없으면 빈 값.
_ship_row_stage() {
  local f
  f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 0
  awk -v rp="$2" -v env="$3" '
    function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    /^## / { insec = ($0 ~ /^##[ \t]*배포[ \t]*$/); next }
    insec && /^[ \t]*\|/ {
      # 저장소 칸이 있는 새 표(7칸→9)와 없는 옛 표(6칸→8)를 함께 받는다.
      nc = split($0, c, "|")
      if (nc == 8)      { r = "wadiz-frontend"; e = trim(c[2]); s = trim(c[3]) }
      else if (nc >= 9) { r = trim(c[2]);       e = trim(c[3]); s = trim(c[4]) }
      else next
      if (r != rp || e != env) next
      gsub(/[ \t]*⚠[ \t]*$/, "", s)
      if (s != "") { print s; exit }
    }
  ' "$f"
}

# _words "a b c" — 공백으로 나눠 **한 줄에 하나씩** 출력한다.
#
# ⛔ 이 라이브러리는 `for x in $var` 같은 **단어 분리에 기대지 않는다.** bash 는 따옴표 없는
#    확장을 공백으로 나누지만 **zsh 는 나누지 않는다**. 세션 셸이 zsh 면 "static global" 이
#    통째로 한 덩어리가 돼 "모르는 번들"로 거부된다(실측: dobby-ship 빌드가 시작되지 않았다).
#    새 코드도 목록을 돌 때는 반드시 이것을 거친다.
_words() { printf '%s\n' "$1" | tr ' \t' '\n\n' | grep -v '^$'; }

# ─────────────────────────────────────────────────────────────────────────────
# 배포 단계 — status.md '## 배포' 표에 **환경마다 한 행**.
#
# 왜 한 줄이 아니라 표인가: 한 오더가 여러 번, 여러 환경으로 나간다(실측 FE1-1800 은 dev 로
# 두 번, FE1-1943 은 rc4 로). 한 줄을 덮어쓰면 "dev 는 끝났고 rc4 는 리뷰 대기" 를 적을 수 없다.
#
# 단계는 아홉 개뿐이고 스킬 10단계와 하나씩 맞물린다. 여기 없는 값은 거부한다 —
# 실측: 검사가 없던 때 남은 두 건 중 한 건이 서식과 달랐다(`배포 완료` 대신 `배포 완료`).
DOBBY_SHIP_STAGE_LIST="PR 생성 / 리뷰 대기 / 리뷰 취소 / 리뷰 반영 N회차 / 머지 대기 / 빌드 대기 / 배포 대기 / 배포 확인 / 검증 중 / 검증 완료"

_ship_stage_ok() {
  case "$1" in
    "PR 생성"|"리뷰 대기"|"리뷰 취소"|"머지 대기"|"빌드 대기"|"배포 대기"|"배포 확인"|"검증 중"|"검증 완료") return 0 ;;
    "리뷰 반영 "[0-9]*회차) return 0 ;;
  esac
  return 1
}

# dobby_ship_stage KEY 저장소 환경 단계 [PR] [빌드] [비고]
#
# 같은 **(저장소, 환경)** 행이 있으면 갱신하고, 없으면 추가한다. 갱신 시각은 자동으로 적는다.
#   · PR·빌드 를 비워 두면 **그 칸은 그대로 둔다** — 머지 단계에서 PR 번호가 지워지지 않게.
#     지우려면 '-' 를 넘긴다.
#   · 비고는 비워 두면 **지운다.** 비고는 "지금 막혀 있다"는 뜻이라 단계가 나아가면 사라져야 한다.
#     비고가 있으면 단계 칸에 ⚠ 가 붙는다 — 막힘은 단계가 아니라 사고다.
#   · 옛 한 줄(`- **배포 단계**:` / `- **배송 단계**:`)이 남아 있으면 이때 지운다.
#
# ⛔ 행 열쇠가 **환경 하나에서 (저장소, 환경) 둘로** 늘었다. 한 오더가 저장소 둘을 건드리면
#    (실측: FE1-1787·FE1-2005 등 12건) 환경만으로는 두 저장소가 같은 행을 덮어쓴다.
# 옛 6칸 표(저장소 칸 없음)는 **여기서 한 번에 7칸으로 올린다** — `- **저장소**:` 줄의 값으로
# 기존 행을 채우고(없으면 wadiz-frontend) 그 줄은 지운다. 메타가 80개가 넘어 일괄 변환 대신
# "쓸 때 올린다"로 간다. 손대지 않은 오더는 옛 모양 그대로 남고 대시보드가 둘 다 읽는다.
dobby_ship_stage() {
  local key="$1" rp="$2" env="$3" st="$4" pr="${5:-}" bd="${6:-}" note="${7:-}" f ts old
  [ -n "$rp" ] && [ -n "$env" ] && [ -n "$st" ] \
    || { _die "쓰임: dobby_ship_stage KEY 저장소 환경 단계 [PR] [빌드] [비고]"; return 1; }
  _ship_has "$rp" "$DOBBY_SHIP_REPOS" \
    || { _die "배포을 맡는 저장소가 아니다: '$rp' (허용: $DOBBY_SHIP_REPOS)"; return 1; }
  _ship_has "$env" "$DOBBY_SHIP_ENVS" \
    || { _die "배포 환경이 아니다: '$env' (허용: $DOBBY_SHIP_ENVS)"; return 1; }
  _ship_stage_ok "$st" \
    || { _die "배포 단계 어휘가 아니다: '$st' (허용: $DOBBY_SHIP_STAGE_LIST)"; return 1; }
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || { _die "status.md 가 없다: $key"; return 1; }
  ts="$(date '+%Y-%m-%d %H:%M')"

  # 옛 표를 올릴 때 기존 행에 채울 저장소. `- **저장소**: owner/repo` 의 뒷마디만 쓴다.
  old="$(sed -nE 's#^[[:space:]]*-[[:space:]]*\*\*저장소\*\*[[:space:]]*:[[:space:]]*`?([^[:space:]`]+).*#\1#p' "$f" | head -1)"
  old="${old##*/}"
  _ship_has "$old" "$DOBBY_SHIP_REPOS" || old="wadiz-frontend"

  # 표가 없으면 '## 현재 단계' 다음에 빈 표를 만든다.
  if ! grep -q '^##[[:space:]]*배포[[:space:]]*$' "$f"; then
    awk '
      function head() { print "## 배포"; print "| 저장소 | 환경 | 단계 | PR | 빌드 | 갱신 | 비고 |"; print "|---|---|---|---|---|---|---|" }
      /^## / { if (p) { head(); print ""; p=0; ins=1 } p = ($0 ~ /현재 단계/) }
      { print }
      END { if (!ins) { print ""; head() } }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi

  awk -v rp="$rp" -v env="$env" -v st="$st" -v pr="$pr" -v bd="$bd" -v note="$note" \
      -v ts="$ts" -v old="$old" '
    function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    function emit(  s, p2, b2) {
      s = st; if (note != "") s = s " ⚠"
      p2 = (keep_pr != "" ? keep_pr : "-"); if (pr != "") p2 = pr
      b2 = (keep_bd != "" ? keep_bd : "-"); if (bd != "") b2 = bd
      printf "| %s | %s | %s | %s | %s | %s | %s |\n", rp, env, s, p2, b2, ts, note
      keep_pr = ""; keep_bd = ""; found = 1
    }
    /^[ \t]*-[ \t]*\*\*배[포송] 단계\*\*/ { next }   # 옛 한 줄(배포·배송)은 버린다
    /^[ \t]*-[ \t]*\*\*저장소\*\*/ { if (insec) next }  # 표가 저장소를 담으므로 이 줄은 버린다
    /^## / { if (insec && !found && seen) emit(); insec = ($0 ~ /^##[ \t]*배포[ \t]*$/) }
    {
      if (insec && $0 ~ /^[ \t]*\|/) {
        seen = 1
        # 칸 수로 옛 표(6칸)와 새 표(7칸)를 가른다. `| a | b |` 는 split 이 앞뒤 빈 조각을
        # 함께 세므로 6칸→8, 7칸→9 다. 내용(빈 비고 등)으로 가르면 틀린다.
        nc = split($0, c, "|")
        n = trim(c[2])
        # ── 머리글·구분선: 언제나 7칸으로 다시 쓴다(옛 6칸 표 승급) ──────────
        if (n == "환경" || n == "저장소") {
          print "| 저장소 | 환경 | 단계 | PR | 빌드 | 갱신 | 비고 |"; next
        }
        if (n ~ /^:?-+:?$/) { print "|---|---|---|---|---|---|---|"; next }
        # ── 자료 행 ────────────────────────────────────────────────────────
        if (nc < 8) { print; next }                 # 모양을 모르는 줄은 그대로 둔다
        if (nc == 8) {
          # 옛 6칸 행 — 저장소 칸을 앞에 끼워 넣는다.
          r = old; e = n; sg = trim(c[3]); p = trim(c[4]); b = trim(c[5]); u = trim(c[6]); nt = trim(c[7])
        } else {
          r = n; e = trim(c[3]); sg = trim(c[4]); p = trim(c[5]); b = trim(c[6]); u = trim(c[7]); nt = trim(c[8])
        }
        if (r == rp && e == env) {
          keep_pr = (p == "-" ? "" : p)
          keep_bd = (b == "-" ? "" : b)
          emit(); next
        }
        printf "| %s | %s | %s | %s | %s | %s | %s |\n", r, e, sg, p, b, u, nt; next
      }
      if (insec && seen && !found) emit()
      print
    }
    END { if (insec && !found && seen) emit() }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f" || return 1
  # 배포 중 리뷰 반영·충돌 해결 커밋은 단계 안의 일이라 기준점을 옮긴다. 기준점이 있는 오더만.
  [ -z "$(_v2_checkpoint_get "$key")" ] || dobby_v2_checkpoint "$key" >/dev/null 2>&1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# dobby_v2_autorun KEY — 설계를 확정한 v2 오더의 자동 실행(run.sh)을 대시보드에 맡겨 띄운다.
#
# 대시보드가 띄우면 터미널·이 세션이 닫혀도 실행이 살아 있고(분리된 프로세스),
# 대시보드 '자동 실행' 잡으로 진행이 보이며, 커밋·푸시 승인(--approve-commit)도 대시보드가 넘긴다.
# 대시보드 주소는 ORCHESTRATION_DASHBOARD_URL (기본 http://localhost:7253).
#   반환 0 = 시작함 · 1 = 대시보드가 시작을 거부(이유 출력) · 2 = 대시보드에 닿지 못함(직접 실행 명령 출력)
dobby_v2_autorun() {
  local key="$1" url="${ORCHESTRATION_DASHBOARD_URL:-http://localhost:7253}" chk res run
  [ -n "$key" ] || { _die "쓰임: dobby_v2_autorun KEY"; return 1; }
  # 대시보드 오더 실행 탭이 띄운 설계 세션이면 이 세션이 끝난 뒤 같은 잡이 run.sh 를 이어서 실행한다.
  # 여기서 띄우면 잡 이름(오더 키)이 겹쳐 대시보드가 "이미 실행 중"으로 거부한다.
  if [ -n "${DOBBY_V2_CHAINED:-}" ]; then
    printf '이 설계 세션이 끝나면 대시보드 잡이 자동 실행을 이어서 시작합니다.\n'
    dobby_event "$key" "설계 세션 끝 — 대시보드 잡이 자동 실행을 이어 감" 2>/dev/null
    return 0
  fi
  run="$DOBBY_LIB_DIR/../skills/do/run.sh"
  chk="$(curl -fsS --max-time 5 "$url/api/orders?v2run=$key" 2>/dev/null)" || {
    printf '대시보드(%s)에 닿지 못해 자동 실행을 띄우지 못했습니다.\n' "$url"
    printf '대시보드를 켠 뒤 오더 화면의 "자동 실행" 버튼을 누르거나, 터미널에서 직접 실행해 주세요:\n  bash %s %s --approve-commit\n' "$run" "$key"
    return 2
  }
  if [ "$(printf '%s' "$chk" | jq -r '.ok')" != "true" ]; then
    printf '자동 실행을 시작할 수 없습니다: %s\n' "$(printf '%s' "$chk" | jq -r '.reason // "이유 없음"')"
    return 1
  fi
  res="$(curl -sS --max-time 10 -X POST "$url/api/orders" -H 'content-type: application/json' \
    -d "$(jq -nc --arg k "$key" '{v2run:true,key:$k}')" 2>/dev/null)"
  if [ "$(printf '%s' "$res" | jq -r '.ok' 2>/dev/null)" = "true" ]; then
    printf '자동 실행을 시작했습니다. 진행 상황은 대시보드 %s/ 의 %s 오더 화면에서 볼 수 있습니다.\n' "$url" "$key"
    dobby_event "$key" "설계 세션이 자동 실행을 시작함 — 구현부터 통합(커밋·푸시)까지" 2>/dev/null
    return 0
  fi
  printf '자동 실행을 시작할 수 없습니다: %s\n' "$(printf '%s' "$res" | jq -r '.error // "응답 없음"' 2>/dev/null)"
  return 1
}

# dobby_fix_count KEY SLUG — 그 담당이 지금까지 한 수정 세션 수(리뷰 지적 수정 fix-N + 검증 실패 수정 fix-test-*).
# agent-logs.json 의 그 슬러그 하위 키를 센다. 수정 세션은 dobby_session_log 를 먼저 부르므로 지금 세션도 들어간다.
# v2 개발 담당의 라운드 칸(보드 카드 숫자)이 이 값이다 — 리뷰 차수가 아니라 실제로 고친 횟수를 보이기 위해서다.
dobby_fix_count() {
  local f; f="$(_order_dir "$1")/agent-logs.json"
  [ -f "$f" ] || { printf '0'; return 0; }
  jq -r --arg s "$2" '(.[$s] // {}) | if type == "object" then [keys[] | select(test("^fix-"))] | length else 0 end' "$f" 2>/dev/null || printf '0'
}

# ── v2 세션 이어 쓰기 판정 — run.sh 와 대화형 세션 마무리(dobby_v2_next_hint)가 같은 규칙을 쓴다 ──
# 기본은 단계마다 새 세션. 다음 일이 '수정'이고, 직전 세션의 마지막 문맥이 DOBBY_REUSE_MAX_CTX 이하이며,
# 마지막 호출 뒤 DOBBY_REUSE_MAX_GAP 초 안일 때만 이어 쓴다. 근거 수치는 skills/do/session-reuse.md.
DOBBY_REUSE_MAX_CTX=120000
DOBBY_REUSE_MAX_GAP=300

# _v2_test_passed KEY — 검증 이력 표의 마지막 행이 '완료'이고 실패가 0이면 0.
_v2_test_passed() {
  awk -F'|' '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## /{ins=(index($0,"테스트 실행 이력")>0)?1:0; next}
    ins && /^\|/ && $2 !~ /회차|---/ {st=t($4); split(t($5),c,"/")}
    END{exit (st=="완료" && c[2]+0==0)?0:1}' "$(_order_dir "$1")/status.md"
}

# _v2_next_is_fix KEY — 다음 세션이 할 일이 '수정'인가(단계 판정 표의 수정 두 줄과 같은 조건).
_v2_next_is_fix() {
  local key="$1" d ph rd
  d="$(_order_dir "$key")"; ph="$(_order_phase "$key")"
  if [ "$ph" = 검증 ]; then _testrun_open "$key" >/dev/null && return 1; ! _v2_test_passed "$key"; return; fi
  [ "$ph" = 리뷰 ] || return 1
  rd="$(find "$d/reviews" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sed 's/.*round-//' | sort -n | tail -1)"
  [ -n "$rd" ] && ls "$d/reviews/round-$rd"/*.md >/dev/null 2>&1 \
    && [ "$(dobby_blocking "$key" "$rd" 2>/dev/null)" -gt 0 ]
}

# _v2_last_call SID — 세션 기록의 마지막 호출 "문맥크기<TAB>경과초". 기록을 못 찾으면 빈 출력.
_v2_last_call() {
  local f
  f="$(ls ~/.claude/projects/*/"$1".jsonl 2>/dev/null | head -1)"
  [ -n "$f" ] || return 0
  jq -rs '[.[] | select(.type == "assistant" and .message.usage != null)] | last // empty
    | [(.message.usage | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)),
       (now - (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | floor)] | @tsv' "$f" 2>/dev/null
}

# dobby_v2_reuse_ok KEY SID — 이어 쓰는 쪽이 싸면 "문맥크기<TAB>경과초" 를 내고 0, 아니면 출력 없이 1.
dobby_v2_reuse_ok() {
  local key="$1" sid="$2" ctx gap
  [ -n "$sid" ] && _v2_next_is_fix "$key" || return 1
  IFS=$'\t' read -r ctx gap <<<"$(_v2_last_call "$sid")"
  [ -n "${ctx:-}" ] && [ "$ctx" -le "$DOBBY_REUSE_MAX_CTX" ] && [ "$gap" -le "$DOBBY_REUSE_MAX_GAP" ] || return 1
  printf '%s\t%s\n' "$ctx" "$gap"
}

# dobby_v2_next_hint KEY — 대화형 세션 마무리용. 이어 쓰는 쪽이 쌀 때만 '다음' 칸에 넣을 줄을 내고, 아니면 아무것도 내지 않는다.
# 평소에 침묵하는 이유: 이 출력도 마지막 응답의 입력이 된다. 30번 중 1번꼴로만 이득이라 매번 출력하면 아끼는 양과 비슷하게 든다.
# 헤드리스(-p) 세션에서는 run.sh 가 판정하므로 침묵한다. 기한은 지금+4분 — 대화형 캐시 5분에서 마지막 응답 시간을 뺐다.
dobby_v2_next_hint() {
  local key="$1" r ctx
  [ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || return 0
  r="$(dobby_v2_reuse_ok "$key" "$(_session_id)")" || return 0
  ctx="${r%%$'\t'*}"
  printf '  - 이번엔 이 세션을 이어 쓰는 쪽이 쌉니다(다음 일: 수정, 지금 문맥 %s 토큰).\n' "$ctx"
  printf '  - %s 전이면 /clear 없이 바로: /do %s\n' "$(date -v+4M '+%H:%M' 2>/dev/null || date -d '+4 min' '+%H:%M')" "$key"
  printf '  - 그 시각이 지났으면 /clear 후 같은 명령을 입력하세요.\n'
}

# dobby_v2_change_open KEY [check] — v2 오더에 들어온 변경 요청(수정 지시·새 버그·추가 설계)을 구현 차례로 되돌린다.
#
# 설계 문서에 변경 절을 적고 사람이 확정한 **뒤에** 부른다. 그다음 dobby_design_ack 를 부르면
# 새 세션의 단계 판정이 "분석 + 승인 = 구현" 으로 읽어 그 변경만 구현한다.
#   · 자동 실행이 돌고 있으면 거부(반환 1) — 그 실행이 같은 상태 문서를 고치고 있다. 대시보드에 닿지 못하면 확인 없이 진행한다.
#   · 단계가 해결이면 해결 표시를 무른다(dobby_resolve undo 와 같은 일).
#   · 다음 리뷰 차수의 빈 폴더를 연다. 이걸 안 하면 리뷰 세션이 지난 차수의 결과 파일에 덮어쓰고,
#     지적 0건인 옛 결과 때문에 리뷰 없이 통합으로 넘어간다. 마지막 차수 폴더가 비어 있으면 그대로 쓴다.
#   · 단계를 분석으로 바꾼다. stdout 으로 이번 변경의 리뷰 시작 차수를 낸다(설계 문서 변경 절에 적는다).
#   · check 를 주면 자동 실행 확인만 하고 아무것도 바꾸지 않는다(변경 절을 쓰기 전에 부른다).
dobby_v2_change_open() {
  local key="$1" mode="${2:-}" url="${ORCHESTRATION_DASHBOARD_URL:-http://localhost:7253}" d f ph rd chk
  [ -n "$key" ] || { _die "쓰임: dobby_v2_change_open KEY"; return 1; }
  d="$(_order_dir "$key")"; f="$d/status.md"
  [ -f "$f" ] || { _die "$key 의 상태 문서가 없습니다"; return 1; }
  if chk="$(curl -fsS --max-time 5 "$url/api/orders?v2run=$key" 2>/dev/null)" \
     && [ "$(printf '%s' "$chk" | jq -r '.running // false' 2>/dev/null)" = "true" ]; then
    printf '%s 의 자동 실행이 돌고 있어 변경을 접수하지 않았습니다. 대시보드 오더 화면에서 실행이 끝나거나 멈춘 뒤 다시 해 주세요.\n' "$key" >&2
    return 1
  fi
  [ "$mode" = check ] && return 0
  ph="$(_order_phase "$key")"
  if [ "$ph" = "해결" ]; then
    awk '/^## 해결/{skip=1; next} /^## /{if(skip)skip=0} !skip{print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    dobby_event "$key" "해결 취소 — 변경 요청 접수" 2>/dev/null
  fi
  rd="$(find "$d/reviews" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sed 's/.*round-//' | sort -n | tail -1)"
  if [ -z "$rd" ]; then rd=1
  elif ls "$d/reviews/round-$rd"/*.md >/dev/null 2>&1; then rd=$((rd + 1))
  fi
  mkdir -p "$d/reviews/round-$rd"
  dobby_phase "$key" 분석
  dobby_event "$key" "변경 요청 접수 — 단계 $ph → 분석, 리뷰는 ${rd}차부터" 2>/dev/null
  printf '%s\n' "$rd"
}

# ─────────────────────────────────────────────────────────────────────────────
# /do auto 모드 — 통합 뒤 배포·검증까지 사람 없이 간다. 설계와 근거: skills/do/auto-mode.md
# 상태 문서 '## 현재 단계' 의 `- **자동 배포 환경**: {env}` 줄이 있는 오더만 해당한다.
# ─────────────────────────────────────────────────────────────────────────────
# dobby_v2_env KEY — 자동 배포 환경 값. 줄이 없으면 빈 출력(통합에서 멈추는 오더).
dobby_v2_env() {
  sed -nE 's/^[ \t]*-[ \t]*\*\*자동 배포 환경\*\*:[ \t]*([a-z0-9]+).*$/\1/p' "$(_order_dir "$1")/status.md" 2>/dev/null | head -1
}

# dobby_v2_set_env KEY ENV — 그 줄을 '- **단계**:' 바로 아래에 적는다(있으면 값만 바꾼다). dev·rc1·rc4 만 받는다.
dobby_v2_set_env() {
  local key="$1" env="$2" f
  _ship_has "$env" "$DOBBY_SHIP_MERGE_ENVS" || { _die "자동 배포 환경은 dev·rc1·rc4 중 하나다: '$env'"; return 1; }
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || { _die "$key 의 상태 문서가 없습니다"; return 1; }
  awk -v env="$env" '
    /^[ \t]*-[ \t]*\*\*자동 배포 환경\*\*/ { next }
    { print }
    /^[ \t]*-[ \t]*\*\*단계\*\*/ && !done { print "- **자동 배포 환경**: " env; done = 1 }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  dobby_event "$key" "자동 배포 환경 → $env" 2>/dev/null
}

# _v2_ship_repos KEY — 워크트리 표에서 배포를 맡는 저장소마다 "저장소<TAB>브랜치<TAB>경로".
_v2_ship_repos() {
  local f r row; f="$(_order_dir "$1")/status.md"
  for r in $DOBBY_SHIP_REPOS; do
    row="$(_wt_row "$f" "$r")"; [ -n "$row" ] && printf '%s\t%s\n' "$r" "$row"
  done
}

# _v2_ship_row KEY 저장소 환경 — '## 배포' 표의 그 행을 "단계 PR 빌드 갱신 비고" 로 준다(구분자 \037).
# 탭으로 나누면 빈 칸이 앞뒤 칸과 붙어 버려서(read 가 탭을 공백으로 다룬다) 다른 구분자를 쓴다.
_v2_ship_row() {
  awk -F'|' -v rp="$2" -v env="$3" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    /^## /{ins=($0 ~ /^##[ \t]*배포[ \t]*$/); next}
    ins && /^\|/ && NF>=9 && t($2)==rp && t($3)==env {printf "%s\037%s\037%s\037%s\037%s\n", t($4),t($5),t($6),t($7),t($8); exit}
  ' "$(_order_dir "$1")/status.md"
}

# _v2_in_env 경로 브랜치 저장소 환경 — 작업 브랜치의 마지막 커밋이 그 환경의 실제 브랜치에 들어갔으면 0.
# 수정 커밋이 새로 생기면 다시 거짓이 되므로 재배포가 필요하다는 표시를 따로 두지 않는다. fetch 는 부르는 쪽이 한다.
_v2_in_env() {
  local eb; eb="$(_ship_branch "$3" "$4")"; [ -n "$eb" ] || return 1
  git -C "$1" merge-base --is-ancestor "origin/$2" "origin/$eb" 2>/dev/null
}

# _v2_epoch "YYYY-MM-DD HH:MM" — 배포 표 갱신 칸을 초로.
_v2_epoch() { date -j -f '%Y-%m-%d %H:%M' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null; }

# dobby_ship_reopen KEY — 자동 배포 환경의 '배포 확인'·'검증 중'·'검증 완료' 행 가운데 작업 브랜치가
# 환경 브랜치에 아직 없는 행(수정 커밋 전의 옛 배포 기록)을 지운다. 지운 저장소를 한 줄씩 낸다.
# 행을 지우는 이유: dobby-ship 0단계가 그 행을 "이미 끝난 배포"로 읽는다. 지우면 PR 생성부터 다시 하고,
# dobby_ship_pr 이 열린 PR 이 없으면 새로 만든다.
dobby_ship_reopen() {
  local key="$1" env f r b p st
  env="$(dobby_v2_env "$key")"; [ -n "$env" ] || return 0
  f="$(_order_dir "$key")/status.md"
  while IFS=$'\t' read -r r b p; do
    st="$(_v2_ship_row "$key" "$r" "$env" | cut -d$'\037' -f1)"
    case "$st" in 배포\ 확인|검증\ 중|검증\ 완료) ;; *) continue ;; esac
    git -C "$p" fetch -q origin 2>/dev/null
    _v2_in_env "$p" "$b" "$r" "$env" && continue
    awk -F'|' -v rp="$r" -v env="$env" '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
      /^## /{ins=($0 ~ /^##[ \t]*배포[ \t]*$/)}
      ins && /^\|/ && NF>=9 && t($2)==rp && t($3)==env {next}
      {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    dobby_event "$key" "옛 배포 기록 지움 — $r $env ($st), 수정 커밋을 다시 배포한다" 2>/dev/null
    printf '%s\n' "$r"
  done < <(_v2_ship_repos "$key")
}

# dobby_v2_ship_next KEY — 통합 단계 auto 오더의 다음 일을 한 줄로 낸다: "일<TAB>저장소<TAB>설명".
# 기다림 두 가지만 넷째 칸이 있다: "일<TAB>저장소<TAB>PR 또는 run id<TAB>기다리기 시작한 시각".
#   blocked     표 단계에 ⚠(막힘)가 있다 — 멈춘다. 설명은 비고
#   wait-review 리뷰봇 리뷰를 기다린다(wadiz-frontend rc1·rc4 의 '리뷰 대기' 이후 새 리뷰가 아직 없다)
#   wait-build  빌드 칸의 run 이 아직 돌고 있다
#   ship        배포 세션이 할 일이 있다
#   verify      모든 저장소가 환경에 들어갔고 '배포 확인' 이후다 — 검증 세션
# 기다림이 있으면 배포 세션을 띄우지 않는다(com.wadiz.web 은 wadiz-frontend 머지·배포 뒤에야 나아갈 수 있다).
# 기다리기 시작한 시각은 그 행의 갱신 칸이다(셸이 10분 알림·30분 멈춤을 이것으로 잰다).
dobby_v2_ship_next() {
  local key="$1" env r b p st pr bd ts nt gr id s wait="" ship="" any=""
  env="$(dobby_v2_env "$key")"; [ -n "$env" ] || { _die "$key 에 자동 배포 환경 줄이 없습니다"; return 1; }
  while IFS=$'\t' read -r r b p; do
    any=1
    IFS=$'\037' read -r st pr bd ts nt <<<"$(_v2_ship_row "$key" "$r" "$env")"
    case "$st" in *⚠*) printf 'blocked\t%s\t%s\n' "$r" "${nt:-비고 없음}"; return 0 ;; esac
    gr="$(_ship_repo "$p")"
    case "$st" in
      "리뷰 대기")
        if _ship_reviewbot "$r" && [ "$env" != dev ] && [ -n "$pr" ] && [ "$pr" != - ]; then
          s="$(gh pr view "${pr#\#}" --repo "$gr" --json reviews \
               --jq '[.reviews[].submittedAt | fromdateiso8601] | max // 0' 2>/dev/null)"
          if [ "${s:-0}" -lt "$(_v2_epoch "$ts")" ]; then
            [ -n "$wait" ] || wait="$(printf 'wait-review\t%s\t%s\t%s' "$r" "$pr" "$ts")"
            continue
          fi
        fi ;;
      "빌드 대기"|"배포 대기")
        for id in $(printf '%s' "$bd" | grep -oE '(static|global|web)#[0-9]+' | cut -d'#' -f2); do
          s="$(gh run view "$id" --repo "$gr" --json status --jq .status 2>/dev/null)"
          if [ -n "$s" ] && [ "$s" != completed ]; then
            [ -n "$wait" ] || wait="$(printf 'wait-build\t%s\t%s\t%s' "$r" "$id" "$ts")"
            continue 2
          fi
        done ;;
    esac
    git -C "$p" fetch -q origin 2>/dev/null
    case "$st" in 배포\ 확인|검증\ 중|검증\ 완료) _v2_in_env "$p" "$b" "$r" "$env" && continue ;; esac
    [ -n "$ship" ] || ship="$(printf 'ship\t%s\t%s' "$r" "${st:-배포 기록 없음}")"
  done < <(_v2_ship_repos "$key")
  [ -n "$any" ] || { printf 'blocked\t-\t워크트리 표에 배포를 맡는 저장소(%s)가 없습니다\n' "$DOBBY_SHIP_REPOS"; return 0; }
  if [ -n "$wait" ]; then printf '%s\n' "$wait"
  elif [ -n "$ship" ]; then printf '%s\n' "$ship"
  else printf 'verify\t-\t모든 저장소가 %s 에 배포됨\n' "$env"
  fi
}

# dobby_v2_test_fixes KEY — 검증 실패를 고친 횟수(agent-logs.json 의 fix-test-* 하위 키 수, 모든 담당 합계).
# 상한은 2번이다(auto-mode.md "수정 상한"). 리뷰 지적 수정(fix-N)은 세지 않는다.
dobby_v2_test_fixes() {
  local f; f="$(_order_dir "$1")/agent-logs.json"
  [ -f "$f" ] || { printf '0'; return 0; }
  jq -r '[.[] | objects | keys[] | select(startswith("fix-test-"))] | length' "$f" 2>/dev/null || printf '0'
}

# dobby_jira_desc KEY [저장 경로] — 이슈 설명을 마크다운으로 받는다. 경로를 주면 파일로, 없으면 화면으로.
# twg 는 설명을 문서 구조 JSON(ADF)으로 준다(FE1-2140: 2만 자 안팎). 그대로 읽으면 MCP(약 5천 자)보다 커서
# 같은 폴더의 adf-to-md.jq 로 바꾼다(같은 이슈 1,872자). 설명이 비어 있으면 아무것도 쓰지 않고 1 을 돌려준다.
# --select 는 반드시 --fields 와 같이 쓴다. 경로가 틀리면 --select 가 무시되고 전체(12만 자)가 나온다.
# 훅 복사본(~/.config/go-dobby/hooks/)에는 adf-to-md.jq 가 없다. 이 헬퍼는 플러그인 원본에서만 부른다.
dobby_jira_desc() {
  local key="$1" out="${2:-}" md
  md="$(twg jira workitem get "$key" --fields description -o json --output-summary none --select data.description 2>/dev/null \
    | jq '.data[0].description | objects | select(.type=="doc")' 2>/dev/null \
    | jq -r -f "$DOBBY_LIB_DIR/adf-to-md.jq" 2>/dev/null)"
  [ -n "$md" ] || return 1
  if [ -n "$out" ]; then printf '%s\n' "$md" >"$out"; else printf '%s\n' "$md"; fi
}

# dobby_jira_start_transition KEY — 할 일(new) 상태면 진행 중으로 바꾼다. 출력: changed / already / done / failed
# 상태 이름이 아니라 분류(statusCategory)로 판정한다. 프로젝트마다 상태 이름이 다를 수 있다.
dobby_jira_start_transition() {
  local key="$1" cat id
  cat="$(twg jira workitem get "$key" --fields status -o json --output-summary none --select data.status.statusCategory.key 2>/dev/null \
    | jq -r '.data[0].status.statusCategory.key // empty' 2>/dev/null)"
  case "$cat" in
    indeterminate) echo already; return 0 ;;
    done) echo done; return 0 ;;
    new) ;;
    *) echo failed; return 1 ;;
  esac
  # 도착 분류가 '진행 중'인 전환을 고른다(전환 목록은 분류별로 묶여 나온다, 552자).
  id="$(twg jira workitem transitions query --id "$key" -o json --output-summary none 2>/dev/null \
    | jq -r '[.data.transitions[]? | select(.category=="진행 중") | .id] | first // empty' 2>/dev/null)"
  [ -n "$id" ] || { echo failed; return 1; }
  if twg jira workitem transition --id "$key" --transition-id "$id" >/dev/null 2>&1; then echo changed; else echo failed; return 1; fi
}

# dobby_v2_notify KEY 본문 — 사람에게 알릴 일을 이벤트 로그에 남긴다. 알림은 대시보드가 상태를 읽어 띄운다.
# 슬랙·메일 발송은 하지 않는다(건당 헤드리스 세션 하나, 23만~31만 토큰). 반환은 언제나 0.
dobby_v2_notify() {
  dobby_event "$1" "알림 — ${2%%$'\n'*}" 2>/dev/null
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 릴리즈 노트 등록 기록 — dobby-release 가 update-release-note 결과를 확인한 뒤 남긴다.
# ─────────────────────────────────────────────────────────────────────────────

DOBBY_RELEASE_MERGE_LIST="머지됨 / 머지 안 함 / 충돌 / 건너뜀 / 확인 못 함"

# dobby_release_note KEY 배포일 저장소 브랜치 행번호 PR 머지 [페이지주소]
#
# status.md `## 릴리즈 노트` 표를 **(배포일, 저장소)별 한 행**으로 넣거나 고친다. 갱신 시각은 자동.
#   · 배포일은 YYYY-MM-DD. 대시보드가 "다음 정기배포에 올라가 있나"를 이 값으로 가른다.
#   · PR 은 `#번호` 또는 `-`(PR 을 만들지 않았거나 건너뜀). 머지는 위 어휘 다섯 개 밖이면 거부.
#   · 표가 없으면 `## 세션` 앞에(없으면 문서 끝에) 새로 만든다.
dobby_release_note() {
  local key="$1" day="$2" rp="$3" br="$4" row="$5" pr="$6" mg="$7" url="${8:--}" f ts
  [ -n "$key" ] && [ -n "$day" ] && [ -n "$rp" ] && [ -n "$br" ] && [ -n "$row" ] && [ -n "$pr" ] && [ -n "$mg" ] \
    || { _die "쓰임: dobby_release_note KEY 배포일 저장소 브랜치 행번호 PR 머지 [페이지주소]"; return 1; }
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { _die "배포일은 YYYY-MM-DD 로: '$day'"; return 1; }
  case "$mg" in 머지됨|"머지 안 함"|충돌|건너뜀|"확인 못 함") ;;
    *) _die "머지 칸 어휘가 아니다: '$mg' (허용: $DOBBY_RELEASE_MERGE_LIST)"; return 1 ;; esac
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || { _die "status.md 가 없다: $key"; return 1; }
  ts="$(date '+%Y-%m-%d %H:%M')"

  if ! grep -q '^##[[:space:]]*릴리즈 노트[[:space:]]*$' "$f"; then
    awk '
      function head() { print "## 릴리즈 노트"; print "| 배포일 | 저장소 | 브랜치 | 행 | 릴리스 PR | 머지 | 페이지 | 갱신 |"; print "|---|---|---|---|---|---|---|---|"; print ""; done = 1 }
      !done && /^##[ \t]*세션[ \t]*$/ { head() }
      { print }
      END { if (!done) { print ""; head() } }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi

  awk -v day="$day" -v rp="$rp" -v br="$br" -v row="$row" -v pr="$pr" -v mg="$mg" -v url="$url" -v ts="$ts" '
    function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    function emit() { printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", day, rp, br, row, pr, mg, url, ts; found = 1 }
    /^## / { if (insec && !found) emit(); insec = ($0 ~ /^##[ \t]*릴리즈 노트[ \t]*$/) }
    insec && /^[ \t]*\|/ {
      split($0, c, "|")
      if (trim(c[2]) == day && trim(c[3]) == rp) { emit(); next }
      print; next
    }
    insec && !found && /^[ \t]*$/ { emit() }
    { print }
    END { if (insec && !found) emit() }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ─────────────────────────────────────────────────────────────────────────────
# 충돌 해결 브랜치 — {브랜치}_into_{환경}
#
# ⛔ 이 저장소에서는 **언제나** 충돌 해결 브랜치로 올린다. 충돌이 없어도 그렇게 한다.
#
# 왜: git 은 깨끗한데 GitHub 이 충돌이라 하는 일이 잦다. 공통 조상이 여러 개일 때
# 생긴다 — git 은 조상들을 재귀적으로 합친 가상 기준으로 병합하지만 GitHub 은 조상
# 하나만 쓴다. 병합 커밋을 미리 만들어 올리면 환경 브랜치가 그 커밋의 조상이 되어
# 모호성이 사라진다. 실측 FE1-1800: #29211·#29272·#29428 이 모두 _into_dev 였고,
# 충돌 해결 브랜치 없이 올린 #29427 만 닫혔다(FE1-1943 도 _into_rc4).
#
# 예전에는 "먼저 그냥 PR 을 만들고 GitHub 이 충돌이라 하면 다시 충돌 해결 브랜치로" 였는데,
# 그러면 PR 을 만들었다 닫고 다시 만든다. 처음부터 충돌 해결 브랜치로 가면 그 왕복이 없다.

# dobby_bridge_make 워크트리 브랜치 환경 — 충돌 해결 브랜치를 만들어 원격에 올린다.
#
# 충돌이 없으면 체크아웃 없이 병합 커밋만 만들어 올린다(작업 트리·HEAD 안 건드림).
#   → stdout: `clean`
# 충돌이 있으면 **임시 워크트리**에 병합을 멈춘 상태로 만들어 두고 그 경로를 돌려준다.
#   → stdout: `conflict {임시워크트리경로}` + 충돌 파일 목록(stderr), 반환값 2
#   오더 워크트리는 건드리지 않는다 — 리뷰를 통과한 상태 그대로 둔다.
# 이미 올린 충돌 해결 브랜치가 두 브랜치를 다 담고 있으면 다시 만들지 않고 `clean`.
# 환경 브랜치만 담고 있으면 그 위에 작업 브랜치의 새 커밋만 합친다 — 앞서 푼 충돌을 다시 풀지 않는다.
dobby_bridge_make() {
  local wt="$1" br="$2" env="$3"
  [ -d "$wt" ] || { _die "워크트리가 없다: $wt"; return 1; }
  local bridge="${br}_into_${env}"
  git -C "$wt" fetch -q origin "$env" "$br" 2>/dev/null
  git -C "$wt" fetch -q origin "$bridge" 2>/dev/null
  if git -C "$wt" rev-parse -q --verify "origin/$bridge" >/dev/null \
     && git -C "$wt" merge-base --is-ancestor "origin/$br" "origin/$bridge" \
     && git -C "$wt" merge-base --is-ancestor "origin/$env" "origin/$bridge"; then
    printf 'clean'
    return 0
  fi
  local from="origin/$env"
  git -C "$wt" rev-parse -q --verify "origin/$bridge" >/dev/null \
    && git -C "$wt" merge-base --is-ancestor "origin/$env" "origin/$bridge" \
    && from="origin/$bridge"

  local tree
  tree="$(git -C "$wt" merge-tree --write-tree "$from" "origin/$br" 2>/dev/null | head -1)"
  if [ -n "$tree" ] && git -C "$wt" merge-tree --write-tree "$from" "origin/$br" >/dev/null 2>&1; then
    local commit
    commit="$(git -C "$wt" commit-tree "$tree" -p "$from" -p "origin/$br" \
      -m "Merge branch '$br' into $env" 2>/dev/null)" \
      || { _die "병합 커밋을 만들지 못했다"; return 1; }
    git -C "$wt" push -q origin "${commit}:refs/heads/${bridge}" --force-with-lease 2>/dev/null \
      || git -C "$wt" push -q origin "${commit}:refs/heads/${bridge}" 2>/dev/null \
      || { _die "충돌 해결 브랜치 $bridge 를 올리지 못했다"; return 1; }
    printf 'clean'
    return 0
  fi

  # ── 충돌 — 임시 워크트리에서 진짜 병합을 해 둔다 ────────────────────────
  local tmp; tmp="$(mktemp -d -t dobbybridge)" || { _die "임시 폴더를 만들지 못했다"; return 1; }
  rm -rf "$tmp"
  git -C "$wt" worktree add -q --detach "$tmp" "$from" 2>/dev/null \
    || { _die "임시 워크트리를 만들지 못했다: $tmp"; return 1; }
  git -C "$tmp" checkout -q -B "$bridge" 2>/dev/null
  git -C "$tmp" merge --no-commit --no-ff "origin/$br" >/dev/null 2>&1

  local files; files="$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null)"
  if [ -z "$files" ]; then
    # merge-tree 는 충돌이라 했는데 실제 병합은 깨끗했다 — 그대로 마무리한다.
    printf 'dobby-lib: 실제 병합은 깨끗했다. 그대로 올린다.\n' >&2
    dobby_bridge_finish "$tmp" "$br" "$env" >/dev/null || return 1
    printf 'clean'
    return 0
  fi
  printf 'dobby-lib: 충돌 %s개 — 임시 워크트리에서 풀어라: %s\n' \
    "$(printf '%s\n' "$files" | grep -c .)" "$tmp" >&2
  printf '%s\n' "$files" >&2
  printf 'conflict %s' "$tmp"
  return 2
}

# dobby_conflict_evidence 임시워크트리 브랜치 환경 — 충돌 파일마다 **양쪽이 왜 건드렸나**.
#
# ⛔ 근거 없이 한쪽을 고르지 않는다. 그래서 고르기 전에 이걸 한 번 부른다.
# 파일마다 따로 git 을 치면 왕복이 파일 수만큼 는다 — 한 번에 모아 준다.
dobby_conflict_evidence() {
  local tmp="$1" br="$2" env="$3" f base
  [ -d "$tmp" ] || { _die "폴더가 없다: $tmp"; return 1; }
  base="$(git -C "$tmp" merge-base "origin/$env" "origin/$br" 2>/dev/null)"
  [ -n "$base" ] || { _die "공통 조상을 찾지 못했다"; return 1; }

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '### %s\n\n' "$f"
    printf '**이 오더 쪽(%s) 이력**\n\n```\n' "$br"
    git -C "$tmp" log --oneline "$base..origin/$br" -- "$f" 2>/dev/null | head -10
    printf '```\n\n**환경 쪽(%s) 이력**\n\n```\n' "$env"
    git -C "$tmp" log --oneline "$base..origin/$env" -- "$f" 2>/dev/null | head -10
    printf '```\n\n**이 오더 쪽 변경**\n\n```diff\n'
    git -C "$tmp" diff "$base" "origin/$br" -- "$f" 2>/dev/null | head -120
    printf '```\n\n**환경 쪽 변경**\n\n```diff\n'
    git -C "$tmp" diff "$base" "origin/$env" -- "$f" 2>/dev/null | head -120
    printf '```\n\n'
  done <<EOF
$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null)
EOF
}

# dobby_bridge_finish 임시워크트리 브랜치 환경 — 검증하고 커밋·푸시하고 정리한다.
#
# 사람이 승인하지 않는 흐름이라 검증을 두껍게 한다. 하나라도 걸리면 **아무것도 올리지 않고**
# 임시 워크트리를 그대로 남긴다(무엇이 걸렸는지 그 자리에서 볼 수 있게).
#   ① 충돌 표시자가 남아 있나
#   ② 해결하지 않은 파일이 남아 있나(UU·AA·DU·UD)
#   ③ 저장소 고유 금지 규칙(dobby_repo_lint)
# 의도 보존(양쪽 핵심 식별자가 결과에 남아 있나)은 기계가 못 가리므로 **스킬이 판단**한다.
dobby_bridge_finish() {
  local tmp="$1" br="$2" env="$3"
  [ -d "$tmp" ] || { _die "폴더가 없다: $tmp"; return 1; }
  local bridge="${br}_into_${env}" bad

  # ① 표시자가 남아 있으면 아직 안 푼 것이다. (작업 트리 내용 기준 — add 여부와 무관)
  bad="$(git -C "$tmp" grep -n -E '^(<<<<<<<|=======|>>>>>>>)' 2>/dev/null | head -20)"
  [ -z "$bad" ] || { _die "충돌 표시자가 남아 있다:
$bad"; return 1; }

  # ② 무엇이 충돌이었는지 기록으로 남긴다. 파일을 고치기만 하고 add 하지 않은 상태가
  #    정상이므로(스킬은 내용만 고친다) 여기서 거부하지 않고 아래에서 add 한다.
  local unmerged; unmerged="$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null)"
  [ -z "$unmerged" ] || printf 'dobby-lib: 충돌이었던 파일 — %s\n' "$(printf '%s' "$unmerged" | tr '\n' ' ')" >&2

  git -C "$tmp" add -A >/dev/null 2>&1

  # ③ 스테이지에 표시자가 섞여 들어가지 않았나(빈칸·탭 오염 포함)
  git -C "$tmp" diff --cached --check >&2 || { _die "스테이지에 문제가 있다(위 출력)"; return 1; }

  if ! dobby_repo_lint "$tmp" HEAD >&2; then
    _die "저장소 고유 금지 규칙에 걸렸다. 위 지적을 고치고 다시 불러라."
    return 1
  fi

  git -C "$tmp" commit -q --no-verify -m "Merge branch '$br' into $env" >/dev/null 2>&1 \
    || { _die "병합 커밋을 만들지 못했다"; return 1; }
  git -C "$tmp" push -q origin "HEAD:refs/heads/${bridge}" --force-with-lease 2>/dev/null \
    || git -C "$tmp" push -q origin "HEAD:refs/heads/${bridge}" 2>/dev/null \
    || { _die "충돌 해결 브랜치 $bridge 를 올리지 못했다"; return 1; }

  git -C "$tmp" worktree remove --force "$tmp" >/dev/null 2>&1 \
    || rm -rf "$tmp" 2>/dev/null
  printf '%s' "$bridge"
}

# dobby_ship_pr KEY 워크트리 브랜치 환경 "제목" "본문" — PR 생성(또는 기존 것 재사용). 번호 stdout.
#
# 막는 것:
#   · 환경이 dev·rc1·rc4·stage 가 아니면 거부(clive 포함)
#   · 워크트리에 미커밋 변경이 남아 있으면 거부 — 리뷰 통과분만 나간다(C1)
#   · 같은 (브랜치→환경) PR 이 이미 열려 있으면 새로 만들지 않고 그 번호를 돌려준다
#     (충돌 해결 브랜치 {브랜치}_into_{환경} 로 올라간 것까지 함께 본다)
#   · ⛔ **언제나 충돌 해결 브랜치({브랜치}_into_{환경})로 올린다** — 충돌이 없어도 그렇게 한다.
#     GitHub 이 멀쩡한 병합을 충돌로 판정하는 일이 잦아(공통 조상 여러 개), 예전처럼
#     "그냥 올렸다가 충돌이라 하면 다시 충돌 해결 브랜치로" 하면 PR 을 만들었다 닫고 다시 만든다.
#   · 충돌이 있으면 충돌 해결 브랜치를 만들지 못하므로 거부한다 — 푸는 것은 dobby_bridge_make 가 만든
#     임시 워크트리에서 스킬이 한다(dobby_conflict_evidence → 해결 → dobby_bridge_finish).
# 해 주는 것:
#   · **저장소마다 다른 베이스 브랜치로 옮긴다**(_ship_branch). com.wadiz.web 의 dev 는
#     `cloud_dev` 라, 논리 환경을 그대로 베이스로 쓰면 없는 브랜치라 실패한다.
#   · 리뷰봇이 도는 저장소(wadiz-frontend)에서 dev 를 뺀 환경에만 --reviewer wadiz-fe/fe1-team 을
#     **자동으로** 붙인다. 리뷰 요청이 있어야 자동 코드리뷰가 돌아 승인이 붙는다.
#     ⛔ com.wadiz.web 에는 붙이지 않는다 — 리뷰봇이 없어 **오지 않을 리뷰를 기다리게 되고**,
#        조직이 달라(wadiz-web) wadiz-fe/fe1-team 은 붙지도 않는다.
dobby_ship_pr() {
  local key="$1" wt="$2" br="$3" env="$4" title="$5" body="$6" n dirty
  _ship_has "$env" "$DOBBY_SHIP_ENVS" || { _die "배포 환경이 아니다: '$env' (허용: $DOBBY_SHIP_ENVS)"; return 1; }
  [ -d "$wt" ] || { _die "워크트리가 없다: $wt"; return 1; }

  # ⛔ 통합까지 끝난 오더인가. 리뷰를 통과한 것만 내보낸다(C1).
  local ph; ph="$(_order_phase "$key")"
  if [ -n "$ph" ]; then
    _ship_has "$ph" "$DOBBY_SHIP_PHASES" || {
      _die "현재 단계가 '$ph' 다 — 배포은 통합이 끝난 뒤에 한다(허용: $DOBBY_SHIP_PHASES). dobby-order 를 먼저 P7 통합까지 진행하라."
      return 1
    }
  fi

  # ⛔ 이 스킬이 맡는 저장소인가. 아니면 조용히 틀린 일을 하기 전에 멈춘다.
  local name; name="$(basename "$(_ship_repo "$wt")")"
  _ship_has "$name" "$DOBBY_SHIP_REPOS" || {
    _die "이 스킬은 '$name' 저장소를 다루지 않는다(맡는 저장소: $DOBBY_SHIP_REPOS). 환경 브랜치 이름·리뷰봇·빌드 방식이 달라 한 틀로 돌리면 틀린 일을 한다. 이 저장소는 사용자가 직접 PR·머지·배포한 뒤 /dobby-test 로 검증만 이어서 하라."
    return 1
  }

  # ⛔ 논리 환경 → 이 저장소의 실제 브랜치. 여기서 갈라야 com.wadiz.web 의 dev 가 cloud_dev 로 간다.
  local base; base="$(_ship_branch "$name" "$env")"
  [ -n "$base" ] || {
    _die "'$name' 에는 '$env' 환경이 없다. 어느 환경으로 내보낼지 사용자에게 확인하고 다시 하라."
    return 1
  }

  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -5)"
  if [ -n "$dirty" ]; then
    _die "워크트리에 미커밋 변경이 남아 있다 — 리뷰를 통과한 것만 내보낸다(C1). 먼저 dobby_commit_push 로 정리하라:
$dirty"
    return 1
  fi

  # 이미 열린 PR — 충돌 해결 브랜치로 올라간 것까지 함께 본다.
  local bridge="${br}_into_${base}" rp
  rp="$(_ship_repo "$wt")"
  n="$(gh pr list --repo "$rp" --head "$br" --base "$base" --state open --json number -q '.[0].number' 2>/dev/null)"
  [ -n "$n" ] || n="$(gh pr list --repo "$rp" --head "$bridge" --base "$base" --state open --json number -q '.[0].number' 2>/dev/null)"
  if [ -n "$n" ]; then
    dobby_ship_stage "$key" "$name" "$env" "PR 생성" "#$n"
    printf '%s' "$n"; return 0
  fi

  # ── 충돌 해결 브랜치를 만든다(충돌이 없어도 언제나) ─────────────────────────
  local made rc
  made="$(dobby_bridge_make "$wt" "$br" "$base")"; rc=$?
  if [ "$rc" -eq 2 ]; then
    _die "$br → $base 에 충돌이 있다. 임시 워크트리에서 풀어라: ${made#conflict }
  ① dobby_conflict_evidence {임시워크트리} $br $base   — 양쪽이 왜 건드렸는지 본다
  ② 근거로 판단해 직접 고친다. 근거로도 어느 쪽이 맞는지 확정되지 않으면 사용자에게 묻는다
  ③ dobby_bridge_finish {임시워크트리} $br $base       — 검증하고 올린다
  그 뒤 이 함수를 다시 부르면 충돌 해결 브랜치로 PR 을 만든다."
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1

  local extra=()
  if _ship_reviewbot "$name" && [ "$env" != "dev" ]; then extra=(--reviewer wadiz-fe/fe1-team); fi
  ( cd "$wt" && gh pr create --base "$base" --head "$bridge" --title "$title" --body "$body" "${extra[@]}" ) >&2 || return 1
  n="$(gh pr list --repo "$rp" --head "$bridge" --base "$base" --state open --json number -q '.[0].number')"
  [ -n "$n" ] || { _die "PR 을 만들었는데 번호를 못 찾았다"; return 1; }
  dobby_event "$key" "PR 생성 — $name #$n ($bridge → $base)"
  dobby_ship_stage "$key" "$name" "$env" "PR 생성" "#$n"
  printf '%s' "$n"
}

# dobby_ship_resubmit KEY 워크트리 브랜치 환경 PR번호 — 리뷰 반영을 새 PR 로 다시 리뷰받는다. 새 번호 stdout.
#
# 자동 코드리뷰는 리뷰 요청에만 돈다. 리뷰를 받으면 요청이 지워져 반영 푸시로는 다시 돌지 않고,
# 요청을 다시 걸어도 돌지 않는다(사용자 확인). 새 PR 을 열면 돈다(실측 FE1-2054 #30106 → #30109).
# 충돌 해결 브랜치를 반영분까지 갱신한 뒤 옛 PR 을 닫고 같은 제목·본문으로 새 PR 을 연다.
dobby_ship_resubmit() {
  local key="$1" wt="$2" br="$3" env="$4" old="$5" name base rp made rc title body n
  name="$(basename "$(_ship_repo "$wt")")"
  _ship_reviewbot "$name" || { _die "'$name' 에는 자동 코드리뷰가 없다 — 새 PR 로 갈아탈 이유가 없다."; return 1; }
  base="$(_ship_branch "$name" "$env")"
  [ -n "$base" ] || { _die "'$name' 에는 '$env' 환경이 없다."; return 1; }
  rp="$(_ship_repo "$wt")"
  [ "$(gh pr view "$old" --repo "$rp" --json state -q .state 2>/dev/null)" = OPEN ] \
    || { _die "PR #$old 이 열려 있지 않다."; return 1; }

  made="$(dobby_bridge_make "$wt" "$br" "$base")"; rc=$?
  if [ "$rc" -eq 2 ]; then
    _die "반영분을 충돌 해결 브랜치에 합치다 충돌이 났다. 임시 워크트리에서 풀어라: ${made#conflict }
  ① dobby_conflict_evidence {임시워크트리} $br $base
  ② 근거로 판단해 직접 고친다
  ③ dobby_bridge_finish {임시워크트리} $br $base
  그 뒤 이 함수를 다시 부른다."
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1

  title="$(gh pr view "$old" --repo "$rp" --json title -q .title)" || return 1
  body="$(gh pr view "$old" --repo "$rp" --json body -q .body)" || return 1
  gh pr close "$old" --repo "$rp" --comment "리뷰 반영분을 새로 리뷰받기 위해 닫고 새 PR 로 이어 갑니다." >&2 || return 1
  n="$(dobby_ship_pr "$key" "$wt" "$br" "$env" "$title" "$body")" || return 1
  gh pr comment "$old" --repo "$rp" --body "#$n 으로 이어 갑니다." >&2
  dobby_event "$key" "PR 다시 열기 — $name #$old 닫음, #$n 에서 리뷰를 새로 받는다"
  printf '%s' "$n"
}

# 워크트리의 저장소(owner/repo).
_ship_repo() { git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##'; }

# dobby_ship_merge KEY 저장소 PR번호 — 머지 전에 막을 것을 다 보고 머지한다.
#
# ⛔ 저장소를 **인자로 받는다.** 예전에는 gh 가 현재 디렉터리로 짐작했는데, 멀티레포 오더는
#    후보가 여러 개라 엉뚱한 저장소의 같은 번호를 볼 수 있다(실측 FE1-1301: 저장소를 잘못
#    잡아 PR 링크가 404 였다).
#
# 막는 것:
#   · 베이스가 그 저장소의 dev·rc1·rc4 브랜치가 아니면 거부(stage·cloud_live·release/* …)
#   · 충돌(CONFLICTING)이면 거부
#   · 반영하지 않은 변경요청(CHANGES_REQUESTED)이 남아 있으면 거부
#     — "기다리지 않는" 환경(stage·dev)에서도 달려 있는 지적을 모르고 덮는 것을 막는다
#   · **G-A** com.wadiz.web 은 같은 환경의 wadiz-frontend 가 머지되기 전이면 거부
dobby_ship_merge() {
  local key="$1" rp="$2" pr="$3" j base mergeable decision env e fe
  [ -n "$rp" ] && [ -n "$pr" ] || { _die "쓰임: dobby_ship_merge KEY 저장소 PR번호"; return 1; }
  _ship_has "$rp" "$DOBBY_SHIP_REPOS" \
    || { _die "배포을 맡는 저장소가 아니다: '$rp' (허용: $DOBBY_SHIP_REPOS)"; return 1; }
  j="$(gh pr view "$pr" --repo "$(_ship_owner "$rp")" --json baseRefName,mergeable,reviewDecision 2>/dev/null)" \
    || { _die "$rp 의 PR #$pr 을 조회하지 못했다"; return 1; }
  base="$(printf '%s' "$j" | sed -nE 's/.*"baseRefName":"([^"]*)".*/\1/p')"
  mergeable="$(printf '%s' "$j" | sed -nE 's/.*"mergeable":"([^"]*)".*/\1/p')"
  decision="$(printf '%s' "$j" | sed -nE 's/.*"reviewDecision":"([^"]*)".*/\1/p')"

  # 베이스 브랜치 → 논리 환경. 머지해도 되는 환경(dev·rc1·rc4) 안에서만 찾는다.
  env=""
  for e in $(_words "$DOBBY_SHIP_MERGE_ENVS"); do
    [ "$(_ship_branch "$rp" "$e")" = "$base" ] && { env="$e"; break; }
  done
  [ -n "$env" ] \
    || { _die "베이스가 '$base' 인 $rp PR 은 이 스킬이 머지하지 않는다(허용 환경: $DOBBY_SHIP_MERGE_ENVS). stage·정식 배포 베이스 반영은 사용자가 직접 한다."; return 1; }
  [ "$mergeable" != "CONFLICTING" ] \
    || { _die "PR #$pr 에 충돌이 있다. 워크트리에서 $base 를 머지해 풀고 푸시한 뒤 다시 하라."; return 1; }
  [ "$decision" != "CHANGES_REQUESTED" ] \
    || { _die "PR #$pr 에 반영하지 않은 변경요청이 있다. 리뷰 내용을 읽고 처리한 뒤 다시 하라."; return 1; }

  # ── G-A. com.wadiz.web 은 wadiz-frontend 가 머지된 뒤에 ──────────────────
  # 둘은 같이 나가야 동작한다(FE 가 부르는 컨트롤러·JSP 가 저쪽에 있다). 먼저 머지하면
  # 그 사이에 배포가 돌아 **한쪽만 반영된 상태**가 된다. FE 행이 없으면(단독 오더) 끄고 간다.
  if [ "$rp" = com.wadiz.web ]; then
    fe="$(_ship_row_rank "$key" wadiz-frontend "$env")"
    if [ -n "$fe" ] && [ "$fe" -lt "$DOBBY_SHIP_RANK_MERGED" ]; then
      _die "wadiz-frontend 가 아직 머지되지 않았다(현재 '$(_ship_row_stage "$key" wadiz-frontend "$env")'). com.wadiz.web 은 그 뒤에 머지한다 — 먼저 머지하면 한쪽만 반영된 상태로 배포가 돈다. FE 머지 뒤에 다시 하라."
      return 1
    fi
  fi

  gh pr merge "$pr" --repo "$(_ship_owner "$rp")" --merge >&2 || return 1
  dobby_event "$key" "$rp PR #$pr 머지 → $base"
  dobby_ship_stage "$key" "$rp" "$env" "빌드 대기" "#$pr"
}

# _ship_owner 저장소이름 → owner/repo. gh 에 --repo 로 넘길 값이다.
_ship_owner() {
  case "$1" in
    wadiz-frontend) printf 'wadiz-fe/wadiz-frontend' ;;
    com.wadiz.web)  printf 'wadiz-web/com.wadiz.web' ;;
  esac
}

# dobby_ship_round KEY 저장소 환경 — 리뷰 반영 라운드를 하나 올린다. 4회째면 거부한다. 회차 stdout.
# 리뷰↔수정이 무한히 오가는 것을 막는다(글로 적은 "3라운드 상한"을 코드로).
# 리뷰봇이 없는 저장소(com.wadiz.web)에서는 쓸 일이 없다 — 불러도 막지는 않는다.
dobby_ship_round() {
  local key="$1" rp="${2:-}" env="${3:-}" f n
  f="$(_order_dir "$key")/status.md"
  [ -f "$f" ] || { _die "status.md 가 없다: $key"; return 1; }
  n="$(grep -cE '^- .* PR 리뷰 [0-9]+회차' "$(_order_dir "$key")/orchestration.md" 2>/dev/null)" || n=0
  n=$((n + 1))
  if [ "$n" -gt 3 ]; then
    [ -n "$rp" ] && [ -n "$env" ] && dobby_ship_stage "$key" "$rp" "$env" "리뷰 대기" "" "" "리뷰 왕복 3회 — 사람 확인 필요"
    _die "리뷰 반영이 3회를 넘었다($n회째). 무엇이 반복해서 걸리는지 정리해 사용자에게 알리고 멈춰라."
    return 1
  fi
  [ -n "$rp" ] && [ -n "$env" ] && dobby_ship_stage "$key" "$rp" "$env" "리뷰 반영 ${n}회차"
  printf '%s' "$n"
}

# dobby_ship_verify KEY "필요번들" "확인된번들" — 배포 대조. 빠진 게 있으면 1을 반환한다.
#
# **테스트 앞의 게이트가 아니라 실패했을 때 쓰는 진단 도구다.** 배포 완료가 확인되면 바로
# 테스트로 가고(스킬 8단계), 실패하면 코드를 의심하기 전에 이것으로 반쪽 배포부터 가른다.
# 맞아떨어질 때는 아무것도 알려 주지 않으면서 기다리게만 하므로 미리 세지 않는다.
#
# 사례 FE1-1808: 빌드가 머지보다 68분 앞선 상태로 회차를 열어 0성공/3실패/4건너뜀.
# 재배포 후 같은 절차로 9/0/0 통과 — 방법이 아니라 순서가 문제였다.
# 인자는 공백으로 구분한 번들 이름 목록이다. 예: dobby_ship_verify FE1-1943 "static global" "static"
dobby_ship_verify() {
  local key="$1" need="$2" got="$3" env="${4:-}" miss="" b
  [ -n "$need" ] || { _die "필요한 번들 목록이 비었다"; return 1; }
  local need_n; need_n="$(_words "$need")"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    _ship_has "$b" "$got" || miss="$miss $b"
  done <<EOF
$need_n
EOF
  if [ -n "$miss" ]; then
    [ -n "$env" ] && dobby_ship_stage "$key" wadiz-frontend "$env" "배포 대기" "" "" "배포 미확인 —${miss}"
    _die "배포가 확인되지 않은 번들이 있다:${miss} (필요: $need / 확인: $got). 테스트 실패가 코드 결함이 아니라 **반쪽 배포** 때문일 수 있다 — 빠진 번들을 다시 빌드하고 배포를 기다린 뒤 회차를 다시 열어라."
    return 1
  fi
  printf '배포 확인 완료: %s\n' "$need"
}

# ─────────────────────────────────────────────────────────────────────────────
# dobby_review_brief 워크트리... — 리뷰 에이전트에게 **미리 붙여 줄 사실**을 한 번에 만든다.
#
# 왜: 리뷰 비용은 내용이 아니라 **왕복 횟수**다. 실측(리뷰 24건) — 명령으로 받아 본 내용은
# 다 합쳐 0.42M 토큰인데 소비는 204M 이었다. 한 번 부를 때마다 그때까지 쌓인 문맥을 통째로
# 다시 읽기 때문이다(FE1-2005: 문맥 79K→250K 로 167회 = 28.7M).
#
# 그래서 리뷰어가 **여러 턴에 걸쳐 스스로 알아내던 것**을 여기서 한 번에 준다.
#   ① 무엇이 바뀌었나(미커밋 기준 diff 통계·파일 목록)
#   ② 저장소 고유 금지 규칙 검사 결과(dobby_repo_lint — 리뷰어가 CLAUDE.md 를 다시 읽을 필요 없음)
#   ③ 사라지거나 바뀐 심볼의 소비처(전수 grep) — 루브릭 A-1 이 심볼마다 시키던 일
#
# 출력은 markdown 이라 프롬프트에 그대로 붙인다.
dobby_review_brief() {
  local wt n
  [ "$#" -gt 0 ] || { _die "쓰임: dobby_review_brief 워크트리..."; return 1; }
  for wt in "$@"; do
    [ -d "$wt" ] || { printf '### %s — 워크트리가 없다\n\n' "$wt"; continue; }
    printf '### %s\n\n' "$(basename "$wt")"

    printf '**바뀐 것(미커밋 포함)**\n\n```\n'
    git -C "$wt" diff HEAD --stat 2>/dev/null | tail -40
    git -C "$wt" status --porcelain 2>/dev/null | grep '^??' | head -20
    printf '```\n\n'

    local gone; gone="$(git -C "$wt" diff HEAD --name-only --diff-filter=D 2>/dev/null)"
    if [ -n "$gone" ]; then
      printf '**지운 파일**\n\n```\n%s\n```\n\n' "$gone"
    fi

    # 변경 본문. 리뷰어가 sed·cat 으로 조각조각 읽던 것을 한 번에 준다.
    # 너무 크면 붙이지 않는다 — 프롬프트가 부풀면 매 왕복이 그만큼 무거워진다.
    local dl; dl="$(git -C "$wt" diff HEAD 2>/dev/null | wc -l | tr -d " ")"
    if [ "${dl:-0}" -gt 0 ] && [ "${dl:-0}" -le "${DOBBY_REVIEW_DIFF_MAX:-1200}" ]; then
      printf '**변경 본문**(%s줄 — 이미 붙였으니 다시 읽지 않아도 된다)\n\n```diff\n' "$dl"
      git -C "$wt" diff HEAD 2>/dev/null
      printf '```\n\n'
    else
      printf '변경 본문 %s줄로 커서 붙이지 않는다 — 워크트리에서 직접 읽어라.\n\n' "${dl:-0}"
    fi

    local lint rc
    lint="$(dobby_repo_lint "$wt" HEAD 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$lint" ]; then
      printf '**저장소 고유 금지 규칙 — 위반 있음**\n\n```\n%s\n```\n\n' "$lint"
    else
      printf '**저장소 고유 금지 규칙 — 위반 없음**(헬퍼가 검사함. 같은 것을 다시 보지 않는다)\n\n'
    fi

    printf '**사라지거나 바뀐 심볼의 소비처**\n\n'
    local syms; syms="$(_review_symbols "$wt")"
    if [ -z "$syms" ]; then
      printf '내보내기·공개 메서드 변경 없음.\n\n'
    else
      printf '| 심볼 | 쓰는 곳 | 위치(최대 3) |\n|---|---|---|\n'
      local sym hits cnt loc
      while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        hits="$(grep -rIn --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist \
                 --exclude-dir=build --exclude-dir=.next --exclude-dir=coverage \
                 -F -- "$sym" "$wt" 2>/dev/null)"
        cnt="$(printf '%s' "$hits" | grep -c . )"
        loc="$(printf '%s\n' "$hits" | cut -d: -f1 | sort -u | head -3 \
               | sed "s#^$wt/##" | awk '{printf "%s%s", (NR>1 ? " · " : ""), $0} END{print ""}')"
        [ "$cnt" -gt 0 ] || loc='소비처 없음'
        printf '| `%s` | %s | %s |\n' "$sym" "$cnt" "$loc"
      done <<EOF
$syms
EOF
      printf '\n'
    fi
  done
}

# _review_symbols 워크트리 — 이번 변경에서 **지워지거나 바뀐** 것 중 소비처를 찾아야 하는 것.
#
# 이름만으로는 모자란다. 실측(FE1-2005 리뷰의 grep 패턴 29개): 식별자 형태는 24% 뿐이고
# 나머지는 **문자열**이었다 — JSP 번들 이름(`reward-simple-pay-app`), 이벤트 이름
# (`simple-pay:requested`), 화면 문구. 이 저장소가 JSP·번들·문자열 키로 엮여 있어서다.
# 그래서 세 가지를 뽑는다: 내보내기·공개 메서드 이름 · 지운 줄의 문자열 리터럴 · 지운 파일 이름.
_review_symbols() {
  local wt="$1" d
  d="$(git -C "$wt" diff HEAD -U0 2>/dev/null | grep '^-' | grep -v '^---')"
  {
    # ① 내보내기·공개 메서드 이름
    printf '%s\n' "$d" | sed -E -n \
        -e 's/.*export[[:space:]]+(const|let|var|function|class|type|interface|enum)[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*).*/\2/p' \
        -e 's/.*export[[:space:]]+default[[:space:]]+function[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*).*/\1/p' \
        -e 's/.*(public|protected|private)[[:space:]]+[A-Za-z0-9_<>,\[\][:space:]]+[[:space:]]([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(.*/\2/p'
    # ② 문자열 리터럴. import 경로(`/`·`@`·`.` 시작)는 뺀다 — 소비처 개념이 아니다.
    printf '%s\n' "$d" | grep -oE "'[^']{4,40}'|\"[^\"]{4,40}\"" \
      | sed -E "s/^['\"]//; s/['\"]$//" \
      | grep -vE '^[@./]|/' | grep -E '^[A-Za-z0-9가-힣]'
    # ③ 지운 파일 이름(확장자 뺀 것) — JSP·설정이 이름으로 부른다
    git -C "$wt" diff HEAD --name-only --diff-filter=D 2>/dev/null \
      | sed -E 's#.*/##; s/\.[A-Za-z0-9]+$//'
  } | awk 'length($0) > 3' | sort -u | head -25
}

# ─────────────────────────────────────────────────────────────────────────────
# dobby_repo_lint — 저장소 고유 금지 규칙을 **이번 변경의 추가된 줄**에서 잡는다.
#
# 왜 "추가된 줄"만 보나: 규칙 대부분이 기존 코드에 이미 많이 깔려 있다(실측 wadiz-frontend:
# static 배럴 import 1,143건 · changeCdnUrl 143건 · export * 65건). 저장소 전체를 검사하면
# 전부 걸려 못 쓴다. 이번 오더가 **새로 넣은 것**만 본다.
#
# 왜 커밋 직전인가: 리뷰어 프롬프트에 "이것도 봐라"라고 적는 것은 지켜지지 않는다.
# dobby_commit_push 가 이걸 불러 위반이 있으면 **거부**하므로 위반 코드가 물리적으로 못 나간다.
# (우회: DOBBY_FORCE=1 — 기존 커밋 메시지 검사와 같은 관례)
#
# 규칙을 늘리려면 아래 case 에 줄을 더한다. 형식: 정규식 | 경로조건 | 제외경로 | 설명
# 경로조건·제외경로가 빈칸이면 적용 안 함(`-`).
# ─────────────────────────────────────────────────────────────────────────────

# 저장소별 규칙표를 stdout 으로 낸다. 한 줄 = 규칙 하나.
_repo_rules() {
  # 한 줄 = 규칙 하나. 필드 구분자는 `|` 다.
  # ⛔ 그래서 **정규식에 `|`(교대)를 쓰지 않는다.** 여러 갈래가 필요하면 규칙을 여러 줄로 쪼갠다.
  #    (처음에 `(a|b)` 를 썼다가 필드가 잘못 잘려 규칙 3개가 조용히 안 걸렸다. 문자 클래스
  #     `[23]?` 처럼 `|` 없이 쓸 수 있으면 그렇게 쓴다.)
  # 형식: 정규식|경로조건|제외1|제외2|제외3|설명       (`-` = 적용 안 함)
  case "$1" in
    */wadiz-frontend)
      cat <<'RULES'
buildOptimizedImageURL|-|packages/core/src/image-optimization/|packages/ui/src/image-optimization/|packages/core/src/utils/url.js|@wadiz/core 의 buildOptimizedImageURL 을 직접 부르지 않습니다(설정 image-webp 를 안 읽어 스위치가 안 걸립니다). @wadiz/ui/image-optimization 의 getOptimizedImageURL 을 쓰세요.
changeCdn[23]?Url|-|packages/utils/src/url|-|-|changeCdnUrl 계열은 옛 함수입니다. 새 호출부에는 getOptimizedImageURL 을 쓰세요.
from '@wadiz/[a-z-]+'|^static/|-|-|-|static 은 webpack 4 라 트리쉐이킹이 제한적입니다. 배럴 대신 서브경로로 import 하세요(@wadiz/waffle/Button).
^export \*|^apps/global/src/.*/index\.ts$|-|-|-|FSD 세그먼트 index.ts 는 export * 를 쓰지 않습니다. 명시적 named export 만 씁니다.
^export \*|^apps/account/src/.*/index\.ts$|-|-|-|FSD 세그먼트 index.ts 는 export * 를 쓰지 않습니다. 명시적 named export 만 씁니다.
.|^packages/artworks/src/index\.ts$|-|-|-|자동으로 생성하는 파일입니다. 임의로 수정하지 않습니다.
.|^packages/waffle-icons/src/index\.ts$|-|-|-|자동으로 생성하는 파일입니다. 임의로 수정하지 않습니다.
RULES
      ;;
  esac
}

# dobby_repo_lint WORKTREE [diff대상] — 위반을 출력하고, 있으면 1을 반환한다.
# diff대상 기본값은 `--cached`(커밋 직전 스테이지). 검사만 해 보려면 `HEAD~1` 등을 넘긴다.
dobby_repo_lint() {
  local wt="$1" target="${2:---cached}" repo rules rf df n=0 out
  [ -d "$wt" ] || { _die "워크트리가 없다: $wt"; return 1; }
  repo="$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
  rules="$(_repo_rules "$repo")"
  [ -n "$rules" ] || return 0   # 규칙이 없는 저장소는 통과

  # ⛔ 규칙을 `awk -v` 로 넘기지 않는다 — 맥 awk 는 줄바꿈이 든 값을 거부한다
  # ("awk: newline in string"). 조용히 실패해서 아무것도 안 잡았다. 파일로 넘긴다.
  rf="$(mktemp -t dobbyrules)" || return 0
  df="$(mktemp -t dobbydiff)" || { rm -f "$rf"; return 0; }
  printf '%s\n' "$rules" > "$rf"
  git -C "$wt" diff "$target" -U0 > "$df" 2>/dev/null

  if [ ! -s "$df" ]; then rm -f "$rf" "$df"; return 0; fi

  out="$(awk '
    # 첫 파일 = 규칙표
    NR == FNR {
      if ($0 == "") next
      nr++
      split($0, F, "|")
      pat[nr]=F[1]; scope[nr]=F[2]; ex1[nr]=F[3]; ex2[nr]=F[4]; ex3[nr]=F[5]; msg[nr]=F[6]
      next
    }
    # 둘째 파일 = diff
    /^\+\+\+ b\// { file = substr($0, 7); next }
    /^@@/ { split($0, H, "+"); split(H[2], L, ","); ln = L[1] + 0; next }
    /^\+/ {
      line = substr($0, 2)
      for (i = 1; i <= nr; i++) {
        if (pat[i] == "") continue
        if (scope[i] != "-" && file !~ scope[i]) continue
        if (ex1[i] != "-" && index(file, ex1[i]) > 0) continue
        if (ex2[i] != "-" && index(file, ex2[i]) > 0) continue
        if (ex3[i] != "-" && index(file, ex3[i]) > 0) continue
        if (line ~ pat[i]) printf "  %s:%d\n    %s\n    → %s\n", file, ln, substr(line,1,110), msg[i]
      }
      ln++
    }
  ' "$rf" "$df")"
  rm -f "$rf" "$df"

  [ -n "$out" ] || return 0
  n="$(printf '%s\n' "$out" | grep -c '→ ')"
  printf '저장소 규칙 위반 %s건 (%s)\n%s\n' "$n" "$repo" "$out" >&2
  return 1
}

# dobby_review_lint KEY [라운드] — 리뷰 파일이 집계 가능한 모양인지 본다. 어긋나면 1을 반환한다.
#
# 라운드를 주면 그 라운드만, 안 주면 전부 본다. **판정 게이트가 아니라 훑어보는 도구다** —
# 라운드를 못 닫게 막는 일은 dobby_blocking 이 한다(그 라운드만 보므로 옛 오더를 벌하지 않는다).
#
# 잡는 것
#   · round-N 폴더 밖에 있는 리뷰 파일 — dobby_blocking 이 아예 보지 않는다
#   · `## [blocker|major|minor|nit] {제목}` 카드가 없는 파일 — 0건으로 집계된다
dobby_review_lint() {
  local key="$1" rd="${2:-}" root f bad=0 rel
  root="$(_order_dir "$key")/reviews"
  [ -d "$root" ] || return 0

  if [ -z "$rd" ]; then
    for f in "$root"/*.md; do
      [ -f "$f" ] || continue
      printf '  %s — round-N 폴더 밖이라 집계되지 않습니다. dobby_review_path %s {n} {슬러그} 가 준 경로에 두세요.\n' \
        "reviews/$(basename "$f")" "$key" >&2
      bad=$((bad + 1))
    done
  fi

  for f in "$root"/round-${rd:-*}/*.md; do
    [ -f "$f" ] || continue
    grep -qE '^## \[(blocker|major|minor|nit)\]' "$f" && continue
    rel="reviews/$(basename "$(dirname "$f")")/$(basename "$f")"
    printf '  %s — `## [blocker|major|minor|nit] {제목}` 카드가 없습니다(%s줄). 머리글만 카드로 바꾸면 됩니다.\n' \
      "$rel" "$(wc -l < "$f" | tr -d ' ')" >&2
    bad=$((bad + 1))
  done

  [ "$bad" -eq 0 ] && return 0
  printf '집계되지 않는 리뷰 파일 %s개 (%s)\n' "$bad" "$key" >&2
  return 1
}


# dobby_ship_build KEY 환경 번들... — 번들마다 CI/CD 워크플로를 건다. run id 들을 stdout.
#
# ⛔ **wadiz-frontend 전용이다.** com.wadiz.web 은 머지 push 가 CI 를 자동으로 돌리므로
#    (app-web-ci.yml 의 push 트리거) 여기서 또 걸면 **같은 빌드가 두 번 돈다.** 그쪽은
#    dobby_ship_web_ci 로 **잡기만** 한다.
#
# 번들→워크플로 대응과 **빠지면 안 되는 옵션**을 여기서 붙인다. 스킬이 생 명령을 치면
# 옵션을 빠뜨린다(실측: static 빌드에 build_entry_all 이 빠져 반쪽만 빌드됐다).
#
# ⛔ static 은 build_entry_all=true 가 필수다. build-static.sh 가 이 값으로 갈린다 —
#    없으면 `yarn build --since {직전 태그}` 로 바뀐 엔트리만 만든다. 공용 패키지를 고쳤을 때
#    그것을 쓰는 엔트리가 안 잡히면 옛 번들이 남고, 그 상태로 테스트하면 수정 전 동작이
#    관측돼 코드 결함으로 오진한다(사례 FE1-1808). 저장소의 정기배포 워크플로도 이 값을 쓴다.
dobby_ship_build() {
  local key="$1" env="$2"; shift 2
  local b wf rid out cell
  _ship_has "$env" "$DOBBY_SHIP_ENVS" || { _die "배포 환경이 아니다: '$env'"; return 1; }
  [ "$#" -gt 0 ] || { _die "빌드할 번들이 없다"; return 1; }

  # 인자를 따로 주든("static" "global") 한 덩어리로 주든("static global") 똑같이 받는다.
  # 셸마다 단어 분리가 달라 호출부가 어느 쪽으로 넘길지 정할 수 없다(_words 주석 참조).
  local raw="$*"

  # admin 은 static 빌드에 옵션으로 얹힌다 — 따로 걸지 않는다.
  local want_admin=0 list=""
  while IFS= read -r b; do
    case "$b" in
      admin) want_admin=1; _ship_has "static" "$list" || list="$list static" ;;
      *) _ship_has "$b" "$list" || list="$list $b" ;;
    esac
  done <<EOF
$(_words "$raw")
EOF

  while IFS= read -r b; do
    local -a args=()
    case "$b" in
      static)  wf="app-static-ci-cd.yml";         args=(-f build_entry_all=true)
               [ "$want_admin" = 1 ] && args+=(-f build_admin=true) ;;
      global)  wf="app-global-ci-cd.yml" ;;
      account) wf="app-global-account-ci-cd.yml" ;;
      studio)  wf="app-studio-ci-cd.yml" ;;
      *) _die "빌드 워크플로를 모르는 번들이다: '$b' (아는 것: static global account studio)"; return 1 ;;
    esac
    # ⛔ --repo 를 명시한다. 멀티레포 오더는 세션 디렉터리가 com.wadiz.web 워크트리일 수 있어,
    #    gh 가 현재 폴더로 저장소를 짐작하면 **없는 워크플로**라며 실패하거나 엉뚱한 곳에 건다.
    gh workflow run "$wf" --repo "$(_ship_owner wadiz-frontend)" \
      -f environment="$env" -f runner=self-hosted "${args[@]}" >&2 || {
      _die "$wf 를 걸지 못했다"; return 1; }
    sleep 3
    rid="$(gh run list --repo "$(_ship_owner wadiz-frontend)" --workflow="$wf" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)"
    printf '%s %s\n' "$b" "$rid"
    out="$out $b#$rid"
    cell="${cell:+$cell · }$b#$rid"
  done <<EOF
$(_words "$list")
EOF
  dobby_event "$key" "빌드 시작 —${out} @ $env"
  dobby_ship_stage "$key" wadiz-frontend "$env" "배포 대기" "" "$cell"
}

# ─────────────────────────────────────────────────────────────────────────────
# com.wadiz.web — 빌드는 자동, 배포는 수동(argocd)
#
# wadiz-frontend 는 빌드가 곧 배포지만 여기는 둘이 갈린다.
#   머지 push → [app] web - CI 자동 실행 → ECR 이미지 + gitops 의 이미지 태그 갱신
#                                        → **여기서 멈춘다.** argocd 가 Manual 이라
#                                          sync 하지 않으면 파드는 옛 이미지 그대로다.
# 실측 2026-10-07: web-rc1-web-server 가 OutOfSync 였다(머지·CI 는 됐는데 sync 안 함).
# ─────────────────────────────────────────────────────────────────────────────

# dobby_ship_web_ci KEY 환경 [머지시각] — 머지로 **자동 시작된** CI run 을 찾아 표에 적는다.
#
# ⛔ 빌드를 걸지 않는다. push 트리거와 겹쳐 두 번 돌기 때문이다.
# 머지 시각(epoch)을 주면 그보다 **나중에 시작된** run 만 받는다 — 남이 같은 브랜치에 push 해
# 돌던 옛 run 을 내 것으로 세지 않기 위해서다. 최대 3분 기다리고, 안 나타나면 거부한다.
#   → stdout: run id
dobby_ship_web_ci() {
  local key="$1" env="$2" since="${3:-}" br rid created waited=0
  _ship_has "$env" "$DOBBY_SHIP_ENVS" || { _die "배포 환경이 아니다: '$env'"; return 1; }
  br="$(_ship_branch com.wadiz.web "$env")"
  [ -n "$br" ] || { _die "com.wadiz.web 에는 '$env' 환경이 없다"; return 1; }

  while :; do
    rid="$(gh run list --repo "$(_ship_owner com.wadiz.web)" --workflow=app-web-ci.yml \
      --branch "$br" --event push --limit 1 --json databaseId,createdAt \
      -q '.[0] | "\(.databaseId) \(.createdAt)"' 2>/dev/null)"
    created="${rid#* }"; rid="${rid%% *}"
    if [ -n "$rid" ] && [ "$rid" != "null" ]; then
      if [ -z "$since" ]; then break; fi
      # createdAt(ISO8601 UTC) 를 epoch 로. BSD date(맥)와 GNU date 를 모두 받는다.
      local c
      c="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$created" '+%s' 2>/dev/null \
        || date -u -d "$created" '+%s' 2>/dev/null)"
      [ -n "$c" ] && [ "$c" -ge "$since" ] && break
    fi
    waited=$((waited + 15))
    [ "$waited" -le 180 ] || {
      _die "머지 뒤 3분이 지나도 com.wadiz.web 의 CI(app-web-ci.yml @ $br)가 시작되지 않았다. push 트리거가 걸리지 않은 것이다 — 머지가 실제로 됐는지, 워크플로가 비활성인지 확인하라."
      return 1
    }
    sleep 15
  done

  dobby_event "$key" "com.wadiz.web CI 시작 — web#$rid @ $br"
  dobby_ship_stage "$key" com.wadiz.web "$env" "빌드 대기" "" "web#$rid"
  printf '%s' "$rid"
}

# dobby_ship_argo KEY 환경 [check] — com.wadiz.web 을 argocd 로 동기화하고 health 까지 기다린다.
#
# `check` 를 붙이면 **보기만 한다**(sync 하지 않음). 테스트가 실패했을 때 "반쪽 배포인가"를
# 가르는 진단용이다 — wadiz-frontend 의 dobby_ship_verify 와 같은 자리.
#
# 막는 것:
#   · 환경이 stage 면 거부 — 스테이지 반영 시점은 사람이 고른다(머지도 사람이 한다)
#   · **G-B** 같은 환경의 wadiz-frontend 가 `배포 확인` 전이면 거부
#       (사용자 요구: 배포는 wadiz-frontend 의 빌드·배포가 끝나면 같이 진행한다)
#   · com.wadiz.web CI run 이 success 가 아니면 거부 — 이미지가 없으면 sync 해도 옛 이미지가 뜬다
#   · argocd 세션이 없으면 거부 — 재로그인은 브라우저 SSO 라 **사람만** 할 수 있다
#   · app list 에 그 앱이 없으면 거부 — 이름을 짐작해 엉뚱한 환경을 건드리지 않는다
#   · 앱 이름에 `-live-` 가 있으면 거부 — 훅 G1 과 이중으로
dobby_ship_argo() {
  local key="$1" env="$2" mode="${3:-}" srv app fe rid st
  _ship_has "$env" "$DOBBY_SHIP_ENVS" || { _die "배포 환경이 아니다: '$env'"; return 1; }
  [ "$env" != stage ] || {
    _die "stage 의 com.wadiz.web 배포는 사용자가 직접 한다(머지도 사용자 몫이다). PR 주소를 알리고 멈춰라."
    return 1
  }
  srv="$(_ship_argo_server "$env")"; app="$(_ship_argo_app "$env")"
  [ -n "$srv" ] && [ -n "$app" ] || { _die "'$env' 의 argocd 대상을 모른다"; return 1; }
  case "$app" in *-live-*) _die "라이브 앱($app)은 이 스킬이 건드리지 않는다 — 별도 릴리스 절차다."; return 1 ;; esac

  # ⛔ 세션. 브라우저 SSO 라 자동 실행이 절대 통과할 수 없다 — 깨끗이 멈추고 사람을 부른다.
  argocd account get-user-info --server "$srv" --grpc-web 2>/dev/null | grep -q 'Logged In: *true' || {
    _die "argocd 세션이 없다($srv). 사용자에게 아래를 실행해 달라고 알리고 멈춰라(브라우저 인증이라 대신 할 수 없다):
  argocd login $srv --sso --grpc-web"
    return 1
  }
  argocd app list --server "$srv" --grpc-web -o name 2>/dev/null | grep -qx "$app" || {
    _die "argocd 에 '$app' 앱이 없다($srv). 이름을 짐작해 다른 환경을 sync 하지 않는다 — app list 로 확인하고 _ship_argo_app 을 고쳐라."
    return 1
  }

  if [ "$mode" = check ]; then
    argocd app list --server "$srv" --grpc-web 2>/dev/null | grep -E "NAME|$app"
    return 0
  fi

  # ── G-B. wadiz-frontend 배포가 끝난 뒤에 ────────────────────────────────
  fe="$(_ship_row_rank "$key" wadiz-frontend "$env")"
  if [ -n "$fe" ] && [ "$fe" -lt "$DOBBY_SHIP_RANK_DEPLOYED" ]; then
    _die "wadiz-frontend 배포가 아직 확인되지 않았다(현재 '$(_ship_row_stage "$key" wadiz-frontend "$env")'). 두 저장소는 같이 반영돼야 하므로 FE 배포 확인 뒤에 sync 한다."
    return 1
  fi

  # ── CI 가 끝났나. 이미지가 없으면 sync 해도 옛 이미지가 뜬다 ──────────────
  rid="$(_ship_cell_run "$key" com.wadiz.web "$env" web)"
  if [ -n "$rid" ]; then
    st="$(gh run view "$rid" --repo "$(_ship_owner com.wadiz.web)" --json status,conclusion \
      -q '"\(.status) \(.conclusion)"' 2>/dev/null)"
    case "$st" in
      "completed success") : ;;
      "completed "*) _die "com.wadiz.web CI(web#$rid)가 ${st#completed } 로 끝났다. 이미지가 없으므로 sync 하지 않는다 — 빌드 로그를 보고 원인을 알려라."; return 1 ;;
      *) _die "com.wadiz.web CI(web#$rid)가 아직 돌고 있다($st). 끝난 뒤에 sync 한다 — gh run watch $rid --repo $(_ship_owner com.wadiz.web) --exit-status"; return 1 ;;
    esac
  fi

  argocd app sync "$app" --server "$srv" --grpc-web >&2 || { _die "sync 에 실패했다($app @ $srv)"; return 1; }
  argocd app wait "$app" --health --timeout 300 --server "$srv" --grpc-web >&2 \
    || { _die "sync 는 됐는데 health 가 300초 안에 Healthy 가 되지 않았다($app). argocd app list --server $srv --grpc-web | grep $app 로 상태를 보고 알려라."; return 1; }

  dobby_event "$key" "com.wadiz.web 배포 — $app @ $srv (sync·Healthy)"
  dobby_ship_stage "$key" com.wadiz.web "$env" "배포 확인"
  printf 'sync 완료: %s @ %s\n' "$app" "$srv"
  printf '⚠ 파드 교체 전에는 옛 응답이 나온다(JSP·urlrewrite.xml 이 이미지 안에 있다).\n' >&2
  printf '  바뀐 지면을 GET 으로 폴링해 반영을 확인한 뒤 검증을 연다(POST·결제·콜백 금지).\n' >&2
}

# _ship_cell_run KEY 저장소 환경 번들 — 빌드 칸에서 `{번들}#{run id}` 의 run id 를 뽑는다.
_ship_cell_run() {
  local f
  f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 0
  awk -v rp="$2" -v env="$3" -v b="$4" '
    function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
    /^## / { insec = ($0 ~ /^##[ \t]*배포[ \t]*$/); next }
    insec && /^[ \t]*\|/ {
      nc = split($0, c, "|")
      if (nc == 8)      { r = "wadiz-frontend"; e = trim(c[2]); cell = trim(c[5]) }
      else if (nc >= 9) { r = trim(c[2]);       e = trim(c[3]); cell = trim(c[6]) }
      else next
      if (r != rp || e != env) next
      n = split(cell, parts, "·")
      for (i = 1; i <= n; i++) {
        p = trim(parts[i])
        if (index(p, b "#") == 1) { print substr(p, length(b) + 2); exit }
      }
      exit
    }
  ' "$f"
}

# ─────────────────────────────────────────────────────────────────────────────
# 광고·데이터 수집 접촉 탐지 — dobby_track_scan
#
# 왜 기계가 판정하나: 광고와 수집은 **화면에 안 보이게 깨진다.** 배너가 사라지면 눈에
# 띄지만, ad.section.view 가 안 나가거나 trackingCustomTag 의 label 이 바뀌는 것은 화면이
# 멀쩡하다. dobby-test 2단계는 "사용자에게 보이는 페이지/기능으로 매핑"해 시나리오를 뽑으므로
# 안 보이는 것은 구조적으로 안 잡힌다.
#
# 실측(오케스트레이션 메타 전수): 분석·구현 문서에 추적·광고 코드가 등장한 오더 29건 중
# 검증 회차에서 실제로 확인한 것은 **4건**이다(FE1-1312·1912·1953·2075). 25건(86%)이
# 확인 없이 나갔다. 사람 판단에 맡기면 빠지므로 탐지를 기계로 내린다.
#
# 이 함수는 **보고이지 게이트가 아니다** — 언제나 0을 반환한다. 막는 일은
# dobby_testrun_lint 가 한다(탐지됐는데 전용 시나리오가 없으면 회차 마감 거부).
# ─────────────────────────────────────────────────────────────────────────────

# 변경된 줄에 하나라도 있으면 "닿았다" 로 보는 심볼.
# ⛔ 지워진 줄(-)에도 적용한다 — 추적 호출을 **지운 것**이 가장 조용한 사고다.
#    화면은 완벽히 멀쩡하고 데이터만 사라진다.
DOBBY_TRACK_SYMBOLS='trackingEvent|trackingCustomTag|trackingBraze|@wadiz/metrics|@wadiz/event-tracker|useTrackingEventRef|EventTracker|dataLayer|gaEvt|appboy'
DOBBY_AD_SYMBOLS='AdBoundary|_refer_section_st|adTracking|parseAdSection'

# 그 파일 자체가 광고·수집 코드인 경로(정규식). 저장소 두 곳을 함께 본다.
DOBBY_TRACK_PATHS='^packages/core/src/metrics/|^packages/event-tracker/|^static/packages/shared/utils/tracking\.js|^static/packages/react-common/src/utils/gaData\.js|^web/WEB-INF/jsp/winclude/tracking'
DOBBY_AD_PATHS='^static/libraries/react-ad-boundary/|^static/packages/banner/|^static/packages/react-banner-components/|^web/WEB-INF/jsp/linkprice/'

# dobby_track_scan KEY [베이스] — 오더의 변경이 광고·수집에 닿는지 판정해 보고한다.
#
# 오더의 '## 워크트리 / 브랜치' 표에 적힌 워크트리를 모두 훑는다. 베이스를 주지 않으면
# 워크트리마다 origin/{그 저장소의 기본 비교 대상}… 을 모르므로, 베이스는 호출부가 준다
# (dobby-ship 은 그 환경의 브랜치, dobby-test 는 배포된 환경의 브랜치).
#
# 결과를 $ORCHESTRATION_META/{키}/track-scan.md 에 남기고 요약을 stdout 으로 낸다.
# dobby_testrun_lint 가 이 파일을 읽어 전용 시나리오 유무를 따진다.
dobby_track_scan() {
  # ⛔ local 을 반복문 안에서 다시 선언하지 않는다 — zsh 는 이미 있는 이름을 다시 local 하면
  #    `d=''` 처럼 **값을 출력한다**(실측: 그 줄이 보고 출력에 섞여 나왔다).
  local key="$1" base="${2:-}" f out wt br rp rel cmp d pr owner envbr body n unseen=""
  [ -n "$key" ] || { _die "쓰임: dobby_track_scan KEY [베이스브랜치]"; return 1; }
  f="$(_order_dir "$key")/track-scan.md"
  [ -d "$(_order_dir "$key")" ] || { _die "오더 폴더가 없다: $key"; return 1; }

  out="$(mktemp -t dobbytrack)" || return 1
  : > "$out"

  # '## 워크트리 / 브랜치' 표: | repo | 브랜치 | 경로 |
  while IFS='|' read -r rp br wt; do
    rp="$(printf '%s' "$rp" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    br="$(printf '%s' "$br" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    wt="$(printf '%s' "$wt" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/`//g')"
    wt="${wt/#\~/$HOME}"
    [ -n "$wt" ] && [ -d "$wt" ] || { unseen="$unseen $rp(워크트리 없음)"; continue; }

    # ── 변경을 어디서 얻나 — 세 단계로 내려간다 ────────────────────────────
    # ⛔ **머지된 뒤에는 3점 diff 가 비어 버린다.** `origin/rc4...HEAD` 는 공통 조상부터
    #    HEAD 까지인데, 브랜치가 rc4 에 머지됐으면 공통 조상이 HEAD 자신이라 공집합이다.
    #    dobby-test 는 **머지·배포 뒤에** 도는 것이 정상이므로 이게 기본 상황이다.
    #    실측 FE1-2075: 워크트리는 살아 있는데 diff 가 0줄이라 "접촉 없음" 으로 나왔다 —
    #    그 오더는 실제로 수집을 확인했던 4건 중 하나다. 조용한 거짓 음성이다.
    d=""
    cmp=""
    if [ -n "$base" ]; then
      cmp="origin/$(_ship_branch "$rp" "$base")"
      git -C "$wt" rev-parse --verify -q "$cmp" >/dev/null 2>&1 || cmp=""
    fi
    [ -n "$cmp" ] || { git -C "$wt" rev-parse --verify -q "origin/$ORCHESTRATION_DEFAULT_BASE" >/dev/null 2>&1 \
      && cmp="origin/$ORCHESTRATION_DEFAULT_BASE"; }

    # ① 아직 머지 전이면 3점 diff 가 이 브랜치의 변경을 그대로 준다. 미커밋도 함께 본다.
    [ -n "$cmp" ] && d="$( { git -C "$wt" diff -U0 "$cmp"...HEAD; git -C "$wt" diff -U0; git -C "$wt" diff -U0 --cached; } 2>/dev/null )"

    # ② 비었으면 PR 의 diff 를 받는다 — 머지된 뒤에도 남아 있는 유일한 정본이다.
    #
    # ⛔ **베이스로 걸러야 한다.** 한 브랜치가 여러 PR 의 head 일 수 있고, 그중에는 릴리스
    #    브랜치로 간 것도 있다. 베이스가 먼 브랜치면 diff 에 남의 변경이 몇 달치 섞여 들어와
    #    온 저장소가 "광고·수집 접촉" 으로 보고된다(실측 FE1-2075: `--head` 만으로 찾으면
    #    hotfix/v20261002 로 간 #29642 가 잡혀 event-tracker 전체가 걸렸다. 이 오더의
    #    rc4 PR 은 충돌 해결 브랜치로 올라간 #29639 이다).
    # 그래서 **충돌 해결 브랜치 + 그 환경 베이스**를 먼저 찾는다(dobby-ship 의 정상 경로다).
    if [ -z "$d" ] && [ -n "$br" ]; then
      owner="$(_ship_owner "$rp")"
      envbr="$(_ship_branch "$rp" "$base")"
      pr=""
      if [ -n "$envbr" ]; then
        pr="$(gh pr list --repo "$owner" --head "${br}_into_${envbr}" --base "$envbr" --state all \
          --json number -q '.[0].number' 2>/dev/null)"
        [ -n "$pr" ] || pr="$(gh pr list --repo "$owner" --head "$br" --base "$envbr" --state all \
          --json number -q '.[0].number' 2>/dev/null)"
      fi
      # 베이스를 모를 때만 아무 PR 이나 받는다 — 그때는 섞여 들어올 수 있음을 감수한다.
      [ -n "$pr" ] || pr="$(gh pr list --repo "$owner" --head "$br" --state all \
        --json number -q '.[0].number' 2>/dev/null)"
      [ -n "$pr" ] && d="$(gh pr diff "$pr" --repo "$owner" 2>/dev/null)"
    fi

    # ③ 그래도 비었으면 dobby-end 가 남긴 코드 변경 스냅샷을 본다.
    if [ -z "$d" ]; then
      d="$(cat "$(_order_dir "$key")"/code-changes/*"$(basename "$wt")"*.diff 2>/dev/null)"
      [ -n "$d" ] || d="$(cat "$(_order_dir "$key")"/code-changes/*.diff 2>/dev/null)"
    fi

    # ⛔ 못 봤으면 "접촉 없음" 이 아니라 **확인 불가**다. 못 본 것을 없는 것으로 적지 않는다.
    [ -n "$d" ] || { unseen="$unseen $rp"; continue; }

    # ── A. 경로로 바로 걸리는 것 ────────────────────────────────────────
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      printf '%s' "$rel" | grep -qE "$DOBBY_TRACK_PATHS" && printf '| [수집] | %s | %s | 수집 코드 자체 |\n' "$rp" "$rel" >> "$out"
      printf '%s' "$rel" | grep -qE "$DOBBY_AD_PATHS"    && printf '| [광고] | %s | %s | 광고 코드 자체 |\n' "$rp" "$rel" >> "$out"
    done <<EOF
$(printf '%s' "$d" | sed -nE 's#^\+\+\+ b/(.+)$#\1#p' | sort -u)
EOF

    # ── B. 바뀐 줄의 심볼로 걸리는 것(연관) ─────────────────────────────
    #    awk 로 파일을 따라가며 +/- 줄만 본다. 같은 파일·같은 갈래는 한 번만 적는다.
    # LC_ALL=C — diff 안에 깨진 바이트가 있으면 awk 가 towc 변환 실패 경고를 쏟는다.
    # 바이트로만 다루면 그 일이 없고, shorten() 이 잘린 조각을 떼므로 출력은 멀쩡하다.
    printf '%s' "$d" | LC_ALL=C awk -v rp="$rp" -v ts="$DOBBY_TRACK_SYMBOLS" -v as="$DOBBY_AD_SYMBOLS" \
      -v strong='trackingEvent|trackingCustomTag|trackingBraze|@wadiz/event-tracker|useTrackingEventRef|EventTracker|dataLayer|gaEvt|appboy' '
      /^\+\+\+ b\// { file = substr($0, 7); delete donet[file]; delete donea[file]; next }
      /^[+-][^+-]/ {
        line = substr($0, 2); sign = substr($0, 1, 1)
        if (file == "") next
        # ⛔ 거짓 양성을 걸러낸다. 게이트는 믿을 수 있어야 쓰인다 —
        #    못 믿을 신호가 섞이면 사람이 통째로 무시하게 된다.
        #  · `import type { CustomTag } from '@wadiz/metrics'` — 타입은 런타임이 없다
        #  · captureError·getLastEventId·errorReportDialog — Sentry 오류 보고지 광고·수집이 아니다
        if (line ~ /import[ \t]+type[ \t]/) next
        if (line ~ /captureError|getLastEventId|errorReportDialog/ && line !~ strong) next
        if (line ~ ts && !(file in donet)) { donet[file] = 1
          printf "| [수집] | %s | %s | %s %s |\n", rp, file, (sign == "-" ? "⛔ 지워짐 —" : "호출"), shorten(line) }
        if (line ~ as && !(file in donea)) { donea[file] = 1
          printf "| [광고] | %s | %s | %s %s |\n", rp, file, (sign == "-" ? "⛔ 지워짐 —" : "호출"), shorten(line) }
      }
      # ⛔ 맥 awk 는 substr 이 **바이트** 단위라 한글을 반 토막 낸다. 깨진 바이트가 섞이면
      #    아래 표시용 awk 가 towc 변환 실패로 죽는다(실측 FE1-2075). 잘린 조각을 떼어 낸다.
      function shorten(s,  t) { gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/\|/, "/", s)
        if (length(s) <= 80) return s
        t = substr(s, 1, 77); sub(/[\300-\377][\200-\277]*$/, "", t); return t "…" }
    ' >> "$out"
  done <<EOF
$(awk '/^## /{ins=(index($0,"워크트리")>0)?1:0; next}
       ins==1 && /^[ \t]*\|/{ n=split($0,a,"|")
         if (n>=5) { r=a[2]; b=a[3]; p=a[4]
           if (r !~ /repo|^[ \t:-]*$/ && p !~ /^[ \t:-]*$/) printf "%s|%s|%s\n", r, b, p } }' \
     "$(_order_dir "$key")/status.md" 2>/dev/null)
EOF

  # 같은 (갈래, 저장소, 파일) 은 한 줄만 남긴다 — A(경로)와 B(심볼)가 같은 파일을 둘 다 잡는다.
  # 남길 때는 **더 알려 주는 쪽**을 고른다: `지워짐` > 심볼 호출 > "코드 자체".
  # ⛔ 파이프 전체를 LC_ALL=C 로 묶는다. 로케일이 UTF-8 이면 sort·cut 이 한글이 섞인 줄에서
  #    `Illegal byte sequence` 로 죽고, 그러면 body 가 통째로 비어 **"탐지 없음" 으로 뒤집힌다**
  #    (실측 FE1-2075: sort 가 죽어 접촉 있는 오더가 없음으로 보고됐다). 거짓 음성이 가장 나쁘다.
  body="$( export LC_ALL=C
    awk -F'|' '{ r = ($0 ~ /지워짐/) ? 0 : (($0 ~ /코드 자체/) ? 2 : 1); print r "\t" $0 }' "$out" 2>/dev/null \
    | sort -t'	' -k1,1n | cut -f2- \
    | awk -F'|' '{ k = $2 "|" $3 "|" $4 } !seen[k]++' \
    | sort -t'|' -k2,2 -k3,3 -k4,4 )"
  rm -f "$out"

  {
    printf '# %s — 광고·데이터 수집 접촉\n\n' "$key"
    printf -- '- **갱신**: %s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf -- '- **비교 대상**: %s\n' "${base:-기본 베이스}"
    [ -n "$unseen" ] && printf -- '- **변경을 보지 못한 저장소**:%s\n' "$unseen"
    printf '\n'
    if [ -n "$unseen" ]; then
      printf '## ⚠ 확인 불가 —%s\n\n' "$unseen"
      printf '이 저장소의 변경을 **읽지 못했다.** 워크트리가 지워졌거나, 머지된 뒤라 3점 diff 가\n'
      printf '비었는데 PR·코드 스냅샷도 찾지 못한 경우다. **"접촉 없음"이 아니다** — 못 본 것을\n'
      printf '없는 것으로 읽지 마라. 아래 중 하나로 직접 확인한다.\n\n'
      printf '```\ngh pr diff {PR번호} --repo {owner/repo} | grep -nE "%s|%s"\n```\n\n' \
        "$DOBBY_TRACK_SYMBOLS" "$DOBBY_AD_SYMBOLS"
    fi
    if [ -z "$body" ]; then
      printf '**탐지된 접촉 없음.** 전용 시나리오를 요구하지 않는다.\n\n'
      printf '> 다만 **상시 그물**(dataLayer 가 비었나 · 추적 콘솔 에러 · 배너 요청 4xx/5xx)은\n'
      printf '> 모든 회차에서 본다. 이 판정은 diff 로 보이는 것만 가린다 — 레이아웃 변경으로\n'
      printf '> 배너가 사라지는 것처럼 diff 에 안 드러나는 것은 그물이 받는다.\n'
    else
      printf '**접촉 있음.** 아래 갈래마다 `[수집]`·`[광고]` 시나리오를 result.md 에 넣어야 한다.\n'
      printf '넣지 않으면 `dobby_testrun_lint` 가 회차 마감을 거부한다.\n\n'
      printf '| 갈래 | 저장소 | 파일 | 근거 |\n|---|---|---|---|\n'
      printf '%s\n' "$body"
      printf '\n⛔ `지워짐` 으로 표시된 줄은 **추적 호출이 사라진 것**이다. 의도한 것인지 반드시 확인한다 —\n'
      printf '화면은 멀쩡하고 데이터만 빠지므로 테스트로도 잡히지 않는다.\n'
    fi
  } > "$f"

  if [ -z "$body" ] && [ -n "$unseen" ]; then
    # 하나도 못 봤는데 "탐지 없음" 이라고 하면 **없다는 말로 읽힌다.** 거짓 음성이 가장 나쁘다.
    printf '%s — 광고·수집 접촉: ⚠ 확인 불가 (변경을 읽지 못했다)\n' "$key"
  elif [ -z "$body" ]; then
    printf '%s — 광고·수집 접촉: 탐지 없음\n' "$key"
  else
    n="$(printf '%s\n' "$body" | LC_ALL=C grep -c . )"
    printf '%s — 광고·수집 접촉: 있음 (%s건)\n' "$key" "$n"
    # 화면에는 12줄까지만. 전부는 track-scan.md 에 있다 — 쏟아지면 아무도 안 읽는다.
    printf '%s\n' "$body" | head -12 | awk -F'|' '{ g=$2; p=$4; e=$5
      gsub(/^[ \t]+|[ \t]+$/, "", g); gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/^[ \t]+|[ \t]+$/, "", e)
      printf "  %-6s %s\n         %s\n", g, p, e }'
    [ "$n" -gt 12 ] && printf '  … 외 %s건 (전부는 track-scan.md)\n' "$(( n - 12 ))"
  fi
  [ -n "$unseen" ] && printf '  ⚠ 확인 불가 —%s (못 본 것이지 없는 것이 아니다. 직접 확인하라)\n' "$unseen"
  printf '→ %s\n' "$f"
  return 0
}

# _track_scan_kinds KEY — track-scan.md 가 보고한 갈래들(`[수집]`·`[광고]`). 없으면 빈 값.
_track_scan_kinds() {
  local f
  f="$(_order_dir "$1")/track-scan.md"
  [ -f "$f" ] || return 0
  grep -oE '\[(수집|광고)\]' "$f" 2>/dev/null | sort -u | tr '\n' ' '
}

# dobby_testrun_lint 결과폴더 — 근거 칸에 **파일 이름만** 적힌 행을 잡는다.
#
# 왜: 그림은 지금까지 한 번도 화면에 뜬 적이 없다(실측 회차 76개: result.md 가 이미지로
# 띄운 것 0개 · 이름만 적힌 것 88개, summary.html 의 <img> 0개). 이름만 적힌 근거는
# 읽는 사람에게 아무것도 알려 주지 않으면서 자리만 차지하고, 파일이 지워지면 빈 칸이 된다.
#
# 규칙은 둘 중 하나다.
#   · 근거 칸에는 **관측한 사실**을 적는다 — 응답 본문·이동 경로·번들 시각·화면 문구.
#   · 화면을 꼭 보여야 하면(레이아웃 깨짐 등) 본문에 `![설명](파일.png)` 으로 **띄운다.**
#     띄우면 파일 이름은 그림이 있는 자리에 적히므로 근거 칸에 또 적을 필요가 없다.
dobby_testrun_lint() {
  local dir="$1" f bad
  [ -d "$dir" ] || { _die "폴더가 없다: $dir"; return 1; }
  f="$dir/result.md"
  [ -f "$f" ] || { _die "result.md 가 없다: $dir"; return 1; }

  bad="$(awk -F'|' '
    /^[ \t]*\|/ && $0 ~ /근거/ && ci == 0 {
      for (i = 1; i <= NF; i++) { h = $i; gsub(/[ \t*]/, "", h); if (h == "근거") ci = i }
      next
    }
    ci > 0 && /^[ \t]*\|/ && $0 !~ /^[ \t]*\|[ \t:-]*\|/ {
      v = $ci; gsub(/^[ \t`]+|[ \t`]+$/, "", v)
      if (v ~ /^[A-Za-z0-9._-]+\.(png|jpg|jpeg|gif|webp)$/) {
        row = $2; gsub(/^[ \t]+|[ \t]+$/, "", row)
        printf "  %s → %s\n", row, v
      }
    }
  ' "$f")"

  if [ -n "$bad" ]; then
    _die "근거 칸에 파일 이름만 적힌 행이 있다. 그림은 화면에 뜨지 않으므로 읽는 사람이 볼 수 없다:
$bad
관측한 사실을 적어라(응답 본문·이동 경로·번들 시각·화면 문구). 화면을 꼭 보여야 하면 본문에 \`![설명](파일.png)\` 으로 띄우고, 근거 칸에는 무엇을 보라는 것인지 글로 적어라."
    return 1
  fi

  # ── 광고·수집: 탐지됐으면 전용 시나리오가 있어야 한다 ─────────────────────
  # 실측: 추적·광고 코드가 등장한 오더 29건 중 검증에서 실제로 확인한 것은 4건(14%)뿐이다.
  # 경고로는 안 된다 — 25건이 경고 없이도 그냥 지나갔듯, 경고가 있어도 지나간다.
  # 확인할 수 없는 사정이면 **시나리오를 넣고 보류로 적으면** 빠져나갈 길이 있다.
  local tkey tkinds k miss=""
  tkey="$(basename "$(dirname "$(dirname "$dir")")")"
  tkinds="$(_track_scan_kinds "$tkey")"
  # ⛔ `for k in $tkinds` 를 쓰지 않는다 — zsh 는 따옴표 없는 확장을 공백으로 나누지 않아
  #    `[광고] [수집]` 이 통째로 한 낱말이 되고, grep 이 영원히 안 맞아 **언제나 거부**한다
  #    (실측: 시나리오를 제대로 넣었는데도 통과하지 못했다). 이 라이브러리가 _words 를 둔 이유다.
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qF "$k" "$f" || miss="$miss $k"
  done <<EOF
$(_words "$tkinds")
EOF
  if [ -n "$miss" ]; then
    _die "광고·수집 접촉이 보고됐는데 result.md 에 해당 시나리오가 없다:$miss

$(sed -n '/^| 갈래/,$p' "$(_order_dir "$tkey")/track-scan.md" 2>/dev/null | head -12)

시나리오의 '확인 항목' 칸에 $miss 를 적어 넣어라. 광고·수집은 **화면에 안 보이게 깨지므로**
다른 시나리오가 통과해도 이것은 따로 봐야 한다.
  [수집] 조작 전 window.__dobbyMark=(window.dataLayer||[]).length 로 표시하고,
         조작 뒤 (window.dataLayer||[]).slice(window.__dobbyMark) 를 근거로 적는다.
  [광고] 배너가 **75% 보일 때까지 스크롤**한 뒤 ad.section.view 를 본다(threshold 0.75).
         링크에 _refer_section_st= 가 있는지도 함께 본다 — 없으면 추적 자체가 안 걸린다.
확인할 수 없는 사정이면 시나리오를 넣고 **판정을 보류**로, 사유를 함께 적어라(빼지 말 것)."
    return 1
  fi

  # ── 여기부터: "이 회차만 보고 배포를 판단할 수 있나" 세 가지 ──────────────
  # 부품은 전부터 있었는데 아무도 채우라고 하지 않아 비어 있었다(실측 75회차 중
  # 조건 칸을 채운 회차 18건 = 24%, 판정 칸이 기계적으로 안 읽히는 시나리오 79건 = 13%).
  # 대시보드(testSummary.ts)는 이미 조건마다 판정을 엄격히 합치고 있어, 입력만
  # 채워지면 "조건 5가지 중 5가지 확인"을 스스로 말한다.
  local key rows
  key="$(basename "$(dirname "$(dirname "$dir")")")"

  rows="$(awk -F'|' '
    function t(x){gsub(/^[ \t*`]+|[ \t*`]+$/,"",x); return x}
    # 머리글에서 칸 위치를 찾는다(스키마 하드코딩 금지 — dobby_agent_state 와 같은 방식)
    /^[ \t]*\|/ && cc==0 && $0 ~ /조건/ && $0 ~ /판정/ {
      for(i=1;i<=NF;i++){h=t($i); if(h=="조건")cc=i; else if(h=="판정")cv=i}
      next
    }
    # 조건·판정 칸이 아예 없는 표 — 옛 형식이다. 새 회차가 이 형식으로 나오면
    # 위 검사가 통째로 건너뛰어 구멍이 된다(실측: 옛 회차 107건 중 81건이 이래서 그냥 통과했다).
    cc==0 && /^[ \t]*\|/ { if (t($2) ~ /^S[0-9]+$/) nocol=1; next }
    cc>0 && /^[ \t]*\|/ {
      num=t($2)
      if (num !~ /^S[0-9]+$/) next
      cond=t($(cc)); verd=t($(cv))
      if (cond == "") printf "COND\t%s\n", num
      else if (cond !~ /^(R|C[0-9]+([ \t]*[,·][ \t]*C[0-9]+)*)$/) printf "CONDBAD\t%s\t%s\n", num, cond
      else if (cond != "R") { n=split(cond, a, /[,·]/); for(i=1;i<=n;i++) printf "HAS\t%s\n", t(a[i]) }
      if (verd !~ /^(PASS|FAIL|SKIP\((환경|위험|미비)\))$/) printf "VERD\t%s\t%s\n", num, verd
    }
    END { if (nocol) print "NOCOL" }
  ' "$f")"

  if printf '%s\n' "$rows" | grep -qx NOCOL; then
    _die "시나리오 표에 '조건'·'판정' 칸이 없다. 머리글을 규격대로 두어라:
  | # | 조건 | 페이지 / URL | 확인 항목 | 기대 | 실제 | 판정 | 근거 |
칸이 없으면 대시보드가 조건별 판정을 셀 수 없어 '사람이 판단하세요'에서 멈춘다."
    return 1
  fi

  local miss_cond bad_cond bad_verd have want uncovered rc=0
  miss_cond="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="COND"{printf " %s", $2}')"
  bad_cond="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="CONDBAD"{printf "  %s → \"%s\"\n", $2, $3}')"
  bad_verd="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="VERD"{printf "  %s → \"%s\"\n", $2, $3}')"

  if [ -n "$miss_cond" ]; then
    _die "조건 칸이 빈 행:$miss_cond
이 시나리오가 어느 해결 조건을 확인하는지 적어라(\`C1\`, 여럿이면 \`C1·C2\`).
어느 조건도 짚지 않는 회귀 확인이면 비우지 말고 **\`R\`** 로 적어라 — 빈 칸은
\"안 적었다\"와 구분되지 않아 대시보드가 그 행을 집계에서 떨어뜨린다."
    rc=1
  fi
  [ -n "$bad_cond" ] && { _die "조건 칸 형식이 틀린 행:
$bad_cond
C 번호(\`C1\`·\`C1·C2\`) 또는 회귀 표시 \`R\` 만 적는다. 조건 문장을 옮겨 적지 않는다."; rc=1; }
  [ -n "$bad_verd" ] && { _die "판정 칸 어휘가 틀린 행:
$bad_verd
PASS · FAIL · SKIP(환경) · SKIP(위험) · SKIP(미비) 다섯 중 하나만 쓴다.
보류는 왜 못 했는지로 가른다 — 환경(브라우저·외부 시스템 한계) · 위험(실행하면
되돌릴 수 없음) · 미비(준비가 모자람). 미비가 하나라도 있으면 배포 판단에 쓸 수 없다."; rc=1; }

  # 선언한 조건이 전부 이 회차에 나왔나(한 회차로 다 못 덮으면 여러 회차의 합을 본다)
  want="$(dobby_conditions "$key" 2>/dev/null)"
  if [ -n "$want" ]; then
    have="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="HAS"{print $2}' | sort -u)"
    local other
    other="$(grep -ho '\bC[0-9]\+\b' "$(dirname "$dir")"/*/result.md 2>/dev/null | sort -u)"
    have="$(printf '%s\n%s\n' "$have" "$other" | sed '/^$/d' | sort -u)"
    uncovered="$(printf '%s\n' "$want" | while read -r c; do
      [ -n "$c" ] || continue
      printf '%s\n' "$have" | grep -qx "$c" || printf ' %s' "$c"
    done)"
    [ -n "$uncovered" ] && { _die "확인한 시나리오가 없는 조건:$uncovered
이 조건을 확인하는 시나리오를 이 회차(또는 앞선 회차)에 넣어라. 조건을 다 덮지 못하면
\"이 오더가 끝났다\"를 셀 수 없어 대시보드가 \"사람이 판단하세요\"에서 멈춘다.
정말 이번 범위에서 확인할 수 없으면 그 조건을 닫히는 조건에서 빼거나 다음 오더로 넘겨라."; rc=1; }
  fi

  return "$rc"
}

# dobby_conditions KEY — status.md '## 닫히는 조건 항목' 표의 C 번호를 한 줄씩 낸다.
# ⛔ 그 절 안만 본다 — 문서 다른 표(회귀 목록 등)의 `| C1 |` 행까지 조건으로 세지 않게.
#    (대시보드 testSummary.ts readClosing 과 같은 기준.)
dobby_conditions() {
  local f
  f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 0
  awk '
    /^## / { ins=(index($0,"닫히는 조건 항목")>0)?1:0; next }
    ins==1 && /^\|/ {
      n=split($0,a,"|"); c=a[2]; gsub(/[ \t*]/,"",c)
      if (c ~ /^C[0-9]+$/) print c
    }' "$f"
}

# dobby_testrun_prune 결과폴더 — 그 회차에서 **아무도 안 가리키는 그림**을 지운다.
#
# 테스트 중 화면을 확인하려고 찍은 그림이 결과 폴더에 그대로 남는다. 근거로 쓴 것은
# result.md·summary.html 이 파일 이름으로 가리키므로, **가리키지 않는 것만** 지우면
# 근거는 하나도 잃지 않는다. 사람이 고를 필요가 없다.
#
# 실측(회차 76개): 그림 66개 중 63개는 본문이 가리키고(87.7MB) 3개만 안 쓰였다(3.3MB).
# 그중 하나는 스킬이 금지한 "요약 화면을 따로 찍은 것"이었다.
#
# ⛔ 안전: test-runs 폴더 안에서만 돌고, 그림 확장자만 지운다. 그 밖이면 아무것도 하지 않는다.
dobby_testrun_prune() {
  local dir="$1" f n del=0 kb=0 sz refs
  [ -d "$dir" ] || { _die "폴더가 없다: $dir"; return 1; }
  case "$dir" in
    *"/test-runs/"*) : ;;
    *) _die "test-runs 회차 폴더가 아니다: $dir"; return 1 ;;
  esac

  # 같은 폴더의 글(md·html)을 한 번만 읽어 둔다.
  #
  # ⛔ grep 으로 판정하지 않는다. 파일 인자 **뒤에** --include 를 주면 macOS 의 grep(BSD)이
  #    그것을 옵션이 아니라 **없는 파일 이름**으로 읽어 종료코드 2(오류)를 낸다. 그러면
  #    "참조 없음"으로 잘못 판정해 **근거 그림까지 전부 지운다.**
  #    실측 FE1-2005(2026-09-28 11:31): result.md 가 가리키던 7장이 모두 지워졌다.
  #      grep -rqF -- "이름" "$dir" --include="*.md"   → 2
  #      grep -rqF --include="*.md" -- "이름" "$dir"   → 0
  #    글로브(`"$dir"/*.md`)도 쓰지 않는다 — zsh 는 짝이 없으면 명령 전체를 멈춰서,
  #    html 이 아직 없을 때 md 까지 못 읽고 "근거 없음"이 된다.
  refs="$(find "$dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.html' \) -exec cat {} + 2>/dev/null)"

  # 글이 하나도 없으면 무엇이 근거인지 알 수 없다 — 아무것도 지우지 않는다.
  if [ -z "$refs" ]; then
    printf 'dobby-lib: 본문(md·html)이 없어 그림을 지우지 않는다: %s\n' "$dir" >&2
    printf '0'; return 0
  fi

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    # 본문이 파일 이름을 가리키면 근거다 — 남긴다.
    case "$refs" in *"$n"*) continue ;; esac
    sz="$(du -k "$f" 2>/dev/null | cut -f1)"; kb=$((kb + ${sz:-0}))
    rm -f "$f" && del=$((del + 1))
    printf '  지움 %s\n' "$n" >&2
  done <<EOF
$(find "$dir" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) 2>/dev/null)
EOF

  if [ "$del" -gt 0 ]; then
    printf '안 쓰는 그림 %s개 지움 (%sKB)\n' "$del" "$kb" >&2
  fi
  printf '%s' "$del"
}

# ─────────────────────────────────────────────────────────────────────────────
# 단계 밖 변경 감지 — /do 단계와 dobby-ship 이 끝날 때 기준점을 남기고, 다음에 지금 상태와 비교한다.
# 기준점은 상태 문서 `## 현재 단계` 의 한 줄이다:
#   - **기준점**: {시각} · 설계 {지문} · {저장소}@{커밋}:{미커밋 지문} · …
# 지문은 내용이 바뀌면 달라지는 짧은 값이다. 머지 커밋으로 들어온 변경(기준 브랜치·i18n-sync)은 세지 않는다.
# ─────────────────────────────────────────────────────────────────────────────
DOBBY_CLEAN_FP="$(printf '' | shasum | cut -c1-8)"

# _v2_worktrees KEY — 워크트리 표의 모든 행을 "저장소<TAB>브랜치<TAB>경로" 로.
_v2_worktrees() {
  awk '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);gsub(/`|\*/,"",x);return x}
    /^## /{ins=(index($0,"워크트리")>0)?1:0; hdr=0; next}
    ins==1 && /^\|/{
      n=split($0,a,"|")
      if(hdr==0){for(i=1;i<=n;i++){c=t(a[i]); if(c=="repo")cr=i; if(c=="브랜치")cb=i; if(c=="경로")cp=i}
        if(cr&&cb&&cp)hdr=1; next}
      r=t(a[cr]); b=t(a[cb]); sub(/[ \t]*\(.*$/,"",b); p=t(a[cp])
      if(r!="" && r !~ /^-+$/ && p!="" && !seen[p]++) print r "\t" b "\t" p
    }' "$(_order_dir "$1")/status.md" 2>/dev/null | sed "s#\t~/#\t$HOME/#"
}

# _v2_design_fp KEY — 설계 문서 + 테스트 계획의 지문.
_v2_design_fp() {
  local d; d="$(_order_dir "$1")"
  cat "$d/design.md" "$d/test-plan.md" 2>/dev/null | shasum | cut -c1-8
}

# _v2_wt_fp 경로 — 커밋 안 된 변경(추적 파일 diff + 새 파일 내용)의 지문. 깨끗하면 DOBBY_CLEAN_FP.
_v2_wt_fp() {
  ( cd "$1" 2>/dev/null || exit 0
    { git diff HEAD --binary 2>/dev/null
      git ls-files -o --exclude-standard -z 2>/dev/null | xargs -0 shasum 2>/dev/null
    } | shasum | cut -c1-8 )
}

# _v2_checkpoint_get KEY — 기준점 줄의 값. 없으면 빈 출력.
_v2_checkpoint_get() {
  sed -nE 's/^[ \t]*-[ \t]*\*\*기준점\*\*:[ \t]*(.*)$/\1/p' "$(_order_dir "$1")/status.md" 2>/dev/null | head -1
}

# _v2_checkpoint_write KEY 값 — `## 현재 단계` 절의 기준점 줄을 바꾸거나 절 끝에 넣는다.
_v2_checkpoint_write() {
  local f; f="$(_order_dir "$1")/status.md"
  [ -f "$f" ] || return 1
  awk -v line="- **기준점**: $2" '
    /^## /{ if(insec && !done){print line; done=1} insec=($0 ~ /현재 단계/) }
    insec && /^[ \t]*-[ \t]*\*\*기준점\*\*/ { if(!done){print line; done=1}; next }
    insec && /^[ \t]*$/ && !done { print line; done=1 }
    {print}
    END{ if(!done) print line }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dobby_v2_checkpoint KEY — 지금 상태를 기준점으로 남긴다. /do 단계와 dobby-ship 이 끝날 때 부른다.
dobby_v2_checkpoint() {
  local key="$1" v r b p h
  [ -f "$(_order_dir "$key")/status.md" ] || { _die "$key 의 상태 문서가 없습니다"; return 1; }
  v="$(_now) · 설계 $(_v2_design_fp "$key")"
  while IFS=$'\t' read -r r b p; do
    [ -d "$p" ] || continue
    h="$(git -C "$p" rev-parse --short=12 HEAD 2>/dev/null)" || continue
    v="$v · $r@$h:$(_v2_wt_fp "$p")"
  done < <(_v2_worktrees "$key")
  _v2_checkpoint_write "$key" "$v"
}

# dobby_v2_drift KEY — 기준점 뒤에 단계 밖에서 바뀐 것을 낸다.
#   첫 줄: "종류<TAB>처음 바뀐 시각". 종류는 none | nobase(기준점 없음) | design | code | both
#   다음 줄들: "commit<TAB>저장소<TAB>커밋<TAB>시각<TAB>제목" 과 "file<TAB>저장소<TAB>상태<TAB>경로"
dobby_v2_drift() {
  local key="$1" cp dfp r b p tok base wfp code="" design="" since="" out="" t df h s l
  cp="$(_v2_checkpoint_get "$key")"
  [ -n "$cp" ] || { printf 'nobase\t\n'; return 0; }
  dfp="$(printf '%s' "$cp" | sed -nE 's/.*설계 ([0-9a-f]+).*/\1/p')"
  if [ "$dfp" != "$(_v2_design_fp "$key")" ]; then
    design=1
    df="$(stat -f '%m' "$(_order_dir "$key")/design.md" "$(_order_dir "$key")/test-plan.md" 2>/dev/null | sort -n | tail -1)"
    [ -n "$df" ] && since="$(date -r "$df" '+%Y-%m-%d %H:%M')"
  fi
  while IFS=$'\t' read -r r b p; do
    [ -d "$p" ] || continue
    tok="$(printf '%s' "$cp" | awk -F' · ' '{for(i=1;i<=NF;i++)print $i}' | sed -nE "s/^[ \t]*$r@([0-9a-f]+):([0-9a-f]+)[ \t]*$/\1 \2/p" | head -1)"
    [ -n "$tok" ] || continue
    base="${tok% *}"; wfp="${tok#* }"
    if git -C "$p" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
      while IFS=$'\t' read -r h t s; do
        [ -n "$h" ] || continue
        code=1; out="$out$(printf 'commit\t%s\t%s\t%s\t%s' "$r" "$h" "$t" "$s")"$'\n'
        { [ -z "$since" ] || [[ "$t" < "$since" ]]; } && since="$t"
      done < <(git -C "$p" log --first-parent --no-merges --reverse --format='%h%x09%ad%x09%s' --date=format:'%Y-%m-%d %H:%M' "$base..HEAD" 2>/dev/null)
    else
      code=1; out="$out$(printf 'commit\t%s\t-\t-\t기준 커밋 %s 이 브랜치에 없음(되감기·이력 재작성)' "$r" "$base")"$'\n'
    fi
    if [ "$(_v2_wt_fp "$p")" != "$wfp" ]; then
      code=1
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        out="$out$(printf 'file\t%s\t%s\t%s' "$r" "${l:0:2}" "${l:3}")"$'\n'
        t="$(stat -f '%m' "$p/${l:3}" 2>/dev/null)"
        [ -n "$t" ] && t="$(date -r "$t" '+%Y-%m-%d %H:%M')" && { [ -z "$since" ] || [[ "$t" < "$since" ]]; } && since="$t"
      done < <(git -C "$p" status --porcelain -uall 2>/dev/null)
    fi
  done < <(_v2_worktrees "$key")
  if [ -n "$code" ] && [ -n "$design" ]; then t=both
  elif [ -n "$code" ]; then t=code
  elif [ -n "$design" ]; then t=design
  else t=none
  fi
  printf '%s\t%s\n%s' "$t" "$since" "$out"
}

# _v2_recent KEY [분] — 최근 N분(기본 15) 안에 사람이 이 오더에서 일하고 있는 흔적이 있으면 0.
# 흔적: 커밋 안 된 파일의 수정 시각, 워크트리 폴더에서 연 세션의 대화 기록(/do 밖에서 연 세션 포함) 수정 시각.
_v2_recent() {
  local key="$1" min="${2:-15}" now r b p l m tr
  now="$(date +%s)"
  while IFS=$'\t' read -r r b p; do
    [ -d "$p" ] || continue
    while IFS= read -r l; do
      m="$(stat -f '%m' "$p/${l:3}" 2>/dev/null)"
      [ -n "$m" ] && [ $((now - m)) -lt $((min * 60)) ] && return 0
    done < <(git -C "$p" status --porcelain -uno 2>/dev/null)
    # 기록 파일의 수정 시각은 대화 없이도 바뀐다(실측) — 후보만 고르고, 판정은 마지막 메시지 시각으로 한다.
    while IFS= read -r tr; do
      l="$(tail -n 30 "$tr" | grep -o '"timestamp":"[0-9T:-]*' | tail -1 | cut -d'"' -f4)"
      m="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${l:0:19}" +%s 2>/dev/null)"
      [ -n "$m" ] && [ $((now - m)) -lt $((min * 60)) ] && return 0
    done < <(find "$HOME/.claude/projects/$(printf '%s' "$p" | sed 's#[/.]#-#g')" -maxdepth 1 -name '*.jsonl' -mmin "-$min" 2>/dev/null)
  done < <(_v2_worktrees "$key")
  return 1
}

# _v2_open_next_round KEY — 다음 리뷰 차수 폴더를 연다(마지막 차수 폴더가 비어 있으면 그대로). 차수를 낸다.
_v2_open_next_round() {
  local d rd; d="$(_order_dir "$1")"
  rd="$(find "$d/reviews" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sed 's/.*round-//' | sort -n | tail -1)"
  if [ -z "$rd" ]; then rd=1
  elif ls "$d/reviews/round-$rd"/*.md >/dev/null 2>&1; then rd=$((rd + 1))
  fi
  mkdir -p "$d/reviews/round-$rd"; printf '%s' "$rd"
}

# _v2_drift_section KEY 차수 감지결과 — 설계 문서 끝에 "단계 밖에서 들어온 수정" 변경 절을 붙인다. 변경 번호를 낸다.
_v2_drift_section() {
  local key="$1" rd="$2" det="$3" f m
  f="$(_order_dir "$key")/design.md"; [ -f "$f" ] || return 1
  m="$(sed -nE 's/^## 변경 ([0-9]+).*/\1/p' "$f" | sort -n | tail -1)"; m=$(( ${m:-0} + 1 ))
  {
    printf '\n## 변경 %s — 단계 밖에서 들어온 수정\n\n' "$m"
    printf -- '- **상태**: 구현 대기 (단계 밖에서 이미 구현됨 — 다시 구현하지 않고 리뷰한다)\n'
    printf -- '- **종류**: 단계 밖 수정\n- **요청**: /do 단계 밖에서 코드가 바뀌었다(자동 감지)\n'
    printf -- '- **접수**: %s\n- **리뷰 시작 차수**: %s차\n\n' "$(_now)" "$rd"
    if printf '%s' "$det" | grep -q '^commit'; then
      printf '### 들어온 커밋\n\n| 저장소 | 커밋 | 시각 | 제목 |\n|---|---|---|---|\n'
      printf '%s\n' "$det" | awk -F'\t' '$1=="commit"{printf "| %s | %s | %s | %s |\n",$2,$3,$4,$5}'
      printf '\n'
    fi
    if printf '%s' "$det" | grep -q '^file'; then
      printf '### 커밋 안 된 파일\n\n| 저장소 | 상태 | 경로 |\n|---|---|---|\n'
      printf '%s\n' "$det" | awk -F'\t' '$1=="file"{printf "| %s | %s | %s |\n",$2,$3,$4}'
      printf '\n'
    fi
    printf '### 리뷰 항목\n\n'
    printf -- '- 위 커밋(`git show {커밋}`)과 파일만 범위로 본다. 설계에 의도가 적혀 있지 않으므로 코드에서 의도를 읽고, 기존 설계·결정과 어긋나는지 본다.\n'
    printf -- '- 이 변경을 확인할 시나리오가 테스트 계획에 있는가. 없으면 `[major]` 로 남긴다(수정 세션이 테스트 계획에 더한다).\n'
  } >> "$f"
  printf '%s' "$m"
}

# dobby_v2_drift_apply KEY — 단계 밖 변경이 있으면 다음 /do 가 알맞은 단계를 하도록 상태를 되돌리고 기준점을 새로 남긴다.
# 출력: none | nobase | kept(지금 단계가 그대로 다룬다) | design(설계 확인부터) | code(리뷰부터)
#   design·both : 단계가 착수·분석이면 그대로(단계 판정의 설계 승인 비교가 다룬다). 아니면 dobby_v2_change_open 으로 분석.
#   code        : 착수·분석·구현이거나 리뷰 결과가 아직 없는 리뷰면 단계는 그대로 두고, 들어온 커밋이 있을 때만 변경 절을 남긴다
#                 (커밋 안 된 변경은 리뷰 브리프가 이미 본다). 그 밖의 단계면 변경 절을 남기고 단계를 구현으로 — 다음은 리뷰다.
dobby_v2_drift_apply() {
  local key="$1" det kind ph rd m d dev
  d="$(_order_dir "$key")"
  det="$(dobby_v2_drift "$key")"; kind="$(printf '%s' "$det" | head -1 | cut -f1)"
  case "$kind" in none|nobase) printf '%s\n' "$kind"; return 0 ;; esac
  det="$(printf '%s' "$det" | tail -n +2)"
  ph="$(_order_phase "$key")"
  if [ "$kind" != code ]; then
    case "$ph" in
      착수|분석) dobby_v2_checkpoint "$key"; printf 'kept\n'; return 0 ;;
    esac
    rd="$(dobby_v2_change_open "$key")" || return 1
    [ "$kind" = both ] && _v2_drift_section "$key" "$rd" "$det" >/dev/null
    dobby_agent_state "$key" analysis-agent 분석 "" "단계 밖 설계 변경 확인" 2>/dev/null
    dobby_event "$key" "단계 밖 설계 변경 감지 — 단계 $ph → 분석, 설계 확인부터 다시" 2>/dev/null
    dobby_v2_checkpoint "$key"; printf 'design\n'; return 0
  fi
  dev="$(_board_dev_slug "$d/orchestration.md")"
  case "$ph" in
    착수|분석|구현)
      printf '%s' "$det" | grep -q '^commit' && _v2_drift_section "$key" "$(_v2_open_next_round "$key")" "$det" >/dev/null
      dobby_v2_checkpoint "$key"; printf 'kept\n'; return 0 ;;
    리뷰)
      rd="$(find "$d/reviews" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sed 's/.*round-//' | sort -n | tail -1)"
      if [ -z "$rd" ] || ! ls "$d/reviews/round-$rd"/*.md >/dev/null 2>&1; then
        printf '%s' "$det" | grep -q '^commit' && _v2_drift_section "$key" "${rd:-1}" "$det" >/dev/null
        dobby_v2_checkpoint "$key"; printf 'kept\n'; return 0
      fi ;;
  esac
  if [ "$ph" = 해결 ]; then
    awk '/^## 해결/{skip=1; next} /^## /{if(skip)skip=0} !skip{print}' "$d/status.md" > "$d/status.md.tmp" && mv "$d/status.md.tmp" "$d/status.md"
  fi
  rd="$(_v2_open_next_round "$key")"
  m="$(_v2_drift_section "$key" "$rd" "$det")"
  dobby_phase "$key" 구현
  [ -n "$dev" ] && dobby_agent_state "$key" "$dev" 대기 2>/dev/null
  dobby_event "$key" "단계 밖 코드 변경 감지 — 변경 $m 로 기록, 단계 $ph → 구현, ${rd}차 리뷰부터 다시" 2>/dev/null
  dobby_v2_checkpoint "$key"; printf 'code\n'
}

# dobby_v2_drift_backfill [KEY accept|review] — 기준점이 없는 /do 오더의 첫 기준점을 정한다.
#   인자 없음: 오더마다 마지막 "통합 완료" 이벤트 때의 커밋을 기준으로 비교해 표 한 줄씩 낸다(바꾸지 않는다).
#             "키<TAB>단계<TAB>판정<TAB>기준 시각<TAB>단계 밖 커밋 수<TAB>커밋 안 된 파일 수"
#             판정: 작업 중(최근 15분 흔적, 제외) | 변경 없음 | 단계 밖 변경 | 기준 없음(통합 전)
#   KEY accept: 지금 상태를 그대로 기준점으로 남긴다.
#   KEY review: 그 기준 커밋으로 기준점을 남긴 뒤 dobby_v2_drift_apply 로 리뷰부터 다시 하게 한다.
dobby_v2_drift_backfill() {
  local key="${1:-}" mode="${2:-}" d k ph ts r b p base v nc nf verdict
  # 기록 시각은 분까지라 그 분의 끝(59초)까지 센다. 통합 커밋이 같은 분에 찍힌다(실측).
  _v2_base_at() { git -C "$1" rev-list -1 --first-parent --before="$2:59" HEAD 2>/dev/null | cut -c1-12; }
  _v2_integrated_at() {
    sed -nE 's/^- ([0-9-]+ [0-9:]+) 통합 완료.*/\1/p' "$(_order_dir "$1")/orchestration.md" 2>/dev/null | tail -1
  }
  if [ -n "$key" ]; then
    case "$mode" in
      accept) dobby_v2_checkpoint "$key"; dobby_event "$key" "기준점 처음 기록 — 지금 상태를 그대로 인정" 2>/dev/null; return 0 ;;
      review)
        ts="$(_v2_integrated_at "$key")"; [ -n "$ts" ] || { _die "$key 에 통합 완료 기록이 없습니다"; return 1; }
        v="$ts · 설계 $(_v2_design_fp "$key")"
        while IFS=$'\t' read -r r b p; do
          base="$(_v2_base_at "$p" "$ts")"; [ -n "$base" ] && v="$v · $r@$base:$DOBBY_CLEAN_FP"
        done < <(_v2_worktrees "$key")
        _v2_checkpoint_write "$key" "$v"
        dobby_event "$key" "기준점 처음 기록 — $ts 통합 때 커밋 기준, 그 뒤 변경은 리뷰부터 다시" 2>/dev/null
        dobby_v2_drift_apply "$key"; return $? ;;
      *) _die "쓰임: dobby_v2_drift_backfill [KEY accept|review]"; return 1 ;;
    esac
  fi
  for d in "$(_meta)"/*/; do
    k="$(basename "$d")"
    grep -q '^## 지난 세션' "$d/status.md" 2>/dev/null || continue
    [ -n "$(_v2_checkpoint_get "$k")" ] && continue
    ph="$(_order_phase "$k")"
    case "$ph" in 해결|종료|완료) continue ;; esac
    ts="$(_v2_integrated_at "$k")"
    if _v2_recent "$k"; then printf '%s\t%s\t작업 중\t%s\t-\t-\n' "$k" "$ph" "${ts:--}"; continue; fi
    [ -n "$ts" ] || { printf '%s\t%s\t기준 없음(통합 전)\t-\t-\t-\n' "$k" "$ph"; continue; }
    nc=0; nf=0
    while IFS=$'\t' read -r r b p; do
      [ -d "$p" ] || continue
      base="$(_v2_base_at "$p" "$ts")"; [ -n "$base" ] || continue
      nc=$((nc + $(git -C "$p" log --first-parent --no-merges --format=%h "$base..HEAD" 2>/dev/null | grep -c .)))
      nf=$((nf + $(git -C "$p" status --porcelain -uall 2>/dev/null | grep -c .)))
    done < <(_v2_worktrees "$k")
    verdict="변경 없음"; [ $((nc + nf)) -gt 0 ] && verdict="단계 밖 변경"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$ph" "$verdict" "$ts" "$nc" "$nf"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 다음 할 일 — 대시보드가 30초마다 부른다. 모델을 부르지 않고 파일·git·프로세스 목록만 본다(토큰 0).
# dobby_v2_next_all — 끝나지 않은 /do 오더마다 JSON 한 줄:
#   {key,title,phase,group,kind,text,since,env,cmd,link,action}
#   group : mine(자동화가 끝나 사람이 할 일이 있음) | notice(알림만, 할 일 없음) | auto(자동 진행 중)
#           | wait(날짜·조건 기다림) | work(터미널에서 작업 중). 정기배포일이 지난 오더는 내지 않는다.
#   action: 대시보드 버튼 — autorun | deploy | approve | drift | "" (cmd 는 복사할 명령, link 는 열 주소)
# ─────────────────────────────────────────────────────────────────────────────
# _v2_drift_cached KEY — dobby_v2_drift 의 첫 줄. 커밋·인덱스·상태 문서·설계 문서가 그대로면 지난 결과를 쓴다.
# 대시보드 주기 판정용이다(오더마다 새 파일 검사가 0.2초). /do 시작의 되돌리기는 이것을 쓰지 않는다.
_v2_drift_cached() {
  local key="$1" d sig r b p g c
  d="$(_order_dir "$key")"
  sig="$(stat -f '%m' "$d/status.md" "$d/design.md" "$d/test-plan.md" 2>/dev/null | tr '\n' ' ')"
  while IFS=$'\t' read -r r b p; do
    [ -d "$p" ] || continue
    g="$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null)"
    sig="$sig $(git -C "$p" rev-parse HEAD 2>/dev/null) $(stat -f '%m' "$g/index" 2>/dev/null)"
  done < <(_v2_worktrees "$key")
  c="${TMPDIR:-/tmp}/dobby-next/$key"
  if [ -f "$c" ] && [ "$(head -1 "$c")" = "$sig" ]; then sed -n 2p "$c"; return 0; fi
  mkdir -p "$(dirname "$c")"
  r="$(dobby_v2_drift "$key" | head -1)"
  printf '%s\n%s\n' "$sig" "$r" > "$c"; printf '%s\n' "$r"
}

# _v2_test_skip KEY — 테스트 계획에 "- **검증**: 필요 없음" 줄이 있으면 참. 배포 뒤 할 일이 없는 오더다.
_v2_test_skip() {
  grep -q '^- \*\*검증\*\*:[[:space:]]*필요 없음' "$(_order_dir "$1")/test-plan.md" 2>/dev/null
}

_v2_md_day() {
  local u w; u="$(date -j -f '%Y-%m-%d' "$1" '+%u' 2>/dev/null)" || { printf '%s' "$1"; return; }
  case "$u" in 1) w=월 ;; 2) w=화 ;; 3) w=수 ;; 4) w=목 ;; 5) w=금 ;; 6) w=토 ;; *) w=일 ;; esac
  printf '%s(%s)' "$(date -j -f '%Y-%m-%d' "$1" '+%m/%d')" "$w"
}

dobby_v2_next_all() {
  local ps today d k f ph title upd env kind grp text since cmd link act dr drk drs rd row st ln dt stf tf
  ps="$(ps -axo command 2>/dev/null)"; today="$(date '+%Y-%m-%d')"
  _v2_emit() {
    jq -nc --arg key "$k" --arg title "$title" --arg phase "$ph" --arg group "$grp" --arg kind "$kind" \
      --arg text "$text" --arg since "$since" --arg env "$env" --arg cmd "$cmd" --arg link "$link" --arg action "$act" \
      '{key:$key,title:$title,phase:$phase,group:$group,kind:$kind,text:$text,since:$since,env:$env,cmd:$cmd,link:$link,action:$action}'
  }
  while IFS= read -r f; do
    d="${f%/status.md}"; k="${d##*/}"
    ph="$(_order_phase "$k")"
    case "$ph" in 해결|종료|완료) continue ;; esac
    title="$(sed -nE 's/^- \*\*제목\*\*:[ \t]*(.*)$/\1/p' "$f" | head -1)"
    upd="$(sed -nE 's/^- \*\*갱신\*\*:[ \t]*([0-9-]+ [0-9:]+).*/\1/p' "$f" | head -1)"
    env="$(dobby_v2_env "$k")"
    grp=mine; kind=""; text=""; since="$upd"; cmd=""; link=""; act=""

    if printf '%s\n' "$ps" | grep -Eq "run\.sh'? '?$k'?( |$)"; then
      grp=auto; kind=running; text="자동 실행 중 — $ph 단계"; _v2_emit; continue
    fi

    dr="$(_v2_drift_cached "$k")"; drk="${dr%%$'\t'*}"; drs="${dr#*$'\t'}"
    if [ "$drk" = design ] || [ "$drk" = both ]; then
      case "$ph" in 착수|분석) ;; *)
        if _v2_recent "$k"; then grp=work; kind=working; text="터미널에서 작업 중 — 설계가 바뀌는 중"
        else kind=drift-design; text="단계 밖에서 설계가 바뀌었습니다 — 설계 확인이 필요합니다"; since="$drs"; cmd="/do $k"
        fi; _v2_emit; continue ;;
      esac
    fi
    if [ "$drk" = code ]; then
      rd="$(find "$d/reviews" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sed 's/.*round-//' | sort -n | tail -1)"
      case "$ph" in
        통합|검증|보류) dr=1 ;;
        리뷰) { [ -n "$rd" ] && ls "$d/reviews/round-$rd"/*.md >/dev/null 2>&1; } && dr=1 || dr="" ;;
        *) dr="" ;;
      esac
      if [ -n "$dr" ]; then
        if _v2_recent "$k"; then grp=work; kind=working; text="터미널에서 작업 중 — 단계 밖에서 코드가 바뀌는 중"
        else kind=drift-code; text="단계 밖에서 코드가 바뀌었습니다 — 리뷰가 필요합니다"; since="$drs"; act=drift
        fi; _v2_emit; continue
      fi
    fi

    case "$ph" in
      보류)
        kind=decision; text="판단이 필요합니다"; cmd="/do $k" ;;
      착수|분석)
        if [ ! -f "$d/design.md" ]; then grp=work; kind=designing; text="설계 작성 중"
        elif _v2_takeover_pending "$k" || ! jq -r '.["사용자"] // empty, .auto // empty' "$d/design-ack.json" 2>/dev/null | grep -qx "$(dobby_design_rev "$k")"; then
          kind=design-confirm; text="설계 확인 대기 — 자동 실행인지 직접 실행인지 답해 주세요"; cmd="/do $k"; act=approve
        else
          kind=run-ready; text="설계 확정 — 자동 실행 대기"; act=autorun
        fi ;;
      구현|리뷰)
        if _v2_recent "$k"; then grp=work; kind=working; text="터미널에서 $ph 진행 중"
        else kind=resume; text="$ph 단계에서 멈춰 있습니다 — 자동 실행으로 이어 가기"; act=autorun
        fi ;;
      통합)
        row="$(awk -F'|' '
          function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
          /^## /{ins=($0 ~ /^##[ \t]*배포[ \t]*$/); next}
          ins && /^\|/ && NF>=9 && t($2)!="저장소" && t($2) !~ /^-+$/ {
            if(t($7)>=best){best=t($7); r=t($2) "\t" t($3) "\t" t($4) "\t" t($7) "\t" t($8)}
          } END{print r}' "$f")"
        IFS=$'\t' read -r ln dt st stf tf <<<"$row"
        if [ -n "$row" ] && case "$st" in *⚠*) true ;; *) false ;; esac; then
          kind=blocked; text="배포가 막혔습니다 — $ln $dt: ${tf:-비고 없음}"; since="$stf"
        elif [ -n "$env" ]; then
          kind=ship-resume; text="$env 배포 이어 가기${st:+ — $ln $st}"; act=autorun
        elif [ -z "$row" ]; then
          kind=deploy; text="통합 완료 — 배포 차례"; act=deploy
        else
          case "$st" in
            배포\ 확인)
              if _v2_test_skip "$k"; then grp=notice; kind=verify-skip; text="$dt 배포 확인 — 검증 필요 없음"; since="$stf"
              else kind=verify; text="$dt 배포 확인 — 검증 차례"; cmd="/do $k"; since="$stf"
              fi ;;
            검증\ 중|검증\ 완료|검증\ 종료) kind=deploy; text="통합 완료 — 배포 차례 (지난 배포: $dt $st)"; act=deploy ;;
            *) kind=ship-continue; text="$ln $dt $st — 배포 이어 가기"; cmd="/dobby-ship $k $dt"; since="$stf" ;;
          esac
        fi ;;
      검증)
        if _testrun_open "$k" >/dev/null; then
          if _v2_recent "$k"; then grp=work; kind=working; text="터미널에서 검증 중"
          else kind=verify-continue; text="검증이 중간에 멈췄습니다 — 남은 묶음 이어 가기"; act=autorun
          fi
        elif _v2_test_passed "$k"; then
          ln="$(sed -nE 's/^- \*\*완료 조건\*\*:[ \t]*(.*)$/\1/p' "$f" | head -1)"
          dt="$(awk -F'|' '
            function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
            /^## /{ins=(index($0,"릴리즈 노트")>0); next}
            ins && /^\|/ && t($2) ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ {if(t($2)>m)m=t($2)} END{print m}' "$f")"
          if [ -n "$ln" ]; then grp=wait; kind=condition; text="완료 조건 기다림 — $ln"
          elif [ -z "$dt" ]; then grp=notice; kind=release; text="검증 통과 — 릴리즈 노트 등록 차례"; cmd="/dobby-release $k"
          elif [[ "$dt" > "$today" ]]; then grp=wait; kind=release-wait; text="$(_v2_md_day "$dt") 정기배포 뒤 해결"; since="$dt 09:00"
          elif [ "$dt" = "$today" ] && ! grep -q '^- \*\*상태\*\*: 완료' "$(_release_file "$dt")" 2>/dev/null; then
            grp=wait; kind=stage-check; text="오늘 정기배포 — stage 확인은 릴리즈 화면에서"; link="/releases/$dt"; since="$dt 09:00"
          else
            continue
          fi
        elif ! awk -F'|' '/^## /{ins=(index($0,"테스트 실행 이력")>0); next} ins && /^\|/ && $2 !~ /회차|---/ {n++} END{exit n?0:1}' "$f"; then
          if _v2_test_skip "$k"; then grp=notice; kind=verify-skip; text="검증 필요 없음 — 릴리즈 노트 등록 차례"; cmd="/dobby-release $k"
          else kind=verify; text="검증 차례"; act=autorun
          fi
        else
          grp=notice; kind=fix; text="검증 실패 — ${env:+자동 실행이 원인을 가르고 }수정 차례"; act=autorun
        fi ;;
      *) continue ;;
    esac
    if [ "$grp" = mine ] && [ "$kind" != decision ] && [ "$kind" != design-confirm ] && _v2_recent "$k"; then
      grp=work; text="터미널에서 작업 중 — $text"; act=""; cmd=""
    fi
    _v2_emit
  done < <(grep -l "^## 지난 세션" "$(_meta)"/*/status.md 2>/dev/null)
}

echo "dobby-lib loaded" >&2
