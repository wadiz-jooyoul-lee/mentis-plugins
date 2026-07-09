# work-dobby

Jira 이슈의 **착수 → 테스트 → 종료** 생명주기와, 상위 이슈를 여러 하위이슈로 나눠 서브 에이전트가 병렬로 구현하는 **멀티 에이전트 오케스트레이션(work-dobby)**을 담은 Claude Code 플러그인 마켓플레이스입니다.

## 담긴 스킬 (플러그인 `work-dobby`)

| 스킬 | 역할 |
|------|------|
| `issue-start` | 이슈 착수 — 워크트리·브랜치 생성 + 코드 분석 |
| `issue-test` | 이슈 테스트 — chrome-devtools로 시나리오 검증, 결과 리포트 |
| `issue-end` | 이슈 종료 — 마무리·워크트리 정리 |
| `agent-start` | 멀티 에이전트용 착수·분석 + 오케스트레이션 메타(계약·보드) 규격 |
| `agent-impl` | 서브 에이전트의 구현 단계 (자기 워크트리·계약 범위 안에서 구현·커밋·리뷰 요청) |
| `work-dobby` | 메인 오케스트레이터 — 하위이슈 분배·구현·리뷰 루프·통합 |

## 설정 (첫 실행 시 1회)

스킬을 처음 실행하면 아래 값을 확인해 `~/.config/work-dobby/config.env`에 저장하고 이후 재사용합니다. **기본값이 있는 항목은 현재 값을 보여주고 변경 의사를 묻고**, 선택 항목은 건너뛸 수 있습니다.

| 변수 | 뜻 | 기본값 |
|------|----|--------|
| `JIRA_BASE_URL` | Jira 호스트 | `https://wadiz.atlassian.net` |
| `DOBBY_WORKSPACE` | 작업 루트(하위 `subtree/`·`meta/`) | `$HOME/work/dobby-workspace` |
| `DOBBY_DEFAULT_BASE` | 기본 베이스 브랜치 | `master` |
| `DOBBY_REPOS_ROOT` | 원본 저장소 상위 폴더 | `$HOME/work` |
| `DOBBY_ENV_MAP` | 테스트 환경→호스트 매핑 | `dev=dev.wadiz.io,rc=rc.wadiz.kr,rc2=rc2.wadiz.kr,rc4=rc4.wadiz.io` |
| `DOBBY_DOCS_ROOT` (선택) | 참고 문서 루트 | 없음 → 문서 없이 진행 |
| `TEST_LOGIN_ID`/`TEST_LOGIN_PW` (선택) | 테스트 계정 | 없음 → 로그인 필요 테스트 생략 |

작업 폴더는 `$DOBBY_WORKSPACE/subtree/{repo}-{이슈키}`, 메타는 `$DOBBY_WORKSPACE/meta/.issue-start/...` 처럼 **분리 저장**됩니다. 설정 예시는 `plugins/work-dobby/config.env.example` 참고.

## 설치

```
/plugin marketplace add <github-owner>/work-dobby
/plugin install work-dobby@work-dobby
```

로컬에서 바로:

```
/plugin marketplace add ~/work/work-dobby
/plugin install work-dobby@work-dobby
```

## 구조

```
work-dobby/
├── .claude-plugin/marketplace.json
└── plugins/work-dobby/
    ├── .claude-plugin/plugin.json
    ├── config.env.example
    └── skills/
        ├── issue-start/  issue-test/  issue-end/
        └── agent-start/  agent-impl/  work-dobby/
```

## 참고

- 기본값 중 일부(Jira 호스트, 테스트 환경 매핑)는 와디즈 환경 기준입니다. 첫 실행 시 각자 환경에 맞게 바꾸면 됩니다.
- 테스트 계정·DB 조회 도구가 없으면 테스트는 **가용 범위 내에서만** 진행합니다.
