#!/usr/bin/env bash
# 오케스트레이션 메타($ORCHESTRATION_META/{키}/) 텍스트 백업.
#
# 왜: 메타에는 종료된 작업의 유일한 코드 기록(code-changes/*.diff)과 분석·리뷰·회고가 들어 있다.
#     워크트리를 지운 뒤에는 이 폴더가 사라지면 되돌릴 방법이 없다.
# 언제: 해결 처리 시점(dobby_resolve가 분리 실행으로 호출) + 사용자가 --all 로 일괄.
# 무엇: 폴더의 텍스트 전부. 이미지는 담지 않는다 — 테스트·확인용이라 데이터로 쓰이지 않고,
#       이미 압축된 형식이라 zstd로 줄지도 않는다(실측 1.05배). 제외 목록은 exclude.txt에 있고
#       사용자가 고칠 수 있다(있으면 덮어쓰지 않는다).
# 어디: $ORCHESTRATION_BACKUP_DIR (기본 ~/claude-projects-backup/orchestration)
#       — 클로드 세션 전사 백업과 같은 폴더의 하위 한 단계. 상위 스크립트는 -maxdepth 1 로만
#       훑으므로 서로 간섭하지 않는다.
# 파일명: {폴더이름}--{YYYYMMDD-HHMMSS}.tar.zst  (키에 하이픈이 있어 구분자는 '--')
# 교체: 새로 만들어 검증까지 통과한 뒤에야 같은 키의 이전 아카이브를 지운다(먼저 지우지 않는다).
# 원본: 읽기만 한다. 원본에 쓰거나 지우는 동작은 없다.
#
# 사용법:
#   dobby-meta-backup.sh {키}                # 한 폴더 (해결 시점 스냅샷)
#   dobby-meta-backup.sh --all               # 메타 전체 훑기(이미 최신인 폴더는 건너뜀)
#   dobby-meta-backup.sh --inprogress [am|pm]  # 작업중인 폴더들을 한 덩이로(임시 보관)
#   DOBBY_META_BACKUP=0 …                    # 아무것도 하지 않고 종료(테스트·복구용)
set -eu

[ "${DOBBY_META_BACKUP:-1}" = "1" ] || exit 0

# ── 설정 로드 (읽기 전용) ─────────────────────────────────────────────
CFG="$HOME/.config/go-dobby/config.env"
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi
: "${ORCHESTRATION_WORKSPACE:=$HOME/work/dobby-workspace}"
META="${ORCHESTRATION_META:-${ORCHESTRATION_META_PATH:-$ORCHESTRATION_WORKSPACE/meta}}"
DEST="${ORCHESTRATION_BACKUP_DIR:-$HOME/claude-projects-backup/orchestration}"

[ -d "$META" ] || { printf 'dobby-meta-backup: 메타 폴더가 없습니다: %s\n' "$META" >&2; exit 1; }
mkdir -p "$DEST/tmp"

LOG="$DEST/backup-log.txt"
EXCLUDE="$DEST/exclude.txt"

# 진행중(작업중) 백업 — 폴더별로 나누지 않고 한 덩이로 모아 임시 보관한다.
# 해결 전에는 폴더별 아카이브가 갱신되지 않아(해결 시점에만 만든다) 그 사이 변경이 무방비다.
INP_DIR="$DEST/inprogress"
INP_LOG="$INP_DIR/inprogress-log.txt"
INP_KEEP_DAYS="${ORCHESTRATION_BACKUP_KEEP_DAYS:-14}"

# 잠금 정리는 트랩 한 개로 모은다. 함수마다 trap을 걸면 나중에 건 것이 앞의 것을 덮어써
# (bash의 EXIT 트랩은 하나뿐) 비정상 종료 시 락이 남는다. 키는 아래 _valid_key 를 통과한
# 것만 락을 만들므로 공백이 없다 — 공백 구분 목록으로 안전하다.
_LOCKS=""
_lock_add()   { _LOCKS="$_LOCKS $1"; printf '%s' "$(date +%s)" > "$1"; }
_lock_drop()  { rm -f "$1"; _LOCKS="${_LOCKS// $1/}"; }
_locks_clean() { local l; for l in $_LOCKS; do rm -f "$l"; done; }
trap _locks_clean EXIT

# 제외 목록 — 없을 때만 만든다(사용자가 고친 내용을 덮어쓰지 않는다).
if [ ! -f "$EXCLUDE" ]; then
  cat > "$EXCLUDE" <<'EOF'
# 오케스트레이션 메타 백업 제외 목록 (tar --exclude-from)
# 이미지: 테스트·확인용이라 데이터로 쓰이지 않고, 이미 압축돼 있어 압축 이득도 없다.
*.png
*.jpeg
*.jpg
*.gif
*.webp
*.bin
# 임시·백업 부스러기
.write-probe.txt
*.tmp
*.bak
*.new
*.backup
*.backup-*
EOF
fi

# 압축기: zstd 없으면 gzip으로 내려간다(파일명·복원 방식은 그대로).
if command -v zstd >/dev/null 2>&1; then
  EXT="tar.zst"
  _compress()   { zstd -q -19 -T0 --long=27 -o "$1" -f; }
  _verify()     { zstd -t "$1" >/dev/null 2>&1; }
  _decompress() { zstd -dc "$1"; }
else
  EXT="tar.gz"
  _compress()   { gzip -9 -c > "$1"; }
  _verify()     { gzip -t "$1" >/dev/null 2>&1; }
  _decompress() { gzip -dc "$1"; }
fi

# tar 구조 검사·목록은 반드시 "풀어서 파이프로" 넘긴다.
#   `tar -tf 파일.tar.zst` 를 직접 쓰면 안 된다 — macOS bsdtar 는 압축 해제를 위해 zstd 를
#   자식 프로세스로 띄우는데, 아카이브 끝(0블록)에서 tar 가 먼저 파이프를 닫으면 자식이
#   SIGPIPE 로 죽어 "Child process exited with status 1" 를 뱉는다. 같은 파일로 3번 돌려
#   1/0/1 로 갈리는 것을 확인했다(파일 자체는 정상 — zstd -t 통과, 파이프 경유 해제 정상).
#   아래처럼 마지막 명령이 tar 면 종료코드가 tar 것이라 이 경쟁 자체가 사라진다.
_tar_list() { _decompress "$1" 2>/dev/null | tar -tf -; }

_now()  { date '+%Y-%m-%d %H:%M:%S'; }
_stamp() { date '+%Y%m%d-%H%M%S'; }
_hsize() { # 바이트 → 사람이 읽는 크기
  awk -v n="$1" 'BEGIN{
    split("B K M G",u," "); i=1
    while (n>=1024 && i<4) { n/=1024; i++ }
    printf (i==1 ? "%d%s" : "%.1f%s"), n, u[i]
  }'
}

# 폴더 이름이 오더 키 형식인지 — 그대로 파일명이 되므로 검증한다.
# 실제로 이벤트 메시지가 키 자리에 들어가 공백 든 폴더가 생긴 사례가 있다.
_valid_key() {
  case "$1" in
    TASK-*) printf '%s' "$1" | grep -qE '^TASK-[A-Za-z0-9._-]+$' ;;
    *)      printf '%s' "$1" | grep -qE '^[A-Z][A-Za-z0-9]*-[0-9]+(-[A-Za-z0-9]+)*$' ;;
  esac
}

# 같은 키의 최신 아카이브 경로(없으면 빈 문자열).
_latest_archive() {
  ls -1t "$DEST/$1--"*.tar.* 2>/dev/null | head -1 || true
}

# ── 한 폴더 백업 ──────────────────────────────────────────────────────
# 반환: 0=백업함 1=건너뜀 2=실패
backup_one() {
  local key="$1" quiet="${2:-}" dir lock stamp tmp out latest
  dir="$META/$key"

  [ -d "$dir" ] || { [ -n "$quiet" ] || printf '⏭  없는 폴더: %s\n' "$key"; return 1; }

  if ! _valid_key "$key"; then
    printf '%s | ⏭ 건너뜀(키 형식 아님) | %s\n' "$(_now)" "$key" >> "$LOG"
    [ -n "$quiet" ] || printf '⏭  건너뜀(키 형식 아님): %s\n' "$key"
    return 1
  fi

  if [ -z "$(find "$dir" -type f -print -quit 2>/dev/null)" ]; then
    [ -n "$quiet" ] || printf '⏭  건너뜀(빈 폴더): %s\n' "$key"
    return 1
  fi

  # 진행 중이면 겹쳐 돌리지 않는다(10분 지난 락은 죽은 것으로 본다 — 상위 백업과 같은 규약).
  lock="$DEST/.lock-$key"
  if [ -f "$lock" ]; then
    local age
    age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 600 ]; then
      [ -n "$quiet" ] || printf '⏭  건너뜀(이미 진행 중): %s\n' "$key"
      return 1
    fi
  fi
  _lock_add "$lock"

  latest="$(_latest_archive "$key")"
  # 최신 아카이브 이후 바뀐 텍스트가 없으면 다시 만들 이유가 없다.
  if [ -n "$latest" ] && [ -z "$(find "$dir" -type f -newer "$latest" \
        ! -name '*.png' ! -name '*.jpeg' ! -name '*.jpg' ! -name '*.gif' \
        ! -name '*.webp' ! -name '*.bin' -print -quit 2>/dev/null)" ]; then
    _lock_drop "$lock"
    [ -n "$quiet" ] || printf '⏭  건너뜀(변경 없음): %s\n' "$key"
    return 1
  fi

  # 담을 대상: 오더 폴더 + 그 키의 부속물(잡 로그·소감). 경로는 메타 루트 기준 상대경로라
  # 복원 시 `tar -xf … -C $ORCHESTRATION_META` 로 제자리에 그대로 들어간다.
  local targets=( "$key" ) j
  for j in "$META/.mentis-jobs/"*"-$key"; do
    [ -d "$j" ] && targets+=( ".mentis-jobs/$(basename "$j")" )
  done
  [ -f "$META/.mentis-quips/$key.json" ] && targets+=( ".mentis-quips/$key.json" )

  stamp="$(_stamp)"
  tmp="$DEST/tmp/$key--$stamp.$EXT.part"
  out="$DEST/$key--$stamp.$EXT"

  local raw files
  raw=$(tar -cf - -C "$META" --exclude-from="$EXCLUDE" "${targets[@]}" 2>/dev/null | wc -c | tr -d ' ')
  if ! tar -cf - -C "$META" --exclude-from="$EXCLUDE" "${targets[@]}" 2>/dev/null | _compress "$tmp"; then
    rm -f "$tmp"; _lock_drop "$lock"
    printf '%s | ❌ 실패(압축) | %s\n' "$(_now)" "$key" >> "$LOG"
    printf '❌ 압축 실패: %s\n' "$key" >&2
    return 2
  fi

  # 검증을 통과하지 못하면 이전 아카이브를 그대로 둔 채 끝낸다.
  if ! _verify "$tmp" || ! _tar_list "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; _lock_drop "$lock"
    printf '%s | ❌ 실패(검증) | %s\n' "$(_now)" "$key" >> "$LOG"
    printf '❌ 검증 실패, 이전 백업 유지: %s\n' "$key" >&2
    return 2
  fi

  files=$(_tar_list "$tmp" 2>/dev/null | grep -vc '/$' || true)
  mv "$tmp" "$out"

  local size ratio
  size=$(stat -f %z "$out")
  ratio=$(awk -v r="$raw" -v c="$size" 'BEGIN{ printf "%.1f", (c>0? r/c : 0) }')
  printf '%s | %s | %5s files | %6s → %6s (%sx) | %s\n' \
    "$(_now)" "$key" "$files" "$(_hsize "$raw")" "$(_hsize "$size")" "$ratio" "$(basename "$out")" >> "$LOG"

  # 교체: 검증까지 끝난 뒤에만 같은 키의 이전 아카이브를 지운다.
  local old
  for old in "$DEST/$key--"*.tar.*; do
    [ -f "$old" ] || continue
    [ "$old" = "$out" ] && continue
    rm -f "$old"
    printf '%s | ↳ 교체: %s 삭제\n' "$(_now)" "$(basename "$old")" >> "$LOG"
  done

  _lock_drop "$lock"
  [ -n "$quiet" ] || printf '✅ %s — %s개 파일, %s → %s (%s배)\n' \
    "$key" "$files" "$(_hsize "$raw")" "$(_hsize "$size")" "$ratio"
  return 0
}

# ── 전체 훑기 ─────────────────────────────────────────────────────────
backup_all() {
  local done_n=0 skip_n=0 fail_n=0 d key rc alllock="$DEST/.lock-__all__"
  # 전체 훑기 동안 유지되는 락 — 폴더별 락은 폴더마다 생겼다 사라져서, 대시보드가 진행 중을
  # 놓치고 "끝났다"고 판단한다. 훑기 자체의 락을 따로 둔다.
  _lock_add "$alllock"
  printf '오케스트레이션 메타 백업 — 전체 훑기\n  원본: %s\n  저장: %s\n\n' "$META" "$DEST"
  while IFS= read -r d; do
    key="$(basename "$d")"
    set +e
    backup_one "$key"
    rc=$?
    set -e
    case "$rc" in
      0) done_n=$((done_n+1)) ;;
      1) skip_n=$((skip_n+1)) ;;
      *) fail_n=$((fail_n+1)) ;;
    esac
  done < <(find "$META" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)

  local total
  total=$(find "$DEST" -maxdepth 1 -type f -name '*.tar.*' -exec stat -f %z {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')
  _lock_drop "$alllock"
  printf '\n완료 — 백업 %d개 · 건너뜀 %d개 · 실패 %d개 · 아카이브 총 %d개 %s\n' \
    "$done_n" "$skip_n" "$fail_n" \
    "$(find "$DEST" -maxdepth 1 -type f -name '*.tar.*' | wc -l | tr -d ' ')" \
    "$(_hsize "$total")"
  [ "$fail_n" -eq 0 ]
}

# ── 진행중(작업중) 폴더 한 덩이 백업 ────────────────────────────────
# 대상: status.md 가 있고 단계가 해결·종료가 아닌 폴더.
#   · 해결·종료된 것은 폴더별 아카이브가 이미 확정돼 있어 뺀다.
#   · status.md 가 없는 폴더(대부분 종료 서머리만 남은 기록물)도 뺀다 — 더 변하지 않는다.
#   · 정본 8단계에 없는 값(완료·보류 등)은 해결·종료가 아니므로 담는다. 임시 백업이라
#     애매한 것은 넉넉히 담는 편이 안전하다.
_inprogress_keys() {
  local d k p
  while IFS= read -r d; do
    k="$(basename "$d")"
    _valid_key "$k" || continue
    [ -f "$META/$k/status.md" ] || continue
    p="$(grep -m1 -oE '^- \*\*단계\*\*: *.*' "$META/$k/status.md" 2>/dev/null \
         | sed -E 's/^- \*\*단계\*\*: *//; s/[[:space:]]*$//')"
    case "$p" in 해결|종료) continue ;; esac
    printf '%s\n' "$k"
  done < <(find "$META" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
}

# 지금 시각의 회차 — 오전(10시 이후) / 오후(15시 이후). 10시 전이면 빈 문자열.
# 15시 이후에 그날 처음 돌면 오후 회차 하나만 만든다(오전은 그날 건너뛴 것으로 둔다).
_inprogress_slot() {
  local h; h=$(date '+%H'); h=${h#0}
  if [ "$h" -ge 15 ]; then printf 'pm'
  elif [ "$h" -ge 10 ]; then printf 'am'
  fi
}

# 반환: 0=백업함 1=건너뜀 2=실패
backup_inprogress() {
  local slot="${1:-}" day out lock keys n raw files size ratio
  [ -n "$slot" ] || slot="$(_inprogress_slot)"
  if [ -z "$slot" ]; then
    printf '⏭  아직 회차 시각이 아닙니다(오전 10시 이후 · 오후 3시 이후)\n'
    return 1
  fi
  case "$slot" in am|pm) ;; *) printf '회차는 am 또는 pm 입니다: %s\n' "$slot" >&2; return 2 ;; esac

  mkdir -p "$INP_DIR"
  day="$(date '+%Y%m%d')"
  out="$INP_DIR/inprogress-$day-$slot.$EXT"
  if [ -f "$out" ]; then
    printf '⏭  이미 있습니다: %s\n' "$(basename "$out")"
    return 1
  fi

  lock="$DEST/.lock-__inprogress__"
  if [ -f "$lock" ] && [ $(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) )) -lt 600 ]; then
    printf '⏭  이미 진행 중\n'
    return 1
  fi
  _lock_add "$lock"

  keys="$(_inprogress_keys)"
  n=$(printf '%s' "$keys" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    _lock_drop "$lock"
    printf '⏭  작업중인 폴더가 없습니다\n'
    return 1
  fi

  local tmp="$INP_DIR/../tmp/inprogress-$day-$slot.$EXT.part"
  # shellcheck disable=SC2086
  raw=$(tar -cf - -C "$META" --exclude-from="$EXCLUDE" $keys 2>/dev/null | wc -c | tr -d ' ')
  # shellcheck disable=SC2086
  if ! tar -cf - -C "$META" --exclude-from="$EXCLUDE" $keys 2>/dev/null | _compress "$tmp"; then
    rm -f "$tmp"; _lock_drop "$lock"
    printf '%s | ❌ 실패(압축) | %s-%s\n' "$(_now)" "$day" "$slot" >> "$INP_LOG"
    printf '❌ 압축 실패\n' >&2
    return 2
  fi
  if ! _verify "$tmp" || ! _tar_list "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; _lock_drop "$lock"
    printf '%s | ❌ 실패(검증) | %s-%s\n' "$(_now)" "$day" "$slot" >> "$INP_LOG"
    printf '❌ 검증 실패\n' >&2
    return 2
  fi
  files=$(_tar_list "$tmp" 2>/dev/null | grep -vc '/$' || true)
  mv "$tmp" "$out"

  size=$(stat -f %z "$out")
  ratio=$(awk -v r="$raw" -v c="$size" 'BEGIN{ printf "%.1f", (c>0? r/c : 0) }')
  printf '%s | %s-%s | %3s orders | %5s files | %6s → %6s (%sx) | %s\n' \
    "$(_now)" "$day" "$slot" "$n" "$files" "$(_hsize "$raw")" "$(_hsize "$size")" "$ratio" \
    "$(basename "$out")" >> "$INP_LOG"

  # 보관 정리: 파일명 날짜가 보관 기간보다 이전이면 지운다(검증 통과 뒤에만).
  local cutoff f fday
  cutoff="$(date -v-"${INP_KEEP_DAYS}"d '+%Y%m%d' 2>/dev/null || echo '')"
  if [ -n "$cutoff" ]; then
    for f in "$INP_DIR"/inprogress-*.tar.*; do
      [ -f "$f" ] || continue
      fday="$(basename "$f" | sed -E 's/^inprogress-([0-9]{8})-.*/\1/')"
      case "$fday" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
      if [ "$fday" -lt "$cutoff" ]; then
        rm -f "$f"
        printf '%s | ↳ 보관기간(%s일) 초과 삭제: %s\n' "$(_now)" "$INP_KEEP_DAYS" "$(basename "$f")" >> "$INP_LOG"
      fi
    done
  fi

  _lock_drop "$lock"
  printf '✅ 진행중 %s-%s — 폴더 %s개, %s개 파일, %s → %s (%s배)\n' \
    "$day" "$slot" "$n" "$files" "$(_hsize "$raw")" "$(_hsize "$size")" "$ratio"
  return 0
}

case "${1:-}" in
  --all|-a) backup_all ;;
  --inprogress|-i) backup_inprogress "${2:-}" ;;
  ''|-h|--help)
    printf '사용법: %s {키}   |   %s --all   |   %s --inprogress [am|pm]\n' \
      "$(basename "$0")" "$(basename "$0")" "$(basename "$0")"
    exit 2 ;;
  *) backup_one "$1" ;;
esac
