---
name: dobby-end
description: 사용자가 직접 실행하는 워크트리 정리 스킬. $DOBBY_WORKSPACE/subtree/ 의 이슈 워크트리들을 스캔해, 상태가 "해결"이고 미푸시 커밋이 없는 것만 골라 제거 전 코드 변경을 code-changes/에 스냅샷으로 남긴 뒤 git worktree remove로 안전하게 제거하고(브랜치는 보존) summary.md에 종료 서머리를 남긴다. 메타 폴더($DOBBY_META/{키}/)는 삭제하지 않고 보존한다. subtree 밖 폴더는 절대 건드리지 않는다. dobby-resolve로 해결 표시된 뒤 실제 코드 폴더를 정리할 때 쓴다. 사용법 /dobby-end (전체) 또는 /dobby-end {키} (특정 이슈만).
---

# dobby-end

`dobby-order`로 만든 이슈 워크트리(`$DOBBY_WORKSPACE/subtree/` 안의 폴더들)를 정리하는 스킬. **`해결` 상태이고 미푸시 커밋이 없는** 워크트리만 찾아 안전하게 제거한다. 파괴적 단계이므로 **사용자가 직접 실행**한다.

> `git worktree remove`로 제거해도 **브랜치는 보존**된다. 메타 폴더(`$DOBBY_META/{키}/`)도 **삭제하지 않는다**(생명주기 원본 기록). 지우는 것은 워크트리(코드 폴더)뿐이다.

## 설정 (첫 실행 시 확인)

작업을 시작하기 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다**: `~/.config/work-dobby/config.env`를 source 해 환경 변수를 불러오고, **이미 값이 있는 변수는 묻지 않고** 빠진 값만 규칙대로 채워 저장·export 한다. 메타 루트 `DOBBY_META`, 변수 목록·기본값, 폴더 배치(워크트리 `$DOBBY_WORKSPACE/subtree/` · 메타 `$DOBBY_META/`)는 모두 그 문서에 있다. 이하 메타 경로는 `$DOBBY_META` 기준.

## 입력

- `args`(선택): 키(`QA-22370`·`TASK-...`). 주면 그 이슈 폴더만 대상. 없으면 `$DOBBY_WORKSPACE/subtree/`의 모든 워크트리 대상.

## 처리 범위 (안전 경계)

- **오직 `$DOBBY_WORKSPACE/subtree/` 하위 폴더만** 다룬다. 원본 소스 repo(`$DOBBY_REPOS_ROOT/{repo}` 등)나 그 밖의 폴더는 절대 건드리지 않는다.
- **`해결` 상태가 아니거나 미푸시 커밋이 남은** 폴더는 제거하지 않는다. 미커밋(작업트리) 변경은 `해결` 이슈면 제거를 막지 않는다(제거 시 버려짐).

## 절차

### 1. subtree 스캔
- `$DOBBY_WORKSPACE/subtree/`가 없으면 "정리할 워크트리 없음"으로 종료.
- 각 폴더명에서 **키**를 추출(`{repo}-{키}`, 키는 `[A-Z]+-[0-9]+` 또는 `TASK-...`). 못 뽑으면 "판단 불가"로 보고(자동 삭제 금지). `args`가 있으면 그 키만.

### 2. 워크트리 상태 확인 (폴더별, 사실 확인)
- 워크트리 여부·소속 원본 repo 파악(`.git` 파일의 `gitdir:`).
- 현재 브랜치: `git -C {폴더} rev-parse --abbrev-ref HEAD`
- **미커밋 변경**: `git -C {폴더} status --porcelain`
- **미푸시 커밋**: `git -C {폴더} log --oneline @{u}..`(업스트림 없으면 그 사실 기록).

### 3. 해결 상태 확인 (메타)
- 각 키의 `$DOBBY_META/{키}/status.md`를 읽어 **현재 단계가 `해결`(또는 이후)** 인지 확인한다. 이게 제거의 1차 기준이다.
- (보조) Jira 상태를 참고로 조회할 수 있으나(`statusCategory.key == "done"`), **제거 기준은 메타의 `해결` 상태 + 미푸시 커밋 없음**이다. status.md가 없거나 해결 상태가 아니면 제거하지 않고 보고.

### 4. 제거 대상 선별 + 보고
- 제거 대상 = (`해결` 상태) AND (미푸시 커밋 없음). 미커밋 변경 여부는 판정에 넣지 않는다(참고 표시).
- **표로 요약**해 보여준다: 폴더 / 해결 상태 / dirty·unpushed / 처리(제거·유지).
  - `해결`이지만 **미푸시 커밋**이 있으면 **유지**(사유 표시). 해결 아님도 유지.

### 5. 코드 변경 스냅샷 (제거 전, 필수)
- 워크트리를 지우면 변경을 못 보므로 **제거 전** 스냅샷을 남긴다.
- 저장: `$DOBBY_META/{키}/code-changes/`(없으면 `mkdir -p`). 베이스 `{base}`는 status.md의 베이스(없으면 `$DOBBY_DEFAULT_BASE`), **`origin/{base}` 우선**.
  ```bash
  git -C {워크트리} log --oneline {base}..HEAD  > $DOBBY_META/{키}/code-changes/{repo}.commits
  git -C {워크트리} diff {base}...HEAD          > $DOBBY_META/{키}/code-changes/{repo}.diff
  ```
- 변경 없으면 빈 파일 무방. 실패(ref 없음 등)면 사유를 서머리에 한 줄 남기고 계속.

### 6. 제거 실행
- `git -C {원본repo} worktree remove {폴더 절대경로}` — 폴더 삭제 + 등록정보 정리, **브랜치 보존**.
  - 미커밋 변경으로 거부되면 `해결` 이슈이므로 `--force`로 제거(미푸시 커밋이 있는 폴더는 4단계에서 이미 유지 처리됨).
- 등록정보가 깨져 실패하면 사용자 동의 후 `rm -rf` + 해당 repo에서 `git worktree prune`.

### 7. 종료 서머리 + 상태
- 제거/유지한 각 키에 `$DOBBY_META/{키}/summary.md`를 남긴다(status.md의 이슈 메타·analysis 요약을 이어받아 종료 정보 추가).
  ```markdown
  # {키} 종료 서머리
  ## 이슈/작업
  - 키 · 타입 · 제목 · (Jira URL 또는 문서 경로)
  ## 종료 처리
  - 처리 일시 · 워크트리 처리(제거/유지 사유)
  | repo | 브랜치(보존) | 경로 | 처리 |
  ## 작업 요약 (analysis.md에서 이어받음)
  - 원인 위치 · 수정 설계 요약
  ```
- `status.md`의 **현재 단계 → `종료`**로 갱신. **메타 폴더 `$DOBBY_META/{키}/`는 삭제하지 않는다**(워크트리만 제거).

### 8. 결과 정리
- 제거/유지 폴더(사유)·저장한 서머리 경로를 표로 요약하고, 남은 `$DOBBY_WORKSPACE/subtree/` 목록을 보여준다.

## 주의

- **`$DOBBY_WORKSPACE/subtree/` 밖은 절대 건드리지 않는다.** 원본 소스 repo·기타 폴더 보호.
- **메타 폴더(`$DOBBY_META/{키}/`)와 서머리는 삭제하지 않는다.** 워크트리(코드 폴더)만 제거 대상.
- 미푸시 커밋이 남은 폴더는 `해결` 상태라도 자동 삭제하지 않고 보고만 한다.
- 제거 기준은 **메타 `해결` 상태**다(Jira는 보조). `git worktree remove`는 브랜치를 지우지 않는다 — 브랜치까지 정리하려면 사용자에게 따로 확인.
- 어려운 용어를 지양한다.
