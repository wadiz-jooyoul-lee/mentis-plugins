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
}

_meta() { printf '%s' "${ORCHESTRATION_META:?ORCHESTRATION_META 미설정 — dobby_load_config 먼저}"; }
_order_dir() { printf '%s/%s' "$(_meta)" "$1"; }

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
  awk -F'|' -v OFS='|' -v slug="$slug" -v st="$st" -v rd="$rd" -v now="$now" '
    function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    {
      if ($0 ~ /^\|/ && NF>=8 && t($2)==slug) {
        old=t($5); ost=t($7)
        active=(st=="분석"||st=="구현"||st=="리뷰")
        if (active && (old=="대기"||old=="완료"||old==""||ost=="")) $7=" " now " "
        $5=" " st " "
        if (rd!="") $6=" " rd " "
        $8=" " now " "
      }
      print
    }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
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
# dobby_log KEY SLUG PATH [ROUND] — 스폰 로그 경로 기록(jq 병합).
dobby_log() {
  local key="$1" slug="$2" p="$3" rd="${4:-}"
  local f; f="$(_order_dir "$key")/agent-logs.json"
  command -v jq >/dev/null 2>&1 || { _die "jq 필요(agent-logs)"; return 1; }
  [ -f "$f" ] || echo '{}' > "$f"
  if [ -n "$rd" ]; then
    jq --arg s "$slug" --arg r "$rd" --arg p "$p" '.[$s] = ((.[$s] // {}) + {($r): $p})' "$f" > "$f.tmp"
  else
    jq --arg s "$slug" --arg p "$p" '.[$s] = $p' "$f" > "$f.tmp"
  fi
  mv "$f.tmp" "$f"
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
dobby_setup_worktree() {
  local repo="$1" key="$2" prefix="$3" base="$4"
  local src="$ORCHESTRATION_REPOS_ROOT/$repo" wt branch
  wt="$ORCHESTRATION_WORKSPACE/subtree/$repo-$key"; branch="$prefix/$key"
  [ -d "$src/.git" ] || git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || { _die "소스 repo 없음: $src"; return 1; }
  mkdir -p "$ORCHESTRATION_WORKSPACE/subtree"
  if git -C "$src" worktree list --porcelain 2>/dev/null | grep -qx "worktree $wt"; then printf '%s' "$wt"; return 0; fi
  if git -C "$src" show-ref --verify --quiet "refs/heads/$base"; then
    git -C "$src" worktree add -b "$branch" "$wt" "$base" >&2 || { _die "worktree add 실패($base)"; return 1; }
  else
    git -C "$src" fetch origin "$base" >&2 2>/dev/null || true
    git -C "$src" worktree add -b "$branch" "$wt" "origin/$base" >&2 || { _die "worktree add 실패(origin/$base)"; return 1; }
  fi
  git -C "$wt" push -u origin "$branch" >&2 2>/dev/null || true
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
      { if ($0 ~ /^\|/ && NF>=8 && t($2)!="슬러그" && t($2) !~ /^-+$/ && t($5)!="" && t($5)!="완료" && t($5)!="상태") {$5=" 완료 "; $8=" " now " "} print }
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

echo "dobby-lib loaded" >&2
