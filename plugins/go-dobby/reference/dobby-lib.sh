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
  local key="$1" title="${2:-$1}" dir; dir="$(_order_dir "$key")"
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
  local key="$1" slug="$2" name="$3" desc="$4" st="$5" rd="${6:-1}"
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
  local key="$1" slug="$2" st="$3" rd="${4:-}"
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
  local key="$1" ph="$2" f now; f="$(_order_dir "$key")/status.md"; now="$(_now)"
  [ -f "$f" ] || return 1
  awk -v ph="$ph" -v now="$now" '
    /^## / { insec = ($0 ~ /현재 단계/) }
    {
      if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*단계\*\*/) { print "- **단계**: " ph; next }
      if (insec && $0 ~ /^[ \t]*-[ \t]*\*\*갱신\*\*/) { print "- **갱신**: " now; next }
      print
    }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ── 리뷰/검증 경로 ───────────────────────────────────────────────────
# dobby_review_path KEY ROUND SLUG — reviews/round-N/{slug}.md 경로(폴더 생성) stdout.
dobby_review_path() {
  local dir; dir="$(_order_dir "$1")/reviews/round-$2"; mkdir -p "$dir"
  printf '%s/%s.md' "$dir" "$3"
}

# dobby_testrun_new KEY N — test-runs/{ts}/ + result.md 골격. 폴더 경로 stdout.
dobby_testrun_new() {
  local key="$1" n="$2" dir; dir="$(_order_dir "$key")/test-runs/$(_ts)"; mkdir -p "$dir"
  [ -f "$dir/result.md" ] || printf '# %s 테스트 결과 — 회차 %s\n\n(진행 중)\n' "$key" "$n" > "$dir/result.md"
  printf '%s' "$dir"
}

# ── 워크트리/커밋/통합 ───────────────────────────────────────────────
# dobby_setup_worktree REPO KEY PREFIX BASE — 워크트리 생성(재사용 시 그대로) + origin push. 경로 stdout.
# dobby_record_branch KEY REPO BRANCH  — status.md '## 브랜치' 섹션에 (브랜치, repo) 한 줄을 중복 없이 남긴다.
# 오케스트레이터가 status.md에 브랜치를 깜빡 안 남겨도 PR 링크·이력이 유지되게 하는 결정론 기록(대시보드 prTargets가 읽음).
dobby_record_branch() {
  local key="$1" repo="$2" branch="$3" sf
  sf="$(_order_dir "$key")/status.md"
  [ -f "$sf" ] || return 0
  grep -q '^## 브랜치' "$sf" || printf '\n## 브랜치\n' >> "$sf"
  grep -qF "$branch" "$sf" || printf -- '- %s (%s)\n' "$branch" "$repo" >> "$sf"
}

dobby_setup_worktree() {
  local repo="$1" key="$2" prefix="$3" base="$4"
  local src="$ORCHESTRATION_REPOS_ROOT/$repo" wt branch
  wt="$ORCHESTRATION_WORKSPACE/subtree/$repo-$key"; branch="$prefix/$key"
  [ -d "$src/.git" ] || git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || { _die "소스 repo 없음: $src"; return 1; }
  mkdir -p "$ORCHESTRATION_WORKSPACE/subtree"
  if git -C "$src" worktree list --porcelain 2>/dev/null | grep -qx "worktree $wt"; then dobby_record_branch "$key" "$repo" "$branch"; printf '%s' "$wt"; return 0; fi
  if git -C "$src" show-ref --verify --quiet "refs/heads/$base"; then
    git -C "$src" worktree add -b "$branch" "$wt" "$base" >&2 || { _die "worktree add 실패($base)"; return 1; }
  else
    git -C "$src" fetch origin "$base" >&2 2>/dev/null || true
    git -C "$src" worktree add -b "$branch" "$wt" "origin/$base" >&2 || { _die "worktree add 실패(origin/$base)"; return 1; }
  fi
  git -C "$wt" push -u origin "$branch" >&2 2>/dev/null || true
  dobby_record_branch "$key" "$repo" "$branch"
  printf '%s' "$wt"
}

# dobby_commit_push WORKTREE BRANCH MSG — 리뷰 통과 후 커밋(--no-verify)·푸시.
dobby_commit_push() {
  local wt="$1" br="$2" msg="$3"
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
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; name="$(basename "$d")"
    key="$(printf '%s' "$name" | grep -oE '[A-Z][A-Za-z0-9]*-[0-9]+|TASK-[A-Za-z0-9-]+' | tail -1)"
    printf '%s\t%s\n' "$d" "$key"
  done
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

echo "dobby-lib loaded" >&2
