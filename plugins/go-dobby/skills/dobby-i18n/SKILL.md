---
name: dobby-i18n
description: 새 다국어 문구를 서포터 다국어 관리 시트의 작성 형식(A~N열)에 맞춰 정리해, 한 번에 복사해 붙여 넣을 수 있는 claude.ai 아티팩트로 게시하는 대화형 스킬. 시트는 크롬으로 **읽기만** 한다 — 탭의 열 규칙과 A열·D열 수식, 첫 빈 줄, 같은 문구의 기존 키, 기존 번역 말투를 읽어 키와 네 언어(ko·en·ja·zh) 값을 정하고, 줄 번호에 맞춘 수식과 검수 상태·마크다운 체크까지 채운 줄을 만든다. 붙여 넣기는 사람이 하고, 사람이 붙여 넣었다고 하면 시트를 다시 읽어 칸마다 대조한다(확인 모드). 설계 세션이 새 문구를 만들 때 이 스킬로 정리해 사람에게 보여 준다. 헤드리스에서는 Artifact 게시 도구가 없어 쓰지 못한다. 사용법 /dobby-i18n {문구 목록 또는 설명} [key={오더키}] [tab={시트 탭}], 확인 /dobby-i18n 확인 [key={오더키}].
---

# dobby-i18n

새 다국어 문구를 **시트에 그대로 붙여 넣을 줄**로 만들어 아티팩트로 보여 준다. 붙여 넣은 뒤에는 시트를 다시 읽어 바르게 들어갔는지 확인한다.

```
/dobby-i18n {문구}
   → 시트 읽기(열 규칙·수식·첫 빈 줄·기존 키·번역 말투)
   → 키와 네 언어 값 정하기 → 아티팩트 게시 → 사람이 붙여 넣기
/dobby-i18n 확인
   → 시트 다시 읽기 → 칸마다 대조 → 결과 보고
```

## 지켜야 할 것 ⛔

- **시트는 읽기만 한다.** 칸을 고르거나 이름 상자로 이동하는 것 말고는 시트에 아무것도 입력하지 않는다. 붙여 넣기는 사람이 한다.
- **언어 파일(`packages/i18n/src/supporter/languages/*.json`)의 원본은 시트다.** 이 스킬은 언어 파일을 고치지 않는다. 개발 중 언어 파일에 넣는 값은 임시값이고, 시트 검수가 끝나 동기화되면 그 값으로 바뀐다.
- **추측으로 열 규칙을 정하지 않는다.** 수식과 열 뜻은 항상 그 탭에서 읽은 것을 쓴다. 저장소 문서의 수식과 실제 시트가 다른 적이 있다(문서에는 `TEXTJOIN` 의 `TRUE` 인자가 빠져 있었다).

## 설정 (첫 실행 시 확인)

작업 전에 **`${CLAUDE_PLUGIN_ROOT}/reference/config.md` 의 "설정 절차"를 그대로 따른다**(config.env 는 읽기만). 이하 메타 경로는 `$ORCHESTRATION_META` 기준이다.

## 입력

```
/dobby-i18n {문구 목록 또는 설명} [key={오더키}] [tab={시트 탭}]
/dobby-i18n 확인 [key={오더키}]
```

| 입력 | 뜻 | 없으면 |
|---|---|---|
| 문구 목록 | 새로 넣을 한국어 문구와 쓰이는 곳. 설계 문서의 문구 표, 파일 경로, 대화에서 말한 목록 모두 받는다 | 멈추고 요청한다 |
| `key=` | 오더 키. 주면 원고를 그 오더 폴더에 두고 아티팩트 링크를 기록한다 | 원고를 `$ORCHESTRATION_META/.artifacts/` 에 둔다 |
| `tab=` | 시트 탭 이름. 탭은 페이지 단위다(예: `17_my_wadiz_page`, `13_funding_payment_page`) | level1Key 로 탭을 찾는다. 못 찾으면 묻는다 |

시트: `https://docs.google.com/spreadsheets/d/1tuPjfm3y1gB0_Xq9MPgR1ZZOdCQG6fJLClIWIMTCxLc` (와디즈 다국어 관리 - 서포터)

## 시트 열 형식

탭마다 같은 형식이다. 아래는 실제 탭에서 읽어 확인한 값이다. 그래도 매번 1단계에서 다시 읽어 맞는지 본다.

| 열 | 내용 | 아티팩트가 넣는 값 |
|---|---|---|
| A | id | 수식 `=TEXTJOIN(".", TRUE, B{n}, C{n}, D{n})` |
| B | level1Key | 페이지 키(예: `my_wadiz_orders_detail_page`) |
| C | level2Key | 영역 키(예: `legacy_delivery_section`) |
| D | level3Key | 수식 `=TEXTJOIN("_", TRUE, F{n}, G{n}, E{n}, IF(I{n}, "markdown", ""))` |
| E | keyProperty | 속성(`label`, `text`, `message`, `title` …) |
| F | keyElementOrContext | 요소나 맥락(`confirm_modal`, `receipt_button` …) |
| G | keyStatus | 상태(`completed`, `canceled` …). 없으면 빈칸 |
| H | status (검수 상태) | 새 줄은 `검수 전` |
| I | 마크다운 체크박스 | `TRUE` 또는 `FALSE` |
| J~M | ko, en, ja, zh | 네 언어 값 |
| N | args 설명 | `{{ arg_0 }}` 자리에 무엇이 들어가는지. 예: `0: 결제 수단 이름 (예: 카드, 네이버페이)` |
| O | 제목 없는 체크박스 | 넣지 않는다(뜻이 시트에 적혀 있지 않다) |
| P | alternativeKey | 넣지 않는다 |

`{n}` 은 그 줄의 번호다. level3Key 는 **F + G + E 순서**로 이어지고, I열이 TRUE 면 끝에 `_markdown` 이 붙는다. 그래서 원하는 키가 이 순서로 나오도록 E, F, G 를 나눠 적는다.

## 절차

### 1단계. 시트 읽기 (크롬, 읽기만)

Google Drive 연결 도구는 쓰지 않는다. `drive.readonly` 권한이 없어 실패하고, 다시 연결해도 권한이 늘지 않는다. 크롬(chrome-devtools)으로 시트를 연 탭 안에서 읽는다. 로그인이 필요하면 우회하지 말고 사람에게 로그인을 부탁한 뒤 기다린다.

**값 읽기** — 시트를 연 탭에서 `evaluate_script` 로 아래를 돌린다. 결과는 파일로 저장하지 말고 바로 돌려받는다(저장 경로 제한에 걸린다).

```js
async () => {
  const ID = '1tuPjfm3y1gB0_Xq9MPgR1ZZOdCQG6fJLClIWIMTCxLc', TAB = '{탭 이름}';
  const res = await fetch(`/spreadsheets/d/${ID}/gviz/tq?tqx=out:csv&headers=0&sheet=${encodeURIComponent(TAB)}`);
  const text = await res.text();
  // 칸 안의 줄바꿈과 따옴표를 지키는 CSV 해석
  const rows = []; let row = [], cell = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
    else if (c !== '\r') cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  // 열 번호: A=0 B=1 C=2 D=3 E=4 F=5 G=6 H=7 I=8 J=9 K=10 L=11 M=12 N=13 O=14 P=15
  return { header: rows[0], count: rows.length, items: rows.slice(1).map((r) => [r[0], r[8], r[9], r[10]]) };
}
```

- `export?format=tsv` 주소는 다른 도메인으로 넘어가 "Failed to fetch" 로 실패한다. 위 `gviz` 주소만 쓴다.
- **열 번호는 위 주석의 대응표로만 센다.** I열(마크다운)을 엉뚱한 번호에서 읽어 "없음"으로 오판한 적이 있다.

**수식 읽기** — 값 읽기에는 수식 결과만 나온다. 수식은 이렇게 읽는다.

1. 이름 상자(`#t-name-box`)에 셀 주소(예: `A330`)를 넣고 Enter 를 보낸다.
2. 잠깐 기다린 뒤 수식 입력줄(`#t-formula-bar-input`)의 글자와, 이름 상자에 지금 표시된 주소를 **함께** 읽는다.
3. 주소가 넣은 값과 다르면 다시 읽는다. 탭이 바뀌는 중에 읽어 A1 이 읽힌 적이 있다.

**읽어서 얻을 것**

| 얻을 것 | 어떻게 |
|---|---|
| 열 머리가 위 "시트 열 형식"과 같은지 | 값 읽기의 `header` |
| A열과 D열 수식 | 마지막으로 채워진 줄의 A, D 칸을 수식 읽기로 |
| 첫 빈 줄 번호 | 값 읽기의 마지막 줄 다음 번호. 그 줄의 A칸을 수식 읽기로 열어 비어 있는지 확인 |
| 같은 문구의 기존 키 | 같은 탭에서 ko 값이 같은 줄. 있으면 새 키를 만들지 않고 그 키를 쓴다 |
| 번역 말투 | 같은 탭의 기존 번역. 예: 메이커는 일본어 メイカー, 중국어 制造者 |

다른 탭에 같은 문구가 있어도 재사용하지 않는다. 키는 페이지(탭) 단위다. 번역 말투 참고로만 쓴다.

### 2단계. 키와 값 정하기

문구마다 아래를 정한다.

1. **level2Key 와 E, F, G**: 같은 탭의 기존 키 모양을 따른다.
2. **마크다운 여부**
   - 목록(`- `), 굵은 글씨, 링크가 들어가면 마크다운 키로 만든다. 화면에서는 `MarkdownToHtml` 로 그린다.
   - 줄바꿈만 있으면 일반 키로 두고, 화면에서 `\n` 과 `white-space: pre-line` 으로 처리한다.
   - **그 문구를 그리는 부품이 줄바꿈을 지원하는지 코드에서 확인한다.** 지원하지 않으면 줄바꿈만 있는 문구도 마크다운 키로 만든다. 예: 확인 창 `ConfirmModal` 의 본문 스타일에는 `pre-line` 이 없어서, 글머리표 한 줄이 붙는 본문을 마크다운 키로 만들었다.
3. **args**: `{{ arg_0 }}` 처럼 바뀌는 값이 있으면 N열에 무엇이 들어가는지 적는다.
4. **네 언어 값**: 1단계에서 읽은 말투를 따른다. 줄바꿈은 값 안에 그대로 둔다.
5. **보이는 곳**: 국내 화면에서만 보이는지(`kr`), 해외 화면에도 보이는지(`all`) 표시한다. 해외에도 보이면 번역이 꼭 필요하다는 뜻이다.

### 3단계. 아티팩트 만들기

이 스킬 폴더의 `template.html` 을 복사해 원고를 만든다.

| key= | 원고 경로 |
|---|---|
| 있음 | `$ORCHESTRATION_META/{키}/artifacts/i18n.html` |
| 없음 | `$ORCHESTRATION_META/.artifacts/i18n-{주제 슬러그}.html` |

원고에서 두 곳만 바꾼다.

- `__TITLE__`: 무엇에 대한 문구인지 담은 짧은 이름. 예: `참여 내역 상세 다국어 키`
- `/*__DATA__*/null`: 아래 "아티팩트 데이터" 형식의 JSON

**아티팩트 데이터**

```json
{
  "title": "참여 내역 상세 다국어 키",
  "lead": "국내 참여 내역 상세를 글로벌 화면으로 합치면서 새로 생기는 문구 23개입니다. …",
  "tab": "17_my_wadiz_page",
  "level1": "my_wadiz_orders_detail_page",
  "startRow": 331,
  "newStatus": "검수 전",
  "formulas": {
    "A": "=TEXTJOIN(\".\", TRUE, B{n}, C{n}, D{n})",
    "D": "=TEXTJOIN(\"_\", TRUE, F{n}, G{n}, E{n}, IF(I{n}, \"markdown\", \"\"))"
  },
  "rows": [
    { "level2": "legacy_delivery_section", "E": "message", "F": "confirm_modal", "G": "",
      "ko": "리워드를 수령했나요? …\n- 리워드를 수령하지 않고 …", "en": "…", "ja": "…", "zh": "…",
      "args": "", "scope": "kr", "markdown": true }
  ],
  "rules": ["L22 는 확인 창 본문이 줄바꿈을 그리지 않아 마크다운 목록으로 썼습니다."],
  "reuse": [{ "key": "funding_payment_page.shipping_address_section.recent_tab_label", "text": "최근 배송지" }]
}
```

- `formulas` 는 1단계에서 읽은 수식의 줄 번호를 `{n}` 으로 바꾼 것이다.
- `rules` 는 시트 규칙 상자에 더할 사실이다. 마크다운으로 정한 이유, args 규칙처럼 붙여 넣는 사람이 알아야 할 것만 적는다.
- `reuse` 는 새로 만들지 않고 기존 키를 쓰는 문구다. 없으면 빈 배열로 두고, 그러면 그 상자는 숨겨진다.

템플릿이 해 주는 것:

- 첫 빈 줄 입력칸. 바꾸면 A열과 D열 수식의 줄 번호가 함께 바뀐다.
- "A~N열 N줄 복사" 단추. 클립보드에 표 형식(`text/html`)과 탭으로 나눈 글(`text/plain`)을 함께 넣는다. 표 형식이 있어야 구글 시트가 칸을 바르게 나누고 칸 안의 줄바꿈을 지킨다.
- "완성 키만 복사" 단추.
- 줄마다 완성 키와 보이는 곳 표시.

### 4단계. 게시

`artifact-design` 스킬 지침에 따라 원고를 Artifact 도구로 게시한다. `icon` 은 `table` 이다. 같은 원고를 다시 게시하면 같은 링크가 갱신된다.

`key=` 가 있으면 링크를 기록한다. 헬퍼로만 쓰고 파일을 직접 고치지 않는다.

- 처음: `dobby_artifact_add {키} i18n "{제목}" {URL}`
- 다시 게시: `dobby_artifact_touch {키} i18n "{무엇을 바꿨나}"`

### 5단계. 보여 주기

사람에게 아래를 보여 준다.

```
다국어 키 정리: {URL}

| 번호 | 완성 키 | ko | 보이는 곳 |
(전체 줄)

붙여 넣는 법
  1. 시트의 {탭} 탭에서 {startRow}행이 첫 빈 줄인지 확인합니다.
  2. 아티팩트의 "A~N열 N줄 복사"를 누릅니다.
  3. 시트에서 {startRow}행의 A열 칸을 고르고 붙여 넣습니다.
붙여 넣으신 뒤 알려 주시면 시트를 다시 읽어 확인하겠습니다.
```

사람이 키나 번역을 고치라고 하면 원고의 데이터를 고쳐 다시 게시한다(4단계). 링크는 그대로다.

### 6단계. 확인 (`확인` 모드, 또는 사람이 붙여 넣었다고 할 때)

1. 원고의 `DATA` 를 읽는다. `key=` 가 있으면 `$ORCHESTRATION_META/{키}/artifacts/i18n.html` 이다.
2. 1단계의 값 읽기로 탭 전체를 다시 읽는다.
3. **완성 키(A열 값)로 줄을 찾는다.** 줄 번호로 찾지 않는다. 붙여 넣은 위치가 계획과 달라도 찾을 수 있다.
4. 줄마다 대조한다.

| 칸 | 기대값 |
|---|---|
| A | 완성 키 (수식 결과) |
| B, C, E, F, G | 데이터 값 |
| D | level3Key (수식 결과) |
| H | `검수 전` (사람이 이미 바꿨으면 다른 값도 통과로 보고 그 값을 적는다) |
| I | 마크다운이면 `TRUE`, 아니면 `FALSE` |
| J~M | 네 언어 값. 칸 안의 줄바꿈까지 같아야 한다 |
| N | args 설명 |
| O | 비어 있음 |

5. 찾은 줄 몇 개는 수식 읽기로 A칸과 D칸을 열어, 값이 아니라 **수식**이 들어갔는지 본다.
6. 결과를 보고한다.

```
시트 확인 결과 ({탭} 탭 {처음 줄}~{끝 줄}행)
  | 번호 | 완성 키 | 결과 |
  일치 N줄, 다름 M줄, 못 찾음 K줄
  (다르면 칸과 시트 값, 기대값을 함께)
```

### 7단계. 이후 안내 (이 스킬은 하지 않음)

붙여 넣은 뒤 남은 일을 알린다.

1. 시트의 GitHub Action 을 실행하고 기획자에게 검수를 요청한다.
2. 검수가 끝나면 `origin/i18n-sync` 브랜치에 반영된다(한 시간마다 자동).
3. 작업 브랜치에서 `node packages/i18n/scripts/sync-i18n.mjs` 로 언어 파일을 받는다.

## 설계 세션에서 쓸 때

설계 중 새 문구가 생기면 이 스킬을 `key={오더키}` 로 부른다. 그다음 설계 문서의 다국어 작업 항목에 아래를 적는다.

- 키와 네 언어 값의 원본은 시트다. 정리 페이지는 `{URL}` 이다.
- 구현은 `packages/i18n/src/supporter/languages/{ko,en,ja,zh}.json` 에 같은 키와 그 페이지의 값을 임시값으로 넣는다.
- 마크다운 키는 어느 부품에서 `MarkdownToHtml` 로 그리는지 적는다.

## 주의

- **대화형 전용**: 헤드리스 실행에는 Artifact 게시 도구와 크롬이 없을 수 있다. 그때는 아티팩트를 만들지 않고, 2단계 결과를 표로 설계 문서에 적은 뒤 "시트 등록 필요"를 확인할 것으로 남긴다.
- 아티팩트는 기본 비공개로 게시된다.
- 아티팩트에는 시트 작업에 필요한 내용만 넣는다. 작업 도구 이야기는 넣지 않는다.
