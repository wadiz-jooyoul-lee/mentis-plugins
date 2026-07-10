# 멀티 저장소 오케스트레이션 견본 — Google One Tap (FE1-1212)

프론트(`wadiz-frontend`)와 백엔드(`kr.wadiz.account`) 두 저장소에 걸친 상위이슈를 나눈 실제 예시. 절차의 각 단계가 어떻게 적용되는지 보여주는 참고용이며, 값은 이 케이스 기준이다.

## 분석 (P1 이전, 저장소별 병렬 Explore)

- **FE**: One Tap/GIS/feature-flag 코드 전무(신규). 재사용 가능 — state API(`packages/api/.../social.service.ts`), 신규가입 라우트 `/social-signup`(세션 쿠키 기반), 트래킹 `@wadiz/metrics`, 로그인 판별 `useIsLoggedInQuery`/`AccountSettings.isLoggedIn`, 전역 마운트 `apps/global/src/app/AppLayout.tsx`·`apps/account App.tsx`. 신규 패키지는 소비 앱마다 `vite alias + tsconfig paths` 양쪽 등록 필요.
- **BE**: 자체가 OAuth2 인가서버. Google 클라이언트·`GoogleAccount`·변환기 이미 존재. **ID Token 검증기(`OpenIdTokenVerifyParser`, 현재 Apple 전용)가 Nimbus로 이미 구현 → Google용 재사용 가능.** 신규/기존 분기는 `SocialUserService`에 존재. 제약: 최종 JWT는 `/oauth/token` 교환으로만 발급, WRMAT 쿠키는 REST 경로에서 자동 발급 안 됨(명시 발급 필요), CSRF 전역 disable, COOP 헤더·nonce 로직 없음(신규).

## 교차 저장소 API 계약 (P3에서 먼저 확정)

- **요청** `POST /oauth2/google/onetap`: `{ credential(=google id_token), nonce, rememberme, returnUrl }`
- **응답**: `{ status: LOGIN | SIGNUP_NEEDED | LINK_NEEDED | …, redirectUrl }` + `WRMAT` Set-Cookie
- FE `verifyIdToken`은 이 계약에 맞춰 구현, BE 컨트롤러는 이 계약을 노출. status는 BE 기존 예외와 1:1 매핑.

## 에이전트 배분 (repo 단위 오너십, 파일 충돌 0)

| 에이전트 | 저장소 | 오너십(수정 허용) | 내용 |
|---|---|---|---|
| FE-pkg | wadiz-frontend | `packages/google-one-tap/**`(신규) | GIS 로더·컴포넌트·훅·verifyIdToken·상수·표시 억제 규칙·트래킹·신규가입 분기 |
| FE-int | wadiz-frontend | `apps/global`·`apps/account`의 `vite.config.ts`·`tsconfig.json`·마운트 파일 | alias/paths 등록 + 마운트 + 노출 플래그 게이팅 |
| BE-extract | kr.wadiz.account | 로그인 성공 후처리 서비스 | 후처리를 GoogleAccount 입력 메서드로 추출 + REST용 WRMAT 명시 발급 |
| BE-onetap | kr.wadiz.account | `adapters/inbound`(신규 컨트롤러/DTO)·Google id_token 파서 Bean·nonce Redis | `POST /oauth2/google/onetap` + 검증 + 상태 매핑 |

## 병렬/순차 판정

- **FE ↔ BE**: 레포가 달라 파일 충돌 0 → 완전 병렬. 단 FE `verifyIdToken`이 API 계약에 의존 → 계약 확정이 선행.
- **BE 내부**: BE-extract → BE-onetap 순차(컨트롤러가 추출 메서드에 의존).
- **FE 내부**: FE-pkg → FE-int(int가 패키지 export에 의존). export 계약 고정 시 병렬 가능하나 int가 소량이라 순차가 churn이 적음.

## 코드 밖(에스컬레이션)

- Google Console에 JavaScript origins 등록(콘솔 설정)
- 저장소 간 배포 순서(BE 먼저)
- 설계 문서 §10 제품 결정(마운트 범위·연동 정책·웹뷰 처리·롤아웃·쿨다운) — 프론트에 GrowthBook이 없어 롤아웃 플래그 메커니즘 자체가 신규 결정
