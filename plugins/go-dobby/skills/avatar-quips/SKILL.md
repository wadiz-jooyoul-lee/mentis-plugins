---
name: avatar-quips
description: mentis 대시보드 전용 재미기능. 한 오더의 에이전트들에 배정된 아바타(BTS·프로미스나인·도비)가 자기 작업 콘텐츠를 읽고 성격대로 한 줄 소감(만족·불평·환호·고민)을 남겨 대시보드 호버 말풍선용 파일을 만든다. ⛔ 오케스트레이션(dobby-order 등)에서는 절대 호출하지 않는다 — 대시보드가 페이지 진입 시 백그라운드로만 실행한다. 사용법 /avatar-quips {키} [슬러그...] — 슬러그를 주면 그 에이전트들 소감만 다시 만들어 병합한다(없으면 전체).
---

# avatar-quips

대시보드가 백그라운드로 실행하는 **재미기능 스킬**. 오더 하나의 각 에이전트에 배정된 아바타가, 자기 작업을 성격대로 촌평하는 짧은 소감을 만들어 `$ORCHESTRATION_META/.mentis-quips/{키}.json`에 저장한다.

> ⛔ **오케스트레이션 미사용**: dobby-order/start/impl/produce는 이 스킬을 호출하지 않는다. 오직 대시보드가 트리거한다. 이 스킬은 코드·메타를 **읽기만** 하고 오더 메타(orchestration.md 등)는 **수정하지 않는다**(별도 `.mentis-quips/` 파일만 씀).

## 실행 모드 (인자로 결정)
`/avatar-quips {키} [슬러그...]`
- **전체 모드**(슬러그 인자 없음): 오더의 모든 에이전트 소감을 만든다(첫 생성 등).
- **선택 모드**(슬러그 인자 있음): **그 슬러그들만** 다시 만들어 기존 `.mentis-quips/{키}.json`에 **병합**한다. 나머지 슬러그의 기존 소감은 그대로 둔다. (대시보드가 "소감 없음 + 소감 만든 뒤 추가 작업함"인 에이전트만 골라 넘긴다.)
아래 절차는 두 모드 공통이되, **대상 슬러그 집합**만 다르다(전체=상태표의 모든 슬러그, 선택=인자로 받은 슬러그).

## 설정
`~/.config/go-dobby/config.env`를 source 해 `$ORCHESTRATION_META`를 확인한다(`${CLAUDE_PLUGIN_ROOT}/reference/config.md`).

## 1. 오더 콘텐츠 읽기 (사실 신호 수집)
`$ORCHESTRATION_META/{키}/`에서 읽는다(있는 것만):
- `orchestration.md` — 에이전트 상태표(슬러그·상태·라운드), 이벤트 로그
- `analysis.md` · `implementation.md`/`produce.md` — 무슨 작업인지
- `reviews/round-*/{슬러그}.md` — 슬러그별 리뷰 라운드 수·심각도
- `agent-logs.json` + 대화 로그 — 슬러그별 수정 파일 수(대략)
각 슬러그의 **컨텍스트 신호**를 뽑는다: 상태(대기/분석중/구현중/수정중/리뷰중/재통합대기/완료), 수정 파일 수, 리뷰 라운드 수.

## 2. 아바타 배정 (대시보드와 동일 — 반드시 일치)
대시보드 `src/lib/avatarAssign.ts`와 **완전히 같은 알고리즘**으로 슬러그→멤버를 정한다. 정확성을 위해 아래 node 스니펫을 그대로 실행해 계산한다(직접 암산 금지). `{키}`와 슬러그 목록만 넣는다.

```bash
node -e '
const BTS=["RM","진","슈가","제이홉","지민","뷔","정국"];
const FROMIS=["송하영","박지원","이채영","이나경","백지헌"];
function hash(s){let h=2166136261>>>0;for(let i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619)>>>0;}return h>>>0;}
const KEY=process.argv[1]; const slugs=[...new Set(process.argv.slice(2).filter(s=>s&&s!=="-"))].sort();
const r=hash(KEY)%100, primary=r<40?"bts":r<80?"fromis":"dobby";
const FILL={bts:["bts","fromis","dobby"],fromis:["fromis","bts","dobby"],dobby:["dobby","bts","fromis"]};
const order=FILL[primary], pool={bts:BTS,fromis:FROMIS,dobby:[]}, used={bts:0,fromis:0,dobby:0};
let gi=0; const map={};
for(const s of slugs){ while(order[gi]!=="dobby"&&used[order[gi]]>=pool[order[gi]].length)gi++; const g=order[gi]; if(g==="dobby")map[s]={group:"dobby"}; else {map[s]={group:g,member:pool[g][used[g]]}; used[g]++;} }
console.log(JSON.stringify(map));
' "{키}" 슬러그1 슬러그2 ...
```
→ 각 슬러그의 `{group, member}`. `group:"dobby"`면 멤버 없음(도비).

> ⚠️ **선택 모드에서도 배정은 전체 슬러그로 계산한다.** 배정은 정렬된 전체 슬러그 순서에 의존하므로, 대상 슬러그만 넣으면 같은 에이전트가 다른 아바타를 받는다. **오더의 모든 슬러그**를 node 스니펫에 넣어 배정을 구한 뒤, 그중 **대상 슬러그의 배정만** 골라 쓴다.

## 3. 성격 (프로필 기반)
멤버별 성격을 아래 성향대로 반영한다(프로필에서 유추). 필요하면 프로필을 더 조사해 보강해도 된다.
- **RM**(리더·래퍼, "파괴신"): 분석적·차분한 리더, 논리 중시, 가끔 자책 개그
- **진**(월드와이드 핸섬, 맏형): 유쾌·자뻑·아재개그, 다정
- **슈가**(프로듀서 Agust D): 시크·무심·현실적, 속은 따뜻
- **제이홉**(희망·댄스캡틴): 초긍정·에너지·환호
- **지민**(섬세·완벽주의): 성실·섬세, 걱정 많음
- **뷔**(4차원·감성·사진/연기): 자유분방·엉뚱·감성
- **정국**(황금막내, 다재다능): 열정·승부욕·막내 패기
- **송하영**(부캡틴): 든든·리더십·성실
- **박지원**(메인보컬): 안정감·차분·프로페셔널
- **이채영**(댄서·래퍼): 활발·힙·에너지
- **이나경**(비주얼·분위기메이커): 밝음·상큼
- **백지헌**(막내·보컬): 씩씩·귀염·에너지
- **도비**(group=dobby): **랜덤 톤**(겸손·충직한 도비 말투 + 매번 무작위 기분). 도비끼리도 조금씩 다르게.

## 4. 소감 생성 (컨텍스트별)
각 슬러그에 대해 **board / changes / reviews** 세 컨텍스트의 소감을 만든다. 성격에 따라 만족·불평·환호·고민이 달라지고, **실제 신호에 근거**해 촌평한다(단, 소감은 주관적 감상이라 사실 주장까지 정확할 필요는 없다 — 재미 요소).
- **board**: 작업 진행상황 소감(상태 기준). 대기=심심/투정, 구현중=집중/의욕, 수정중=헐레벌떡/불평, 리뷰중=긴장, 완료·재통합대기=환호/뿌듯
- **changes**: 자기 수정 파일·diff에 대한 소감(파일 많으면 볼멘소리/뿌듯, 적으면 깔끔 등)
- **reviews**: 리뷰 라운드 소감(1회=개운, 여러 번=투덜/각오)
각 소감 = `{ "mood": <happy|cheer|complain|ponder|chill|tired|bored>, "text": "<한 문장, ~30자>" }`. text는 한국어 구어체, 이모지 0~1개.

## 5. 에이전트별 작업 지문(agents) 기록
대상 각 슬러그에 대해 **작업 지문** `sig = "<상태>#<라운드>"`를 구한다. 대시보드가 이 값으로 "소감 만든 뒤 추가 작업했는지"를 판단한다(달라지면 다음 새로고침 대상).
- **상태**: orchestration.md 상태표의 그 슬러그 상태 칸(대기/분석중/구현중/수정중/리뷰중/재통합대기/완료). 단, `deliverables/{슬러그}.md` 또는 `deliverables/{슬러그}/`가 있으면 상태를 **완료**로 본다(대시보드 보정과 일치).
- **라운드**: 상태표의 라운드 칸 문자열(없으면 빈 문자열). 예: `완료#1`, `구현중#`.

## 6. 저장 (원자적 · 병합 · 격리)
`$ORCHESTRATION_META/.mentis-quips/`가 없으면 `mkdir -p`.

**⚠️ 병합 필수**: 기존 `{키}.json`이 있으면 먼저 읽어서, 이번 대상 슬러그의 항목만 갱신하고 **나머지 슬러그의 기존 값(board/changes/reviews/agents)은 그대로 유지**한다(선택 모드에서 다른 에이전트 소감을 지우면 안 됨). 전체 모드면 전체가 대상이라 사실상 전체 갱신이 된다.

병합한 최종 내용을 **임시 파일에 쓰고 rename** 한다(생성 중 중단돼도 반쪽 파일이 안 생기게):
```bash
mkdir -p "$ORCHESTRATION_META/.mentis-quips"
# 기존 파일을 읽어 병합한 최종 JSON을 {키}.json.tmp 에 먼저 쓰고
mv "$ORCHESTRATION_META/.mentis-quips/{키}.json.tmp" "$ORCHESTRATION_META/.mentis-quips/{키}.json"
```
파일 스키마:
```json
{
  "generatedAt": "<ISO 시각>",
  "agents":  { "<슬러그>": { "sig": "완료#1" } },
  "board":   { "<슬러그>": { "mood": "cheer", "text": "..." } },
  "changes": { "<슬러그>": { "mood": "ponder", "text": "..." } },
  "reviews": { "<슬러그>": { "mood": "complain", "text": "..." } }
}
```
- `agents[슬러그].sig`는 5번에서 구한 지문. 대상 슬러그는 board와 agents를 **반드시** 채운다(둘 중 하나라도 비면 대시보드가 계속 "미생성"으로 보고 다시 요청함).
- 리뷰가 없는 슬러그는 `reviews`에서 생략, 로그 없는 슬러그는 `changes` 생략 가능.

## 원칙
- 오더 메타를 수정하지 않는다. `.mentis-quips/` 외 아무 데도 쓰지 않는다.
- 실패해도 대시보드는 말풍선만 안 뜰 뿐이므로, 확신 없으면 무리하게 채우지 말고 board만이라도 안전하게 만든다.
