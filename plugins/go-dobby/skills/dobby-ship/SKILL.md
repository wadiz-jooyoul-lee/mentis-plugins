---
name: dobby-ship
description: 구현·리뷰가 끝난 오더를 배포 환경까지 밀어 넣는 스킬. PR 생성 → 자동 코드리뷰 반영 → 머지 → 빌드 → 배포 확인 → dobby-test 실행을 한 세션에서 이어서 한다. dobby-order 제약 C1이 "정식 배포 베이스로의 PR·머지는 별도 절차로 사용자가 직접"이라고 비워 둔 자리를 채우는 스킬이며, 그래서 사용자가 명시적으로 부를 때만 동작한다. 저장소 둘을 맡는다 — wadiz-frontend 와 com.wadiz.web 이고, 한 오더가 둘 다 건드리면 둘 다 PR 을 같은 틀로 만든 뒤 순서를 지켜 내보낸다(머지는 wadiz-frontend 가 머지된 뒤에 com.wadiz.web, 배포는 wadiz-frontend 배포가 끝난 뒤에 com.wadiz.web 을 argocd 로 sync). com.wadiz.web 은 리뷰봇이 없어 리뷰를 기다리지 않고, 빌드가 머지 push 로 자동으로 돌며(걸지 않고 run id 만 잡는다), CI 가 끝나도 argocd 가 Manual 이라 sync 하지 않으면 배포되지 않는다. 환경(dev·rc1·rc4·stage)을 반드시 입력받고 저장소마다 실제 브랜치로 옮긴다(com.wadiz.web 의 dev 는 cloud_dev). 인자는 순서를 가리지 않는다 — 네 환경 이름 중 하나면 환경, 이슈 키나 브랜치 모양이면 대상 오더로 알아서 가른다. cloud_live(clive)로는 절대 가지 않는다. wadiz-frontend 는 dev 를 뺀 rc1·rc4·stage 에 리뷰어로 wadiz-fe/fe1-team 을 반드시 붙이되(리뷰 요청이 있어야 자동 코드리뷰가 돈다), 기다렸다 반영하는 것은 rc1·rc4 뿐이고 stage 는 기다리지 않되 그 시점에 달려 있는 리뷰는 읽어 반영하며 dev 는 충돌만 본다. 머지는 dev·rc1·rc4 만 하고 stage 는 양쪽 저장소 모두 PR 까지만 만들어 두고 사용자가 직접 머지·배포한다. 승인(APPROVED)이어도 리뷰 본문을 반드시 읽어 고칠 지적이 있으면 고치고 푸시한 뒤 그 리뷰에 무엇을 반영하고 무엇을 왜 안 했는지 코멘트로 남기고 머지한다(승인은 반영 후 바로 머지, 변경요청은 반영 후 다시 리뷰 대기). 지켜야 하는 것은 글이 아니라 dobby_ship_* 헬퍼와 훅 G1 이 거부로 강제한다. 머지·빌드·argocd sync 는 반드시 사용자에게 묻고, 리뷰 반영 왕복은 3라운드에서 멈춘다. 여러 번 불려도 되도록 status.md에 저장소마다 배포 단계를 적고 그 지점부터 이어서 한다. 사용법 /dobby-ship {키|브랜치} {dev|rc1|rc4|stage} (순서 무관, 키를 빼면 현재 브랜치에서 찾는다).
---

# dobby-ship

리뷰까지 끝난 오더를 **배포 환경에 올려 테스트가 시작되는 데까지** 밀어 넣는다.

```
wadiz-frontend  PR → 리뷰 → (반영) → 머지 → 빌드 → 배포 완료 ─┐
                      ↑________|      ⛔사람  ⛔사람           │
com.wadiz.web   PR → (리뷰 없음) → 머지 → CI 자동 → argocd sync ┴→ dobby-test
                                    ↑              ↑              └ 실패하면 번들·파드 대조
                                 FE 머지 뒤      FE 배포 뒤       ⛔사람
```

`dobby-order`는 **자기 브랜치 푸시까지**만 한다(제약 C1). 그 다음 한 칸을 이 스킬이 맡는다.

## 맡는 저장소는 둘이다 — 틀이 다르다

환경 브랜치 이름·리뷰봇 유무·빌드 방식·**배포 방식**이 저장소마다 다르다. 한 틀로 돌리면 조용히 틀린 일을 한다.

| 저장소 | 환경→브랜치 | 리뷰봇 | 빌드 | 배포 |
|---|---|---|---|---|
| `wadiz-frontend` | 그대로 | **있음** | 수동(번들별) | 빌드가 곧 배포 |
| `com.wadiz.web` | `dev`→**`cloud_dev`**, 나머지 그대로 | **없음** | **자동**(머지 push) | **argocd sync 가 따로 필요** |

각 칸을 틀리면 이렇게 된다.

- `com.wadiz.web` 에 `dev` 로 PR 을 만들면 **없는 브랜치라 실패한다** (`cloud_dev` 다).
- 리뷰어를 붙이면 **오지 않을 리뷰를 10분 기다린다.** 게다가 조직이 달라(`wadiz-web`) `wadiz-fe/fe1-team` 은 붙지도 않는다.
- 빌드를 걸면 push 트리거와 겹쳐 **두 번 돈다.**
- **sync 를 빼먹으면 배포가 아예 안 된다.** 네 환경 모두 `SYNCPOLICY=Manual` 이라 CI 가 이미지 태그를 고쳐도 파드는 옛 이미지 그대로다 (실측: 조회 시점에 `web-rc1-web-server` 가 `OutOfSync` 였다 — 머지·CI 는 됐는데 아무도 sync 하지 않은 상태).

### 한 오더가 둘 다 건드리면 — 둘 다 맡되 순서를 지킨다

둘은 **같이 나가야 동작한다.** FE 가 부르는 컨트롤러·JSP 가 `com.wadiz.web` 에 있어서, 한쪽만 반영되면 그 사이에 화면이 깨진다.

```
머지   wadiz-frontend 가 머지된 뒤에  →  com.wadiz.web      (G-A)
배포   wadiz-frontend 배포가 끝난 뒤에 →  com.wadiz.web sync (G-B)
```

**글이 아니라 헬퍼가 거부로 강제한다** — `dobby_ship_merge` 와 `dobby_ship_argo` 가 `## 배포` 표에서 `wadiz-frontend` 행의 단계를 보고 이르면 막는다. 순서를 어길 수 없다.

`com.wadiz.web` 만 건드리는 오더는 FE 행이 없으므로 **게이트가 꺼지고 혼자 간다.**

## 설정 읽기

작업 전에 `${CLAUDE_PLUGIN_ROOT}/reference/config.md`의 "설정 절차"를 그대로 따른다: `~/.config/go-dobby/config.env`를 source 해 환경 변수를 **읽기만** 한다. ⛔ 이 스킬은 config.env를 저장·수정·생성하지 않는다(값 변경은 `dobby-init` 전용). 메타 루트는 `$ORCHESTRATION_META`.

## 인자 — 순서를 가리지 않는다

```
/dobby-ship FE1-1982 rc4
/dobby-ship rc4 FE1-1982       ← 같다
/dobby-ship rc4                ← 오더는 현재 브랜치에서 찾는다
/dobby-ship feature/FE1-1982 rc4
```

받은 토막을 **모양으로 가른다.** `env=` 같은 이름표를 붙이게 하지 않는다 — 넷 중 하나인지 보면 바로 알 수 있는 값이라 이름표는 군더더기다.

| 토막이 이러면 | 이렇게 본다 |
|---|---|
| `dev` · `rc1` · `rc4` · `stage` 중 하나 | **환경** |
| `FE1-1982` · `TASK-{슬러그}` 꼴 | **오더 키** |
| `feature/FE1-1982` 처럼 `/`가 있는 브랜치 | 거기서 **오더 키를 뽑는다**(`FE1-1982`) |
| `clive` · `cloud_live` · `master` | **거부한다** — 훅 G1 이 PR·머지·빌드를 모두 막는다 |
| 그 밖 | 무엇인지 되묻고 멈춘다 — 짐작해서 넘기지 않는다 |

**가르고 나서 확인한다.**

- **환경이 없으면** 묻고 멈춘다. 짐작해서 고르지 않는다 — 어디로 내보내는지는 사람이 정할 일이다.
- **오더 키가 없으면** 현재 브랜치 이름에서 찾는다(`feature/FE1-1982` → `FE1-1982`). 거기서도 못 찾으면 묻고 멈춘다.
- **환경이 둘 이상이면** 어느 쪽인지 묻고 멈춘다. 먼저 온 것을 고르지 않는다.
- 찾은 키로 `$ORCHESTRATION_META/{키}/status.md` 가 실제로 있는지 본다. 없으면 오더가 아니라고 알리고 멈춘다.

**가른 결과를 시작할 때 한 줄로 보여 준다.** 잘못 갈랐으면 사람이 바로 알아채야 한다.

```
FE1-1982 를 rc4 로 배포합니다 (브랜치 feature/FE1-1982)
```

### 환경 하나가 세 가지를 정한다

PR 베이스 브랜치이자, 빌드 워크플로의 `environment` 입력값이자, argocd 서버·앱이다. 워크플로가 `environment` 값으로 빌드할 브랜치를 고르므로, 둘이 어긋나면 **머지한 것과 다른 것이 배포된다**. 그래서 따로 받지 않고 하나로 묶는다.

**받는 것은 언제나 논리 환경(`dev`·`rc1`·`rc4`·`stage`)이다.** 실제 브랜치는 저장소마다 헬퍼가 옮긴다 — `com.wadiz.web` 의 `dev` 는 `cloud_dev` 다. 논리 이름으로 통일해야 `## 배포` 표의 두 저장소 행이 같은 환경으로 맞물려 순서를 셀 수 있다.

### ⛔ `clive` 는 거부한다

`clive` 는 `cloud_live` 브랜치이고, 이는 `ORCHESTRATION_DEFAULT_BASE` — `dobby-order` 제약 C1이 **"정식 배포 베이스로의 PR·머지 금지"** 로 못박은 대상이다. 사용자가 요청해도 하지 않고, 라이브 반영은 별도 릴리스 절차로 진행하도록 안내한다.

## 절차

### 0. 이어서 할 자리 찾기

`status.md`의 `## 배포` 표에서 **이번 환경의 저장소별 행**을 찾는다. 있으면 그 단계 다음부터, 없으면 1번부터.

```markdown
## 배포
| 저장소 | 환경 | 단계 | PR | 빌드 | 갱신 | 비고 |
|---|---|---|---|---|---|---|
| wadiz-frontend | dev | 검증 완료 | #29436 | static#36364314238 · global#36364316550 | 2026-09-28 10:05 | |
| wadiz-frontend | rc4 | 리뷰 대기 | #29440 | - | 2026-09-28 11:20 | |
| com.wadiz.web | rc4 | 머지 대기 | #11131 | - | 2026-09-28 11:21 | |
```

**(저장소, 환경)마다 한 행**이다. 위 상태에서 `/dobby-ship {키} rc4` 는 rc4 의 두 행을 함께 이어 간다 — FE 는 `리뷰 대기` 부터, WEB 은 FE 머지를 기다리는 `머지 대기` 에 서 있다. dev 행은 건드리지 않는다.

> 옛 오더는 저장소 칸이 없는 6칸 표다. **고치려 들지 않는다** — `dobby_ship_stage` 가 다음에 쓸 때 7칸으로 올리면서 기존 행을 `- **저장소**:` 줄의 값으로 채운다.

단계 뒤의 `⚠` 는 그 환경이 **막혀 있다**는 뜻이다. 비고를 읽고, 사람 판단이 필요한 것이면 진행하지 말고 사용자에게 알린다.

이 스킬은 **여러 번 불린다.** 사람 리뷰를 기다려야 하거나 라운드 상한에 걸리면 깨끗이 멈추고, 사용자가 다시 부르면 이어서 한다.

### 1. 앞단 확인 (못 넘어가면 여기서 멈춘다)

| 확인 | 아니면 |
|---|---|
| `status.md` 현재 단계가 **`통합` 이후**다 (통합·검증·해결·종료) | 아직 통합이 안 끝났다고 알리고 멈춘다 |
| `## 워크트리 / 브랜치` 표에 **맡는 저장소가 하나라도** 있다 (`wadiz-frontend`·`com.wadiz.web`) | 이 스킬이 맡는 저장소가 아니라고 알리고 멈춘다 |
| 그 저장소마다 브랜치가 적혀 있다 | 워크트리가 없다고 알리고 멈춘다 |
| 그 브랜치들이 원격에 푸시돼 있다 (`git ls-remote`) | `dobby-order`가 P6까지 못 갔다는 뜻이다. 멈춘다 |
| 환경을 골랐다 (dev·rc1·rc4·stage 중 하나) | 묻고 멈춘다 |

⛔ **미커밋 변경이 남아 있으면 멈춘다.** 리뷰를 통과한 것만 나가야 한다(C1). 저장소마다 본다.

**맡는 저장소를 전부 고른다.** 하나만 보고 나머지를 넘기지 않는다 — 넘기면 한쪽만 반영돼 화면이 깨진다. `## 워크트리 / 브랜치` 표가 정본이다.

```
FE1-1787 을 rc4 로 배포합니다
  wadiz-frontend  feature/FE1-1787 → rc4
  com.wadiz.web   feature/FE1-1787 → rc4   (FE 머지·배포 뒤에 따라갑니다)
```

**단계 이름을 헷갈리지 않는다.** 정본은 `착수·분석·구현·리뷰·통합·검증·해결·종료` 여덟이다. `완료` 는 **에이전트 상태표**의 값이지 단계가 아니다 — `dobby-order` P7 의 "구현 에이전트 상태를 `완료`로 갱신한다"를 단계로 잘못 읽기 쉽다. **`dobby-order` 가 끝나는 지점이 `통합`** 이므로 그것이 기본 진입 조건이다(실제 메타에 `완료` 로 적힌 오더가 4개 있어 받아는 준다).

이 검사는 `dobby_ship_pr` 이 **거부로 강제한다** — 표만 보고 넘어갈 수 없다.

### 2. PR 생성 — `dobby_ship_pr` (저장소마다)

**맡는 저장소마다 한 번씩 부른다. 틀은 똑같다** — 충돌 해결 브랜치·제목·본문 규칙이 같다.

```bash
PR_FE="$(dobby_ship_pr {키} {FE워크트리}  {브랜치} {환경} "{제목}" "{본문}")"
PR_WEB="$(dobby_ship_pr {키} {WEB워크트리} {브랜치} {환경} "{제목}" "{본문}")"
```

생 `gh pr create` 를 치지 않는다. 헬퍼가 **대신 지켜 준다.**

| 헬퍼가 막는 것 | 왜 |
|---|---|
| 환경이 `dev`·`rc1`·`rc4`·`stage` 가 아니면 거부 | `clive` 로 새는 길을 없앤다 |
| 그 저장소에 그 환경이 없으면 거부 | 없는 브랜치로 PR 을 만들지 않는다 |
| 워크트리에 미커밋 변경이 있으면 거부 | 리뷰를 통과한 것만 나간다(C1) |
| 같은 (브랜치→베이스) PR 이 열려 있으면 그 번호를 돌려준다 | 중복 생성을 막는다 |
| **저장소마다 베이스 브랜치를 옮긴다** | `com.wadiz.web` 의 `dev` 는 `cloud_dev` 다 |
| 리뷰봇이 있는 저장소에서 `dev` 를 뺀 환경에만 `--reviewer wadiz-fe/fe1-team` 을 **자동으로 붙인다** | 깜빡하면 리뷰가 안 달려 4번에서 10분을 헛되이 기다린다. 반대로 `com.wadiz.web` 에 붙이면 **오지 않을 리뷰를 기다린다** |
| **GitHub 이 충돌로 판정하면 충돌 해결 브랜치로 다시 올린다** | 두 저장소의 정상 경로다(아래) |
| 진짜 충돌이면 거부한다 | 충돌 해결은 `/merge-branch` 가 한다 |

충돌 해결 브랜치 이름은 **베이스 브랜치 기준**이라 `com.wadiz.web` 의 dev 는 `feature/FE1-1787_into_cloud_dev` 가 된다. 그 저장소도 같은 관례를 쓴다(실측: `cloud_live_into_rc4`·`cloud_live_into_cloud_dev`).

### 충돌은 헬퍼가 갈라 준다

| 상황 | 헬퍼가 하는 일 |
|---|---|
| 깨끗함 | 그대로 PR 을 연다 |
| **GitHub 만 충돌이라 함** | **충돌 해결 브랜치 `{브랜치}_into_{환경}` 로 다시 올린다** (자동) |
| 진짜 충돌 | **거부한다** — `/merge-branch {브랜치} {환경}` 으로 풀고 다시 오라고 알린다 |

가운데가 **이 저장소의 정상 경로다.** git 은 깨끗한데 GitHub 이 충돌이라 하는 경우인데, **공통 조상이 여러 개**일 때 생긴다 — git 은 조상들을 재귀적으로 합친 가상 기준으로 병합하지만 GitHub 은 조상 하나만 쓴다. 병합 커밋을 미리 만들어 올리면 환경 브랜치가 그 커밋의 조상이 되어 모호성이 사라진다(`merge-branch` 스킬의 5.4 → 6.2.1 경로를 그대로 따른다).

실측으로 **예외가 아니라 기본**이다.

```
FE1-1800  #29211 · #29272 · #29428   feature/FE1-1800_into_dev → dev   전부 머지됨
          #29427                      feature/FE1-1800     → dev       닫힘
FE1-1943  #29384                      feature/FE1-1943_into_rc4 → rc4  머지됨
```

병합 결과는 **체크아웃 없이** `git merge-tree --write-tree` 로 미리 계산한다 — 작업 트리·HEAD·인덱스를 건드리지 않는다.


**제목·본문만 쓰면 된다.**

- **제목**은 `status.md`의 `- **제목**:` 을 쓴다. 이슈 키를 앞에 붙인다.
- **본문**은 `outcome.md`(없으면 `implementation.md`)에서 **무엇을 왜 고쳤는지**를 쉬운 말로 추린다. 내부 용어(`round-N`·슬러그·`P숫자`·`blocking=`)는 쓰지 않는다 — 팀이 읽는 글이다.
- 본문 끝에 Jira 주소 한 줄.
- ⛔ 금지 서명(`Co-Authored-By` 등)을 넣지 않는다.

→ `dobby_event {키} "PR 생성 — #{번호} ({브랜치} → {환경})"`
→ 배포 표의 `PR 생성` 과 PR 번호는 **`dobby_ship_pr` 이 직접 적는다.** 따로 부르지 않는다.

### 3. 저장소·환경에 따라 갈린다

| 저장소 | 환경 | 자동 코드리뷰 | 팀 리뷰어 | 리뷰 대기 | 머지 | 배포 |
|---|---|---|---|---|---|---|
| `wadiz-frontend` | `rc1` · `rc4` | 돈다 | 붙인다 | **기다린다** (4번) | 스킬 | 빌드 |
| `wadiz-frontend` | `stage` | 돈다 | 붙인다 | 안 기다린다 (달려 있으면 읽는다) | **사용자** | — |
| `wadiz-frontend` | `dev` | 안 돈다 | 안 붙인다 | 안 기다린다 (충돌만) | 스킬 | 빌드 |
| `com.wadiz.web` | `dev`·`rc1`·`rc4` | **안 돈다** | **안 붙인다** | **안 기다린다 (충돌만)** | 스킬 (FE 뒤) | **sync** (FE 배포 뒤) |
| `com.wadiz.web` | `stage` | 안 돈다 | 안 붙인다 | 안 기다린다 (충돌만) | **사용자** | **사용자** |

`wadiz-frontend` 의 `[event] Claude Code Review` 워크플로가 도는 대상은 `rc[0-9]`·`stage`·`cloud_live` 다 — `dev` 만 빠져 있다.

**`com.wadiz.web` 은 어느 환경이든 리뷰를 기다리지 않는다.** 리뷰봇이 없다(실측 2026-10-07: 최근 머지 PR 5건 모두 `reviews`·`reviewRequests` 가 0건이고, 등록돼 있는 `Copilot code review` 워크플로도 마지막 실행이 2026-03-24 로 멈춰 있다). 그래도 사람이 남긴 리뷰가 달려 있으면 읽고 반영한다 — `dobby_ship_merge` 가 미반영 변경요청을 거부하므로 모르고 덮을 수는 없다.

**`stage` — 기다리지는 않되 달린 것은 본다.**

봇 리뷰가 실측 1분 51초~6분 44초에 오므로, 여기 도달했을 때 **이미 달려 있는 일이 흔하다.** 기다리느라 멈추지는 않지만, 달려 있는 것을 못 본 척하고 머지하지는 않는다.

```bash
gh pr view {번호} --json reviews,reviewDecision,mergeable,mergeStateStatus
```

| 그 시점에 | 할 일 |
|---|---|
| 리뷰가 아직 없다 | 기다리지 않고 5번으로 |
| 승인만 있다 | 5번으로 |
| **지적·변경요청이 있다** | **4번의 반영 절차를 그대로 밟는다** (읽고·판단하고·고치고·푸시) |

반영해서 푸시했으면 봇이 다시 도는데, 그때도 **기다리지 않는다** — 5번 머지 직전에 한 번 더 보므로 거기서 잡힌다. 라운드 상한 3회는 똑같이 적용한다.

**`dev` 는 충돌만 본다.**

```bash
gh pr view {번호} --json mergeable,mergeStateStatus
```

`CONFLICTING` 이면 워크트리에서 베이스를 머지해 충돌을 풀고 푸시한 뒤 다시 본다. 못 풀면 무엇이 부딪혔는지 알리고 멈춘다.

### 4. 리뷰 기다리기·반영 (`wadiz-frontend` 의 rc1 · rc4 만)

⛔ **`com.wadiz.web` PR 에는 이 절을 적용하지 않는다.** 리뷰봇이 없어 오지 않을 리뷰를 기다리게 된다.

PR이 열리거나 푸시될 때마다 자동 코드리뷰가 돌아 리뷰를 남기고, 크리티컬이 없으면 **승인까지 한다**. 실측 응답은 **1분 51초 · 3분 51초 · 6분 44초**였다.

```bash
gh pr view {번호} --json reviews,reviewDecision,mergeable,mergeStateStatus
```

**최대 10분** 기다린다(30초 간격). 그동안 다른 일을 하지 않는다.

- 10분이 지나도 리뷰가 없으면 → 리뷰어가 제대로 붙었는지 먼저 본다(`gh pr view --json reviewRequests`). 안 붙었으면 붙이고 다시 기다린다. 붙어 있는데도 안 오면 `dobby_ship_stage {키} wadiz-frontend {환경} "리뷰 대기"` 로 적고 **멈춘다**.

**판정 — ⛔ 승인이 곧 "읽지 않아도 된다"가 아니다**

승인 리뷰에도 "고치면 좋겠다" 수준의 지적이 함께 달린다. 승인만 보고 넘어가면 그 지적이 통째로 버려진다. **어느 경우든 리뷰 본문을 먼저 읽고** 고칠 것이 있는지부터 가른다.

| 결과 | 할 일 |
|---|---|
| `APPROVED` · 고칠 지적 **없음** | 5번(머지)으로 — **봇 승인이어도 그대로 진행한다** |
| `APPROVED` · 고칠 지적 **있음** | 아래 반영 절차 → **5번(머지)으로** |
| 변경 요청(`CHANGES_REQUESTED`) | 아래 반영 절차 → **이 절 처음으로**(새 리뷰를 기다린다) |
| 단순 코멘트(지적 없음) | 5번으로 |

**승인과 변경 요청은 반영 뒤가 다르다.** 승인은 리뷰어가 이미 "머지해도 된다"고 판정한 것이라 지적을 반영하고 바로 머지한다. 변경 요청은 그 판정이 아직 없으므로 반영 후 다시 리뷰를 받는다.

**반영 절차**

1. `gh pr view {번호} --comments` 로 리뷰 본문을 **전부** 읽는다.
2. 지적마다 **타당한지 판단한다.** 추측하지 말고 코드를 열어 확인한다.
   - 타당 → 워크트리에서 고친다. `dobby-impl`의 규율(계약 범위·주석 분량)을 따른다.
   - 아님 → **고치지 않는다.** 왜 아닌지 근거를 3번 코멘트에 적는다.
3. 고친 게 있으면 커밋·푸시.
   `dobby_commit_push {워크트리} {브랜치} "{메시지}"`
4. **그 리뷰에 코멘트를 단다 — 반영했든 안 했든 전부 적는다.**

   ```bash
   gh pr comment {번호} --body "$(cat <<'EOF'
   리뷰 반영했습니다.

   | 지적 | 처리 | 근거 |
   |---|---|---|
   | 빈 배열일 때 0건으로 보고됨 | 반영 | 결과 파일이 없을 때와 0건을 갈라 적었습니다 |
   | 상수를 파일 밖으로 빼기 | 안 함 | 이 파일에서만 씁니다. 빼면 쓰는 곳을 찾아 들어가야 합니다 |
   EOF
   )"
   ```

   리뷰어가 다음에 볼 때 **무엇이 반영됐고 무엇이 왜 안 됐는지**가 한 곳에 있어야 한다. 특정 줄에 달린 지적이면 `gh api repos/{owner}/{repo}/pulls/{번호}/comments/{코멘트ID}/replies` 로 그 자리에 답해도 된다.
5. 다음은 **판정 표대로** 간다.
   - 승인 상태였으면 → **5번(머지)으로.**
   - 변경 요청이었으면 → 이 절 처음으로(푸시하면 리뷰 봇이 다시 돈다).

   ⚠️ **승인 뒤 반영한 코드는 새 리뷰를 못 받고 머지될 수 있다.** 봇 응답이 1분 51초~6분 44초라 푸시 직후 머지하면 그 사이에 끼인다. 그래서 **반영은 리뷰가 짚은 범위 안에서만** 한다 — 지적과 무관한 것을 같이 고치지 않는다. 새 리뷰가 제때 와서 변경요청이면 `dobby_ship_merge` 가 머지를 거부하므로 그때는 이 절 처음으로 돌아간다.

### 3라운드 상한 — `dobby_ship_round`

반영을 시작하기 **전에** 부른다. 회차(`리뷰 반영 N회차`)를 표에 적어 주고, 4회째면 **거부하면서** 비고에 `리뷰 왕복 3회 — 사람 확인 필요` 를 남긴다.

```bash
N="$(dobby_ship_round {키} wadiz-frontend {환경})" || exit   # 4회째면 여기서 멈춘다
```

회차는 이벤트 로그의 `PR 리뷰 {N}회차` 줄을 세어 정한다. 그래서 반영 후 반드시 남긴다.

→ `dobby_event {키} "PR 리뷰 {N}회차 — {요약}"`

**같은 지적이 두 번 나오면 상한 전이라도 멈춘다.** 고쳤는데 또 나왔다는 것은 잘못 고쳤다는 뜻이고, 이건 세는 것으로는 못 잡아 사람이 봐야 한다.

### 5. 머지 ⛔ 사용자 확인 — ① `wadiz-frontend` → ② `com.wadiz.web`

**`stage` 는 여기서 끝난다.** 양쪽 저장소 모두 PR 을 만들어 두고 `dobby_ship_stage {키} {저장소} stage "머지 대기"` 로 적은 뒤, 사용자에게 PR 주소를 알리고 멈춘다. 스테이지 반영은 **시점을 사람이 고르는 일**이라 스킬이 정하지 않는다(훅 G1 도 stage 머지를 막는다).

`dev`·`rc1`·`rc4` 는 이어서 간다.

**묻는다.** 다음을 보여 주고 승인을 받는다. 저장소가 둘이면 **한 번에 묻고 순서대로 처리한다.**

```
① wadiz-frontend  PR #29399  feature/FE1-1982 → rc4
   승인  wadiz-chulki-kim (자동 코드리뷰) · 12개 파일 +140 −86
② com.wadiz.web   PR #11131  feature/FE1-1982 → rc4   (리뷰 없음 · ① 머지 뒤)
   3개 파일 +24 −8
머지할까요?
```

**왜 묻는가**: 승인을 준 것이 **사람이 아니라 봇**이다. "크리티컬 없음"은 "머지해도 된다"와 다르다. 봇 승인만 보고 자동으로 머지하면 아무도 안 본 코드가 공용 브랜치에 들어간다. `com.wadiz.web` 은 아예 아무도 안 봤다.

승인받으면 **헬퍼로, 순서대로** 머지한다.

```bash
dobby_ship_merge {키} wadiz-frontend {FE PR번호}     # ① 먼저
dobby_ship_merge {키} com.wadiz.web  {WEB PR번호}    # ② FE 가 머지된 뒤에만 통과한다
```

| 헬퍼가 막는 것 | 왜 |
|---|---|
| 베이스가 그 저장소의 `dev`·`rc1`·`rc4` 브랜치가 아니면 거부 | stage·cloud_live·release/* 는 사용자가 직접 |
| 충돌(`CONFLICTING`)이면 거부 | 풀고 나서 온다 |
| 반영 안 한 변경요청이 남아 있으면 거부 | **기다리지 않고 온 `stage`·`dev`·`com.wadiz.web` 에서도 지적을 모르고 덮지 못하게 한다** |
| **G-A** `com.wadiz.web` 인데 같은 환경의 `wadiz-frontend` 가 아직 머지 전이면 거부 | 먼저 머지하면 한쪽만 반영된 상태로 배포가 돈다 |

충돌이면 워크트리에서 베이스를 머지해 풀고 푸시한 뒤 다시 한다. 못 풀면 무엇이 부딪혔는지 알리고 멈춘다.

**①은 됐는데 ②가 막히면 되돌리지 않는다.** FE 는 이미 나갔으니, 무엇이 왜 막혔는지 알리고 멈춘다 — 되돌릴지는 사람이 정할 일이다.

→ 머지 성공과 다음 단계(`빌드 대기`)는 **`dobby_ship_merge` 가 직접 적는다.** 따로 부르지 않는다.

### 6. 빌드 ⛔ 사용자 확인 — `wadiz-frontend` 만 건다

**`com.wadiz.web` 은 걸지 않는다.** 머지 push 가 `app-web-ci.yml` 을 자동으로 돌리므로, 또 걸면 **같은 빌드가 두 번 돈다.** 시작된 run 을 **잡기만** 한다.

```bash
dobby_ship_web_ci {키} {환경}        # run id 를 찾아 빌드 칸에 web#{run id} 로 적는다
```

머지 직후 3분 안에 run 이 안 나타나면 거부한다 — push 트리거가 안 걸렸다는 뜻이라 사람이 봐야 한다.

아래는 `wadiz-frontend` 이야기다. **어느 번들을 다시 빌드해야 하는지**를 먼저 판정한다. 변경 파일 경로로 정한다.

| 바뀐 경로 | 워크플로 |
|---|---|
| `apps/global/` | `app-global-ci-cd.yml` |
| `apps/account/` | `app-global-account-ci-cd.yml` |
| `static/services/admin/` | `app-static-ci-cd.yml` (+ `build_entry_all=true` + `build_admin=true`) |
| `static/` (admin 제외) | `app-static-ci-cd.yml` (+ `build_entry_all=true`) |
| `studio/` | `app-studio-ci-cd.yml` |
| `packages/`·`libraries/` | 아래 ②로 가른다 |

### ⛔ 공용 꾸러미를 고쳤다고 그것을 쓰는 번들을 전부 빌드하지 않는다

배럴(`@wadiz/api/web`)을 여러 번들이 나눠 쓰므로, "쓰면 빌드"로 정하면 **동작이 하나도 안 바뀌는 번들까지** 빌드한다. 실측 FE1-1787: 친구 관리 화면만 고쳤는데 `account`·`admin` 이 켜졌다 — 둘 다 그 화면을 그리지 않는데, 바뀐 `packages/api/src/web/social.service.ts` 가 든 배럴을 함께 import 하기 때문이다.

두 단계로 가른다.

1. **직접 고친 번들은 무조건 빌드한다** — `apps/global/`·`static/`·`studio/` 안의 파일을 고친 번들.
2. **공용 꾸러미만 닿는 번들**은 **바뀐 파일이 내보내는 이름**을 그 번들 소스에서 찾아본다.

```bash
# 예: packages/api/src/web/social.service.ts 가 바뀌었을 때
grep -n "^export" packages/api/src/web/social.service.ts          # 내보내는 이름을 뽑고
grep -rn "{그 이름}" apps/account/src static/services/admin        # 그 번들이 쓰는지 본다
```

쓰면 빌드하고, **안 쓰면 빌드하지 않는다.** 확인이 안 되면 빌드한다(안전 쪽). 빌드하지 않기로 한 번들은 사용자에게 알릴 때 이유와 함께 적는다.

**묻는다.**

```
바뀐 파일 23개 → 다시 빌드할 번들: static, global
             (account·admin 은 공용 꾸러미만 닿고 쓰지 않아 제외)
rc4 로 빌드할까요?
```

승인받으면 번들마다 건다. **→ 헬퍼 `dobby_ship_build {키} {환경} {번들...}`**

```bash
dobby_ship_build {키} {환경} static global
dobby_ship_build {키} {환경} "static global"    # 한 덩어리로 줘도 같다
```

**번들을 셸 변수에 담아 넘기지 않는다.** 세션 셸이 zsh 면 `$BUNDLES` 가 나뉘지 않아 `"static global"` 이 통째로 한 번들 이름이 된다(실측: 이 때문에 빌드가 시작되지 않았다). 헬퍼가 두 형태를 모두 받도록 고쳤지만, **이름을 그대로 적는 것**이 가장 안전하다.

헬퍼가 번들마다 맞는 워크플로와 **빠지면 안 되는 옵션**을 붙여 준다.

```bash
# static — entry_all 을 반드시 붙인다
gh workflow run app-static-ci-cd.yml -f environment={환경} -f runner=self-hosted -f build_entry_all=true
# admin 이 포함되면 build_admin 도
gh workflow run app-static-ci-cd.yml -f environment={환경} -f runner=self-hosted -f build_entry_all=true -f build_admin=true
# 나머지
gh workflow run app-global-ci-cd.yml         -f environment={환경} -f runner=self-hosted
gh workflow run app-global-account-ci-cd.yml -f environment={환경} -f runner=self-hosted
gh workflow run app-studio-ci-cd.yml         -f environment={환경} -f runner=self-hosted
```

### ⛔ static 은 `build_entry_all=true` 가 없으면 반쪽만 빌드된다

`build-static.sh` 가 이 값으로 갈린다.

```bash
if [[ $BUILD_ENTRY_ALL == true || -z $GIT_PREVIOUS_TAG ]]; then
    yarn build $BUILD_OPTIONS                            # 엔트리 전부
else
    yarn build $BUILD_OPTIONS --since $GIT_PREVIOUS_TAG  # 직전 태그 이후 바뀐 것만
fi
```

빼면 lerna 가 "바뀐 패키지"만 골라 빌드한다. **공용 패키지(`packages/`)를 고쳤을 때 그것을 쓰는 엔트리가 안 잡히면 옛 번들이 그대로 남는다.** 그 상태로 테스트하면 수정 전 동작이 관측돼 코드 결함으로 오진한다(사례 FE1-1808).

저장소 자신의 정기배포도 이 값을 쓴다.

```bash
# schedule-prepare-branch-for-regular-release.yml
gh workflow run app-static-ci-cd.yml --field environment=stage \
  --field runner=self-hosted --field build_entry_all=true
```

실행 이름 꼬리의 ` - all` 이 이 값이 켜졌다는 표시다 — `static - CI/CD - dev - all (self-hosted)`.

건 직후 `gh run list --workflow={파일} --limit 1 --json databaseId,url` 로 run id 를 받아 적어 둔다.

→ 배포 표의 `배포 대기` 와 빌드 칸(`static#{run id} · global#{run id}`)은 **`dobby_ship_build` 가 직접 적는다.**

→ `dobby_event {키} "빌드 시작 — {번들들} @ {환경}"`

**왜 묻는가**: rc 환경은 **여러 사람이 같이 쓴다.** 내 오더가 머지됐다고 바로 배포하면 남이 테스트하던 것이 갈아엎힌다.

### 7. 배포 완료 확인

#### `wadiz-frontend` — 두 신호를 함께 본다

**㉠ 우리가 건 빌드** — 우리가 시작했으니 끝도 안다.

```bash
gh run watch {run-id} --exit-status
```

**㉡ 슬랙 배포 알림** — 남이 건 배포에 내 커밋이 묻어 나갈 수 있다. 이건 슬랙이 아니면 알 길이 없다.

```
채널   #배포-알림-dev · #배포-알림-rc · #배포-알림-live
형식   배포알림 RC: static-rc4-20260923-083521 #2801 배포 완료
       by {누가}
       * Merge pull request #29384 from wadiz-fe/feature/FE1-1943_into_rc4
       * fix: FE1-1983 …
```

커밋 목록에서 **이 오더의 PR 번호 또는 이슈 키**를 찾는다.

**언제 보나**: 빌드를 건 뒤 **3분 뒤부터 1분 간격**으로, 최대 15분. 실측 배포 시간은 **가장 빠름 1분 56초 · 평균 4분 09초 · 가장 느림 8분 33초**(12건)라 3분이면 첫 조회부터 잡히는 것도 있다.

→ `dobby_ship_stage {키} wadiz-frontend {환경} "배포 확인"`

#### `com.wadiz.web` — ⛔ 슬랙에는 안 뜬다

```bash
gh run watch {web run id} --repo wadiz-web/com.wadiz.web --exit-status
```

실측(2026-10-07 `#배포-알림-rc` 최근 30건): 전부 FE 번들(`static`·`global`·`global-account`·`studio`)이고 **`web-server` 는 한 건도 없다.** 채널 전체 검색에서 나온 2건은 2026년 6월의 `rc-web`·`rc2-web` — 지금 쓰지 않는 옛 Jenkins 환경이다. **슬랙을 기다리지 마라.** CI 가 끝나면 8번으로 간다.

CI 가 끝나도 **아직 배포가 아니다.** 이미지가 ECR 에 올라가고 gitops 의 이미지 태그가 바뀐 것뿐이다.

### 8. argocd sync ⛔ 사용자 확인 — `com.wadiz.web` (신규)

`wadiz-frontend` 배포가 **확인된 뒤에** 한다. 사용자 요구이자 둘이 같이 반영돼야 하기 때문이고, `dobby_ship_argo` 가 FE 행을 보고 이르면 거부한다(G-B).

**묻는다.**

```
wadiz-frontend  rc4 배포 확인 (static #2894 · global #3409)
com.wadiz.web   CI 완료 (web #37423509807)
→ argo/web-rc4-web-server @ argocd.rc4.wadiz.io 를 sync 할까요?
```

**왜 묻는가**: rc 환경은 여러 사람이 같이 쓴다. 빌드와 같은 이유다.

승인받으면 **헬퍼로** 한다. 생 `argocd` 를 치지 않는다.

```bash
dobby_ship_argo {키} {환경}
```

| 헬퍼가 막는 것 | 왜 |
|---|---|
| 환경이 `stage` 면 거부 | 머지가 사람 몫이니 배포도 사람 몫이다 |
| **G-B** 같은 환경의 `wadiz-frontend` 가 `배포 확인` 전이면 거부 | 둘이 같이 반영돼야 한다 |
| `com.wadiz.web` CI 가 `success` 가 아니면 거부 | 이미지가 없으면 sync 해도 **옛 이미지가 뜬다** |
| argocd 세션이 없으면 거부 | 재로그인은 브라우저 SSO 라 **사람만** 할 수 있다 |
| `app list` 에 그 앱이 없으면 거부 | 이름을 짐작해 엉뚱한 환경을 건드리지 않는다 |
| 앱 이름에 `-live-` 가 있으면 거부 | 훅 G1 과 이중으로 |

헬퍼가 `app sync` 뒤 `app wait --health --timeout 300` 까지 기다린다.

**세션이 끊겼으면 깨끗이 멈추고 사용자에게 이 줄을 알린다.** 대신 실행할 수 없다.

```
argocd login argocd.rc4.wadiz.io --sso --grpc-web
```

> 서버 두 곳에 동시에 로그인해 둘 수 없다 — 실측(2026-10-07) rc4 로그인 뒤 dev 에 로그인하니 rc4 가 `Refresh token is invalid or has already been claimed by another client` 로 끊겼다. 한 오더는 환경 하나로 나가므로 문제가 되지는 않지만, 끊긴 줄 모르고 지나가지 않게 헬퍼가 sync 전에 확인한다.

#### ⛔ sync 가 끝나도 파드 교체 전에는 옛 응답이 나온다

`com.wadiz.web` 은 **JSP 와 `urlrewrite.xml` 이 컨테이너 이미지 안에** 들어 있다. `urlrewrite.xml`·컨트롤러 변경은 필터 init 에서 한 번만 읽으므로 **파드가 새로 떠야** 반영된다.

바뀐 지면을 **읽기 전용 GET 으로** 폴링해 반영 시점을 잡은 뒤 검증을 연다.

```bash
curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}\n' "https://rc4.wadiz.io{경로}"
```

⛔ **PG 콜백·POST·결제·취소·해지는 절대 호출하지 않는다.** GET 만 쓴다.

여기를 건너뛰면 **수정 전 동작이 관측돼 코드 결함으로 오진한다** — `FE1-1808`(반쪽 배포를 코드 결함으로 오진)과 같은 함정이 저장소만 바뀌어 재현된다.

### 9. 검증 실행

배포가 **완료됐다고 확인되면 바로 테스트한다.** 번들이 다 올라갔는지 미리 세지 않는다.

```
/dobby-test {키}
```

환경 인자로 방금 배포한 환경을 넘긴다. `dobby-test` 에도 선확인 단계가 있어 한 번 더 걸러 준다. **저장소가 둘이어도 검증은 한 번**이다 — 사용자가 보는 것은 화면 하나지 저장소가 아니다.

→ `dobby_ship_stage {키} {저장소} {환경} "검증 중"` (맡은 저장소마다)

**왜 미리 안 세나**: 번들 대조는 맞아떨어질 때는 아무것도 알려 주지 않고, 기다리게만 한다. 반쪽 배포는 **테스트가 실패로 드러내 준다.** 그때 원인을 가르는 데 쓰는 편이 값이 크다.

### 10. 실패했을 때 — 배포부터 본다

테스트가 실패하면 **코드를 의심하기 전에 배포부터 확인한다.** 저장소마다 볼 것이 다르다.

**`wadiz-frontend` — 번들이 다 올라갔나**

```bash
dobby_ship_verify {키} "static global" "static" {환경}
```

```
배포가 확인되지 않은 번들이 있다: global
(필요: static global / 확인: static)
```

빠진 게 있으면 **코드 결함이 아니라 반쪽 배포다.** 그 번들만 다시 빌드(6단계)하고 배포를 기다린 뒤 회차를 다시 연다.

**`com.wadiz.web` — sync 됐나, 파드가 바뀌었나**

```bash
dobby_ship_argo {키} {환경} check      # sync 하지 않고 보기만 한다
```

```
NAME                      STATUS      HEALTH
argo/web-rc4-web-server   OutOfSync   Healthy     ← sync 가 빠졌다
argo/web-rc4-web-server   Synced      Progressing ← 파드가 아직 교체 중이다
```

- `OutOfSync` → 8단계를 안 했거나 그 뒤에 새 CI 가 돌았다. 다시 sync 한다.
- `Synced` + `Progressing` → **파드 교체 중이다.** 조금 더 기다렸다 지면 GET 으로 확인하고 회차를 다시 연다.
- `Synced` + `Healthy` 인데도 옛 화면이면 지면 GET 으로 실제 응답을 확인한다.

⛔ **반쪽 배포를 코드 결함으로 오진하지 않는다.** 사례 FE1-1808: 빌드가 머지보다 68분 앞선 상태로 회차를 열어 **0성공/3실패/4건너뜀**. 재배포 후 같은 절차로 9/0/0 통과 — 방법이 아니라 **순서**가 문제였다. 실패를 보면 먼저 이걸 의심한다.

빠진 것이 없는데도 실패했으면 그때가 진짜 코드 문제다.

→ `dobby_event {키} "배포 확인 — {번들}@{환경} {빌드번호}"`

### 11. 마감

→ `dobby_ship_stage {키} {저장소} {환경} "검증 완료"` (맡은 저장소마다)

사용자에게 한눈에 보여 준다. **저장소마다 한 줄**이다.

```
FE1-1787  →  rc4  검증 완료

wadiz-frontend  PR #29399 머지 (리뷰 1회차 통과) · static #2801 · global #3276
com.wadiz.web   PR #11131 머지 (리뷰 없음) · web #37423509807 · sync 10:42 Healthy
검증            /dobby-test 3회차 12건 통과
```

## status.md 에 적는 것

`## 배포` 표에 **(저장소, 환경)마다 한 행**. 다음에 이 스킬이 불렸을 때 어디부터 이어서 할지를 이 표로 정하고, **저장소 사이의 순서(G-A·G-B)도 이 표를 보고 센다.**
직접 쓰지 말고 **→ 헬퍼 `dobby_ship_stage {키} {저장소} {환경} "{단계}" [PR] [빌드] [비고]`** 로 남긴다.

```markdown
## 배포
| 저장소 | 환경 | 단계 | PR | 빌드 | 갱신 | 비고 |
|---|---|---|---|---|---|---|
| wadiz-frontend | rc4 | 검증 완료 | #29463 | static#36387729548 · global#36387738312 | 2026-09-28 16:03 | |
| com.wadiz.web | rc4 | 검증 완료 | #11131 | web#37423509807 · sync#20261007-1042 | 2026-09-28 16:21 | |
```

**단계 어휘는 아홉 개 그대로다 — `com.wadiz.web` 에도 새 낱말을 만들지 않았다.** 뜻만 저장소에 맞게 읽는다.

| 단계 | `wadiz-frontend` | `com.wadiz.web` |
|---|---|---|
| `리뷰 대기`·`리뷰 반영 N회차` | 쓴다 | **안 쓴다** (리뷰봇이 없다) |
| `머지 대기` | 리뷰 통과, 머지 차례 | **FE 머지를 기다리는 중** |
| `빌드 대기` | 머지됨, 빌드 걸 차례 | 머지됨, **자동 CI 가 도는 중** |
| `배포 대기` | 빌드 걸었고 배포 기다림 | CI 끝남, **argocd sync 차례** |
| `배포 확인` | 슬랙 알림으로 확인 | **sync + Healthy 통과** |

여기 없는 값을 넘기면 헬퍼가 거부한다.

```
PR 생성 → 리뷰 대기 → 리뷰 반영 N회차 → 머지 대기 → 빌드 대기
              └ 리뷰 취소 (PR 이 머지 없이 닫힘 — 여기서 멈춘다)
        → 배포 대기 → 배포 확인 → 검증 중 → 검증 완료
```

| 칸 | 규칙 |
|---|---|
| PR · 빌드 | 비우면 **그대로 둔다**(머지 단계에서 PR 번호가 지워지지 않게). 지우려면 `-` |
| 비고 | 비우면 **지운다**. 비고는 "지금 막혀 있다"는 뜻이라 단계가 나아가면 사라져야 한다 |
| 단계 뒤 `⚠` | 비고가 있으면 자동으로 붙는다 — **막힘은 단계가 아니라 사고다** |

다섯 자리는 **헬퍼가 알아서 적는다.** 스킬이 부르는 것은 `리뷰 대기`·`리뷰 취소`·`배포 확인`·`검증 중`·`검증 완료` 다섯뿐이다.

**`리뷰 취소`** 는 PR 이 **머지 없이 닫힌** 자리다. 리뷰가 문제를 잡아 되돌렸거나 사람이 접은
경우이고, 그대로 두면 `리뷰 대기` 로 남아 «아직 기다리는 중»으로 읽힌다. 비고에 **왜 닫혔는지**를
적고 멈춘다. 다시 가려면 원인을 고쳐 PR 을 새로 만들어야 한다.

| 헬퍼 | 적는 것 |
|---|---|
| `dobby_ship_pr` | `PR 생성` + PR 번호 |
| `dobby_ship_round` | `리뷰 반영 N회차` (4회째면 비고에 사유) |
| `dobby_ship_merge` | `빌드 대기` |
| `dobby_ship_build` | `배포 대기` + 빌드 칸 (`wadiz-frontend`) |
| `dobby_ship_web_ci` | `빌드 대기` + 빌드 칸 `web#{run id}` (`com.wadiz.web`) |
| `dobby_ship_argo` | `배포 확인` (`com.wadiz.web`) |
| `dobby_ship_verify` | 빠진 번들이 있으면 비고 |

## 주의

- **추측하지 않는다.** 리뷰 지적이 타당한지, 어느 번들이 영향을 받는지 — 전부 코드를 열어 확인한다. 부득이 추측이 섞이면 추측이라 밝히고 근거를 댄다.
- **머지·빌드·argocd sync 는 사람에게 묻는다.** 되돌리기 어렵고 남에게 영향을 준다.
- **두 저장소의 순서를 지킨다.** 머지는 FE 뒤에, 배포는 FE 배포 뒤에. 헬퍼가 막지만 순서를 알고 움직여야 헛걸음이 없다.
- **`clive`(cloud_live)로는 가지 않는다.** 라이브 반영은 별도 릴리스 절차다.
- **한 번에 다 못 해도 된다.** 기다릴 수 없는 곳에서 깨끗이 멈추고 배포 단계를 남기는 것이, 억지로 진행하는 것보다 낫다.
- 진행 상황은 **한국어와 존댓말**로 적는다.

## 무엇이 코드로 강제되나

글로 적은 ⛔ 는 지켜지지 않는다. 지켜야 하는 것은 **거부하는 함수**와 **훅**으로 내려가 있다.

| 강제되는 것 | 어디서 |
|---|---|
| cloud_live 로 PR·push·머지·빌드 | 훅 G1 (생 명령도 막힌다) |
| **라이브 argocd 앱 sync · `--server` 없는 sync** | **훅 G1** |
| 머지 베이스가 dev·rc1·rc4·cloud_dev 인지 | 훅 G1 + `dobby_ship_merge` |
| 저장소마다 맞는 베이스 브랜치 | `dobby_ship_pr` (`_ship_branch`) |
| 미커밋 상태로 PR | `dobby_ship_pr` |
| 리뷰어 누락·오부착 | `dobby_ship_pr` (리뷰봇 있는 저장소에만 자동 부착) |
| PR 중복 생성 | `dobby_ship_pr` |
| 충돌·미반영 변경요청 상태로 머지 | `dobby_ship_merge` |
| **G-A FE 머지 전에 com.wadiz.web 머지** | **`dobby_ship_merge`** |
| **G-B FE 배포 전에 argocd sync** | **`dobby_ship_argo`** |
| **CI 실패·미완 상태로 sync** | **`dobby_ship_argo`** |
| **argocd 세션 없이·모르는 앱으로 sync** | **`dobby_ship_argo`** |
| 리뷰 왕복 4회 이상 | `dobby_ship_round` |
| 반쪽 배포로 테스트 | `dobby_ship_verify` · `dobby_ship_argo {키} {환경} check` |
| 배포 단계 어휘·환경·저장소가 정본 밖 | `dobby_ship_stage` |
| 단계 기록 누락 | 헬퍼 일곱이 **자기가 한 일을 직접 적는다** |

**여기 없는 것은 판단이라 강제할 수 없다** — 지적이 타당한가, 무엇을 고칠 것인가, PR 본문을 어떻게 쓸 것인가. 그건 이 문서가 맡는다.
