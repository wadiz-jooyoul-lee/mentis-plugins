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
- 각 시나리오 머리에 `- **번들**: static-global` 처럼 그 시나리오가 확인하는 번들을 적는다. 표의 "확인 시나리오" 칸과 맞아야 한다.
- 시나리오의 대상 주소는 그 번들이 실제로 그리는 화면이어야 한다. 예를 들어 `static-global` 시나리오가 JSP 화면 주소를 가리키면 그 번들을 확인한 것이 아니다. 어느 번들이 그 주소를 그리는지 모르면 코드의 경로 정의(라우트)에서 찾는다.
- 회귀 확인 시나리오도 이 규칙을 따른다. 영향 번들이 둘이면 회귀 확인도 번들마다 둔다.

## 검증할 때

- 배포 반영 확인(새 코드가 실제로 올라갔는지)은 영향 번들마다 따로 한다. 한 번들이 올라갔다고 다른 번들도 올라갔다고 보지 않는다.
- 회차를 열기 전에 표를 다시 본다. 영향인데 시나리오가 없는 번들이 있으면 시나리오를 더한 뒤에 연다.
- 확인할 수 없는 번들이 있으면(예: 그 환경에 배포가 안 됨) 시나리오를 빼지 말고 판정을 `SKIP(사유)` 로 남긴다.
