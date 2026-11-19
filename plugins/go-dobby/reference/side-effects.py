#!/usr/bin/env python3
"""지우거나 갈아끼우는 코드가 하던 '안 보이는 일'(수집·광고·CRM·쓰기 요청·저장소)을 import 를 따라가며 찾는다.

dobby-lib.sh 의 dobby_side_effect_inventory · dobby_side_effect_check · dobby_migration_drift ·
dobby_track_scan 이 부른다. 찾을 이름은 환경 변수(DOBBY_TRACK_SYMBOLS 등)로 받는다 — 이름 목록은 dobby-lib.sh 한 곳에 둔다.

  inventory --repo DIR [--ref REF] --out FILE --key KEY --repo-name NAME --base-commit H PATH...
  follow    --repo DIR --from FILE SPEC...        # 지워진 import 하나가 안에서 하던 일(TSV)
  check     FILE                                  # 닫히지 않은 줄을 알린다(있으면 1)
  drift     --repo DIR --file FILE --branch REF   # 기준 커밋 뒤 지울 경로에 들어온 커밋을 표에 맞춘다(안 닫혔으면 1)
"""
import argparse
import os
import re
import subprocess
import sys

EXTS = ('.ts', '.tsx', '.js', '.jsx')
# 따라 들어가지 않는 곳 — 수집·요청을 '정의'하는 곳이라 부르는 쪽에서 이미 잡힌다. 들어가면 정의마다 줄이 생긴다
STOP = ('packages/api/', 'packages/core/src/metrics/', 'packages/event-tracker/', 'packages/waffle', 'packages/i18n/',
        'packages/utils/', 'packages/format/', 'packages/settings/', 'static/packages/fetch-api/',
        'static/packages/waffle', 'static/libraries/', 'static/mocks/', 'node_modules/',
        'packages/core/src/lib/AppBridge/', 'static/packages/shared/utils/tracking')
IMPORT_RE = re.compile(r"""^\s*(?:import|export)\s+(?:type\s+)?(?:(.*?)\s+from\s+)?['"]([^'"]+)['"]""")
DYN_RE = re.compile(r"""(?:import|require)\(\s*['"]([^'"]+)['"]\s*\)""")
COND_RE = re.compile(r'\bif\s*\(|&&|\?\s|\bcase\s')


def env_re(name, default=''):
    v = os.environ.get(name, default)
    return re.compile(v) if v else None


LANES = [
    ('수집', env_re('DOBBY_TRACK_SYMBOLS')),
    ('광고', env_re('DOBBY_AD_SYMBOLS')),
    ('CRM', env_re('DOBBY_CRM_SYMBOLS')),
    ('쓰기 요청', env_re('DOBBY_WRITE_SYMBOLS')),
    ('저장소', env_re('DOBBY_STORAGE_SYMBOLS')),
]


class Tree:
    """작업 폴더 또는 git 커밋 하나를 파일 묶음으로 본다."""

    def __init__(self, repo, ref=None):
        self.repo, self.ref, self.cache = repo, ref, {}
        if ref:
            out = subprocess.run(['git', '-C', repo, 'ls-tree', '-r', '--name-only', ref],
                                 capture_output=True, text=True, check=True).stdout
            self.files = set(out.split('\n'))
        else:
            self.files = None
        self.pkgs = self._packages()

    def exists(self, p):
        if self.files is not None:
            return p in self.files
        return os.path.isfile(os.path.join(self.repo, p))

    def read(self, p):
        if p not in self.cache:
            try:
                if self.ref:
                    self.cache[p] = subprocess.run(['git', '-C', self.repo, 'show', f'{self.ref}:{p}'],
                                                   capture_output=True, text=True, check=True).stdout
                else:
                    with open(os.path.join(self.repo, p), encoding='utf-8', errors='replace') as f:
                        self.cache[p] = f.read()
            except Exception:
                self.cache[p] = ''
        return self.cache[p]

    def _packages(self):
        import json
        found = {}
        cands = [f for f in (self.files or []) if re.match(r'^(packages|static/packages|static/libraries|apps)/[^/]+/package\.json$', f)]
        if self.files is None:
            for top in ('packages', 'static/packages', 'static/libraries', 'apps'):
                d = os.path.join(self.repo, top)
                if os.path.isdir(d):
                    cands += [f'{top}/{x}/package.json' for x in os.listdir(d)
                              if os.path.isfile(os.path.join(d, x, 'package.json'))]
        for pj in cands:
            try:
                name = json.loads(self.read(pj)).get('name')
            except Exception:
                continue
            if name:
                found[name] = os.path.dirname(pj)
        return found

    def with_ext(self, base):
        base = os.path.normpath(base)
        for c in [base] + [base + e for e in EXTS] + [f'{base}/index{e}' for e in EXTS]:
            if self.exists(c) and c.endswith(EXTS):
                return c
        return None

    def resolve(self, spec, src):
        if spec.startswith('.'):
            return self.with_ext(os.path.join(os.path.dirname(src), spec))
        if spec.startswith('@/'):
            m = re.match(r'^(apps/[^/]+)/', src)
            return self.with_ext(f'{m.group(1)}/src/{spec[2:]}') if m else None
        parts = spec.split('/')
        name, sub = ('/'.join(parts[:2]), '/'.join(parts[2:])) if spec.startswith('@') else (parts[0], '/'.join(parts[1:]))
        d = self.pkgs.get(name)
        if not d:
            return None
        if not sub:
            return self.with_ext(f'{d}/src/index') or self.with_ext(f'{d}/index')
        return self.with_ext(f'{d}/src/{sub}') or self.with_ext(f'{d}/{sub}')


def stopped(p):
    return any(p.startswith(s) for s in STOP) or '/__mocks__/' in p or '/mocks/' in p


def imported_names(clause):
    """`A, { B, C as D }` → {'default','B','C'} · `* as X` → None(전부)."""
    if clause is None:
        return set()
    if '*' in clause:
        return None
    names = set()
    m = re.search(r'\{([^}]*)\}', clause)
    if m:
        for part in m.group(1).split(','):
            part = part.strip().replace('type ', '')
            if part:
                names.add(part.split(' as ')[0].strip())
    head = re.sub(r'\{[^}]*\}', '', clause).strip(' ,')
    if head:
        names.add('default')
    return names


def statements(text):
    """여러 줄에 걸친 import·export 문을 한 줄로 합쳐 (줄번호, 문장) 으로 낸다."""
    lines, i = text.split('\n'), 0
    while i < len(lines):
        ln = lines[i]
        if re.match(r'^\s*(import|export)\b', ln) and ('from' not in ln or '{' in ln and '}' not in ln):
            j, buf = i, ln
            while j + 1 < len(lines) and not re.search(r"""['"]\s*;?\s*$""", buf) and j - i < 60:
                j += 1
                buf += ' ' + lines[j].strip()
            yield i + 1, buf
            i = j + 1
            continue
        yield i + 1, ln
        i += 1


def barrel_targets(tree, path, names, depth=0):
    """묶음 파일(index)에서 가져온 이름이 실제로 정의된 파일만 찾는다. 묶음 전체를 따라가면 패키지가 통째로 끌려온다."""
    if names is None or depth > 6:
        return [path]
    text = tree.read(path)
    own = [n for n in names if n != 'default' and re.search(
        rf'export\s+(?:default\s+)?(?:async\s+)?(?:const|let|var|function\*?|class|interface|type|enum)\s+{re.escape(n)}\b', text)]
    hits = []
    if own or ('default' in names and re.search(r'export\s+default\b', text)):
        hits.append(path)
    for _, st in statements(text):
        m = IMPORT_RE.match(st)
        if not m or not st.lstrip().startswith('export'):
            continue
        clause, spec = m.group(1), m.group(2)
        tgt = tree.resolve(spec, path)
        if not tgt:
            continue
        if clause is None or clause.strip() == '*':
            sub = barrel_targets(tree, tgt, names, depth + 1)
            hits += [s for s in sub if s != tgt or exports_any(tree, tgt, names)]
        else:
            m2 = re.search(r'\{([^}]*)\}', clause)
            exported = {}
            if m2:
                for part in m2.group(1).split(','):
                    part = part.strip()
                    if part:
                        a = part.split(' as ')
                        exported[a[-1].strip()] = a[0].strip()
            want = {exported[n] for n in names if n in exported}
            if want:
                hits += barrel_targets(tree, tgt, want, depth + 1)
    return hits or ([path] if names else [])


def exports_any(tree, path, names):
    text = tree.read(path)
    return any(re.search(rf'export\s+(?:default\s+)?(?:async\s+)?(?:const|let|var|function\*?|class)\s+{re.escape(n)}\b', text)
               for n in names if n != 'default')


def is_barrel(text):
    body = [l for l in text.split('\n') if l.strip() and not l.strip().startswith(('//', '/*', '*'))]
    return bool(body) and all(re.match(r'^\s*(export|import)\b|^\s*[}\w\'",]+[,}]?\s*;?$', l) for l in body)


def walk(tree, starts):
    """시작 파일들에서 import 를 따라간다. 돌려주는 값: {파일: 경유 경로}."""
    seen, queue = {}, [(s, s) for s in starts]
    while queue:
        p, via = queue.pop(0)
        if p in seen or stopped(p):
            continue
        seen[p] = via
        for _, st in statements(tree.read(p)):
            m = IMPORT_RE.match(st)
            specs = [(m.group(1), m.group(2))] if m else []
            specs += [(None, s) for s in DYN_RE.findall(st)]
            for clause, spec in specs:
                if m and clause is not None and re.match(r'^\s*import\s+type\b', st):
                    continue
                tgt = tree.resolve(spec, p)
                if not tgt or stopped(tgt) or tgt in seen:
                    continue
                names = imported_names(clause) if clause is not None else None
                targets = barrel_targets(tree, tgt, names) if is_barrel(tree.read(tgt)) else [tgt]
                for t in targets:
                    if t not in seen and not stopped(t):
                        queue.append((t, f'{via} → {t}' if len(via) < 400 else via))
    return seen


def scan(tree, files, lanes=None):
    rows = []
    for p, via in files.items():
        text = tree.read(p).split('\n')
        for i, ln in enumerate(text):
            s = ln.strip()
            if not s or s.startswith(('//', '*', '/*', 'import ', 'export {', 'export *')):
                continue
            for lane, rx in LANES:
                if rx is None or (lanes and lane not in lanes):
                    continue
                if rx.search(s):
                    cond = ''
                    for k in range(i - 1, max(-1, i - 16), -1):
                        if COND_RE.search(text[k]):
                            cond = text[k].strip()[:80]
                            break
                    rows.append({'lane': lane, 'loc': f'{p}:{i + 1}', 'code': s[:100], 'via': via, 'cond': cond})
                    break
    return rows


def cell(x):
    return str(x).replace('|', '/').replace('\n', ' ')


def parse_table(text, header_word):
    """제목에 header_word 가 있는 절의 표를 dict 목록으로 읽는다."""
    out, cols, insec = [], None, False
    for ln in text.split('\n'):
        if ln.startswith('## '):
            insec, cols = header_word in ln, None
            continue
        if not insec or not ln.strip().startswith('|'):
            continue
        cells = [c.strip() for c in ln.strip().strip('|').split('|')]
        if cols is None:
            cols = cells
            continue
        if all(re.match(r'^:?-+:?$', c) for c in cells if c):
            continue
        out.append(dict(zip(cols, cells)))
    return out


RULES = """## 닫는 규칙

- 줄마다 `판정` 칸을 채운다. 비어 있으면 설계를 확정할 수 없고 통합도 막힌다.
  - `옮김` — `새 코드` 칸에 새 코드에서 같은 일을 하는 자리를 `파일:행` 으로 적는다.
  - `뺌` — **기획서에 뺀다고 적힌 것만** 뺄 수 있다. `새 코드` 칸에 `기획서: {문서 이름} — "{인용}"` 을 적는다.
    기획서에 그런 말이 없으면 `옮김` 이다. 사람에게 묻지 않는다.
  - `무관` — 탐지가 잘못 걸린 줄(부수 효과가 아님)이다. `새 코드` 칸에 이유를 적는다.
- `근처 조건` 은 그 호출을 감싼 조건의 참고값이다. CRM 줄은 이 조건(예: 마케팅 미동의자만)이 새 코드에서도 같아야 하고,
  테스트 계획에 그 조건을 갖춘 계정으로 `[CRM]` 시나리오를 둔다. 앱 전용(`appBridge`)은 브라우저로 재현할 수 없으니
  `새 코드` 칸의 대조로 닫는다.
"""


def cmd_inventory(a):
    tree = Tree(a.repo, a.ref)
    starts = []
    for p in a.paths:
        p = p.rstrip('/')
        if tree.files is not None:
            starts += sorted(f for f in tree.files if (f == p or f.startswith(p + '/')) and f.endswith(EXTS))
        elif os.path.isdir(os.path.join(a.repo, p)):
            for root, _, fs in os.walk(os.path.join(a.repo, p)):
                starts += [os.path.relpath(os.path.join(root, f), a.repo) for f in fs if f.endswith(EXTS)]
        elif p.endswith(EXTS):
            starts.append(p)
    starts = [s for s in starts if not re.search(r'(__tests?__|\.test\.|\.stories\.)', s)]
    files = walk(tree, starts)
    rows = scan(tree, files)
    old = {}
    if os.path.isfile(a.out):
        with open(a.out, encoding='utf-8') as f:
            prev = f.read()
        for r in parse_table(prev, '목록'):
            old[(r.get('위치', '').strip('`').rsplit(':', 1)[0], r.get('호출', ''))] = (r.get('새 코드', ''), r.get('판정', ''))
        drift = prev[prev.find('## 설계 뒤 옛 코드 변경'):] if '## 설계 뒤 옛 코드 변경' in prev else ''
    else:
        drift = ''
    order = {l: i for i, (l, _) in enumerate(LANES)}
    rows.sort(key=lambda r: (order[r['lane']], r['loc']))
    lines = [f'# {a.key} — 지우는 코드의 부수 효과 목록', '',
             f'- **저장소**: {a.repo_name}',
             '- **지울 경로**: ' + ', '.join(f'`{p}`' for p in a.paths),
             f'- **기준 커밋**: {a.repo_name}@{a.base_commit}',
             f'- **따라간 파일**: {len(files)}개 (시작 {len(starts)}개)', '',
             RULES, '## 목록', '',
             '| # | 갈래 | 위치 | 호출 | 경유 | 근처 조건 | 새 코드 | 판정 |',
             '|---|---|---|---|---|---|---|---|']
    for i, r in enumerate(rows, 1):
        new, verdict = old.get((r['loc'].rsplit(':', 1)[0], cell(r['code'])), ('', ''))
        via = r['via'].split(' → ')
        via_s = r['via'] if len(via) <= 2 else f'{via[0]} → … → {via[-1]}'
        lines.append(f"| {i} | {r['lane']} | `{r['loc']}` | {cell(r['code'])} | {cell(via_s)} | {cell(r['cond'])} | {new} | {verdict} |")
    if not rows:
        lines.append('| - | - | 찾은 것 없음 | - | - | - | - | - |')
    text = '\n'.join(lines) + '\n'
    if drift:
        text += '\n' + drift
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(text)
    by = {}
    for r in rows:
        by[r['lane']] = by.get(r['lane'], 0) + 1
    print(f"부수 효과 {len(rows)}줄 — " + ', '.join(f'{k} {v}' for k, v in by.items()) + f" · 따라간 파일 {len(files)}개")
    print(f'→ {a.out}')


def verdict_problem(new, verdict):
    v = verdict.strip()
    if not v:
        return '판정이 비어 있다'
    if v.startswith('옮김') or v.startswith('반영'):
        return None if re.search(r'[\w\]\)]\.(tsx?|jsx?|jsp|java|scss)?:\d+', new) or re.search(r':\d+', new) else '새 코드 칸에 `파일:행` 이 없다'
    if v.startswith('뺌'):
        return None if '기획서' in new else '뺌은 기획서 근거가 있어야 한다(새 코드 칸에 `기획서: 문서 — "인용"`). 기획서에 없으면 옮김이다'
    if v.startswith('무관'):
        return None if len(new.strip()) >= 6 else '무관이면 새 코드 칸에 이유를 적는다'
    return f'모르는 판정 `{v}` (옮김·뺌·무관 중 하나)'


def cmd_check(a):
    with open(a.file, encoding='utf-8') as f:
        text = f.read()
    bad = []
    for r in parse_table(text, '목록'):
        if r.get('#', '-') == '-':
            continue
        why = verdict_problem(r.get('새 코드', ''), r.get('판정', ''))
        if why:
            bad.append(f"  {r.get('#')}. [{r.get('갈래')}] {r.get('위치')} — {why}")
    for r in parse_table(text, '설계 뒤 옛 코드 변경'):
        if r.get('커밋', '-') == '-':
            continue
        why = verdict_problem(r.get('새 코드', ''), r.get('판정', ''))
        if why:
            bad.append(f"  커밋 {r.get('커밋')} {r.get('제목', '')[:40]} — {why}")
    if bad:
        print('닫히지 않은 줄:')
        print('\n'.join(bad))
        return 1
    print('부수 효과 목록이 모두 닫혔다.')
    return 0


def header_value(text, label):
    m = re.search(rf'^- \*\*{label}\*\*:\s*(.+)$', text, re.M)
    return m.group(1).strip() if m else ''


def cmd_drift(a):
    with open(a.file, encoding='utf-8') as f:
        text = f.read()
    base = header_value(text, '기준 커밋').split('@')[-1]
    paths = re.findall(r'`([^`]+)`', header_value(text, '지울 경로'))
    if not base or not paths:
        print('기준 커밋이나 지울 경로가 없다', file=sys.stderr)
        return 2
    log = subprocess.run(['git', '-C', a.repo, 'log', '--no-merges', '--date=short', '--format=%h\t%ad\t%s',
                          f'{base}..{a.branch}', '--'] + paths, capture_output=True, text=True)
    if log.returncode != 0:
        print(log.stderr.strip(), file=sys.stderr)
        return 2
    old = {r.get('커밋'): r for r in parse_table(text, '설계 뒤 옛 코드 변경')}
    rows = []
    for ln in log.stdout.strip().split('\n'):
        if not ln:
            continue
        h, d, s = ln.split('\t', 2)
        changed = subprocess.run(['git', '-C', a.repo, 'show', '--name-only', '--format=', h, '--'] + paths,
                                 capture_output=True, text=True).stdout.split()
        prev = old.get(h, {})
        rows.append(f"| {h} | {d} | {cell(s[:70])} | {cell(', '.join(os.path.basename(c) for c in changed[:4]))} | "
                    f"{prev.get('새 코드', '')} | {prev.get('판정', '')} |")
    sec = ['## 설계 뒤 옛 코드 변경', '',
           f'기준 커밋 뒤 `{a.branch}` 까지 지울 경로를 고친 커밋이다. 이 변경이 새 코드에도 들어갔는지 줄마다 닫는다'
           ' (`반영` + `파일:행` · `뺌` + 기획서 근거 · `무관` + 이유).', '',
           '| 커밋 | 날짜 | 제목 | 바뀐 파일 | 새 코드 | 판정 |', '|---|---|---|---|---|---|']
    sec += rows or ['| - | - | 없음 | - | - | - |']
    head = text.split('## 설계 뒤 옛 코드 변경')[0].rstrip('\n')
    with open(a.file, 'w', encoding='utf-8') as f:
        f.write(head + '\n\n' + '\n'.join(sec) + '\n')
    print(f'설계 뒤 옛 코드 변경 {len(rows)}건 ({base}..{a.branch})')
    return 0


def cmd_follow(a):
    tree = Tree(a.repo, a.ref)
    for item in a.specs:
        # `경로::이름,이름` — 이름이 없으면(부수 효과 import) 그 파일 전체, `*` 이면 묶음 전체를 따라간다
        spec, _, nm = item.partition('::')
        tgt = tree.resolve(spec, a.src)
        if not tgt or stopped(tgt):
            continue
        # 이름은 공백을 뺀 채 온다(`Foo,{A,B@C}` — @ 는 as). 없으면 그 파일 전체, `*` 면 묶음 전체
        names = imported_names(nm.replace('@', ' as ')) if nm else None
        targets = barrel_targets(tree, tgt, names) if (names and is_barrel(tree.read(tgt))) else [tgt]
        for r in scan(tree, walk(tree, [t for t in targets if not stopped(t)]), lanes={'수집', '광고', 'CRM'}):
            print(f"{r['lane']}\t{item}\t{r['loc']}\t{r['code'][:70]}")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('inventory')
    p.add_argument('--repo', required=True); p.add_argument('--ref'); p.add_argument('--out', required=True)
    p.add_argument('--key', required=True); p.add_argument('--repo-name', required=True)
    p.add_argument('--base-commit', required=True); p.add_argument('paths', nargs='+')
    p = sp.add_parser('check'); p.add_argument('file')
    p = sp.add_parser('drift')
    p.add_argument('--repo', required=True); p.add_argument('--file', required=True); p.add_argument('--branch', required=True)
    p = sp.add_parser('follow')
    p.add_argument('--repo', required=True); p.add_argument('--ref'); p.add_argument('--from', dest='src', required=True)
    p.add_argument('specs', nargs='+')
    a = ap.parse_args()
    return {'inventory': cmd_inventory, 'check': cmd_check, 'drift': cmd_drift, 'follow': cmd_follow}[a.cmd](a) or 0


if __name__ == '__main__':
    sys.exit(main())
