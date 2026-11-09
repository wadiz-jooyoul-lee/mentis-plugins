#!/usr/bin/env python3
"""릴리즈 노트 요일 구역에서 이슈 키가 든 행을 읽어, update-release-note 의 build 가 받는 계획 파일 모양으로 출력한다.

사용법
  release-note-row.py extract <body.html> <화|목> <이슈 키>
표 칸 해석은 update-release-note 의 release_row.py 를 그대로 불러 쓴다(경로는 RELEASE_ROW 환경 변수).
"""
import html
import importlib.util
import json
import os
import re
import sys


def load_release_row():
    spec = importlib.util.spec_from_file_location("release_row", os.environ["RELEASE_ROW"])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def cmd_extract(path, day, key):
    rr = load_release_row()
    body = open(path, encoding="utf-8").read()
    start, end = rr.day_section(body, day)
    if start is None:
        print(f"{day}요일 정기 배포 구역을 찾지 못했습니다", file=sys.stderr)
        return 1
    row = next((m for m in rr.rows_in(body[start:end])
                if len(rr.cells_of(m.group(2))) >= 13 and rr.key_in(key, m.group(2))), None)
    if row is None:
        print(f"{key} 가 든 행이 없습니다", file=sys.stderr)
        return 1
    cells = rr.cells_of(row.group(2))
    mention = re.search(r'data-user-id="([^"]+)"[^>]*>@?([^<]*)<', cells[5])
    if not mention:
        print("개발 담당자 칸에서 계정을 찾지 못했습니다", file=sys.stderr)
        return 1
    paras = lambda c: [rr.text(p) for p in re.findall(r"<p[^>]*>(.*?)</p>", c, re.S) if rr.text(p)]
    # 릴리즈 주요 내용: Jira 링크마다 바로 뒤 목록의 줄이 브랜치
    items = []
    for m in re.finditer(r'<a href="([^"]+/browse/[A-Z][A-Z0-9]*-\d+)"[^>]*>.*?</a>(.*?)(?=<a href="[^"]+/browse/|$)',
                         cells[4], re.S):
        ul = re.search(r"<ul[^>]*>(.*?)</ul>", m.group(2), re.S)
        branches = [rr.text(li) for li in re.findall(r"<li[^>]*>(.*?)</li>", ul.group(1), re.S)] if ul else []
        items.append({"jiraUrl": html.unescape(m.group(1)), "branches": branches})
    if not items:
        print("릴리즈 주요 내용 칸에서 Jira 링크를 찾지 못했습니다", file=sys.stderr)
        return 1
    checks = {}
    env = re.search(r'<input type="checkbox" checked>\s*([^<]*)', cells[6])
    if env and rr.text(env.group(1)):
        checks["env"] = rr.text(env.group(1))
    for m in re.finditer(r'<input type="checkbox" checked>', cells[7]):
        if rr.text(cells[7][m.end(): cells[7].find("</li>", m.end())]) == "PASS":
            checks["pass"] = True
    if 'type="checkbox" checked' in cells[9]:
        checks["release"] = True
    plan_row = {"service": " ".join(paras(cells[1])), "feature": rr.text(cells[2]),
                "team": rr.text(cells[3]), "items": items}
    if checks:
        plan_row["checks"] = checks
    print(json.dumps({"accountId": mention.group(1), "name": html.unescape(mention.group(2)).strip(),
                      "number": rr.text(cells[0]), "rows": [plan_row]}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 5 or sys.argv[1] != "extract":
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(cmd_extract(*sys.argv[2:]))
