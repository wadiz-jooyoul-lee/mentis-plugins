# mentis-plugins

Jira 이슈 생명주기와 멀티 에이전트 오케스트레이션을 담은 Claude Code 플러그인 마켓플레이스입니다. 두 플러그인을 제공합니다:

- **`work-dobby`** — 이슈의 **착수 → 구현 → 테스트 → 종료** 생명주기 + 멀티 에이전트 오케스트레이션 (원본).
- **`go-dobby`** — work-dobby를 재설계한 **단일 진입점 오케스트레이션**. 모든 이슈/작업을 `dobby-order` 하나로 시작해 필요한 에이전트 수(팬아웃 K)를 스스로 판단해 진행합니다. 설계 상세는 `plugins/go-dobby/reference/redesign-spec.md` 참고.

## work-dobby 스킬

**단독 이슈 생명주기** (`issue-start → issue-impl → issue-test → issue-end`)

| 스킬 | 역할 |
|------|------|
| `issue-start` | 이슈 착수 — 워크트리·브랜치 생성 + 코드 분석 + 테스트 목록 초안 |
| `issue-impl` | 이슈 구현 — 분석 설계대로 구현 + 적대적 셀프 코드리뷰 + 커밋·푸시 + (리뷰 안정 시) 베이스 머지 |
| `issue-test` | 이슈 테스트 — chrome-devtools로 시나리오 검증, 결과 리포트 |
| `issue-end` | 이슈 종료 — 마무리·워크트리 정리 |

**멀티 에이전트 오케스트레이션**

| 스킬 | 역할 |
|------|------|
| `i-order-you-to-develop` | 메인 오케스트레이터 — 하위이슈 분배·구현·리뷰 루프·통합 |
| `agent-start` | 멀티 에이전트용 착수·분석 + 오케스트레이션 메타(계약·보드) 규격 |
| `agent-impl` | 서브 에이전트의 구현 단계 (자기 워크트리·계약 범위 안에서 구현·커밋·리뷰 요청) |

## go-dobby 스킬 (재설계)

모든 작업을 **`dobby-order` 하나로 시작**합니다. 진입 후 코드 범위(파일 오너십)로 에이전트 수(K)를 판단해 — 단일 버그면 K=1, 에픽/여러 영역이면 K≥2 — 착수·구현·리뷰·통합을 오케스트레이션합니다. 이슈 없이 **문서만 주는 진입**(`TASK-{slug}`)도 지원합니다.

| 스킬 | 역할 | 호출 |
|------|------|------|
| `dobby-order` | 유일 진입점 — 팬아웃 K 판단·착수·구현·리뷰·통합 오케스트레이션 | 사용자 |
| `dobby-start` | 에이전트별 착수·분석 (베이스 로컬/원격 모두 처리, docs 2단계 참조) | 내부 |
| `dobby-impl` | 에이전트별 구현·자기 브랜치 푸시·리뷰 피드백 반영 | 내부 |
| `dobby-test` | 실브라우저 검증 (자동 해결 승격 없음) | 사용자 |
| `dobby-resolve` | 해결 표시 — 상태만 `해결`, 폴더 유지(비파괴) | 사용자 |
| `dobby-end` | 워크트리 정리 — 스냅샷 후 제거(브랜치 보존) | 사용자 |

주요 차이: 단독/오케스트레이션 경로 단일화, 이슈당 폴더 1개(`$DOBBY_META/{키}/`) + 단일 status.md 인덱스, 코드리뷰는 오케스트레이터가 단독 수행, 정식 배포 베이스로의 PR·머지 금지(최종 반영은 사용자 수동 PR).

## 설정 (첫 실행 시 1회)

스킬을 처음 실행하면 아래 값을 확인해 `~/.config/work-dobby/config.env`에 저장하고 이후 재사용합니다. **기본값이 있는 항목은 현재 값을 보여주고 변경 의사를 묻고**, 선택 항목은 건너뛸 수 있습니다.

| 변수 | 뜻 | 기본값 |
|------|----|--------|
| `JIRA_BASE_URL` | Jira 호스트 | `https://wadiz.atlassian.net` |
| `DOBBY_WORKSPACE` | 작업 루트(하위 `subtree/`·`meta/`) | `$HOME/work/dobby-workspace` |
| `DOBBY_META_PATH` (선택) | 메타 경로 직접 지정(subtree와 분리) | 없음 → `$DOBBY_WORKSPACE/meta` |
| `DOBBY_DEFAULT_BASE` | 기본 베이스 브랜치 | `master` |
| `DOBBY_REPOS_ROOT` | 원본 저장소 상위 폴더 (소스 루트 = `$DOBBY_REPOS_ROOT/{repo}`) | `$HOME/work/repos` |
| `DOBBY_ENV_MAP` | 테스트 환경→호스트 매핑 | `dev=dev.wadiz.io,rc=rc.wadiz.kr,rc2=rc2.wadiz.kr,rc4=rc4.wadiz.io` |
| `DOBBY_DOCS_ROOT` | 참고 문서 루트 (`{repo}.md` 또는 `{repo}/`, 없으면 소스 확인) | `$HOME/work/repos/docs` |
| `TEST_LOGIN_ID`/`TEST_LOGIN_PW` (선택) | 테스트 계정 | 없음 → 로그인 필요 테스트 생략 |

작업 폴더는 `$DOBBY_WORKSPACE/subtree/{repo}-{이슈키}`, 메타는 `$DOBBY_META/.issue-start/...`(기본 `$DOBBY_WORKSPACE/meta`, `DOBBY_META_PATH`로 별도 지정 가능)처럼 **분리 저장**됩니다. 설정 예시는 `plugins/work-dobby/config.env.example`, 스킬이 공유하는 설정 절차·변수 규격의 단일 출처는 `plugins/work-dobby/reference/config.md` 참고.

## 설치

```
/plugin marketplace add <github-owner>/mentis-plugins
/plugin install work-dobby@mentis-plugins     # 또는 go-dobby@mentis-plugins
```

로컬에서 바로:

```
/plugin marketplace add ~/work/mentis-plugins
/plugin install work-dobby@mentis-plugins     # 또는 go-dobby@mentis-plugins
```

## 구조

```
mentis-plugins/
├── .claude-plugin/marketplace.json
└── plugins/
    ├── work-dobby/                      # 원본
    │   ├── .claude-plugin/plugin.json
    │   ├── config.env.example
    │   ├── reference/config.md          # 공통 설정(단일 출처)
    │   └── skills/
    │       ├── issue-start/  issue-impl/  issue-test/  issue-end/
    │       └── i-order-you-to-develop/  agent-start/  agent-impl/
    └── go-dobby/                        # 재설계 (단일 진입점)
        ├── .claude-plugin/plugin.json
        ├── config.env.example
        ├── reference/
        │   ├── config.md                # 공통 설정
        │   └── redesign-spec.md         # 재설계 SSOT
        └── skills/
            ├── dobby-order/             # 유일 진입점
            ├── dobby-start/  dobby-impl/
            └── dobby-test/  dobby-resolve/  dobby-end/
```

## 참고

- 기본값 중 일부(Jira 호스트, 테스트 환경 매핑)는 와디즈 환경 기준입니다. 첫 실행 시 각자 환경에 맞게 바꾸면 됩니다.
- 테스트 계정·DB 조회 도구가 없으면 테스트는 **가용 범위 내에서만** 진행합니다.
