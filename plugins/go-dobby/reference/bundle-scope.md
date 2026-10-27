# 영향 번들 판정 (테스트 설계 공통)

테스트 계획을 쓰는 스킬(`do` 설계 세션, `dobby-start`, `dobby-test`)이 **시나리오를 쓰기 전에** 따르는 단일 출처다.

## 왜 먼저 판정하나

`wadiz-frontend` 는 화면 묶음(번들) 네 개를 **따로 빌드하고 따로 배포한다.** 공용 꾸러미(`packages/`)를 고치면 그 코드가 여러 번들에 동시에 들어간다. 그런데 시나리오를 "사용자에게 보이는 페이지"부터 떠올리면, 이슈에 적힌 화면 하나만 떠올리고 끝난다. 그 화면이 속한 번들만 확인되고, 같은 코드를 쓰는 **다른 번들의 화면은 확인 없이 나간다.**

번들마다 따로 봐야 하는 이유는 세 가지다.
- 빌드와 배포가 따로라서, 한 번들은 새 코드이고 다른 번들은 옛 코드일 수 있다.
- 같은 컴포넌트라도 둘러싼 환경이 다르다. 국제화 초기화 여부, 스타일, 로그인 방식이 번들마다 다르다(사례 FE1-1317: 어드민에서 공용 컴포넌트가 국제화 초기화가 없어 렌더 즉시 멈췄다).
- 그래서 한 번들에서 통과했다고 다른 번들도 통과라고 볼 근거가 없다.

## 네 번들

| 번들 | 소스 경로 | 올라가는 곳 | 화면이 뜨는 곳 | 빌드 헬퍼 이름 |
|---|---|---|---|---|
| `static` | `static/` (`entries/*`, `services/admin`, `packages/`, `libraries/`) | `wadiz.static.{환경}/` 맨 위 | `com.wadiz.web` 의 JSP 페이지가 `/static/{엔트리}/bundle.js` 로 불러 그리는 국내 레거시 화면. `static/entries/web` 은 **모든 JSP 페이지**가 먼저 불러오는 공통 엔트리다. `static/services/admin` 은 어드민 화면이다 | `static` (어드민은 `admin`) |
| `static-global` | `apps/global/` | `wadiz.static.{환경}/global` | 글로벌 화면(한 페이지짜리 앱). 국내 화면 일부도 이 번들이 그린다(`apps/global` 안의 `korea-routes/`) | `global` |
| `static-account` | `apps/account/` | `wadiz.static.{환경}/global-account` | 통합 로그인·회원가입·비밀번호 찾기·소셜 연동·탈퇴 화면. 주소는 `account.{환경}.wadiz.io` 꼴이다(live 는 `account.wadiz.io`) | `account` |
| `studio` | `studio/` (`funding`, `store`, `startup`, `studio-services` 등) | `wadiz.static.{환경}/studio` | 메이커가 펀딩·스토어 프로젝트를 만들고 관리하는 스튜디오 화면 | `studio` |

근거:
- 올라가는 곳은 `wadiz-frontend/.github/workflows/app-cd.yml` 의 `Set S3_BUCKET_PATH` 단계다. `static` 이 아니면 앱 이름을 하위 폴더로 붙인다.
- static 의 JSP 로드 규칙은 `wadiz-frontend/static/CLAUDE.md` 의 "JSP 번들 로드 규칙"이다.
- account 주소는 도서관 `~/work/repos/docs/wadiz-frontend/api-details/apps-user-facing.md` 의 `apps/account` 절이다.

번들 이름은 배포 위치를 따라 적는다. 빌드할 때 `dobby_ship_build` 에 넘기는 이름은 마지막 칸이다.

## 판정 순서

### 1. 바뀌는 파일 목록을 잡는다

- 설계 단계면 설계 문서(또는 분석 문서)의 **고칠 파일 목록**을 쓴다.
- 구현이 끝났으면 `git diff --name-only origin/{base}...{branch}` 를 쓴다.
- `wadiz-frontend` 파일이 하나도 없으면(예: `com.wadiz.web` 만 고침) 판정은 여기서 끝난다. 표에 "해당 없음 — wadiz-frontend 변경 없음" 한 줄만 적는다.

### 2. 경로로 바로 정해지는 번들

| 바뀐 경로 | 번들 |
|---|---|
| `static/` 아래 | `static` |
| `apps/global/` 아래 | `static-global` |
| `apps/account/` 아래 | `static-account` |
| `studio/` 아래 | `studio` |

`static/entries/web/` 을 고쳤으면 모든 JSP 페이지에 들어간다. 시나리오의 대상 화면을 이슈 화면 하나로 좁히지 말고, 성격이 다른 JSP 화면을 하나 더 넣는다.

### 3. 공용 꾸러미(`packages/` 등)는 실제로 쓰는지 찾아본다

공용 꾸러미를 "가져다 쓰는 번들 전부"로 잡지 않는다. 묶음 파일(배럴, 여러 파일을 한 이름으로 다시 내보내는 파일)을 통째로 가져오는 번들은, 바뀐 기능을 쓰지 않아도 걸린다(사례 FE1-1787: 친구 관리 화면만 고쳤는데 쓰지 않는 `account`·`admin` 이 걸렸다).

바뀐 파일이 **내보내는 이름**을 뽑고, 네 번들의 소스에서 그 이름을 찾는다.

```bash
# 예: packages/features/src/feed/FeedList.tsx 가 바뀌었을 때
grep -n "^export" packages/features/src/feed/FeedList.tsx                 # 내보내는 이름
grep -rln "FeedList" static/entries static/services apps/global/src apps/account/src studio \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' | grep -v node_modules
```

- 찾은 곳이 또 다른 공용 꾸러미 파일이면, 그 파일이 내보내는 이름으로 한 번 더 찾는다. 공용 컴포넌트가 다른 공용 컴포넌트 안에 들어가 번들에 닿는 경우가 많다.
- 쓰는 곳이 있으면 **영향**이다. 근거 칸에 `파일:라인` 을 적는다.
- 쓰는 곳이 없으면 **제외**다. 근거 칸에 찾은 명령과 "0건"을 적는다.
- 찾아도 판단이 서지 않으면 **영향**으로 둔다(안전 쪽). 근거 칸에 왜 판단이 안 섰는지 적는다.

### 4. 영향인 번들에서 그 코드가 화면에 나오는지 본다

가져오는(import) 파일이 있다고 그 화면이 실제로 뜨는 것은 아니다. **빌드에 들어가는 것**과 **사용자가 그 화면을 보는 것**은 다르다. 시나리오를 쓰기 전에 그려지는 길을 끝까지 따라간다.

1. 그 컴포넌트를 그리는 조건을 찾는다. 라우트 정의, 창을 여는 함수(`useOpenModalPortal` 등)의 호출처, 주소 쿼리로 여는 처리(`useAutoOpenModalFromURL` 등)다.
2. 그 조건이 요구하는 주소를 **어느 번들이 그리는지** 확인한다. JSP 화면은 도서관의 `com.wadiz.web.md` 컨트롤러 표로, 실제 환경은 그 주소의 HTML 이 불러오는 번들 파일로 본다. ⛔ 정적 라우터에 경로가 있다고 그 번들이 그린다고 보지 않는다 — 서버가 다른 번들을 내려 주는 주소가 있다(아래 표).

   ```bash
   curl -s https://rc4.wadiz.io/{경로} | grep -o 'cdn-static[^"]*\(main/main\.js\|korea-main\.js\)'
   ```
3. 2번의 번들이 1번의 컴포넌트가 든 번들과 다르면, 그 컴포넌트는 **화면에 닿지 않는다.**

화면에 닿지 않으면 이렇게 적는다.

- 판정은 **영향**(빌드는 필요하다)으로 두고, 근거 칸에 `화면 닿지 않음 — {1~3번 근거}` 를 적는다.
- 그 컴포넌트를 직접 여는 시나리오는 만들지 않는다. 대신 그 번들이 **실제로 그리는 화면**에서 오류 없이 뜨는지 보는 회귀 시나리오를 하나 둔다.

이미 확인된 닿지 않는 길이다. 같은 컴포넌트를 고치면 다시 확인하지 말고 이 사실을 쓴다.

| 컴포넌트 | 열리는 조건 | 닿지 않는 이유 | 확인한 오더 |
|---|---|---|---|
| `static/entries/main/src/pages/portal/MainModalPortal.jsx` 의 `RewardsSelectionModal` | `/web/campaign/detail/{번호}?modal=reward-selection`, 모바일 폭 | 그 주소는 `GlobalKoreaFundingDetailController` 가 글로벌 앱(`global/korea-main.js`)으로 그린다(`com.wadiz.web.md:1063`). static 메인 라우터의 상세 경로는 316736 을 스토어로 보내는 것 하나뿐이다(`RouterConfig.tsx`). 같은 쿼리는 `apps/global/src/app/ModalPortal.tsx` 가 글로벌 창으로 연다 | FE1-2164(2026-10-26), FE1-2261(2026-10-27) |
| `static/entries/main/src/routes/RouterConfig.tsx` 의 `web/main/earlybird`·`web/main/planned` 화면 | 정적 메인 라우터에 경로가 있음 | 서버가 그 주소에 글로벌 앱(`global/korea-main.js`)을 내려 준다(rc4 HTML 확인). PC 폭이면 정적 라우터도 `/web/main` 으로 돌려보낸다(`RedirectToMainWithParams`). 같은 날 `main/main.js` 를 내려 준 주소는 `/web/wish/main`·`/web/wadiztraders`·`/web/wevent/wadizawards`·`/web/iplicense/main`·`/web/project/registration` | FE1-2261(2026-10-27) |

사례: FE1-2164 가 이 창의 시나리오 S25·S45 를 네 회차에 걸쳐 `SKIP(환경)` 으로 남긴 뒤 닿지 않음을 확인했다. 그런데 그 브랜치에서 딴 FE1-2261 이 같은 창을 영향 화면으로 다시 올리고, 있지도 않은 "찜 카드의 리워드 선택 버튼"을 진입으로 적었다.

## 테스트 계획에 적는 법

테스트 계획 맨 앞(사전 준비 바로 뒤)에 `## 영향 번들` 표를 둔다. **네 번들을 모두 한 줄씩** 적는다. 빠진 줄은 판정하지 않은 것으로 본다.

```markdown
## 영향 번들
| 번들 | 판정 | 근거 | 확인 시나리오 |
|---|---|---|---|
| static | 영향 | `static/entries/main/src/pages/feed/FeedPage.jsx` 직접 수정 | S1, S3 |
| static-global | 영향 | 바뀐 `FeedList` 를 `apps/global/src/pages/feed/FeedPage.tsx:12` 가 씀 | S2 |
| static-account | 제외 | `FeedList` 를 쓰는 곳 0건 (`grep -rln FeedList apps/account/src`) | — |
| studio | 해당 없음 | 닿는 파일 없음 | — |
```

- **영향인 번들마다, 그 번들이 그리는 화면에서 확인하는 시나리오를 최소 하나** 둔다. 같은 공용 컴포넌트를 확인하더라도 번들이 다르면 시나리오를 따로 만든다.
  - 근거 칸이 `화면 닿지 않음` 인 번들은 그 번들이 실제로 그리는 화면의 회귀 시나리오로 채운다(판정 순서 4). 이 규칙을 채우려고 닿지 않는 화면의 시나리오를 지어내지 않는다.
- 각 시나리오 머리에 `- **번들**: static-global` 처럼 그 시나리오가 확인하는 번들을 적는다. 표의 "확인 시나리오" 칸과 맞아야 한다.
- 시나리오의 대상 주소는 그 번들이 실제로 그리는 화면이어야 한다. 예를 들어 `static-global` 시나리오가 JSP 화면 주소를 가리키면 그 번들을 확인한 것이 아니다. 어느 번들이 그 주소를 그리는지 모르면 코드의 경로 정의(라우트)에서 찾는다.
- 회귀 확인 시나리오도 이 규칙을 따른다. 영향 번들이 둘이면 회귀 확인도 번들마다 둔다.

## 검증할 때

- 배포 반영 확인(새 코드가 실제로 올라갔는지)은 영향 번들마다 따로 한다. 한 번들이 올라갔다고 다른 번들도 올라갔다고 보지 않는다.
- 회차를 열기 전에 표를 다시 본다. 영향인데 시나리오가 없는 번들이 있으면 시나리오를 더한 뒤에 연다.
- 확인할 수 없는 번들이 있으면(예: 그 환경에 배포가 안 됨) 시나리오를 빼지 말고 판정을 `SKIP(사유)` 로 남긴다.
