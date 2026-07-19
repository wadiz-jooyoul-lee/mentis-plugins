# mentis-docs 공통 설정

`docs-sync` 스킬이 사용하는 **설정 절차와 환경 변수 규격**이다.

## 설정 절차

실행 시작 시 `~/.config/mentis-docs/config.env`를 읽는다:

```bash
[ -f ~/.config/mentis-docs/config.env ] && source ~/.config/mentis-docs/config.env
```

- **파일이 있으면** 값을 읽어 그대로 쓰고, 비어 있는 변수는 아래 표의 기본값을 **메모리에서만** 쓴다(파일에 되쓰지 않는다).
- **파일이 없으면(최초 실행)** 기본값을 사용자에게 보여주고, 변경 의사를 물은 뒤 최종 값을 `~/.config/mentis-docs/config.env`에 저장한다(`config.env.example`을 틀로). 저장 후 다시 source 한다.
  - 헤드리스(무인) 실행이라 사용자 확인이 불가하면, 기본값으로 파일을 생성하고 그 사실을 로그로 남긴다.

> 설정 값을 **바꾸는 것**은 최초 실행 또는 사용자가 명시적으로 "설정을 바꿔라"고 요청한 경우에만 한다. 평상시 실행은 읽기 전용이다.

## 환경 변수

| 변수 | 뜻 | 기본값 |
|------|-----|--------|
| `DOCS_REPOS_ROOT` | 원본 저장소들이 있는 상위 폴더(하위 폴더 각각이 레포) | `$HOME/work/repos` |
| `DOCS_ROOT` | 문서 루트. 레포 `X` 문서 = `$DOCS_ROOT/X.md` 또는 `$DOCS_ROOT/X/` | `$HOME/work/repos/docs` |
| `DOCS_SYNC_EXCLUDE` | pull/diff 제외 폴더(쉼표) | `docs,execute_all` |
| `DOCS_SYNC_MAP` | 이름으로 안 맞는 레포↔문서 수동 매핑(`레포=문서상대경로` 쉼표) | (없음) |
| `DOCS_SYNC_BRANCH_PREFIX` | 문서 커밋용 브랜치 접두사. 비우면 커밋 안 함(작업트리만) | (없음) |

## 레포 → 문서 매핑 규칙

1. `DOCS_SYNC_MAP`에 명시된 레포는 그 경로를 쓴다.
2. 없으면 `$DOCS_ROOT/{레포}.md`(파일)를 찾는다.
3. 없으면 `$DOCS_ROOT/{레포}/`(폴더)를 찾는다 — 폴더면 그 안의 대표 문서(`{레포}.md` → `README.md` → 첫 최상위 `.md`)를 고른다.
4. 그래도 없으면 **"문서 없음(신규 후보)"** 로 분류하고 문서를 새로 만들지는 않는다(요약에만 보고).

## 비-대상 자동 제외

- `$DOCS_ROOT` 자신, `.git`이 없는(=git 저장소 아님) 폴더, 파일(디렉터리 아님), `DOCS_SYNC_EXCLUDE` 목록.
