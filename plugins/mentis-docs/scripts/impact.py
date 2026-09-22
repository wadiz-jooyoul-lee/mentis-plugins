#!/usr/bin/env python3
"""이번 pull 의 diff 를 문서별 작업 목록으로 바꾼다.

docs-sync 가 저장소마다 한 번씩 부른다. 판단하지 않는다.
"어느 문서의 어느 줄을 왜 봐야 하는지"만 뽑는다.

  python3 impact.py <저장소> <BEFORE> <AFTER> [--json] [--max-review N] [--per-doc N]

작업을 두 층으로 나눠 낸다.
  확정 — 삭제·이름변경, 그리고 인용한 줄과 겹치는 수정. 반드시 고친다.
  확인 — 문서가 인용한 파일이 수정됨. 읽고 판단한다.
         문서마다 5건까지, 전체 60건까지 낸다.

환경 변수: DOCS_ROOT, DOCS_REPOS_ROOT
"""
import os, re, sys, json, subprocess, collections

HOME  = os.path.expanduser('~')
REPOS = os.environ.get('DOCS_REPOS_ROOT') or f'{HOME}/work/repos'
DOCS  = os.environ.get('DOCS_ROOT')       or f'{HOME}/work/repos/docs'

EXT  = r'(?:java|kt|kts|ts|tsx|jsp|xml|ya?ml|swift|vue|js|mjs|cjs|properties|gradle|sql|py|sh|m|h|mm)'
# 인용과 함께 줄번호 부분도 따로 붙잡는다
CITE = re.compile(r'`([A-Za-z0-9_][A-Za-z0-9_./@-]*\.' + EXT + r')(?::([0-9][0-9,~\-]*))?`')

WARN = []


def sh(args, cwd=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        WARN.append(f'{" ".join(args[:5])} (rc={r.returncode}): {r.stderr.strip()[:140]}')
    return r.stdout


def changed_files(repo, before, after):
    """이번 범위에서 바뀐 파일을 상태별로 모은다. -M 으로 이름변경을 추적한다."""
    out = sh(['git', 'diff', '--name-status', '-M', '--find-renames=40%',
              f'{before}..{after}'], cwd=os.path.join(REPOS, repo))
    rows = []
    for line in out.splitlines():
        parts = line.split('\t')
        st = parts[0]
        if st.startswith('R') and len(parts) >= 3:
            rows.append(('R', parts[1], parts[2]))
        elif len(parts) >= 2:
            rows.append((st[0], parts[1], None))
    return rows


def file_size(repo, rev, path):
    out = sh(['git', 'show', f'{rev}:{path}'], cwd=os.path.join(REPOS, repo))
    return max(out.count('\n'), 1)


def changed_ranges(repo, before, after, path):
    """수정된 파일에서 '옛 쪽' 기준으로 바뀐 줄 구간을 뽑는다."""
    out = sh(['git', 'diff', '-U0', f'{before}..{after}', '--', path],
             cwd=os.path.join(REPOS, repo))
    rng = []
    for m in re.finditer(r'^@@ -(\d+)(?:,(\d+))? ', out, re.M):
        a = int(m.group(1)); b = int(m.group(2) or 1)
        rng.append((a, a + max(b, 1) - 1))
    return rng


def parse_cited_lines(spec):
    """'30-225' 나 '12,40' 같은 표기를 (시작, 끝) 목록으로."""
    out = []
    if not spec:
        return out
    for part in spec.split(','):
        part = part.strip().replace('~', '-')
        if not part:
            continue
        if '-' in part:
            a, _, b = part.partition('-')
            if a.isdigit() and b.isdigit():
                out.append((int(a), int(b)))
        elif part.isdigit():
            out.append((int(part), int(part)))
    return out


def build_doc_index():
    """문서 → 인용 목록. 인용마다 줄번호와 문서 안 위치를 같이 들고 있는다."""
    idx = collections.defaultdict(list)     # basename -> [(문서, 문서줄, 인용전체, 줄범위)]
    for root, dirs, files in os.walk(DOCS):
        dirs[:] = [d for d in dirs if d not in ('.git', '_tools')]
        for fn in sorted(files):
            if not fn.endswith('.md'):
                continue
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, DOCS)
            for ln, text in enumerate(open(p, encoding='utf-8', errors='replace'), 1):
                for path, spec in CITE.findall(text):
                    idx[os.path.basename(path)].append(
                        (rel, ln, path, parse_cited_lines(spec)))
    return idx


ACTION = {
    'D': ('삭제됨',     '그 서술을 지우거나 대체 대상을 찾는다'),
    'R': ('이름바뀜',   '경로만 새 것으로 고친다'),
    'M': ('내용바뀜',   '인용한 줄이 바뀐 구간과 겹친다. 서술을 다시 확인한다'),
    'A': ('추가됨',     '같은 폴더를 열거한 목록이면 빠졌는지 본다'),
    'm': ('수정확인',   '인용한 파일이 바뀌었다. 서술이 아직 맞는지 읽는다'),
}
CONFIRMED = ('D', 'R', 'M', 'A')     # 확정 — 반드시 처리
REVIEW    = ('m',)                   # 확인 — 읽고 판단


def main():
    if len(sys.argv) < 4:
        print(__doc__); sys.exit(2)
    repo, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
    as_json = '--json' in sys.argv
    max_review = 60
    per_doc = 5
    if '--max-review' in sys.argv:
        max_review = int(sys.argv[sys.argv.index('--max-review') + 1])
    if '--per-doc' in sys.argv:
        per_doc = int(sys.argv[sys.argv.index('--per-doc') + 1])

    idx  = build_doc_index()
    rows = changed_files(repo, before, after)
    items = []

    # 추가된 파일의 폴더별 개수 — 목록형 문서 판정에 쓴다
    added_dirs = collections.Counter(os.path.dirname(p) for st, p, _ in rows if st == 'A')

    for st, path, newpath in rows:
        base = os.path.basename(path)
        hits = idx.get(base, [])
        if st == 'A':
            # 추가된 파일은 인용이 있을 리 없다.
            # 그 파일이 들어간 폴더를 '열거하고 있는' 문서만 찾는다.
            # 폴더 이름의 마지막 조각만 맞춰 보면 API 같은 흔한 이름이 전부 걸린다.
            # 그래서 인용 경로의 폴더 전체가 정확히 같을 때만 센다.
            d = os.path.dirname(path)
            if not d:
                continue
            sib = collections.Counter()
            for lst in idx.values():
                for doc, ln, cpath, _ in lst:
                    if os.path.dirname(cpath) == d:
                        sib[doc] += 1
            for doc, n in sib.items():
                if n >= 2:
                    items.append(dict(doc=doc, line=None, status='A', file=path,
                                      new_file=None, cited=None,
                                      why=f'이 문서가 {d} 안의 파일을 {n}개 열거 중'))
            continue

        ranges = changed_ranges(repo, before, after, path) if st == 'M' else []
        # 바뀐 줄 수만으로 줄을 세우면 큰 설정값 파일이 작은 템플릿을 밀어낸다.
        # 파일 크기 대비 비율로 보면 구조가 바뀐 작은 파일이 위로 온다.
        nchg  = sum(b - a + 1 for a, b in ranges)
        ratio = nchg / file_size(repo, after, path) if st == 'M' else 0
        for doc, ln, cpath, cited in hits:
            kind = st
            if st == 'M':
                hit = cited and ranges and any(a <= ce and cs <= b
                                               for cs, ce in cited for a, b in ranges)
                # 인용한 줄과 겹치면 확정, 아니면 '확인' 층으로 내린다.
                # 내려도 버리지는 않는다. 줄번호 없는 인용이 훨씬 많기 때문이다.
                kind = 'M' if hit else 'm'
            items.append(dict(doc=doc, line=ln, status=kind, file=path,
                              new_file=newpath, cited=cpath, why=None,
                              weight=round(ratio, 3), changed=nchg))

    # 파일 이름이 같은 파일이 여러 곳에서 지워지면 같은 줄이 여러 번 걸린다. 한 번만 남긴다.
    seen, uniq = set(), []
    for it in items:
        k = (it['doc'], it['line'], it['status'], it['file'])
        if k in seen:
            continue
        seen.add(k); uniq.append(it)
    items = uniq
    items.sort(key=lambda x: (x['doc'], x['line'] or 0, x['file']))

    fixed  = [x for x in items if x['status'] in CONFIRMED]
    review = [x for x in items if x['status'] in REVIEW]
    # 확인 층 줄 세우기.
    # 전체를 바뀐 줄 수로만 세우면 설정값 파일이 템플릿·소스를 밀어낸다.
    # 그래서 문서마다 따로 상한을 둔다. 관련 문서가 하나도 빠지지 않게 하려는 것이다.
    review.sort(key=lambda x: (-(x.get('weight') or 0), -(x.get('changed') or 0),
                               x['doc'], x['line'] or 0))
    per, cut = collections.Counter(), []
    for it in review:
        if per[it['doc']] >= per_doc:
            continue
        per[it['doc']] += 1
        cut.append(it)
    cut.sort(key=lambda x: (x['doc'], x['line'] or 0))
    cut = cut[:max_review]

    if as_json:
        print(json.dumps(dict(repo=repo, before=before, after=after,
                              confirmed=fixed, review=cut,
                              review_total=len(review), warnings=WARN),
                         ensure_ascii=False, indent=1))
        return

    def dump(rows, title):
        print(f'\n{title}')
        if not rows:
            print('   (없음)')
            return
        cur = None
        for it in rows:
            if it['doc'] != cur:
                cur = it['doc']
                print(f'── {cur}')
            label, todo = ACTION[it['status']]
            loc = f":{it['line']}" if it['line'] else ''
            extra = ''
            if it['status'] == 'm':
                extra = f"  (바뀐 줄 {it.get('changed')}, 파일의 {round((it.get('weight') or 0)*100)}%)"
            print(f"   {loc:<7} [{label}] {it['file']}{extra}")
            if it['status'] == 'R':
                print(f"   {'':<7}          새 경로: {it['new_file']}")
            print(f"   {'':<7}          → {it['why'] or todo}")

    docs = {x['doc'] for x in items}
    print(f'[{repo}] {before[:9]}..{after[:9]} — 관련 문서 {len(docs)}개')
    dump(fixed,  f'■ 확정 {len(fixed)}건 — 반드시 고칩니다')
    dump(cut,    f'■ 확인 {len(cut)}건 — 읽고 판단합니다'
                 + (f' (전체 {len(review)}건 중 상위 {len(cut)}건)' if len(review) > len(cut) else ''))
    if WARN:
        print('\n[경고]')
        for w in dict.fromkeys(WARN):
            print('  -', w)


if __name__ == '__main__':
    main()
