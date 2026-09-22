#!/usr/bin/env python3
"""문서 본문이 코드와 얼마나 벌어졌는지 점수로 매긴다.

docs-sync 의 pull 이 끝난 직후 실행한다. 저장소가 최신이어야 판정이 맞다.
고치지는 않는다. 사람이 볼 우선순위 목록만 낸다.

  python3 check-stale.py [--top N] [--json]

환경 변수: DOCS_ROOT, DOCS_REPOS_ROOT, DOCS_SYNC_EXCLUDE
"""
import os, re, sys, json, subprocess, collections, datetime

HOME    = os.path.expanduser('~')
REPOS   = os.environ.get('DOCS_REPOS_ROOT') or f'{HOME}/work/repos'
DOCS    = os.environ.get('DOCS_ROOT')       or f'{HOME}/work/repos/docs'
EXCLUDE = {x.strip() for x in (os.environ.get('DOCS_SYNC_EXCLUDE') or 'docs,execute_all').split(',') if x.strip()}
TODAY   = datetime.date.today()

TOP  = 25
JSON = '--json' in sys.argv
if '--top' in sys.argv:
    TOP = int(sys.argv[sys.argv.index('--top') + 1])

EXT  = r'(?:java|kt|kts|ts|tsx|jsp|xml|ya?ml|swift|vue|js|mjs|cjs|properties|gradle|sql|py|sh|m|h|mm)'
CITE = re.compile(r'`([A-Za-z0-9_][A-Za-z0-9_./@-]*\.' + EXT + r')(?::[0-9][0-9,~\-]*)?`')


WARNED = []


def sh(args, cwd=None, timeout=120):
    """git 을 돌리고 표준출력을 돌려준다.

    실패를 조용히 삼키지 않는다. 빈 결과를 정상으로 오해하면
    판정이 통째로 0점이 되면서도 정상처럼 보인다.
    """
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout)
    except Exception as e:
        WARNED.append(f'{" ".join(args[:4])}: {e}')
        return ''
    if r.returncode != 0:
        WARNED.append(f'{" ".join(args[:4])} (rc={r.returncode}): {r.stderr.strip()[:160]}')
    return r.stdout


# ── 신호 1 준비: 저장소 전체 파일 색인 ────────────────────────────────
def build_index():
    basenames = collections.defaultdict(set)
    repos = []
    for name in sorted(os.listdir(REPOS)):
        p = os.path.join(REPOS, name)
        if name in EXCLUDE or not os.path.isdir(p) or not os.path.exists(f'{p}/.git'):
            continue
        repos.append(name)
        for f in sh(['git', 'ls-files'], cwd=p).splitlines():
            basenames[os.path.basename(f)].add(f'{name}/{f}')
    return basenames, set(repos)


# ── 신호 2 준비: 문서 본문이 마지막으로 바뀐 날 ────────────────────────
# 인용블록(`>` 로 시작)만 늘어난 커밋은 본문 수정으로 치지 않는다.
def body_dates():
    root = sh(['git', 'rev-parse', '--show-toplevel'], cwd=DOCS).strip()
    if not root:
        return {}, None
    prefix = os.path.relpath(DOCS, root)
    prefix = '' if prefix == '.' else prefix + '/'
    stream = sh(['git', 'log', '-p', '--no-merges', '--date=short',
                 '--format=\x01%ad', '--', prefix or '.'], cwd=root, timeout=600)

    # 커밋은 최신순으로 나온다. 문서마다 처음 만난 본문 수정이 가장 최근 것이다.
    # 검사하는 키와 저장하는 키가 어긋나면 옛 커밋이 덮어써 버린다. 같은 키를 쓴다.
    out, date, key = {}, None, None
    for line in stream.split('\n'):
        if line.startswith('\x01'):
            date = line[1:].strip()
        elif line.startswith('+++ b/'):
            path = line[6:]
            key = os.path.relpath(path, prefix) if prefix else path
        elif key and date and key not in out and len(line) > 1 \
                and line[0] in '+-' and line[1] not in '+->':
            out[key] = date
    if not out:
        WARNED.append('본문 수정일을 한 건도 구하지 못했습니다 (신호 2 무효)')
    return out, root


# ── 신호 3 준비: 낡은 표현 사전 ────────────────────────────────────────
def obsolete_terms():
    path = os.path.join(DOCS, '_tools', 'obsolete-terms.tsv')
    terms = {}
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            parts = line.split('\t')
            terms[parts[0].strip()] = (parts[1].strip() if len(parts) > 1 else '')
    return terms


def main():
    basenames, reposet = build_index()
    bodies, _ = body_dates()
    terms = obsolete_terms()

    commit_cache = {}
    def commits_since(repo, since):
        if repo not in commit_cache:
            commit_cache[repo] = sh(['git', 'log', '--no-merges', '--format=%ad',
                                     '--date=short'], cwd=os.path.join(REPOS, repo)).split()
        return sum(1 for d in commit_cache[repo] if d > since)

    def owner(rel, cited):
        stem = rel[:-3].split('/')[0]
        if stem in reposet:
            return stem
        base = os.path.basename(rel)[:-3]
        if base in reposet:
            return base
        heads = collections.Counter(c.split('/', 1)[0] for c in cited
                                    if c.split('/', 1)[0] in reposet)
        return heads.most_common(1)[0][0] if heads else None

    rows = []
    for root, dirs, files in os.walk(DOCS):
        dirs[:] = [d for d in dirs if d not in ('.git', '_tools')]
        for fn in sorted(files):
            if not fn.endswith('.md'):
                continue
            rel  = os.path.relpath(os.path.join(root, fn), DOCS)
            text = open(os.path.join(root, fn), encoding='utf-8', errors='replace').read()

            cited = sorted(set(CITE.findall(text)))
            miss = []
            for c in cited:
                head = c.split('/', 1)[0]
                hits = basenames.get(os.path.basename(c), set())
                if head in reposet:
                    hits = {h for h in hits if h.startswith(head + '/')}
                if not hits:
                    miss.append(c)

            repo  = owner(rel, cited)
            bdate = bodies.get(rel, TODAY.isoformat())
            age   = (TODAY - datetime.date(*map(int, bdate.split('-')))).days
            ncom  = commits_since(repo, bdate) if repo else 0
            # 낡은 표현은 본문에서만 센다. 인용 블록(`>`)은 과거 기록이거나
            # "예전에는 이랬다" 는 정정 기록이라 세면 오히려 점수가 올라간다.
            body_text = '\n'.join(l for l in text.split('\n')
                                   if not l.lstrip().startswith('>'))
            obs   = [t for t in terms if t in body_text]

            score = len(miss) * 3 + min(ncom, 300) * 0.1 + len(obs) * 4
            if score < 1:
                continue
            rows.append(dict(doc=rel, repo=repo or '-', score=round(score, 1),
                             missing=len(miss), cited=len(cited), missing_files=miss[:10],
                             body_date=bdate, body_age_days=age, commits_since=ncom,
                             obsolete=obs))

    rows.sort(key=lambda r: -r['score'])
    rows = rows[:TOP]

    if JSON:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return
    if not rows:
        print('본문 점검이 필요한 문서가 없습니다.')
        return
    print(f'{"점수":>6} {"소실인용":>9} {"본문방치":>8} {"그새커밋":>8}  문서  (저장소)')
    print('-' * 96)
    for r in rows:
        o = (' ⚠ ' + ','.join(r['obsolete'])) if r['obsolete'] else ''
        print(f"{r['score']:6.0f} {r['missing']:4d}/{r['cited']:<4d} "
              f"{r['body_age_days']:6d}일 {r['commits_since']:8d}  {r['doc']}  ({r['repo']}){o}")

    if WARNED:
        print('\n[경고] 아래를 확인하세요. 점수가 낮게 나왔을 수 있습니다.')
        for w in dict.fromkeys(WARNED):
            print('  -', w)


if __name__ == '__main__':
    main()
