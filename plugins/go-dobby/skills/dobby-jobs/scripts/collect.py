#!/usr/bin/env python3
"""팀 이슈 조사. 사용: collect.py {baseline|daily} SINCE UNTIL
SINCE·UNTIL 은 'YYYY-MM-DD HH:MM'(한국 시각). 결과는 $ORCHESTRATION_DOCS_ROOT/_dobby-jobs/ 에 쓴다."""
import glob
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

MODE, SINCE, UNTIL = sys.argv[1], sys.argv[2], sys.argv[3]
HOME = os.path.expanduser("~")
REPOS = os.environ.get("ORCHESTRATION_REPOS_ROOT", f"{HOME}/work/repos")
META = os.environ.get("ORCHESTRATION_META_PATH") or os.environ.get("ORCHESTRATION_META") or f"{HOME}/work/orchestration-meta"
OUT = os.path.join(os.environ.get("ORCHESTRATION_DOCS_ROOT", f"{REPOS}/docs"), "_dobby-jobs")
PROJECTS = os.environ.get("DOBBY_JOBS_PROJECTS", "FE1,FE2,CLIENT").split(",")
# Jira 상태 번호. 이름으로 쓰면 CHANGED TO 조건이 0건이 된다
IN_PROGRESS, RESOLVED, CLOSED = "10155", "5", "6"
FIELDS = "summary,status,assignee,parent,priority,issuetype,created,updated,resolutiondate,description,project"
DOC_RE = re.compile(r"https://(?:wadiz\.atlassian\.net/wiki/[^\s\"'\\)\]]+|(?:www\.)?figma\.com/[^\s\"'\\)\]]+|docs\.google\.com/[^\s\"'\\)\]]+)")
KEY_RE = re.compile(r"(?<![A-Za-z0-9])((?:" + "|".join(PROJECTS) + r")-\d+)(?!\d)")
ANY_KEY = re.compile(r"[A-Z][A-Z0-9]*-\d+")
IGNORE = re.compile(r"(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|Podfile\.lock)$")
STAGES = ["착수 전", "개발 중", "리뷰 중", "검증 환경 반영", "배포 대기", "라이브 반영"]
STATUS_KO = {"In Progress": "진행 중", "Resolved": "해결됨", "Closed": "종료"}
POOL = ThreadPoolExecutor(8)


def sh(cmd, cwd=None, timeout=120):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def twg(args):
    try:
        return json.loads(sh(["twg", "-o", "json", "--output-summary", "none", *args]))
    except Exception:
        return None


def query_projects(cond):
    """key < X 는 같은 프로젝트끼리만 비교된다. 여러 프로젝트를 한 번에 끊어 받으면 둘째 쪽부터 한 프로젝트만 남으므로 따로 받는다."""
    return [i for p in PROJECTS for i in query_all(f"project = {p} AND ({cond})")]


def query_all(jql):
    """twg 는 다음 쪽 표시를 주지 않아 이슈 번호 내림차순 100건씩 끊어 받는다. 한 프로젝트 안에서만 쓴다."""
    res, extra = [], ""
    while True:
        d = twg(["jira", "workitem", "query", "--jql", f"{jql} {extra} ORDER BY key DESC", "--limit", "100", "--fields", FIELDS])
        if d is None:
            raise SystemExit(f"Jira 조회 실패: {jql}")
        iss = d.get("data", {}).get("issues", [])
        res += iss
        if len(iss) < 100:
            return res
        extra = f"AND key < {iss[-1]['key']}"


def norm(i):
    f = i.get("fields") or i
    st, par, pj = f.get("status") or {}, f.get("parent") or {}, f.get("project") or {}
    desc = json.dumps(f.get("description") or "", ensure_ascii=False)
    return {
        "key": i["key"], "project": i["key"].split("-")[0], "team": pj.get("name"),
        "summary": f.get("summary"), "status": st.get("name"),
        "done": (st.get("statusCategory") or {}).get("key") == "done",
        "assignee": (f.get("assignee") or {}).get("displayName") or "담당자 없음",
        "parent": par.get("key"), "parentSummary": (par.get("fields") or {}).get("summary"),
        "priority": (f.get("priority") or {}).get("name"), "type": (f.get("issuetype") or {}).get("name"),
        "created": f.get("created"), "updated": f.get("updated"), "resolved": f.get("resolutiondate"),
        "docs": sorted(set(DOC_RE.findall(desc)))[:6],
    }


def status_changes(key):
    d = twg(["jira", "workitem", "changelog", "query", "--issue-id", key, "--first", "100"]) or {}
    lo, hi = SINCE.replace(" ", "T"), UNTIL.replace(" ", "T")
    return [{"at": h["created"], "from": STATUS_KO.get(it.get("fromString"), it.get("fromString")),
             "to": STATUS_KO.get(it.get("toString"), it.get("toString")), "by": (h.get("author") or {}).get("displayName")}
            for h in d.get("data") or [] for it in h.get("items", [])
            if it.get("field") == "status" and lo <= h["created"][:16] <= hi]


# ---------- 1. Jira ----------
me = ((twg(["whoami"]) or {}).get("data") or {}).get("name")
inprog = {n["key"]: n for n in map(norm, query_projects(f"status = {IN_PROGRESS}"))}
if MODE == "baseline":
    # 끝나지 않은 이슈 전부 + 지난주 월요일 이후 끝난 이슈
    u = datetime.strptime(UNTIL[:10], "%Y-%m-%d")
    last_monday = (u - timedelta(days=u.weekday() + 7)).strftime("%Y-%m-%d")
    base = [norm(i) for i in query_projects(f"statusCategory != Done OR resolved >= '{last_monday}'")]
    picked = {n["key"]: n for n in base}
else:
    win = f"created >= '{SINCE}' AND created <= '{UNTIL}' OR status CHANGED TO ({IN_PROGRESS},{RESOLVED},{CLOSED}) DURING ('{SINCE}', '{UNTIL}')"
    picked = {n["key"]: n for n in map(norm, query_projects(win))}
    for k, ch in zip(list(picked), POOL.map(status_changes, list(picked))):
        picked[k]["changes"] = ch
        picked[k]["isNew"] = SINCE.replace(" ", "T") <= (picked[k]["created"] or "")[:16]
issues = {**inprog, **picked}
for k in picked:
    issues[k]["picked"] = True
names = {i["project"]: i["team"] for i in issues.values() if i["team"]}
teams = {p: names.get(p, p) for p in PROJECTS}

# ---------- 2. 저장소와 브랜치 ----------
repos = [os.path.basename(p) for p in sorted(glob.glob(f"{REPOS}/*")) if os.path.isdir(f"{p}/.git")]


def fetch(repo):
    """원격 브랜치 목록만 갱신한다. 실패한 저장소 이름을 돌려준다."""
    try:
        r = subprocess.run(["git", "fetch", "--quiet", "--prune", "origin"], cwd=f"{REPOS}/{repo}", capture_output=True, timeout=90)
        return repo if r.returncode else None
    except Exception:
        return repo


fetch_failed = sorted(filter(None, POOL.map(fetch, repos)))


def remote_refs(repo):
    out = sh(["git", "for-each-ref", "--format=%(refname:short)\t%(objectname)\t%(committerdate:iso-strict)", "refs/remotes/origin"], cwd=f"{REPOS}/{repo}")
    return repo, [l.split("\t") for l in out.splitlines() if l and l.count("\t") == 2 and not l.startswith("origin/HEAD")]


refs = dict(POOL.map(remote_refs, repos))


def live_branch(repo):
    names = {r[0] for r in refs.get(repo, [])}
    return next((b for b in ("origin/cloud_live", "origin/master", "origin/main") if b in names), None)


def key_files(cwd, base, tip, keys):
    """그 이슈 키가 붙은 커밋이 바꾼 파일만 본다. 병합해 들어온 남의 변경을 빼기 위함."""
    greps = [f"--grep={k}" for k in ([keys] if isinstance(keys, str) else keys)]
    out = sh(["git", "log", f"{base}..{tip}", "--no-merges", "-i", *greps, "--name-only", "--format="], cwd=cwd)
    return sorted({f for f in out.split() if not IGNORE.search(f)})


branches = {}
for repo, rs in refs.items():
    for name, sha, date in rs:
        for k in set(KEY_RE.findall(name)):
            if k in issues:
                branches.setdefault(k, []).append({"key": k, "repo": repo, "branch": name[len("origin/"):], "sha": sha, "date": date})

# release/ 는 배포 브랜치(release/v20261112, release/26.47.0)만. release/CLIENT-331_into_dev 같은 병합용은 뺀다
ENV_RE = re.compile(r"^origin/(cloud_live|master|main|stage|release/v?\d[^/]*|dev|cloud_dev|rc\d*|cloud_rc\d*)$")
RELEASE_RE = re.compile(r"^release/v?\d")


def inspect(b):
    cwd = f"{REPOS}/{b['repo']}"
    envs = [l.strip() for l in sh(["git", "branch", "-r", "--contains", b["sha"]], cwd=cwd).splitlines() if ENV_RE.match(l.strip())]
    b["in"] = sorted({e[len("origin/"):] for e in envs})
    lb = live_branch(b["repo"])
    b["live"] = bool(lb and lb in envs)
    b["files"] = key_files(cwd, lb, b["sha"], b["key"]) if lb and not b["live"] else []
    return b


allb = [b for v in branches.values() for b in v]
list(POOL.map(inspect, allb))


def gh_prs(repo):
    m = re.search(r"github\.com[:/](.+?)(?:\.git)?$", sh(["git", "remote", "get-url", "origin"], cwd=f"{REPOS}/{repo}").strip())
    if not m:
        return repo, []
    try:
        return repo, json.loads(sh(["gh", "pr", "list", "-R", m.group(1), "--state", "all", "--limit", "500",
                                    "--json", "number,state,headRefName,baseRefName,updatedAt,url,isDraft,reviewDecision"]))
    except Exception:
        return repo, []


prs = dict(POOL.map(gh_prs, sorted({b["repo"] for b in allb})))
for b in allb:
    b["prs"] = [{"n": p["number"], "state": p["state"], "base": p["baseRefName"], "url": p["url"], "draft": p["isDraft"], "review": p["reviewDecision"]}
                for p in prs.get(b["repo"], []) if p["headRefName"] == b["branch"]]


def stage_of(bs):
    best = 0
    for b in bs:
        envs = set(b["in"]) | {p["base"] for p in b["prs"] if p["state"] == "MERGED"}
        lb = (live_branch(b["repo"]) or "")[len("origin/"):]
        s = 1
        if any(p["state"] == "OPEN" for p in b["prs"]):
            s = 2
        if any(re.match(r"^(dev|cloud_dev|rc\d*|cloud_rc\d*)$", e) for e in envs):
            s = 3
        if any(e == "stage" or RELEASE_RE.match(e) for e in envs):
            s = 4
        if b["live"] or (lb and lb in envs):
            s = 5
        best = max(best, s)
    return STAGES[best]


for k, it in issues.items():
    bs = sorted(branches.get(k, []), key=lambda b: b["date"], reverse=True)
    it["branches"] = [{x: b[x] for x in ("repo", "branch", "date", "in", "live", "prs")} for b in bs]
    it["stage"] = "에픽" if it["type"] == "에픽" and not bs else stage_of(bs)
    it["lastCommit"] = bs[0]["date"] if bs else None

# ---------- 3. 내 오더와 겹침 ----------
def read_order(d):
    t = open(f"{d}/status.md", encoding="utf-8").read()
    g = lambda label: (re.search(rf"^- \*\*{label}\*\*: (.+)$", t, re.M) or [None, ""])[1].strip()
    sec = re.search(r"## 워크트리 / 브랜치\n(.*?)(?:\n## |\Z)", t, re.S)
    rows = []
    for line in (sec.group(1) if sec else "").splitlines():
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) >= 3 and c[0] and c[0] != "repo" and not set(c[0]) <= set("-: "):
            rows.append({"repo": c[0], "branch": c[1], "path": c[2]})
    return {"key": os.path.basename(d), "title": g("제목"), "stage": g("단계"), "rows": rows}


orders = []
for d in sorted(glob.glob(f"{META}/*/status.md")):
    o = read_order(os.path.dirname(d))
    if o["stage"] and o["stage"] not in ("종료", "해결", "완료") and not o["key"].startswith("RELEASE"):
        orders.append(o)

okeys = [o["key"] for o in orders if ANY_KEY.fullmatch(o["key"])]
oinfo = {n["key"]: n for n in map(norm, query_all(f"key in ({','.join(okeys)})"))} if okeys else {}
# 하위 이슈 키로 커밋한 오더도 있어 하위 이슈 키가 붙은 커밋까지 센다
subs = {}
for n in map(norm, query_all(f"parent in ({','.join(okeys)})") if okeys else []):
    subs.setdefault(n["parent"], []).append(n["key"])

for o in orders:
    files = set()
    for r in o["rows"]:
        cwd = f"{REPOS}/{r['repo']}"
        lb = live_branch(r["repo"]) if os.path.isdir(cwd) else None
        if not lb:
            continue
        tip = f"origin/{r['branch']}"
        if not sh(["git", "rev-parse", "--verify", "-q", tip], cwd=cwd).strip() and os.path.isdir(r["path"]):
            cwd, tip = r["path"], "HEAD"
        files |= {f"{r['repo']}:{f}" for f in key_files(cwd, lb, tip, [o["key"], *subs.get(o["key"], [])])}
    o["files"] = files

# 라이브에 없는 내 커밋이 없는 오더(라이브 배포됨, 작업 시작 전)와 Jira 가 끝난 오더는 비교하지 않는다
orders = [o for o in orders if o["files"] and not (oinfo.get(o["key"]) or {}).get("done")]
# 내 이슈끼리는 비교하지 않는다
mine = set(okeys) | {k for v in subs.values() for k in v}
overlaps = []
for o in orders:
    o["parent"] = (oinfo.get(o["key"]) or {}).get("parent")
    o["title"] = o["title"] or (oinfo.get(o["key"]) or {}).get("summary") or o["key"]
    odirs = {f.rsplit("/", 1)[0] for f in o["files"]}
    for k, it in issues.items():
        if k in mine or (me and it["assignee"] == me):
            continue
        bfiles = {f"{b['repo']}:{f}" for b in branches.get(k, []) for f in b["files"]}
        same = sorted(o["files"] & bfiles)
        if same:
            overlaps.append({"order": o["key"], "issue": k, "level": "충돌 주의", "why": same[:8], "more": max(0, len(same) - 8)})
        elif o["parent"] and o["parent"] == it["parent"]:
            overlaps.append({"order": o["key"], "issue": k, "level": "같은 기능", "why": [f"같은 상위 이슈 {it['parent']}"]})
        else:
            sd = sorted(odirs & {f.rsplit("/", 1)[0] for f in bfiles})
            if sd:
                overlaps.append({"order": o["key"], "issue": k, "level": "같은 기능", "why": [f"같은 폴더 {x}" for x in sd[:3]]})
    o["fileCount"] = len(o.pop("files"))
    o.pop("rows")

# ---------- 4. 저장 ----------
data = {"mode": MODE, "since": SINCE, "until": UNTIL, "generatedAt": datetime.now().isoformat(timespec="minutes"),
        "me": me, "teams": teams, "fetchFailed": fetch_failed, "repoCount": len(repos),
        "issues": list(issues.values()), "orders": orders, "overlaps": overlaps}
day = UNTIL[:10]
os.makedirs(f"{OUT}/daily", exist_ok=True)
by = {i["key"]: i for i in data["issues"]}


def link(k):
    return f"[{k}](https://wadiz.atlassian.net/browse/{k})"


def cell(s):
    return str(s or "").replace("|", "\\|").replace("\n", " ")


def branch_text(i):
    if not i["branches"]:
        return "없음"
    b = i["branches"][0]
    pr = next((p for p in b["prs"] if p["state"] != "CLOSED"), None)
    ko = {"OPEN": "열림", "MERGED": "병합됨"}
    return f"`{b['repo']}/{b['branch']}`" + (f" · [#{pr['n']}]({pr['url']}) {ko.get(pr['state'], pr['state'])}" if pr else "")


def kind(i):
    to = (i.get("changes") or [{}])[-1].get("to")
    return {"진행 중": "진행 시작", "해결됨": "해결됨", "종료": "종료"}.get(to, "새로 생김")


def overlap_rows(rows):
    out = ["| 겹침 | 상대 이슈 | 담당 | 진행도 | 내 오더 | 겹친 근거 |", "|---|---|---|---|---|---|"]
    for x in rows:
        i = by[x["issue"]]
        out.append(f"| {x['level']} | {link(i['key'])} {cell(i['summary'])} | {cell(i['assignee'])} | {i['stage']} | {x['order']} | {cell(', '.join(x['why']))} |")
    return out


md = []
if MODE == "daily":
    picked_l = [i for i in data["issues"] if i.get("picked")]
    md += [f"# 팀 이슈 변경 — {day}", "", f"조사 기간: {SINCE} 부터 {UNTIL} 까지", "", "## 한눈에 보기", "",
           "| 팀 | 새로 생김 | 진행 시작 | 해결됨 | 종료 |", "|---|---|---|---|---|"]
    for p, name in teams.items():
        t = [i for i in picked_l if i["project"] == p]
        md.append(f"| {name} | " + " | ".join(str(sum(1 for i in t if kind(i) == k)) for k in ("새로 생김", "진행 시작", "해결됨", "종료")) + " |")
    hot = [x for x in overlaps if by[x["issue"]].get("picked")]
    md += ["", f"## 내 오더와 겹치는 변경 {len(hot)}건", ""] + (overlap_rows(hot) if hot else ["없음"])
    md += ["", "## 바뀐 이슈", "", "| 이슈 | 팀 | 담당 | 이전 상태 | 지금 상태 | 진행도 | 브랜치·PR |", "|---|---|---|---|---|---|---|"]
    for i in picked_l:
        ch = i.get("changes") or []
        prev = ch[0]["from"] if ch else "새 이슈"
        md.append(f"| {link(i['key'])} {cell(i['summary'])} | {teams[i['project']]} | {cell(i['assignee'])} | {prev} | {i['status']} | {i['stage']} | {branch_text(i)} |")
    open(f"{OUT}/daily/{day}.md", "w").write("\n".join(md) + "\n")
else:
    md += [f"# 팀 이슈 기준 정리 — {day}", "", "끝나지 않은 이슈 전부와 지난주 월요일 이후 끝난 이슈입니다.", "",
           "| 이슈 | 팀 | 담당 | 상태 | 진행도 | 브랜치·PR |", "|---|---|---|---|---|---|"]
    for i in sorted(data["issues"], key=lambda i: (i["project"], i["status"] or "", i["key"])):
        md.append(f"| {link(i['key'])} {cell(i['summary'])} | {teams[i['project']]} | {cell(i['assignee'])} | {i['status']} | {i['stage']} | {branch_text(i)} |")
    open(f"{OUT}/baseline-{day}.md", "w").write("\n".join(md) + "\n")

pm = [f"# 담당자별 진행 — {UNTIL} 기준", ""]
for p, name in teams.items():
    act = [i for i in data["issues"] if i["project"] == p and i["status"] == "진행 중"]
    pm += [f"## {name} (진행 중 {len(act)}건)", ""]
    people = {}
    for i in act:
        people.setdefault(i["assignee"], []).append(i)
    for who, lst in sorted(people.items(), key=lambda x: -len(x[1])):
        pm += [f"### {who} — {len(lst)}건", "", "| 이슈 | 진행도 | 브랜치·PR | 마지막 커밋 |", "|---|---|---|---|"]
        for i in sorted(lst, key=lambda i: -STAGES.index(i["stage"]) if i["stage"] in STAGES else 1):
            pm.append(f"| {link(i['key'])} {cell(i['summary'])} | {i['stage']} | {branch_text(i)} | {(i['lastCommit'] or '없음')[:10]} |")
        pm.append("")
open(f"{OUT}/by-person.md", "w").write("\n".join(pm) + "\n")

om = [f"# 내 오더와 겹치는 팀 작업 — {UNTIL} 기준", ""]
for o in orders:
    rows = [x for x in overlaps if x["order"] == o["key"]]
    if rows:
        om += [f"## {o['key']} {o['title']} (오더 단계: {o['stage']})", ""] + overlap_rows(sorted(rows, key=lambda x: x["level"] != "충돌 주의")) + [""]
open(f"{OUT}/overlap.md", "w").write("\n".join(om) + "\n")

json.dump(data, open(f"{OUT}/daily/{day}.json" if MODE == "daily" else f"{OUT}/baseline-{day}.json", "w"), ensure_ascii=False, indent=1)
json.dump(data, open(f"{OUT}/latest.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps({"mode": MODE, "issues": len(issues), "picked": len(picked), "branches": len(allb), "orders": len(orders),
                  "overlaps": len(overlaps), "fetchFailed": fetch_failed}, ensure_ascii=False))
