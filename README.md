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

## 설치

```
/plugin marketplace add <github-owner>/work-dobby
/plugin install work-dobby@work-dobby
```

로컬에서 바로 쓰려면:

```
/plugin marketplace add ~/work/work-dobby
/plugin install work-dobby@work-dobby
```

## 구조

```
work-dobby/
├── .claude-plugin/
│   └── marketplace.json      # 마켓플레이스 매니페스트
└── plugins/
    └── work-dobby/
        ├── .claude-plugin/
        │   └── plugin.json    # 플러그인 매니페스트
        └── skills/
            ├── issue-start/SKILL.md
            ├── issue-test/SKILL.md
            ├── issue-end/SKILL.md
            ├── agent-start/SKILL.md
            ├── agent-impl/SKILL.md
            └── work-dobby/SKILL.md
```

## 참고

- 일부 스킬에는 `~/work/subtree/...` 등 와디즈/작성자 환경에 맞춘 경로·규약이 포함되어 있습니다. 다른 환경에서 쓰려면 해당 부분을 각자 환경에 맞게 조정하세요.
