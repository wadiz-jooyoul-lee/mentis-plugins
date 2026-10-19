# go-dobby 토큰 절감 설계

작성일 2026-10-19. 기준 코드는 `mentis-plugins` 의 `origin/main`(3793b2e, go-dobby 0.2.87)이다.
이 문서만 보고 구현할 수 있게 바꿀 파일, 넣을 코드, 확인 방법을 모두 적었다.

---

## 0. 왜 하는가 — 오늘 오전 분석에서 확인한 사실

오늘 오전(00시~12시) 사용량을 API 정가로 환산하면 약 $194.7 이었다.

| 항목 | 금액 | 비중 |
|---|---|---|
| 캐시 읽기 | 약 $97.8 | 50.3% |
| 캐시 쓰기 (1시간 보관) | 약 $39.4 | 20.2% |
| 캐시 쓰기 (5분 보관) | 약 $21.7 | 11.1% |
| 출력 | 약 $35.8 | 18.4% |

캐시 읽기는 "호출할 때마다 그때까지 쌓인 문맥 전체를 다시 읽는 비용"이다. 그래서 비용은 대략 **호출 수 × 문맥 크기**로 정해진다. 아래 작업은 모두 이 두 값 가운데 하나를 줄인다.

| 확인한 원인 | 근거 (실측) | 줄이는 작업 |
|---|---|---|
| 긴 세션에서 다음 일을 이어서 함 | 세션 `58312aff` 는 문맥 52만에서 릴리즈를 이어 해 1,801만 토큰을 썼다. 같은 일을 다른 세션에서 한 두 번은 각각 약 450만 | 작업 A |
| `/do` 스킬 본문이 큼 | `skills/do/SKILL.md` 하나가 약 3만 3,800 토큰. 스킬을 끈 빈 세션 전체(2만 4,280)보다 크다 | 작업 E |
| 자동 실행 세션에 쓰지 않는 MCP(외부 도구 연결)가 붙음 | 크롬 도구 하나만 남기면 첫 호출 문맥이 42,648에서 35,454로 약 7,200 줄었다 | 작업 C |
| Jira 를 MCP 로 다룸 | 상태 전환이 MCP 로는 호출 2번 약 1만 2천 자, twg 로는 1번 57자 | 작업 D |
| twg 를 옵션 없이 쓰면 결과가 큼 | 옵션 없는 `get` 25,681자, 이슈 2개 `bulk-get` 166,771자 | 작업 B |

---

## 1. 작업 목록과 순서

모두 `~/work/mentis-plugins/plugins/go-dobby/` 아래를 고친다. 아래 표의 경로는 이 폴더 기준이다.

| 순서 | 작업 | 하는 일 | 바꾸는 파일 |
|---|---|---|---|
| 1 | A. 긴 세션 입력 막기 | 문맥이 25만 토큰 넘는 세션에서 `/do`, `/dobby-*` 명령을 막는다. `/do` 가 끝난 세션에 일반 질문이 오면 경고한다 | `hooks/prompt-guard.sh`(새 파일), `hooks/hooks.json`, `hooks/HOOKS.md` |
| 2 | B. twg 과다 출력 막기 | twg 이슈 조회에 결과를 줄이는 옵션이 없으면 막는다 | `hooks/pre-bash.sh`, `hooks/hooks.json`, `skills/dobby-init/SKILL.md`, `hooks/HOOKS.md` |
| 3 | D. Jira MCP 를 twg 로 바꾸기 | 스킬 7곳과 공통 문서의 Jira 호출을 twg 명령으로 바꾼다 | `reference/jira-twg.md`(새 파일), `reference/adf-to-md.jq`(새 파일), `reference/dobby-lib.sh`, `reference/jira-start.md`, 스킬 6개, `skills/do/SKILL.md` |
| 4 | C. 자동 실행 MCP 제한 | 자동 실행 세션에 크롬 도구 MCP 하나만 붙인다. 세션 안 알림은 알림 헬퍼로 보낸다 | `skills/do/run.sh`, `skills/do/SKILL.md`, `skills/do/auto-mode.md` |
| 5 | E. `/do` 본문 나누기 | 단계별 절을 `skills/do/steps/` 의 파일로 옮긴다 | `skills/do/SKILL.md`, `skills/do/steps/*.md`(새 파일 11개) |
| 6 | 마무리 | 버전 올리기, 설계 기록 남기기 | `.claude-plugin/plugin.json`, 저장소 루트 `.claude-plugin/marketplace.json`, `skills/do/token-diet.md`(이 문서) |

**순서를 이렇게 정한 이유**

- 작업 A, B 는 다른 파일과 겹치지 않는다. 동작을 바꾸지 않고 막기만 하므로 먼저 넣어도 위험이 작다.
- 작업 B 를 작업 D 보다 먼저 넣는다. twg 로 바꾼 스킬이 옵션을 빠뜨리면 B 가 바로 잡아 준다.
- 작업 E 는 `skills/do/SKILL.md` 의 글을 다른 파일로 옮긴다. 작업 C, D 도 같은 파일을 고친다. 그래서 E 를 마지막에 한다. 먼저 하면 C, D 의 수정 위치가 여러 파일로 흩어진다.

**이번에 하지 않는 것**

| 대상 | 하지 않는 이유 |
|---|---|
| 짧은 Bash 호출 줄이기 (지난 설계의 수정안 5) | 많았던 세션은 사람과 대화한 분석 세션이었다. 작업 A 가 들어가면 상당 부분 줄어든다. 자동 실행 단계의 Bash 횟수는 아직 재지 않았다. 작업 A~E 를 넣은 뒤 다시 재고 정한다 |
| 사용자 설정의 플러그인·연결 도구 끄기 (지난 설계의 수정안 3-나) | 사용자 전체 설정이라 직접 정하실 일이다. 그리고 `--settings` 로 플러그인 6개를 꺼 봤지만 문맥이 줄지 않았다(34,884 와 34,938) |
| `~/.claude.json` 에서 mcp-atlassian 서버 지우기 | 호출마다 약 2,300 토큰이 준다. 하지만 작업 D 를 모두 넣고 한동안 써 본 뒤에 지워야 한다. 먼저 지우면 아직 안 바꾼 곳이 멈춘다 |
| `/do` 스킬 머리말(description) 줄이기 | 머리말이 길다(본문 앞 136줄이 7,794자). 하지만 스킬 목록에 어떻게 실리는지 재지 않았다. 따로 확인한 뒤 정한다 |

---

## 2. 작업 A — 긴 세션에서 go-dobby 명령 막기 (규칙 G19, G20)

### 2-1. 무엇을 막는가

| 상황 | 처리 | 규칙 |
|---|---|---|
| 입력이 `/do`, `/go-dobby:…`, `/dobby-…` 로 시작하고, 직전 응답의 문맥이 25만 토큰 이상 | **막는다.** "`/clear` 뒤 다시 입력하라"고 사람에게 보여 준다 | G19 |
| 직전 응답이 `/do` 의 세션 닫기 안내("이 세션을 닫아 주세요")였고, 입력이 `/` 로 시작하지 않는 일반 글 | **막지 않는다.** 사람에게 경고를 보이고, 모델에게 "새 세션을 권하라"는 한 줄을 더한다 | G20 |
| 그 밖 | 아무것도 하지 않는다 | — |

**기준값을 25만으로 정한 이유**: 최근 14일 세션 기록에서 go-dobby 명령을 입력한 순간 395번을 모두 집계했다.

- 새 세션도 첫 호출 문맥이 이미 중앙값 7만 2천이다. 기본 지시문, 도구 목록, 스킬 본문 때문이다. 그래서 15만은 너무 쉽게 넘는다.
- 절감의 대부분은 30만 이상에서 시작한 소수의 명령에서 나온다.

반복 실행된 `/dobby-qa` 세션(`9dcb8636`) 하나는 짧은 명령 수십 번이 막히는 횟수를 부풀리므로 빼고 셌다.

| 기준 | 막히는 명령 수 | 막아서 줄일 수 있는 양(추정) | 15만 대비 |
|---|---|---|---|
| 15만 | 37 | 23억 6천만 | 100% |
| 20만 | 31 | 21억 7천만 | 92% |
| **25만** | **26** | **20억 9천만** | **88%** |
| 30만 | 22 | 20억 | 85% |
| 40만 | 16 | 14억 4천만 | 61% |

"줄일 수 있는 양"은 (시작 문맥 − 7만 2천) × 그 명령의 호출 수를 더한 값이다. 새 세션에서 같은 일을 해도 호출 수가 같았을 것이라는 가정을 둔 **추정**이다. 25만은 15만 효과의 88%를 지키면서 막히는 횟수를 30% 줄인다. 집계는 세션 기록(`~/.claude/projects/` 의 jsonl)을 한 번 훑는 일회성 스크립트로 했다.

또 자동 실행(`run.sh`)은 직전 세션 문맥이 12만 이하일 때만 이어 쓴다(`reference/dobby-lib.sh` 2538번째 줄 `DOBBY_REUSE_MAX_CTX=120000`). 기준이 이보다 크므로 자동 실행의 이어 쓰기를 막지 않는다.

**끄는 법**: `~/.config/go-dobby/config.env` 에 `DOBBY_PROMPT_GUARD=off` 를 넣는다. 기준값은 `DOBBY_PROMPT_GUARD_CTX` 로 바꾼다.

### 2-2. 훅 형식 (Claude Code 문서로 확인)

출처는 https://code.claude.com/docs/en/hooks 의 UserPromptSubmit 절이다.

| 항목 | 문서 내용 |
|---|---|
| 입력 | 공통 필드(`session_id`, `transcript_path`, `cwd` 등)에 더해 `prompt`(입력한 글) |
| 막기 | `{"decision":"block","reason":"…"}`. `reason` 은 사람에게 보이고 모델 문맥에는 들어가지 않는다 |
| 사람에게 경고 | `systemMessage`. 다만 이 이벤트에서 화면에 보이는지는 문서에 명시가 없다. **구현 뒤 실제로 확인한다** |
| 모델에게 글 더하기 | `hookSpecificOutput.additionalContext` |
| 주의 | `transcript_path` 파일은 늦게 써질 수 있다. 그래서 읽은 문맥 값이 한 번 전 값일 수 있다. 25만 기준을 판정하는 데는 문제가 없다 |

**어디에 등록하나**: 플러그인 `hooks/hooks.json` 에 넣는다. `hooks/HOOKS.md` 의 "전달 경로" 절에 따르면 플러그인 훅 가운데 버그로 사라지는 것은 PreToolUse·PostToolUse 의 command 훅뿐이다. SessionStart 같은 나머지 훅은 정상 동작한다. UserPromptSubmit 도 여기에 해당할 것으로 보지만 **실측한 적은 없다.** 구현 뒤 확인하고, 동작하지 않으면 작업 B 처럼 `dobby-init` 이 사용자 설정에 등록하게 바꾼다.

### 2-3. 새 파일 `hooks/prompt-guard.sh`

아래 코드는 시제품으로 시험을 마쳤다(2-5 절).

```bash
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
```

**G20 판정 문구의 근거**: `skills/do/SKILL.md` 공통 규칙 "세션을 닫는 법"(828번째 줄부터)의 고정 형식에 `- 이 세션을 닫아 주세요. (/clear 또는 터미널 종료)` 줄이 있다. 작업 E 로 본문을 나눠도 이 절은 `SKILL.md` 에 남는다. 이 문구를 바꾸면 이 훅도 함께 고쳐야 한다. 그래서 그 절에 주석 한 줄을 더한다(2-4).

### 2-4. 함께 고칠 곳

**`hooks/hooks.json`** — 최상위 `hooks` 에 이벤트를 하나 더한다.

```json
"UserPromptSubmit": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash",
        "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/prompt-guard.sh"],
        "timeout": 5,
        "statusMessage": "go-dobby 입력 검사"
      }
    ]
  }
]
```

`if` 는 넣지 않는다. 문서에 따르면 `if` 는 도구 이벤트에서만 평가되고, 다른 이벤트에 `if` 가 있으면 그 훅은 **아예 실행되지 않는다.**

**`skills/do/SKILL.md` 공통 규칙 "세션을 닫는 법"** — 형식 코드 블록 바로 아래에 한 줄을 더한다.

```
`이 세션을 닫아 주세요` 문구는 바꾸지 않는다. 입력 검사 훅(`hooks/prompt-guard.sh`, G20)이 이 문구로 단계가 끝났는지 안다.
```

**`hooks/HOOKS.md` "현재 구현된 규칙" 표** — 두 행을 더한다.

```
| G19 | 문맥 25만 토큰 이상 세션에서 `/do`·`/go-dobby:*`·`/dobby-*` 시작 금지(`DOBBY_PROMPT_GUARD_CTX`, `DOBBY_PROMPT_GUARD=off` 로 끔) | UserPromptSubmit | block | 플러그인 hooks.json | do 공통 규칙 "세션을 닫는 법" |
| G20 | `/do` 세션 닫기 안내 뒤 일반 요청에 경고(막지 않음) | UserPromptSubmit | systemMessage + additionalContext | 플러그인 hooks.json | 상동 |
```

### 2-5. 시제품 시험 결과

가짜 세션 기록 파일을 만들어 넣어 봤다. 한 번 실행에 약 0.02초 걸렸다.

| 상황 | 결과 |
|---|---|
| 문맥 30만 + `/do FE1-1` | 막음 |
| 문맥 30만 + `/go-dobby:dobby-release` | 막음 |
| 문맥 30만 + 일반 질문 | 통과 |
| 문맥 20만 + `/do FE1-1` | 통과 (기준 미만) |
| 문맥 5만 + `/do FE1-1` | 통과 |
| 닫기 안내 뒤 일반 질문 | 경고 |
| 닫기 안내 뒤 `/clear` | 통과 |
| 기록 파일 없음 (새 세션) | 통과 |

### 2-6. 구현 뒤 확인

1. 위 표를 그대로 다시 돌린다.
2. 실제 세션에서 확인한다.
   - 문맥이 25만 넘는 세션에서 `/do {아무 키}` 를 입력해 막히는지 본다.
   - 닫기 안내로 끝난 `/do` 세션에서 일반 질문을 해서 경고가 화면에 보이는지 본다. 보이지 않으면 `systemMessage` 대신 막지 않는 다른 방법을 찾아야 한다.
3. `claude -p "/do {키}"` 로 자동 실행 세션이 막히지 않는지 본다. 새 세션이라 기록 파일이 없으므로 통과해야 한다.

---

## 3. 작업 B — twg 과다 출력 막기 (규칙 G18)

### 3-1. 측정값

| 명령 | 옵션 없이 | 옵션을 붙이면 |
|---|---|---|
| `jira workitem bulk-get` (이슈 2개) | **166,771자** | `--fields summary,status` 2,520자 / `-o json --output-summary` 1,797자 |
| `jira workitem query --jql …` | **54,344자** | `--limit 2` 약 2,300자 / `-o json --output-summary` 1,000자 |
| `jira workitem get --full` | **30,336자** | — |
| `jira workitem get` | **25,681자** | `--fields summary,status` 1,084자 / `--output-file` 145자 |
| `jira workitem changelog query` | 8,383자 | (막지 않음) |
| `jira workitem transitions query` | 552자 | (막지 않음) |
| `transition`, `update` | 19~57자 | (막지 않음) |

`query` 의 도움말에는 `--limit` 이 없고 `--first` 만 있다. 그래도 `--limit 2` 를 실제로 넣어 보니 이슈 2개만 나왔다. 그래서 둘 다 개수 제한으로 인정한다.

### 3-2. 판정 규칙

**대상**: 단순 명령 하나에 `twg jira workitem get`, `bulk-get`, `query` 가 있을 때만 본다.

**통과 조건** (하나라도 있으면 통과):

| 통과 조건 | 이유 |
|---|---|
| `--fields`, `--field` | 필요한 칸만 받는다 |
| `--select` | 필요한 값만 받는다 |
| `--output-file` | 결과가 파일로 간다 |
| `--output-summary` (값이 없거나 `auto`, `stats`, `inline`) | 전체는 파일로 가고 화면에는 요약만 나온다. `none` 은 원본 그대로라 인정하지 않는다 |
| 뒤에 파이프(`|`)가 있다 | `jq`, `head` 같은 뒤 프로그램이 결과를 줄인다 |
| 결과를 파일로 돌린다(`>`) | 화면에 안 나온다. 오류 출력 돌리기(`2>/dev/null`, `2>&1`)는 인정하지 않는다 |
| `query` 에 `--limit` 또는 `--first` 가 20 이하 | 받는 개수에 상한이 있다 |
| 명령에 `TWG_RAW=1` 이 있다 | 사람이 전체 결과를 원한 경우의 우회로. 기존 `DOBBY_FORCE=1` 과 같은 방식이다 |

**명령 나누기**: `;`, `&&`, `||`, 줄바꿈으로 단순 명령을 나눈다. 파이프 `|` 로는 나누지 않는다. 파이프 뒤 프로그램이 결과를 줄이는지 봐야 하기 때문이다.

### 3-3. 어디에 넣나

**기존 `hooks/pre-bash.sh` 에 규칙을 하나 더한다.** 새 스크립트를 만들지 않는 이유는 `hooks/HOOKS.md` "새 훅 추가 절차" 3번 때문이다. "기존 디스패처에 case 를 추가한다(새 스크립트·새 등록을 늘리지 않는 게 기본)"라고 정해 두었다.

`pre-bash.sh` 는 go-dobby 설정 파일(`config.env`)이 없으면 아무것도 하지 않는다. 그래서 이 규칙은 go-dobby 를 쓰는 사람에게만 적용된다. 이 컴퓨터에는 설정 파일이 있으므로 모든 프로젝트에 적용된다.

**전달 경로가 중요하다.** `hooks/HOOKS.md` 첫 절에 따르면 플러그인 `hooks.json` 의 PreToolUse 훅은 Claude Code 버그(anthropics/claude-code#34573)로 **동작하지 않는다.** 실제로는 `dobby-init` 이 스크립트를 `~/.config/go-dobby/hooks/` 로 복사하고 `~/.claude/settings.json` 에 등록한 것이 동작한다. 그래서 세 곳을 함께 고쳐야 한다.

| 파일 | 고칠 내용 |
|---|---|
| `hooks/pre-bash.sh` | G18 규칙 코드 추가 (3-4) |
| `hooks/hooks.json` | `"if": "Bash(twg *)"` 항목 추가 (버그가 고쳐지면 살아날 자리) |
| `skills/dobby-init/SKILL.md` "4. 안전 훅 등록" 의 JSON 예시 | 같은 `"if": "Bash(twg *)"` 항목 추가 (실제로 동작하는 자리) |

**`if: "Bash(twg *)"` 로 걸러도 되는 근거**: 훅 문서의 "How `if` patterns match Bash commands" 표에 이렇게 나온다.

| 명령 | `if` 일치 여부 |
|---|---|
| `FOO=bar git push` | 일치. 앞의 변수 대입은 떼고 본다. 그래서 `TWG_RAW=1 twg …` 도 훅이 실행된다 |
| `npm test && git push` | 일치. 이어 붙인 명령을 하나씩 본다 |
| 판별할 수 없는 명령 | 패턴과 상관없이 훅을 실행한다 |

`;` 로 이은 명령은 문서에 예가 없다. 그래서 구현 뒤 `S=1; twg jira workitem get X` 로 실제로 확인한다(3-7). 걸리지 않으면 `twg` 만 `if` 없이 실행하도록 바꾼다. 그 경우 모든 Bash 호출마다 스크립트가 뜨지만, 첫 줄에서 `twg` 가 없으면 바로 끝나므로 부담은 작다.

### 3-4. `hooks/pre-bash.sh` 에 넣을 코드

파일 맨 위 설명 주석의 규칙 목록에 한 줄을 더한다.

```bash
#   G18: twg Jira 조회(get·bulk-get·query)는 결과를 줄이는 옵션과 함께만 (옵션 없는 get 2만 6천 자, bulk-get 17만 자)
```

공통 함수(`deny`) 정의 뒤, `# ── G12.` 절 바로 앞에 넣었다. 규칙 사이에 일찍 끝나는 분기는 없다. 그래서 위치는 "여러 규칙에 함께 걸리면 어느 사유가 먼저 나오나"만 바꾼다. 시제품으로 시험을 마친 코드다.

```bash
# ── G18. twg Jira 조회는 결과를 줄이는 옵션과 함께 ─────────────────────
# 옵션 없는 조회는 결과가 그대로 문맥에 들어간다(실측 2026-10-19: get 25,681자, bulk-get 2건 166,771자,
# query 54,344자). 문맥에 한 번 들어간 글은 그 세션의 남은 호출마다 다시 읽힌다.
# 줄이는 옵션 하나라도 있으면 통과한다. 사람이 전체를 원했으면 TWG_RAW=1 로 우회한다.
# dobby 스코프 가드를 두지 않는다 — 어느 폴더에서 부르든 문맥 비용은 같다(공통 규율 3의 "전역 성격" 규칙).
case "$CMD" in
  *twg*)
    case "$CMD" in *TWG_RAW=1*) ;; *)
      # ; && || 줄바꿈으로 단순 명령을 나눈다. 파이프(|)는 나누지 않는다 — 뒤 프로그램이 결과를 줄이는 경우라서.
      while IFS= read -r seg; do
        printf '%s' "$seg" | grep -qE '(^|[[:space:]])twg[[:space:]]+jira[[:space:]]+workitem[[:space:]]+(get|bulk-get|query)([[:space:]]|$)' || continue
        case "$seg" in *'|'*) continue ;; esac                            # 파이프: 뒤 프로그램이 줄인다
        printf '%s' "$seg" | sed -E 's/[0-9]?>&[0-9]//g; s/2>[[:space:]]*[^[:space:]]+//g' | grep -q '>' && continue   # 결과를 파일로 보냄(2> 는 제외)
        case "$seg" in *--fields*|*'--field '*|*--field=*|*--select*|*--output-file*) continue ;; esac
        printf '%s' "$seg" | grep -qE -- '--output-summary([[:space:]]+(auto|stats|inline)|=(auto|stats|inline)|[[:space:]]*$|[[:space:]]+-)' && continue
        if printf '%s' "$seg" | grep -qE 'workitem[[:space:]]+query'; then
          n="$(printf '%s' "$seg" | sed -nE 's/.*--(limit|first)[ =]+([0-9]+).*/\2/p')"
          [ -n "$n" ] && [ "$n" -le 20 ] && continue
        fi
        deny G18 "twg Jira 조회 결과가 너무 큽니다(옵션 없는 get 약 2만 6천 자, bulk-get 이슈 2개 약 17만 자, query 약 5만 4천 자). 다음 중 하나를 붙여 다시 실행하세요. 필요한 칸만: --fields summary,status,labels / 파일로 받기: -o json --output-file {경로} / 요약만 받기: -o json --output-summary / 값 고르기: -o json --output-summary none --select data.{경로} / query 는 개수 제한: --limit 20. 사람이 전체 결과를 원했으면 명령 앞에 TWG_RAW=1 을 붙이세요."
      done <<<"$(printf '%s\n' "$CMD" | awk '{gsub(/&&|\|\||;/, "\n"); print}')"
    ;; esac ;;
esac
```

`deny` 는 `pre-bash.sh` 에 이미 있는 함수다. 거부 사유는 모델에게 전달된다(훅 문서: `"deny"` 의 `permissionDecisionReason` 은 "shown to Claude"). 그래서 모델이 사유를 읽고 옵션을 붙여 다시 실행할 수 있다.

### 3-5. `hooks/hooks.json` 과 `dobby-init` 에 더할 항목

`hooks/hooks.json` 의 `matcher: "Bash"` 묶음 끝에 더한다.

```json
{
  "type": "command",
  "if": "Bash(twg *)",
  "command": "bash",
  "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash.sh"],
  "timeout": 5,
  "statusMessage": "go-dobby 안전 검사"
}
```

`skills/dobby-init/SKILL.md` 97번째 줄(`"if": "Bash(python3 *)"` 항목) 뒤에 같은 모양으로 더한다. 경로만 `/Users/{사용자}/.config/go-dobby/hooks/pre-bash.sh` 로 쓴다.

```json
{ "type": "command", "if": "Bash(twg *)", "command": "bash", "args": ["/Users/{사용자}/.config/go-dobby/hooks/pre-bash.sh"], "timeout": 5, "statusMessage": "go-dobby 안전 검사" }
```

**이미 설치한 사람에게 전달되는 과정**: `pre-bash.sh` 가 바뀌므로 `hooks/session-start.sh` 가 다음 세션 시작 때 "복사본이 최신과 다르다"고 알린다. 사람이 `/dobby-init` 을 다시 실행하면 복사본과 사용자 설정 항목이 함께 갱신된다. 릴리스 설명에 "`/dobby-init` 재실행 필요"를 적는다(`HOOKS.md` 새 훅 추가 절차 7번).

### 3-6. `hooks/HOOKS.md` 표에 더할 행

```
| G18 | twg Jira 조회(`get`·`bulk-get`·`query`)에 줄이는 옵션(`--fields`·`--field`·`--select`·`--output-file`·`--output-summary`(none 제외)·파이프·파일 저장·query `--limit`/`--first` ≤ 20)이 없으면 차단. `TWG_RAW=1` 우회 | PreToolUse·Bash | deny | settings.json(if: twg — dobby-init 등록) | 토큰 절감(token-diet.md) |
```

### 3-7. 확인

**시제품 시험 결과 (25건 모두 기대와 같음)**

| 명령 | 기대와 결과 |
|---|---|
| `twg jira workitem get FE1-2197` | 거부 |
| `cd /tmp && twg jira workitem bulk-get A-1 A-2` | 거부 |
| `twg jira workitem query --jql "project = FE1"` | 거부 |
| `twg jira workitem query --jql "x" --limit 50` | 거부 (상한 20 초과) |
| `twg jira workitem get X --full` | 거부 |
| `twg jira workitem get X -o json --output-summary none` | 거부 |
| `S=1; twg jira workitem get X` | 거부 |
| `twg jira workitem get X 2>/dev/null` | 거부 |
| `twg jira workitem get X 2>&1` | 거부 |
| `false \|\| twg jira workitem get X` | 거부 |
| `twg jira workitem get FE1-2197 --fields summary,status` | 통과 |
| `twg jira workitem get X --field customfield_10015` | 통과 |
| `twg jira workitem get X -o json --output-file a.json` | 통과 |
| `twg jira workitem get X -o json --output-summary none --select data.description` | 통과 |
| `twg jira workitem bulk-get A B -o json --output-summary` | 통과 |
| `twg jira workitem query --jql "x" --limit 5` | 통과 |
| `twg jira workitem query --jql "x" --first 20` | 통과 |
| `twg jira workitem get X > /tmp/a.json` | 통과 |
| `twg jira workitem get X 2>/dev/null >/tmp/a.json` | 통과 |
| `twg jira workitem get X -o json \| jq .fields.status` | 통과 |
| `TWG_RAW=1 twg jira workitem get FE1-2197` | 통과 |
| `twg jira workitem transition --id X --transition-id "진행 중"` | 통과 (대상 아님) |
| `twg jira workitem transitions query --id X` | 통과 (대상 아님) |
| `twg jira workitem comment query --issue-id X` | 통과 (대상 아님) |
| `git status` | 통과 (twg 없음) |

**구현 뒤 확인**

1. 실제 `pre-bash.sh` 에 위 25건을 같은 방법으로 넣어 본다.
   ```bash
   jq -n --arg c 'twg jira workitem get FE1-2197' '{cwd:"/tmp",tool_input:{command:$c}}' | bash hooks/pre-bash.sh
   ```
2. 기존 규칙이 그대로인지 본다. `git push origin master`(G1 거부), `rm -rf ~/work/orchestration-meta/X`(G6 거부)를 넣어 본다.
3. `/dobby-init` 을 다시 실행해 설정을 갱신한 뒤 새 세션에서 확인한다.
   - `twg jira workitem get FE1-2197` 를 시켜 막히는지 본다. 막힌 뒤 모델이 옵션을 붙여 다시 실행하는지도 본다.
   - `S=1; twg jira workitem get FE1-2197` 도 막히는지 본다. 이것으로 `;` 처리를 확인한다.

---

## 4. 작업 D — Jira MCP 를 twg 로 바꾸기

### 4-1. FE1-2197 시험으로 확인한 사실

| 일 | twg 명령 | 결과 크기 | 비고 |
|---|---|---|---|
| 한국어 상태 이름으로 전환 | `twg jira workitem transition --id {키} --transition-id "진행 중"` | 57자 | 전환 목록을 먼저 보지 않아도 된다 |
| 시작 날짜 적기 | `twg jira workitem update --id {키} --field customfield_10015=2026-10-19` | 43자 | `=null` 로 비울 수 있다 |
| 레이블 더하기 | `twg jira workitem update --id {키} --add-labels {레이블}` | 19자 | **결과 글에 레이블이 표시되지 않는다.** 다시 조회해서 확인해야 한다 |
| 코멘트 달기 | `twg jira workitem comment create --issue-id {키} --body "…" --body-format markdown` | 2,539자 | 작성자 정보가 따라온다. 코멘트 번호만 뽑아 쓴다 |
| 전환 목록 | `twg jira workitem transitions query --id {키}` | 552자 | 도착 상태가 분류(해야 할 일, 진행 중, 완료)별로 묶여 나온다 |

전환 목록의 실제 출력은 이렇다.

```
  진행 중
    • In Progress (1) → 진행 중                        (id: 2)

  완료
    • Closed → 종료                                   (id: 51)
    • Resolved → 해결됨                                (id: 41)
```

### 4-2. 설명 본문 문제와 해결

twg 로 설명(`description`)을 받으면 Jira 문서 구조 JSON(ADF, Atlassian Document Format)으로 나온다. FE1-2140 의 설명은 19,552자였다. MCP 는 마크다운으로 약 5천 자를 돌려줬다. 그대로 쓰면 오히려 손해다.

그래서 **ADF 를 마크다운으로 바꾸는 변환기**를 둔다. 시제품을 FE1-2140 에 돌려 보니 19,552자가 1,872자가 됐다. 제목, 목록, 중첩 목록, 코드 표시, 링크가 모두 살아 있었다.

**새 파일 `reference/adf-to-md.jq`** 

```jq
# ADF(Jira 문서 구조 JSON) → 마크다운 비슷한 글. 이슈 설명을 읽기 위한 것이라 모양보다 내용 보존이 목적이다.
def inline: if .type=="text" then
    (.text) as $t | ([.marks[]?.type] ) as $m
    | if ($m|index("code")) then "`\($t)`" elif ($m|index("strong")) then "**\($t)**" else $t end
    + ( [.marks[]? | select(.type=="link") | " (\(.attrs.href))"] | join("") )
  elif .type=="hardBreak" then "\n"
  elif .type=="mention" then "@\(.attrs.text // "")"
  elif .type=="inlineCard" then (.attrs.url // "")
  elif .type=="emoji" then (.attrs.text // "")
  else ([.content[]? | inline] | join("")) end;
def block($ind):
  def item($i; $mark): $i + $mark + ([.content[]? | if (.type=="bulletList" or .type=="orderedList") then "\n" + block($i + "  ") else block("") end] | join(""));
  if .type=="paragraph" then $ind + ([.content[]? | inline] | join(""))
  elif .type=="heading" then ("#" * .attrs.level) + " " + ([.content[]? | inline] | join(""))
  elif .type=="bulletList" then [.content[] | item($ind; "- ")] | join("\n")
  elif .type=="orderedList" then [.content | to_entries[] | (.key as $k | .value | item($ind; "\($k + 1). "))] | join("\n")
  elif .type=="codeBlock" then "```\(.attrs.language // "")\n" + ([.content[]?.text] | join("")) + "\n```"
  elif .type=="blockquote" then [.content[]? | block("> ")] | join("\n")
  elif .type=="rule" then "---"
  elif .type=="mediaSingle" or .type=="mediaGroup" then "[첨부 이미지: " + ([.content[]?.attrs.alt // .content[]?.attrs.id // "이름 없음"] | join(", ")) + "]"
  elif .type=="table" then [.content[] | "| " + ([.content[] | [.content[]? | block("")] | join(" ")] | join(" | ")) + " |"] | join("\n")
  elif .type=="panel" or .type=="expand" or .type=="nestedExpand" then [.content[]? | block($ind)] | join("\n\n")
  else ([.content[]? | inline] | join("")) end;
[.content[]? | block("")] | join("\n\n")
```

**`reference/dobby-lib.sh` 에 더한 헬퍼 두 개** (`dobby_v2_notify` 바로 앞)

```bash
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
```

`$DOBBY_LIB_DIR` 는 `dobby-lib.sh` 18번째 줄에 이미 있는 변수다. 이 파일이 있는 폴더(`reference/`)를 가리킨다. 백업 스크립트(851번째 줄)와 `run.sh`(2505번째 줄)도 같은 방법으로 찾는다.

`--select` 경로는 구현 때 FE1-2197 로 확인했다. `--select` 를 쓰면 결과가 `data: [ {...} ]` 모양이 되고 칸이 바로 펼쳐진다(`fields` 아래가 아니다). 그래서 상태 분류의 경로는 `data.status.statusCategory.key` 이고, 꺼낼 때는 `.data[0].status.statusCategory.key` 다.

`--select` 경로가 틀리면 조용히 무시되고 전체 결과가 나온다. `--fields` 없이 틀린 경로를 주면 127,478자, `--fields status` 와 함께 틀리면 1,718자였다. 그래서 `--select` 는 언제나 `--fields` 와 함께 쓴다.

`dobby-init` 이 `dobby-lib.sh` 를 `~/.config/go-dobby/hooks/` 로 복사한다. 이 복사본은 훅만 쓰고 스킬은 플러그인 쪽 원본을 쓴다. 그래도 `adf-to-md.jq` 를 같은 폴더에서 찾으므로, 복사본에서 이 헬퍼를 부를 일은 없다는 점을 주석에 적는다.

### 4-3. 공통 문서 `reference/jira-twg.md` (새 파일)

스킬마다 명령을 따로 적지 않고 이 문서 하나를 가리킨다. `reference/jira-start.md` 를 여러 스킬이 같이 쓰는 것과 같은 방식이다. 내용은 아래 그대로 쓴다.

````markdown
# Jira 는 twg 로 다룬다 (go-dobby 공통)

Jira 조회와 쓰기는 MCP 대신 `twg` 명령으로 한다. MCP 보다 결과가 훨씬 작다.
(상태 전환: MCP 호출 2번 약 1만 2천 자, twg 1번 57자. 2026-10-19 FE1-2197 실측)

⛔ 조회 명령에는 **반드시 결과를 줄이는 옵션을 붙인다.** 옵션 없는 `get` 은 2만 6천 자, 이슈 2개 `bulk-get` 은 17만 자다.
옵션이 없으면 안전 훅(G18)이 막는다.

⛔ `--select` 는 **`--fields` 와 함께** 쓴다. `--select` 경로가 틀리면 조용히 무시되고 전체 결과(12만 자)가 나온다.
`--fields` 가 있으면 틀려도 그 칸만큼(2천 자 안팎)만 나온다.

`dobby_jira_*` 헬퍼는 `source "${CLAUDE_PLUGIN_ROOT}/reference/dobby-lib.sh"` 뒤에 부른다.

## 명령표

| 할 일 | 명령 | 결과 |
|---|---|---|
| 제목·상태·유형·상위·레이블 | `twg jira workitem get {키} --fields summary,status,issuetype,parent,labels` | 약 1.6천 자 |
| 설명 본문 | `dobby_jira_desc {키}` (화면) 또는 `dobby_jira_desc {키} {파일}` | 마크다운. FE1-2140 1,872자 |
| 칸 몇 개 확인 | `twg jira workitem get {키} --fields customfield_10015,labels` | 1천 자 안팎 |
| 진행 중으로 전환 | `dobby_jira_start_transition {키}` | `changed`·`already`·`done`·`failed` 한 낱말 |
| 다른 상태로 전환 | `twg jira workitem transitions query --id {키}` 로 도착 상태 번호를 보고 `twg jira workitem transition --id {키} --transition-id {번호}` | 552자 + 57자 |
| 칸 값 바꾸기 | `twg jira workitem update --id {키} --field {칸}={값}` (비우기는 `--field {칸}=null`) | 43자 |
| 레이블 더하기 | `twg jira workitem update --id {키} --add-labels {a},{b}` | 19자. 결과에 레이블이 안 나오므로 다시 조회해 확인 |
| 코멘트 목록 | `twg jira workitem comment query --issue-id {키} -o json --output-summary none --output-file {파일}` 뒤 파일에서 필요한 것만 `jq` 로 읽는다 | 코멘트 1개에 약 1.9천 자 |
| 코멘트 달기 | `twg jira workitem comment create --issue-id {키} --body-format markdown --body "…" -o json --output-summary none --select data.id` | 388자. 번호는 `.data.id` |
| 코멘트 고치기 | `twg jira workitem comment update --id {코멘트 번호} --issue-id {키} --body-format markdown --body "…"` | |
| 설명 고치기 | `twg jira workitem update --id {키} --description-format markdown --description "…"` | |
| JQL 검색 | `twg jira workitem query --jql "…" --fields summary,status,assignee --limit 20` | 이슈 수에 비례 |
| 첨부 목록 | `twg jira workitem attachment query --issue-id {키}` | |
| 첨부 받기 | `twg jira workitem attachment download --attachment-id {번호} --output-path {파일}` | |

전환 목록은 도착 상태가 분류(해야 할 일, 진행 중, 완료)별로 묶여 나온다. JSON 으로 받으면 `.data.transitions[]` 에 `id`, `toName`, `category` 가 있다.

## 레이블은 더하기만 한다

`--add-labels` 는 기존 레이블을 지우지 않는다. "기존 + 새것" 목록을 만들어 통째로 넣을 필요가 없다.

## 실패하면

twg 가 없거나 인증이 안 되면 `twg auth status` 결과를 보고에 적고 멈춘다. MCP 로 되돌아가지 않는다.
````

**구현 때 확인한 것** (2026-10-19, FE1-2197. 시험 뒤 모두 되돌렸다)

| 항목 | 결과 |
|---|---|
| `comment query` 결과 크기 | 코멘트 1개에 JSON 1,862자. 그래서 파일로 받아 필요한 칸만 읽게 했다 |
| `comment create … --select data.id` | 388자. 번호는 `.data.id` 에 있다(배열이 아니다). 시험 코멘트는 지웠다 |
| 전환 목록의 칸 | `id`, `name`, `toName`, `category` 넷뿐이다. MCP 의 `isAvailable` 이 없어서 `dobby-release` 는 "목록에 없으면 바꾸지 않는다"로 고쳤다 |
| `dobby_jira_start_transition` | BACKLOG 에서 `changed`, 다시 부르면 `already`. 끝난 뒤 BACKLOG 로 되돌렸다 |
| `dobby_jira_desc FE1-2140` | 1,872자 마크다운 |

### 4-4. 파일별로 바꿀 곳

| 파일 | 줄 | 지금 | 바꿀 내용 |
|---|---|---|---|
| `skills/do/SKILL.md` | 144~146 (1-1 의 2번) | "Jira 이슈를 조회한다 … Jira 상태를 진행 중으로 전환한다" | 조회는 `twg jira workitem get {키} --fields summary,status,issuetype,parent,labels`. 전환은 `dobby_jira_start_transition {키}`. 설명이 필요하면 `dobby_jira_desc {키} $ORCHESTRATION_META/{키}/jira-issue.md`. 맨 앞에 "`${CLAUDE_PLUGIN_ROOT}/reference/jira-twg.md` 의 명령을 쓴다" 한 줄 |
| `reference/jira-start.md` | 28, 35, 41, 44, 48, 56~64 | `editJiraIssue`, `getJiraIssue`, 도구 이름표 | 시작 날짜는 `twg jira workitem update --id {키} --field customfield_10015={오늘}`. 상위 레이블 조회는 `twg jira workitem get {상위키} --fields labels`. 레이블은 `--add-labels`(기존 목록과 합칠 필요 없음, 41~44줄의 "통째로 바꾸는 칸" 설명 삭제). 확인은 `--fields customfield_10015,labels`. 끝의 "도구 이름" 표는 `jira-twg.md` 를 가리키는 한 줄로 바꾼다. `dobby_jira_start_transition` 이 `changed` 를 돌려줬을 때만 시작 날짜를 적는다 |
| `skills/dobby-start/SKILL.md` | 34, 35 | `jira_get_issue`(`expand: renderedFields`), `jira_get_issue_images`, `jira_get_transitions`, `jira_transition_issue` | 조회는 `--fields` 형태, 설명은 `dobby_jira_desc`. 이미지는 `attachment query` 로 목록을 보고 필요한 것만 `attachment download`. 전환은 `dobby_jira_start_transition`(`done` 이면 사용자 확인은 그대로) |
| `skills/dobby-order/SKILL.md` | 175~181 | `jira_get_transitions`, `jira_transition_issue`, 이슈 원문 저장 | 전환은 `dobby_jira_start_transition {키}`. 원문 저장은 `dobby_jira_desc {루트키} $ORCHESTRATION_META/{루트키}/jira-issue.md`. 하위 이슈 탐색 JQL(174줄 `parent = {상위}`)은 `twg jira workitem query --jql "parent = {상위}" --fields summary,status,issuetype --limit 50`. **이 한 곳만 상한 20을 넘는다.** 하위 이슈가 20개를 넘을 수 있기 때문이다. G18 에 걸리지 않도록 `--fields` 를 붙인다(`--fields` 가 있으면 개수와 상관없이 통과) |
| `skills/dobby-qa/SKILL.md` | 87 | `jira_search` | `twg jira workitem query --jql "…" --fields summary,status,assignee,parent,issuetype --limit 20` |
| 같은 파일 | 95 | `jira_get_issue`(`expand: renderedFields`) | `twg jira workitem get {버그키} --fields summary,status,parent,labels` + `dobby_jira_desc {버그키}` |
| 같은 파일 | 118 | `jira_get_transitions` → `jira_transition_issue` | `dobby_jira_start_transition {버그키}` |
| 같은 파일 | 181, 203 | `jira_add_comment`, 기존 코멘트 수정 | `comment create` / `comment query` 로 기존 `## 수정 완료` 코멘트를 찾아 `comment update` |
| 같은 파일 | 205 | 도착 상태 `done` 인 전이로 전환 | `transitions query` 의 `완료` 묶음에서 도착 상태 `해결됨` 을 골라 `transition` |
| `skills/dobby-release/SKILL.md` | 167, 173~174 | `getJiraIssue`, `editJiraIssue` 로 `customfield_10217` | 조회 `twg jira workitem get {키} --fields customfield_10217,status`. 수정 `twg jira workitem update --id {키} --field customfield_10217={배포일}` |
| 같은 파일 | 184~187 | `getTransitionsForJiraIssue`, `transitionJiraIssue`, `getJiraIssue` | `transitions query` 에서 도착 상태 `해결됨` 의 번호를 골라 `transition`. 확인은 `--fields status`. 184줄의 "FE1 에서 확인한 값: 번호 41" 은 그대로 둔다(오늘 출력에서도 41 로 나왔다) |
| `skills/dobby-summary/SKILL.md` | 60 | `jira-issue.md` 가 없으면 `getJiraIssue` 로 설명 조회 | `dobby_jira_desc {키}` (파일로 저장하지 않는 지금 규칙 유지) |
| `skills/dobby-jira-tab/SKILL.md` | 3, 20~21 | "Atlassian MCP" 절 | 절 제목을 "Jira 는 twg 로"로 바꾸고 `jira-twg.md` 를 가리킨다. "토큰 기반 Atlassian MCP 가 있어야 동작" 문장은 "twg 인증(`twg auth status`)이 있어야 동작"으로 바꾼다 |
| 같은 파일 | 26 (snapshot) | MCP 로 설명 조회 후 저장 | `dobby_jira_desc {키} $ORCHESTRATION_META/{키}/jira-issue.md` |
| 같은 파일 | 36 (comments) | MCP 로 전체 코멘트 조회 | `comment query … -o json --output-file {임시}` 뒤 파일을 읽어 정리 |
| 같은 파일 | 72~75 (post) | 코멘트 수정 또는 추가, 설명 병합 | 코멘트: `comment query` 로 `## 구현 요약` 코멘트를 찾아 `comment update`, 없으면 `comment create`. 설명: `dobby_jira_desc {키}` 로 지금 설명을 받아 병합한 뒤 `update --description-format markdown --description` |

### 4-5. 주의: `jira-issue.md` 형식이 조금 바뀐다

지금 `jira-issue.md` 는 MCP 가 돌려준 마크다운이다. 앞으로는 변환기 출력이다. 대시보드 Jira 탭이 이 파일을 그대로 보여 주므로 화면이 조금 다를 수 있다. 구현 뒤 기존 오더 하나의 파일과 새로 만든 파일을 대시보드에서 나란히 열어 비교한다.

### 4-6. 확인

1. FE1-2197 에서 아래를 차례로 해 보고 원상복구한다. 지난번과 같은 순서로 되돌리고 시험 전 값과 비교한다.
   - `dobby_jira_start_transition FE1-2197` 이 `changed` 를 돌려주고 상태가 진행 중이 되는지
   - `reference/jira-start.md` 절차대로 시작 날짜와 레이블이 들어가는지
   - `jira-twg.md` 의 코멘트 달기 명령이 코멘트 번호만 돌려주는지
2. `dobby_jira_desc FE1-2140` 출력이 원문과 같은 내용인지 눈으로 본다.
3. `grep -rn -e 'jira_' -e 'JiraIssue' -e 'getTransitions' -e 'transitionJira' -e 'Atlassian MCP' plugins/go-dobby` 결과가 `HOOKS.md` 와 기록성 문장 말고는 없는지 본다.

---

## 5. 작업 C — 자동 실행 세션에 크롬 도구 MCP 만 붙이기

### 5-1. 근거

`claude -p` 로 실행된 `/do` 세션을 단계별로 집계했다.

| 단계 | 자동 실행 기록 | 필요한 MCP |
|---|---|---|
| 구현 | 25개 세션, MCP 사용 0회 | 없음 |
| 리뷰 | 28개 세션, MCP 사용 0회 | 없음 |
| 수정 | 4개 세션, MCP 사용 0회 | 없음 |
| 통합 | 23개 세션, Jira 상태 변경 1회 | 없음. 이 1회는 스킬 지시에 없는 행동이었다 |
| 배포 | 2개 세션 | 없음 (`gh`, `argocd` 명령만 씀) |
| 검증 | 자동 실행 기록 없음 | chrome-devtools |
| 검증 실패 분석 | 자동 실행 기록 없음 | 알림용 Slack, Gmail |

`run.sh` 는 세션을 띄운 뒤에야 단계가 정해진다. 그래서 단계별로 MCP 를 나누지 않고 모든 단계에 크롬 도구 하나만 붙인다. 크롬 도구를 붙여 두는 비용은 호출당 약 570 토큰이다(35,454 − 34,884).

`--strict-mcp-config`(지정한 MCP 만 쓰는 옵션)를 켜면 **claude.ai 연결 도구(Slack, Gmail, Atlassian 등)도 모두 사라진다.** 그래서 세션 안에서 직접 보내던 알림을 알림 헬퍼로 바꿔야 한다. 작업 D 로 Jira 는 twg(Bash 명령)를 쓰므로 영향이 없다.

### 5-2. `skills/do/run.sh`

**① 설정 준비 — `CONSENT=` 줄 앞에 넣는다**

```bash
# 자동 실행 세션에는 크롬 도구 MCP 하나만 붙인다. 검증 단계만 브라우저를 쓰고 나머지 단계는 MCP 를 쓰지 않는다.
# 연결 도구까지 다 붙으면 첫 호출 문맥이 42,648, 크롬 도구만이면 35,454 다(2026-10-19 실측). 근거: token-diet.md 작업 C.
# --strict-mcp-config 는 claude.ai 연결 도구(슬랙·메일)도 뺀다. 그래서 세션 안의 알림은 dobby_v2_notify 로 보낸다.
# 크롬 도구 설정은 사람마다 경로가 달라 ~/.claude.json 에서 그대로 옮겨 온다. 없으면 제한 없이 실행한다.
mcp=()
MCP_CFG="${TMPDIR:-/tmp}/dobby-mcp-$KEY.json"
if jq -e '.mcpServers["chrome-devtools"]' ~/.claude.json >/dev/null 2>&1 \
   && jq '{mcpServers: {"chrome-devtools": .mcpServers["chrome-devtools"]}}' ~/.claude.json >"$MCP_CFG" 2>/dev/null; then
  mcp=(--strict-mcp-config --mcp-config "$MCP_CFG")
else
  dobby_event "$KEY" "자동 실행 MCP 제한 못 함 — ~/.claude.json 에 chrome-devtools 설정이 없어 모든 MCP 를 붙인 채 실행" 2>/dev/null
fi
```

**② `claude -p` 실행 줄**

```bash
# 지금
out="$(cd "$WT" && claude -p ${resume[@]+"${resume[@]}"} "/do $KEY" ${extra[@]+"${extra[@]}"} --permission-mode "$MODE" --output-format json 2>/dev/null)"
# 바꾼 뒤
out="$(cd "$WT" && claude -p ${resume[@]+"${resume[@]}"} "/do $KEY" ${extra[@]+"${extra[@]}"} ${mcp[@]+"${mcp[@]}"} --permission-mode "$MODE" --output-format json 2>/dev/null)"
```

**③ 머리 주석(1~29줄)** 에 한 줄을 더한다.

```bash
# MCP: 세션마다 크롬 도구 하나만 붙인다(--strict-mcp-config). 슬랙·메일 알림은 dobby_v2_notify 가 따로 띄운 세션이 보낸다.
```

### 5-3. `skills/do/SKILL.md` 공통 규칙 "알림 보내는 법"

통째로 아래로 바꾼다.

```markdown
## 알림 보내는 법 (자동 배포 오더)

알림은 셸 한 줄로 보낸다.

    dobby_v2_notify {키} "{본문}"

이 헬퍼가 알림 전용 짧은 세션을 따로 띄워 슬랙 DM 과 메일로 같은 본문을 보낸다. 받는 사람은 `dobby-lib.sh` 의 `DOBBY_NOTIFY_SLACK`·`DOBBY_NOTIFY_EMAIL` 이다.

슬랙·메일 도구를 이 세션에서 직접 찾거나 부르지 않는다. 자동 실행 세션에는 그 도구가 붙어 있지 않다(`run.sh` 가 크롬 도구 하나만 붙인다).

보내지 못해도 세션을 멈추지 않는다. 헬퍼가 알림 내용을 이벤트 로그에 먼저 남긴다.
```

### 5-4. `skills/do/auto-mode.md` 258번째 줄

"헤드리스 세션의 슬랙·Gmail 연결 — 연결돼 있다" 행의 판정 칸 끝에 한 문장을 더한다.

```
2026-10-19 부터 run.sh 가 --strict-mcp-config 로 크롬 도구만 붙이므로, 단계 세션에는 이 연결이 없다. 알림은 dobby_v2_notify 가 띄운 별도 세션이 보낸다(token-diet.md 작업 C).
```

### 5-5. 확인

| 확인 | 방법 |
|---|---|
| 설정 파일이 바르게 만들어지는지 | `run.sh` 의 ① 부분만 떼어 실행하고 `jq . "$MCP_CFG"` |
| 세션에 크롬 도구만 붙는지 | `claude -p "ok" --strict-mcp-config --mcp-config "$MCP_CFG" --output-format stream-json --verbose` 의 첫 줄(`subtype: init`)에서 `mcp_servers` 를 본다 |
| 검증 단계가 동작하는지 | 크롬 도구만 붙인 상태로 `dobby-test` 가 브라우저 시나리오를 끝까지 돌리는지 한 번 실제로 본다. **검증 단계는 아직 자동으로 실행된 적이 없다** |
| 세션 안에서 알림 헬퍼가 동작하는지 | MCP 를 제한한 `claude -p` 세션 안에서 `dobby_v2_notify` 를 불러 슬랙 DM 과 메일이 실제로 오는지 본다. 세션 안에서 다른 `claude -p` 를 띄우는 것이 권한 모드(`auto`)에서 막히지 않는지도 이때 함께 본다. **두 가지 모두 아직 확인하지 않았다** |

---

## 6. 작업 E — `/do` 본문을 단계별 파일로 나누기

### 6-1. 지금 구조와 나눈 뒤 읽는 양

`skills/do/SKILL.md` 는 967줄, 36,856자(약 3만 3,800 토큰)다. 모든 세션이 이 전체를 읽는다.

**남기는 것** (모든 단계에 필요)

| 줄 | 내용 | 글자 수 |
|---|---|---|
| 1~136 | 머리말, 사용법, 단계 판정 | 7,794 |
| 826~967 | 공통 규칙, 하지 않는 것 | 4,940 |
| 합계 | | 12,734 |

**옮기는 것** (`skills/do/steps/` 아래 새 파일)

| 줄 | 절 | 새 파일 | 글자 수 | 그 단계 세션이 읽는 양 | 지금 대비 |
|---|---|---|---|---|---|
| 137~374 | 세션 1 · 설계 (테스트 계획 양식 포함) | `steps/design.md` | 8,703 | 21,437 | 58% |
| 375~418 | 세션 2 · 구현 | `steps/impl.md` | 1,375 | 14,109 | 38% |
| 419~474 | 세션 3 · 리뷰 | `steps/review.md` | 1,798 | 14,532 | 39% |
| 475~509 | 세션 4 · 수정 | `steps/fix.md` | 1,221 | 13,955 | 37% |
| 510~537 | 세션 5 · 통합 | `steps/integrate.md` | 1,008 | 13,742 | 37% |
| 538~549 | 세션 5-2 · 배포 | `steps/ship.md` | 446 | 13,180 | 35% |
| 550~578 | 세션 6 · 검증 | `steps/verify.md` | 999 | 13,733 | 37% |
| 579~614 | 세션 6-2 · 검증 실패 처리 | `steps/triage.md` | 1,212 | 13,946 | 37% |
| 615~625 | 세션 6-3 · 판단 답 받기 | `steps/answer.md` | 587 | 13,321 | 36% |
| 626~726 | 이어받기 설계 | `steps/takeover.md` | 3,870 | 16,604 (+설계 파일) | 45% (+) |
| 727~825 | 변경 접수 | `steps/change.md` | 2,903 | 15,637 (+설계 파일) | 42% (+) |

지난번 분석에서 "하위 작업 브랜치가 있으면…"을 별도 큰 절(5,095)로 셌던 것은 잘못이었다. 661번째 줄의 그 글은 코드 블록 안의 셸 주석이다. 실제로는 "이어받기 설계" 절의 일부다. 위 표는 이것을 바로잡은 값이다.

**기대 효과 (추정)**: 자동 실행의 대부분인 구현, 리뷰, 수정, 통합 세션이 읽는 양이 지금의 37~39%가 된다. 토큰으로 보면 세션당 약 2만 1천 토큰이 줄고, 그 세션의 모든 호출에서 이만큼 덜 읽는다. 이 값은 글자 수 비율(3만 3,800 토큰 ÷ 36,856자)로 계산한 **추정**이다. 나눈 뒤 6-5 의 방법으로 실측해 확정한다.

### 6-2. 단계끼리 서로 가리키는 곳

옮긴 뒤 끊기지 않게 해야 할 참조다. 본문을 검색해 찾았다.

| 가리키는 절 | 줄 | 가리키는 대상 | 처리 |
|---|---|---|---|
| 판단 답 받기 | 620 | 설계의 "1-5 자족성 점검" | `answer.md` 에 "`steps/design.md` 의 1-5 절을 읽고 그대로 한다" |
| 이어받기 설계 | 684, 691, 700, 702, 714, 716 | 설계의 1-3, 1-4, 1-5, 1-6, 1-7 | `takeover.md` 첫머리에 "`steps/design.md` 를 함께 읽는다" |
| 이어받기 설계 | 679, 696, 706 | 변경 접수 3, 4, 5절 | `takeover.md` 첫머리에 "`steps/change.md` 도 함께 읽는다" |
| 변경 접수 | 776, 782, 786, 808 | 설계의 1-3, 1-5, 1-6 | `change.md` 첫머리에 "`steps/design.md` 를 함께 읽는다" |
| 검증, 검증 실패 처리 | 573, 611 | 공통 규칙 "알림 보내는 법" | 공통 규칙은 `SKILL.md` 에 남으므로 그대로 둔다 |
| 설계 | 149, 350 | 공통 규칙 "세션 기록", "사람에게 묻지 않는다" | 그대로 둔다 |
| 공통 규칙 | 863 | 변경 접수 | "`steps/change.md` 를 읽고 변경 접수로 받는다"로 바꾼다 |
| 하지 않는 것 | 963 | 변경 접수 | 그대로 둔다 (이름만 나온다) |

변경 접수와 이어받기 설계는 사람과 대화하는 드문 세션이라, 설계 파일을 함께 읽어도 손해가 작다.

### 6-3. `SKILL.md` 에 넣을 안내

"단계 판정" 절의 표 바로 아래(124번째 줄 부근)에 넣는다.

```markdown
**판정한 단계의 파일 하나만 읽는다.** 단계 본문은 이 폴더의 `steps/` 에 나눠 두었다. 다른 단계의 파일은 읽지 않는다. 모든 세션이 모든 단계의 본문을 읽으면 호출마다 그만큼 다시 읽기 때문이다(나누기 전 이 파일 하나가 약 3만 3,800 토큰).

| 이번 세션에서 할 일 | 읽을 파일 |
|---|---|
| 설계, 설계 수정 대화 | `steps/design.md` |
| 이어받기 설계 | `steps/takeover.md` (안에서 `design.md`, `change.md` 를 함께 읽으라고 안내한다) |
| 구현 | `steps/impl.md` |
| 리뷰 | `steps/review.md` |
| 수정 | `steps/fix.md` |
| 통합 | `steps/integrate.md` |
| 배포 | `steps/ship.md` |
| 검증 | `steps/verify.md` |
| 실패 처리 | `steps/triage.md` |
| 판단 답 받기 | `steps/answer.md` |
| 변경 접수 | `steps/change.md` |
```

### 6-4. 옮기는 방법

- 각 절을 **글자 그대로** 옮긴다. 절 안의 문장은 고치지 않는다. 6-2 표의 참조만 고친다.
- 옮긴 파일의 첫 줄 제목은 원래 절 제목(`# 세션 2 · 구현` 등)을 그대로 쓴다.
- `auto-mode.md`, `session-reuse.md` 를 같은 폴더에 따로 둔 방식과 같다.
- 손으로 잘라 붙이면 빠뜨리기 쉽다. 줄 번호로 자르는 짧은 스크립트로 옮기고, 옮긴 뒤 모든 파일의 글자 수 합이 원래 본문과 같은지(6-3 의 안내 글 제외) 확인한다.

### 6-5. 확인

1. **글자 수 대조**: `SKILL.md` 의 남은 부분과 `steps/*.md` 의 합이 원래 36,856자 + 새 안내 글과 같은지 본다.
2. **토큰 실측**: 지난번과 같은 방법으로 잰다. 빈 폴더에서 스킬을 끈 실행(24,280)과, `/do` 본문 + `steps/impl.md` 를 넣은 실행의 첫 호출 문맥 차이를 본다.
3. **단계별 실제 실행**: 시험 오더 하나로 자동 실행을 끝까지 돌려 각 단계가 자기 파일만 읽는지 본다. 세션 기록에서 `Read` 호출의 경로를 확인한다.

---

## 7. 마무리 — 버전, 브랜치, 커밋

| 항목 | 내용 |
|---|---|
| 브랜치 | `origin/main`(3793b2e)에서 `feat/token-diet` 를 만든다. 지금 `~/work/mentis-plugins` 는 `fix/ship-pr-reuse-bridge` 에 있지만, main 에 없는 커밋이 0개라 그대로 두고 새 브랜치로 옮겨도 된다 |
| 버전 | 0.2.87 에서 0.2.88 로 올린다. `plugins/go-dobby/.claude-plugin/plugin.json` 4번째 줄과 저장소 루트 `.claude-plugin/marketplace.json` 16번째 줄 두 곳 |
| 설계 기록 | 이 문서를 `skills/do/token-diet.md` 로 넣는다. `auto-mode.md`, `session-reuse.md` 처럼 근거 문서로 둔다. |
| 커밋 | 작업마다 하나씩 나눈다(A, B, D, C, E, 버전). 커밋과 푸시는 확인을 받은 뒤 한다 |
| 릴리스 설명에 적을 것 | "`/dobby-init` 을 다시 실행해야 twg 검사(G18)가 동작한다" |
| 설치 뒤 순서 | 플러그인 재설치, `/dobby-init` 재실행, 새 세션 시작 |

---

## 8. 정하실 것

| 질문 | 제안 | 이유 |
|---|---|---|
| 한 브랜치로 묶을까, 작업마다 나눌까 | 한 브랜치, 작업별 커밋 | 서로 맞물린다. 작업 B 가 작업 D 의 실수를 잡고, 작업 C 는 작업 D 가 있어야 Jira 가 끊기지 않는다 |
| G19 가 막는 범위 | 모든 `/dobby-*` 를 막는다 | 큰 문맥에서는 어떤 명령이든 호출마다 비싸다. 다만 `/dobby-status` 처럼 짧게 끝나는 명령까지 막는 것이 불편하면, 막을 명령을 고르는 목록으로 바꿀 수 있다 |
| G19 기준값 | **25만 토큰 (확정)** | 15만 효과의 88%를 지키면서 막히는 횟수를 30% 줄인다(2-1 표) |
| G18 의 `query` 개수 상한 | 20 | 이슈 2개가 약 2,300자이므로 20개면 약 2만 3천 자다. 그 이상은 `--fields` 를 붙이게 한다 |
| mcp-atlassian 서버 삭제 시점 | 작업 D 를 넣고 1~2주 써 본 뒤 | 바꾸지 못한 곳이 있으면 그때 드러난다 |
