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
dobby_docs_gate() {
  local key="$1" kw="$2" f root hits
  f="$(_order_dir "$key")/docs-refs.md"; mkdir -p "$(dirname "$f")"
  root="${ORCHESTRATION_DOCS_ROOT:-${ORCHESTRATION_REPOS_ROOT:-$HOME/work/repos}/docs}"
  {
    printf '# %s — 착수 docs 확인\n\n' "$key"
    printf -- '- **검색 루트**: %s\n' "$root"
    printf -- '- **키워드**: %s\n\n' "$kw"
  } > "$f"
  if [ ! -d "$root" ]; then
    printf '## 결과\n- DOCS_ROOT 없음 — docs 없이 코드 분석 진행(설정 확인 권장)\n' >> "$f"
    printf 'dobby-lib: docs 루트 없음(%s) — docs 없이 진행\n' "$root" >&2
    return 0
  fi
  hits="$(dobby_docs_search "$kw")"
  if [ -z "$hits" ]; then
    printf '## 결과\n- 히트 없음 — 관련 문서 없음, 코드 분석 진행\n' >> "$f"
    return 0
  fi
  { printf '## 결과 (먼저 읽을 문서)\n'; printf '%s\n' "$hits" | sed 's/^/- /'; } >> "$f"
  printf '%s\n' "$hits"
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

# dobby_agent_state KEY SLUG STATE [ROUND] — 그 행 상태/갱신만 수정. 비활성→활성 진입 시 착수 갱신.
dobby_agent_state() {
  local key="$1" slug="$2" st rd="${4:-}"
  st="$(dobby_norm_state "$3")"
  local f now; f="$(_order_dir "$key")/orchestration.md"; now="$(_now)"
  # 헤더 인식형: `## 에이전트 상태표` 헤더에서 상태/라운드/착수/갱신 컬럼 위치를 찾아 그 칸만 수정한다.
  # (오더마다 상태표 스키마가 달라 컬럼 위치를 하드코딩하면 엉뚱한 칸을 덮어써 표가 깨진다.)
  awk -F'|' -v OFS='|' -v slug="$slug" -v st="$st" -v rd="$rd" -v now="$now" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    BEGIN{ins=0;hdr=0;ci_slug=0;ci_st=0;ci_rd=0;ci_start=0;ci_up=0}
    /^## / { ins=($0 ~ /에이전트 상태표/)?1:0; hdr=0; print; next }
    ins==1 && /^\|/ {
      if (hdr==0) {
        for(i=1;i<=NF;i++){c=t($i)
          if(c=="슬러그")ci_slug=i; else if(c=="상태")ci_st=i
          else if(c=="라운드")ci_rd=i; else if(c=="착수")ci_start=i; else if(c=="갱신")ci_up=i}
        if(ci_slug>0 && ci_st>0) hdr=1
        print; next
      }
      issep=1; for(i=2;i<NF;i++){c=t($i); if(c!="" && c !~ /^-+$/){issep=0;break}}
      if(issep){print;next}
      if(t($(ci_slug))==slug){
        old=t($(ci_st)); ost=(ci_start>0)?t($(ci_start)):"x"
        active=(st=="분석"||st=="구현"||st=="리뷰")
        if(ci_start>0 && active && (old=="대기"||old=="완료"||old==""||ost=="")) $(ci_start)=" " now " "
        $(ci_st)=" " st " "
        if(ci_rd>0 && rd!="") $(ci_rd)=" " rd " "
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
  if [ -n "$rd" ]; then
    jq --arg s "$slug" --arg r "$rd" --arg p "$p" '.[$s] = ((.[$s] // {}) + {($r): $p})' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    jq --arg s "$slug" --arg p "$p" '.[$s] = $p' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
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
    if ! grep -qE '^## \[(blocker|major|minor|nit)\]' "$f"; then
      printf 'dobby-lib: ⚠ %s 에 심각도 카드 헤더(## [blocker|major|minor|nit] …)가 없음 — 이 파일은 직접 읽어 blocking을 판정하세요\n' "$(basename "$f")" >&2
    fi
    c="$(grep -cE '^## \[(blocker|major)\]' "$f" 2>/dev/null)" || c=0
    n=$((n + c))
  done
  printf '%s' "$n"
}

# dobby_testrun_new KEY [총시나리오수] — 회차를 자동 계산(기존 test-runs/ 폴더 수 + 1)하고
# test-runs/{ts}/ + result.md 골격을 만든 뒤, status.md '## 테스트 실행 이력' 표에
# 이번 회차 행(상태 테스트중·집계 0/0/0)을 추가한다. 폴더 경로 stdout.
# (집계 칸의 "(전체 N)"은 참고 표기 — 대시보드는 앞 숫자 3개(성공/실패/skip)만 읽는다.)
dobby_testrun_new() {
  local key="$1" total="${2:-}" n dir sf now
  n="$(find "$(_order_dir "$key")/test-runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  n=$((n + 1))
  dir="$(_order_dir "$key")/test-runs/$(_ts)"; mkdir -p "$dir"
  [ -f "$dir/result.md" ] || printf '# %s 테스트 결과 — 회차 %s\n\n(진행 중)\n' "$key" "$n" > "$dir/result.md"
  sf="$(_order_dir "$key")/status.md"; now="$(_now)"
  if [ -f "$sf" ]; then
    _table_row_append "$sf" "테스트 실행 이력" \
      "| 회차 | 시작 | 상태 | 성공/실패/skip | 폴더 |" "|------|------|------|----------------|------|" \
      "| $n | $now | 테스트중 | 0/0/0${total:+ (전체 $total)} | $dir |"
  fi
  printf '%s' "$dir"
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

# dobby_record_branch KEY REPO BRANCH [워크트리경로] — status.md '## 워크트리 / 브랜치' 표에 행을 중복 없이 남긴다.
# 대시보드 계약: parseWorktrees는 `| repo | 브랜치 | 경로 |` 표를 읽고(경로 칸 필수), 경로 실존 여부로
# 워크트리 정리(worktreeRemoved)를 판정하며 prTargets가 브랜치를 읽는다 — 경로까지 꼭 넘겨라.
dobby_record_branch() {
  local key="$1" repo="$2" branch="$3" wt="${4:-}" sf
  sf="$(_order_dir "$key")/status.md"
  [ -f "$sf" ] || return 0
  grep -qF "| $branch |" "$sf" && return 0
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
  if git -C "$src" show-ref --verify --quiet "refs/heads/$base"; then
    git -C "$src" worktree add -b "$branch" "$wt" "$base" >&2 || { _die "worktree add 실패($base)"; return 1; }
  else
    git -C "$src" fetch origin "$base" >&2 2>/dev/null || true
    git -C "$src" worktree add -b "$branch" "$wt" "origin/$base" >&2 || { _die "worktree add 실패(origin/$base)"; return 1; }
  fi
  git -C "$wt" push -u origin "$branch" >&2 2>/dev/null || true
  dobby_record_branch "$key" "$repo" "$branch" "$wt"
  printf '%s' "$wt"
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
- **근거**: (리뷰 클린·테스트 결과·통합 브랜치)
- **비고**: 워크트리·메타 유지. 추가 수정 시 dobby-order P8 재개.
EOF
  dobby_event "$key" "해결 표시 — status 해결"
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

# dobby_scaffold_doc KEY analysis|implementation|produce [슬러그] — 요약 문서에 고정 섹션 틀을
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
    *) _die "dobby_scaffold_doc: 알 수 없는 종류 '$type' (analysis|implementation|produce)"; return 2 ;;
  esac
}

# dobby_card KEY FILE "제목행" "본문" — 카드형 문서(decisions.md·side-effects.md·test-guide.md)에
# `## 제목행` 블록을 앞뒤 빈 줄과 함께 append한다(읽기 없이). 대시보드가 `## ` 단위로 카드를
# 쪼개므로 이 경계만 지키면 카드가 안 깨진다. 본문의 필드 라벨은 자유(파서가 요구하지 않음).
dobby_card() {
  local key="$1" file="$2" header="$3" body="$4"
  dobby_append "$key" "$file" "$(printf '\n## %s\n\n%s\n' "$header" "$body")"
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
         | ((((($r.history // {})[$s] // []) | last | .text?) // $r.board[$s].text // "") ) as $t
         | $s + "\t" + $t' "$f" 2>/dev/null
}

# dobby_quips_merge KEY 새소감JSON파일 — 새 소감(대상 슬러그만 담김)을 기존 {키}.json에 병합하고
# board 소감을 history에 append한 뒤 원자적으로(tmp→rename) 저장한다. 다른 슬러그의 기존 값은 보존.
# 새 파일 스키마: { "agents":{슬러그:{sig}}, "board":{...}, "changes":{...}, "reviews":{...} } (있는 것만).
# history 항목의 state는 agents[슬러그].sig의 `#` 앞부분에서 얻는다. 시각은 DOBBY_ISO로 덮어쓰기 가능.
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
        .[$s] = ((.[$s] // []) + [{
          at: $at,
          state: (((($n.agents // {})[$s].sig) // "") | split("#")[0]),
          mood: $n.board[$s].mood,
          text: $n.board[$s].text }])))
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
    ph="$(grep -cE '^\((원인 위치|실제 실행되는 코드 경로 증명|어디를 어떻게)' "$f2" 2>/dev/null)" || ph=0
    [ "${ph:-0}" -gt 0 ] 2>/dev/null && _w "$(basename "$f2") 틀 자리표시 ${ph}곳이 안 채워짐 — 헤더 아래 내용을 채우세요"
  done < <(find "$dir" -maxdepth 1 -type f \( -name 'analysis*.md' -o -name 'implementation*.md' -o -name 'produce*.md' \) 2>/dev/null)

  printf '(치명 %d, 경고 %d)\n' "$e" "$w"
  [ -n "$strict" ] && return "$e"
  return 0
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

# dobby_set_session KEY [CWD] — status.md '## 세션'에 세션 ID·경로 기록(대시보드 '이어가기'의 근거).
# 세션 ID는 손으로 적지 않는다 — cwd로 전사 파일명을 계산한다(스킬 여러 곳의 복붙을 이 함수로 대체).
dobby_set_session() {
  local key="$1" cwd="${2:-$(pwd)}" f enc sid
  f="$(_order_dir "$key")/status.md"; [ -f "$f" ] || return 1
  enc="$(printf '%s' "$cwd" | sed 's#[/.]#-#g')"          # 인코딩cwd: '/'·'.' → '-'
  sid="$(basename "$(ls -t "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null | head -1)" .jsonl 2>/dev/null)"
  [ -n "$sid" ] || { printf 'dobby-lib: 세션 전사 못 찾음(%s) — 세션 기록 건너뜀\n' "$enc" >&2; return 0; }
  grep -q '^## 세션' "$f" && return 0                     # 이미 있으면 유지(비파괴)
  cat >> "$f" <<EOF

## 세션
- **세션 ID**: $sid
- **작업 경로**: $cwd
EOF
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
  local enc tr
  enc="$(printf '%s' "$cwd" | sed 's#[/.]#-#g')"
  tr="$(ls -t "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null | head -1)"
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

echo "dobby-lib loaded" >&2
