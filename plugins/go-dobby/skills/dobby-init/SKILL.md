---
name: dobby-init
description: go-dobby 환경 설정만 담당하는 스킬. `~/.config/go-dobby/config.env`를 만들거나 고치는 유일한 스킬이다(작업 스킬은 config.env를 절대 쓰지 않고 읽기만 한다). 대화형으로 각 환경 변수(메타/워크스페이스/베이스 브랜치/저장소 루트/Jira 등)의 현재값·기본값을 보여주고, 사용자가 정한 값만 저장한다. 비파괴 원칙: 이미 있는 값은 사용자가 명시적으로 바꾸지 않는 한 그대로 보존하고, 기존 키를 임의로 지우지 않는다. 다른 스킬이 "config.env가 없다"고 안내하면 이 스킬을 먼저 실행한다. 사용법 /dobby-init [reset].
---

# dobby-init

go-dobby의 **환경 설정 전용** 스킬. `~/.config/go-dobby/config.env`를 **만들거나 고치는 유일한 주체**다.

> **왜 이 스킬만 config.env를 쓰나:** 예전엔 모든 작업 스킬이 "빠진 값을 채워 저장"했는데, 헤드리스(무인) 실행 중 config.env가 재작성되며 사용자가 지정한 선택 값(예: `ORCHESTRATION_META_PATH`)이 조용히 사라지는 사고가 있었다. 그래서 **작업 스킬(dobby-order·impl·resolve 등)은 config.env를 읽기만** 하고, **설정 변경은 오직 이 스킬에서만** 한다. 변수 규격·기본값의 단일 출처는 `${CLAUDE_PLUGIN_ROOT}/reference/config.md`다.

## 입력

- `args` 없음(기본): 대화형 설정. config.env가 있으면 **현재값을 보존**하며 빠진 것만 묻고, 없으면 새로 만든다.
- `reset`: 기본값을 기준으로 처음부터 다시 확인한다(그래도 **저장은 사용자가 확인한 값만**, 기존 값은 기본 제안값으로 보여줌).

## 비파괴 원칙 (강제)

1. **기존 값 보존**: config.env에 이미 있는 값은 **사용자가 이 세션에서 명시적으로 바꾸겠다고 한 것만** 변경한다. 나머지는 **한 글자도 바꾸지 않는다.**
2. **기존 키 유지**: 설정 파일에 있던 키(선택 변수 포함)를 임의로 **삭제하지 않는다.** 특히 `ORCHESTRATION_META_PATH` 같은 선택 값은, 사용자가 "지워라"라고 하지 않는 한 그대로 다시 쓴다.
3. **모르는 키도 보존**: 표에 없는 사용자 정의 키가 파일에 있으면 그대로 둔다.

## 절차

### 1. 현재 설정 읽기
```bash
mkdir -p ~/.config/go-dobby
[ -f ~/.config/go-dobby/config.env ] && source ~/.config/go-dobby/config.env
```
- 파일이 있으면 **현재값을 표로 보여준다**(민감값은 마스킹하지 않아도 되지만 길면 축약). 없으면 "새로 설정합니다"라고 안내한다.

### 2. 변수별 확인 (대화형)
`${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 **"환경 변수" 표**를 기준으로, 각 변수를 다음과 같이 처리한다:

- **이미 값이 있는 변수**: `현재값`을 보여주고 **그대로 둘지 / 바꿀지** 묻는다. 아무 응답이 없으면 **유지**가 기본.
- **비어 있고 기본값이 있는 변수**: 기본값을 제안하고 그대로 쓸지 바꿀지 묻는다.
- **선택 변수**(`ORCHESTRATION_META_PATH`, `TEST_LOGIN_ID`/`TEST_LOGIN_PW`): 생략 시 영향(예: 메타 경로 미지정 → `$ORCHESTRATION_WORKSPACE/meta` 사용)을 설명하고 **생략을 허용**한다. 이미 값이 있으면 **보존**이 기본.

> 여러 개를 한꺼번에 물어도 되지만, **"현재값 유지"가 항상 기본 선택지**여야 한다. 사용자가 명시적으로 바꾼 것만 반영한다.

### 3. 저장 (사용자 확인 후)
- 확정된 값으로 config.env를 **다시 쓴다.** 이때 **기존 파일에 있던 모든 키를 포함**해 쓴다(1·2에서 유지하기로 한 값 + 사용자가 바꾼 값 + 원래 있던 모르는 키). 선택 변수도 값이 있으면 반드시 다시 포함한다.
- 형식(예):
  ```bash
  # go-dobby 공통 설정
  export JIRA_BASE_URL=...
  export ORCHESTRATION_WORKSPACE=...
  export ORCHESTRATION_DEFAULT_BASE=...
  export ORCHESTRATION_REPOS_ROOT=...
  export ORCHESTRATION_DOCS_ROOT=...
  export ORCHESTRATION_ENV_MAP=...
  export ORCHESTRATION_META_PATH=...   # 사용자가 지정했으면 반드시 유지
  ```
- 저장 전 **변경 요약(diff)** 을 보여주고 확인받는다: `유지 N개 / 변경 M개 / 추가 K개`. **삭제는 사용자가 명시적으로 요청한 경우에만** 표시·수행한다.

### 4. 안전 훅 등록 (settings.json)

플러그인 hooks.json의 PreToolUse command 훅은 Claude Code 버그(anthropics/claude-code#34573)로
**조용히 드랍되어 발화하지 않는다.** 그래서 go-dobby 안전 훅(G1·G5·G6 — `hooks/HOOKS.md` 참조)은
이 단계에서 **사용자 settings.json에 등록해야만 동작한다.**

1. **스크립트 복사** (플러그인 업데이트 반영은 이 스킬 재실행으로 이뤄진다):
   ```bash
   mkdir -p ~/.config/go-dobby/hooks
   cp "${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash.sh" ~/.config/go-dobby/hooks/pre-bash.sh
   ```
2. **`~/.claude/settings.json`에 등록** — 비파괴 원칙을 settings.json에도 그대로 적용한다:
   - 기존 내용(다른 훅·권한·설정)은 **한 글자도 건드리지 않고**, `hooks.PreToolUse` 배열에
     go-dobby 항목만 병합한다(jq 병합 권장).
   - go-dobby 항목의 식별 기준은 **args 경로에 `go-dobby/hooks/pre-bash.sh` 포함 여부**다.
     이미 있으면 그대로 두고(등록 완료 상태), 없을 때만 아래를 추가한다.
   - `${CLAUDE_PLUGIN_ROOT}`는 settings.json에서 치환되지 않으므로 **홈을 풀어 쓴 절대 경로**를 쓴다:
   ```json
   {
     "matcher": "Bash",
     "hooks": [
       {
         "type": "command",
         "if": "Bash(*git *)|Bash(*gh pr*)|Bash(*rm *)|Bash(*rmdir *)",
         "command": "bash",
         "args": ["/Users/{사용자}/.config/go-dobby/hooks/pre-bash.sh"],
         "timeout": 5,
         "statusMessage": "go-dobby 안전 검사"
       }
     ]
   }
   ```
   - 저장 전 `jq . ~/.claude/settings.json`으로 **파싱 확인**(스키마 오류 하나면 그 파일의 훅
     전체가 조용히 꺼진다), 변경 요약을 보여주고 확인받는다.
3. **적용 시점 안내**: settings.json 훅 변경은 **새 세션부터** 적용된다고 알린다.
4. **원복(버그가 고쳐진 뒤)**: #34573이 수정되면 플러그인 hooks.json의 훅이 그대로 살아난다.
   그때 사용자가 요청하면 settings.json의 go-dobby 항목과 `~/.config/go-dobby/hooks/` 복사본을
   제거한다(중복 발화 방지). 그 전에는 임의로 지우지 않는다.

### 5. 안내
- 저장된 최종 설정을 요약해 보여주고(메타 경로가 어디로 정해졌는지 명확히, 안전 훅 등록 여부 포함), 이제 `/dobby-order {키}` 등 작업 스킬을 실행하면 된다고 안내한다.

## 주의

- **이 스킬 밖에서는 config.env를 쓰지 않는다**(작업 스킬은 전부 읽기 전용 — config.md "설정 절차" 참조).
- **사실 기반**: 현재값·기본값을 추측하지 말고 파일·config.md 표에서 확인해 보여준다.
- 어려운 용어를 지양하고 쉬운 말로 설명한다.
