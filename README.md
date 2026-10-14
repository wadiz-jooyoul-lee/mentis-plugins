# mentis-plugins

Jira 이슈 생명주기와 멀티 에이전트 오케스트레이션, 문서 동기화를 담은 Claude Code 플러그인 마켓플레이스입니다. 두 플러그인을 제공합니다:

- **`go-dobby`** — 이전 플러그인 work-dobby(삭제됨)를 재설계한 **단일 진입점 오케스트레이션**. 모든 이슈/작업을 `dobby-order` 하나로 시작해 필요한 에이전트 수(팬아웃 K)를 스스로 판단해 진행합니다. 설계 상세는 `plugins/go-dobby/reference/redesign-spec.md` 참고.
- **`mentis-docs`** — 레포 **git pull 후 diff를 근거로 대응 문서를 자동 갱신**하는 `docs-sync` 스킬.

## go-dobby 스킬 (재설계)

모든 작업을 **`dobby-order` 하나로 시작**합니다. 진입 후 코드 범위(파일 오너십)로 에이전트 수(K)를 판단해 — 단일 버그면 K=1, 에픽/여러 영역이면 K≥2 — 착수·구현·리뷰·통합을 오케스트레이션합니다. 이슈 없이 **문서만 주는 진입**(`TASK-{slug}`)도 지원합니다.

| 스킬 | 역할 | 호출 |
|------|------|------|
| `dobby-order` | 유일 진입점 — 팬아웃 K 판단·착수·구현·리뷰·통합 오케스트레이션 | 사용자 |
| `dobby-start` | 에이전트별 착수·분석 (베이스 로컬/원격 모두 처리, docs 2단계 참조) | 내부 |
| `dobby-impl` | 에이전트별 구현·자기 브랜치 푸시·리뷰 피드백 반영 (code) | 내부 |
| `dobby-produce` | 에이전트별 비소스 산출 (문서·리서치·분석 등, code 대신) | 내부 |
| `dobby-test` | 실브라우저 검증 (code만, 자동 해결 승격 없음) | 사용자 |
| `dobby-resolve` | 해결 표시 — 상태만 `해결`, 폴더 유지(비파괴) | 사용자 |
| `dobby-end` | 워크트리 정리 — 스냅샷 후 제거(브랜치 보존) | 사용자 |

주요 차이: 단독/오케스트레이션 경로 단일화, 이슈당 폴더 1개(`$DOBBY_META/{키}/`) + 단일 status.md 인덱스, 코드리뷰는 오케스트레이터가 단독 수행, 정식 배포 베이스로의 PR·머지 금지(최종 반영은 사용자 수동 PR).

## mentis-docs 스킬

레포를 pull 하고 **그 pull로 실제 들어온 변경(diff)만 근거로 대응 문서를 갱신**합니다.

| 스킬 | 역할 | 호출 |
|------|------|------|
| `repos-setup` | git 주소 명세서(`REPOS.md`)를 읽어 **없으면 clone, 있으면 pull** → 성공은 침묵, 실패만 로깅 → 요약 보고 | 사용자 |
| `docs-sync` | 레포별 pull 전후 HEAD 비교 → 변경 커밋·이슈키·파일 diff 수집 → 레포↔문서 매핑 → 문서 컨벤션대로 비파괴 갱신 → 요약 보고 | 사용자 |

- `repos-setup` 사용법: `/repos-setup` (전체) · `/repos-setup app-api wadiz-frontend` (특정) · `/repos-setup clone-only` · `/repos-setup pull-only`. 정본 명세서는 `$HOME/work/repos/REPOS.md`(repos 저장소에 포함). 토큰은 실패 개수에만 비례(성공은 출력 없음).
- `docs-sync` 사용법: `/docs-sync` (전체) 또는 `/docs-sync wadiz-frontend app-api` (특정 레포), `pull=off`로 pull 생략. **pull 수행 → 자동 반영 → 요약 보고**. 문서 없는 레포는 "신규 후보"로만 보고, 원본 소스는 수정하지 않습니다.
- 설정 변수(`~/.config/mentis-docs/config.env`): `DOCS_REPOS_ROOT`(기본 `$HOME/work/repos`), `DOCS_ROOT`(기본 `$HOME/work/repos/docs`), `REPOS_MANIFEST`(기본 `$HOME/work/repos/REPOS.md`), `DOCS_SYNC_EXCLUDE`, `DOCS_SYNC_MAP`, `DOCS_SYNC_BRANCH_PREFIX`. 규격은 `plugins/mentis-docs/reference/config.md` 참고.

## 설정 (첫 실행 시 1회)

go-dobby 설정은 `/dobby-init` 으로 `~/.config/go-dobby/config.env` 에 저장합니다. 변수 규격은 `plugins/go-dobby/reference/config.md` 참고.

## 설치

```
/plugin marketplace add <github-owner>/mentis-plugins
/plugin install go-dobby@mentis-plugins     # 또는 mentis-docs@mentis-plugins
```

로컬에서 바로:

```
/plugin marketplace add ~/work/mentis-plugins
/plugin install go-dobby@mentis-plugins     # 또는 mentis-docs@mentis-plugins
```

## 구조

```
mentis-plugins/
├── .claude-plugin/marketplace.json
└── plugins/
    └── go-dobby/                        # 재설계 (단일 진입점)
        ├── .claude-plugin/plugin.json
        ├── config.env.example
        ├── reference/
        │   ├── config.md                # 공통 설정
        │   └── redesign-spec.md         # 재설계 SSOT
        └── skills/
            ├── dobby-order/             # 유일 진입점
            ├── dobby-start/  dobby-impl/  dobby-produce/
            └── dobby-test/  dobby-resolve/  dobby-end/
```

## 참고

- 기본값 중 일부(Jira 호스트, 테스트 환경 매핑)는 와디즈 환경 기준입니다. 첫 실행 시 각자 환경에 맞게 바꾸면 됩니다.
- 테스트 계정·DB 조회 도구가 없으면 테스트는 **가용 범위 내에서만** 진행합니다.
