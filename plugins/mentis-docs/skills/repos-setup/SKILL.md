---
name: repos-setup
description: 레포 git 주소 명세서(REPOS_MANIFEST, 기본 ~/work/repos/REPOS.md)를 읽어 로컬 작업 폴더 구조를 구성하는 스킬. 명세서의 각 레포에 대해 폴더가 없으면 git clone, 이미 있으면 git pull --ff-only 를 수행한다. 성공은 조용히 넘기고 실패만 로그 파일(.repos-setup-failures.log)에 기록해 토큰 소모를 최소화하며, 마지막에 clone/pull/실패 개수 요약 한두 줄만 보고한다. 문서 분석·갱신은 하지 않는다(그건 docs-sync 담당). 원본 소스는 pull/clone 외에 수정하지 않는다. 사용법 /repos-setup (특정 레포만 /repos-setup app-api wadiz-frontend, pull 생략 clone만 /repos-setup clone-only).
---

# repos-setup

레포 **git 주소 명세서**를 읽어 로컬 `~/work/repos` 구조를 구성하는 스킬. **없으면 clone, 있으면 pull**, **실패만 기록**한다. 문서 분석·갱신은 하지 않는다(그건 `docs-sync`).

> 핵심 원칙 (토큰 최소화)
> - 성공은 **출력 없이 패스**, 실패만 파일에 기록한다. 모델에는 **요약 한두 줄**만 돌아오게 한다.
> - 한 번의 bash 실행 안에서 루프를 모두 돌린다(레포마다 도구 호출을 나누지 않는다).
> - 토큰은 레포 수가 아니라 **실패 개수**에 비례한다.

## 설정 (첫 실행 시)
작업 시작 전 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 따른다**: `~/.config/mentis-docs/config.env`를 source. 필요한 값은 `DOCS_REPOS_ROOT`(구성 대상 루트)와 `REPOS_MANIFEST`(명세서 경로).

## 사용법
- `/repos-setup` — 명세서 전체를 대상으로 없으면 clone, 있으면 pull.
- `/repos-setup {폴더...}` — 명세서 중 지정한 폴더만.
- `/repos-setup clone-only` — 없는 것만 clone(기존 폴더 pull 생략).
- `/repos-setup pull-only` — 기존 폴더 pull만(없는 것 clone 생략).

## 명세서 형식 (REPOS_MANIFEST)
`~/work/repos/REPOS.md`의 마크다운 표. `Git 주소` 칸에 `github.com`이 포함된 행만 대상이며, `| 폴더 | Git 주소 | Org |` 순서다. 헤더/구분선은 url 필터로 자동 제외된다.

## 절차 (단일 스크립트로 실행 — 성공 침묵/실패만 로깅)

아래를 **한 번의 bash 실행**으로 돌린다. 인자(대상 폴더 목록·모드)는 실행 전에 셸 변수로 넣는다.

```bash
[ -f ~/.config/mentis-docs/config.env ] && source ~/.config/mentis-docs/config.env
ROOT="${DOCS_REPOS_ROOT:-$HOME/work/repos}"
MANIFEST="${REPOS_MANIFEST:-$ROOT/REPOS.md}"
FAIL="$ROOT/.repos-setup-failures.log"
MODE="both"          # both | clone-only | pull-only  (사용자 인자에 따라 설정)
ONLY=""              # 공백 구분 폴더 목록(지정 시 그 폴더만). 예: ONLY="app-api wadiz-frontend"
: > "$FAIL"
cloned=0; pulled=0; failed=0; skipped=0

[ -f "$MANIFEST" ] || { echo "명세서 없음: $MANIFEST"; exit 1; }

# 명세서에서 (폴더 URL) 추출: github.com 포함 행만, '|' 구분 2·3번째 칸
awk -F'|' 'NF>=4 && $3 ~ /github\.com/ {
  f=$2; u=$3; gsub(/^[ \t]+|[ \t]+$/,"",f); gsub(/^[ \t]+|[ \t]+$/,"",u); print f"\t"u
}' "$MANIFEST" | while IFS=$'\t' read -r folder url; do
  [ -n "$folder" ] && [ -n "$url" ] || continue
  if [ -n "$ONLY" ] && ! printf '%s\n' $ONLY | grep -qx "$folder"; then continue; fi
  dest="$ROOT/$folder"
  if [ -d "$dest/.git" ]; then
    [ "$MODE" = "clone-only" ] && { skipped=$((skipped+1)); continue; }
    if git -C "$dest" pull --ff-only --quiet >/dev/null 2>>"$FAIL"; then
      pulled=$((pulled+1))
    else
      failed=$((failed+1)); echo "PULL FAIL: $folder" >> "$FAIL"
    fi
  elif [ -e "$dest" ]; then
    failed=$((failed+1)); echo "SKIP(폴더 존재하나 git 아님): $folder" >> "$FAIL"
  else
    [ "$MODE" = "pull-only" ] && { skipped=$((skipped+1)); continue; }
    if git clone --quiet "$url" "$dest" 2>>"$FAIL"; then
      cloned=$((cloned+1))
    else
      failed=$((failed+1)); echo "CLONE FAIL: $folder ($url)" >> "$FAIL"
    fi
  fi
  # 카운터는 서브셸(while) 안이라 아래에서 재집계
done

# while 이 파이프 서브셸이라 카운터가 사라지므로, 결과는 로그·폴더 상태로 재집계해 요약한다.
echo "repos-setup 완료 — 실패 $(grep -c 'FAIL\|SKIP' "$FAIL") 건${_x:+}"
```

> 위 `while`은 파이프 서브셸이라 카운터 변수가 상위로 안 넘어온다. **성공 개수까지 정확히 세려면** 파이프 대신 프로세스 치환을 쓴다:
> `while ...; do ...; done < <(awk ... "$MANIFEST")` — 이러면 `cloned/pulled/failed/skipped` 가 유지되어 `echo "clone $cloned, pull $pulled, 실패 $failed, 스킵 $skipped${failed:+ (상세: $FAIL)}"` 한 줄로 보고할 수 있다. 구현 시 이 형태를 쓴다.

### 모드/인자 매핑
- `clone-only` → `MODE=clone-only`, `pull-only` → `MODE=pull-only`, 그 외 → `both`.
- 폴더 인자들 → `ONLY="app-api wadiz-frontend"` 처럼 설정.

## 보고 (모델이 받는 것 = 요약만)
- 정상: `clone N, pull M, 실패 0` 한 줄.
- 실패가 있을 때만 `$FAIL`(= `$ROOT/.repos-setup-failures.log`)을 읽어 실패 레포·사유를 표로 정리해 보고한다. 성공분은 읽지 않는다.
- 필요 시 "명세서에 있으나 로컬에 없던 → clone함 / 로컬에 있으나 명세서에 없는 폴더(고아)"를 덧붙일 수 있다(고아 점검은 선택).

## 주의
- pull은 `--ff-only`. 로컬 커밋·충돌이 있는 레포는 자동 병합하지 않고 실패로 로깅(데이터 보호).
- clone은 https 주소를 쓴다. 인증이 필요하면 git credential helper가 설정돼 있어야 한다(없으면 해당 레포는 실패로 남고 사용자에게 안내).
- `.repos-setup-failures.log`는 `$DOCS_REPOS_ROOT` 루트에 생긴다. repos 저장소 `.gitignore`가 루트를 무시하므로 커밋되지 않는다(의도된 동작).
- 이 스킬은 **소스를 clone/pull 외에 수정하지 않는다.** 문서 갱신이 필요하면 이어서 `docs-sync`를 쓴다.
