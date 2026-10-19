#!/usr/bin/env python3
"""WEB Release Note 의 요일별 정기배포 표에서 내 행을 찾고, stage 배포확인 칸만 체크하고, 전후를 검증한다.

사용법
  stage_note.py mine   <body.html> <화|목> <accountId>               내 행 목록(JSON)
  stage_note.py build  <body.html> <화|목> <edits.json> <행localId>...  stage 칸 체크 수정 파일 + 계획(JSON)
  stage_note.py verify <before.html> <after.html> <행localId>...       바뀐 곳이 그 행들의 stage 칸뿐인지 (실패 시 종료 코드 1)
"""
import html
import json
import re
import sys

# 표 칸 순서: 0 번호 · 1 서비스 · 2 기능 · 3 담당 팀 · 4 릴리즈 주요 내용 · 5 개발 담당자
#            6 검증 환경 · 7 RC 검증 결과 · 8 검증 담당자 · 9 release · 10 stage · 11 live · 12 비고
DEV, CONTENT, STAGE = 5, 4, 10
KEY_RE = re.compile(r"\b[A-Z][A-Z0-9]+-\d+\b")
BOX_RE = re.compile(r'<input type="checkbox"( checked)?>')


def text(fragment):
    t = html.unescape(re.sub(r"<[^>]+>", " ", fragment)).replace("\xa0", " ")
    return re.sub(r"\s+", " ", t).strip()


def day_section(body, day):
    keyword = "화요일 정기배포" if day == "화" else "목요일 정기배포"
    m = next((h for h in re.finditer(r"<h2[^>]*>.*?</h2>", body, re.S) if keyword in text(h.group(0))), None)
    if not m:
        return None
    nxt = re.search(r"<h2[^>]*>", body[m.end():])
    return body[m.start(): m.end() + nxt.start() if nxt else len(body)]


def rows_in(fragment):
    return list(re.finditer(r'<tr data-local-id="([^"]+)"[^>]*>(.*?)</tr>', fragment, re.S))


def cells_of(row_html):
    return re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", row_html, re.S)


def load(path):
    return open(path, encoding="utf-8").read()


def cmd_mine(path, day, account):
    sec = day_section(load(path), day)
    if sec is None:
        print(f"{day}요일 정기배포 구역을 찾지 못했습니다", file=sys.stderr)
        return 1
    out = []
    for m in rows_in(sec):
        cells = cells_of(m.group(2))
        if len(cells) < 13 or f'data-user-id="{account}"' not in cells[DEV]:
            continue
        content = cells[CONTENT]
        keys = sorted(set(KEY_RE.findall(" ".join(re.findall(r'href="[^"]*/browse/([^"/?#]+)', content)) + " " + text(content))))
        branches = [text(li) for li in re.findall(r"<li[^>]*>(.*?)</li>", content, re.S) if "/" in text(li)]
        boxes = BOX_RE.findall(cells[STAGE])
        out.append({
            "number": text(cells[0]),
            "localId": m.group(1),
            "keys": keys,
            "services": text(cells[1]).split(),
            "branches": branches,
            "stageBoxes": len(boxes),
            "stageChecked": len(boxes) == 1 and bool(boxes[0]),
        })
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


def cmd_build(path, day, edits_path, *ids):
    sec = day_section(load(path), day)
    if sec is None:
        print(f"{day}요일 정기배포 구역을 찾지 못했습니다", file=sys.stderr)
        return 1
    found = {m.group(1): m for m in rows_in(sec)}
    edits, plan = [], []
    for lid in ids:
        m = found.get(lid)
        if m is None:
            print(f"행을 찾지 못했습니다: {lid} — 손대지 않고 멈춥니다", file=sys.stderr)
            return 1
        whole, inner = m.group(0), m.group(2)
        cells = cells_of(inner)
        stage = cells[STAGE]
        boxes = BOX_RE.findall(stage)
        if len(boxes) != 1:
            print(f"{text(cells[0])}번 행 stage 칸 체크박스가 {len(boxes)}개입니다 — 손대지 않고 멈춥니다", file=sys.stderr)
            return 1
        if boxes[0]:
            plan.append({"number": text(cells[0]), "localId": lid, "already": True})
            continue
        if whole.count(stage) != 1:
            print(f"{text(cells[0])}번 행 stage 칸을 행 안에서 하나로 집지 못했습니다 — 손대지 않고 멈춥니다", file=sys.stderr)
            return 1
        new_stage = stage.replace('<input type="checkbox">', '<input type="checkbox" checked>', 1)
        edits.append({"name": "replaceNode", "localId": lid, "value": whole.replace(stage, new_stage, 1)})
        plan.append({"number": text(cells[0]), "localId": lid, "already": False})
    json.dump(edits, open(edits_path, "w", encoding="utf-8"), ensure_ascii=False)
    print(json.dumps(plan, ensure_ascii=False, indent=1))
    return 0


def signature(body):
    # 미리 보기·저장 뒤 본문은 HTML 을 다시 써서 돌려준다. 그래서 원문 HTML 이 아니라
    # 칸마다 보이는 글자와 체크 상태로 비교한다(원문 비교는 모든 행을 바뀐 것으로 본다).
    rows = {}
    for m in rows_in(body):
        rows[m.group(1)] = [(text(c), tuple(bool(x) for x in BOX_RE.findall(c))) for c in cells_of(m.group(2))]
    outside = text(re.sub(r'<tr data-local-id="[^"]+"[^>]*>.*?</tr>', " ", body, flags=re.S))
    return rows, outside


def cmd_verify(before_path, after_path, *ids):
    b, bo = signature(load(before_path))
    a, ao = signature(load(after_path))
    problems, changed = [], []
    for lid, cb in b.items():
        ca = a.get(lid)
        if ca is None:
            problems.append(f"사라진 행: {lid}")
            continue
        if ca == cb:
            continue
        diff = [i for i in range(max(len(cb), len(ca))) if (cb[i] if i < len(cb) else None) != (ca[i] if i < len(ca) else None)]
        changed.append({"number": cb[0][0], "localId": lid, "cells": diff,
                        "stage": [cb[STAGE][1], ca[STAGE][1]] if len(ca) > STAGE else None})
        if lid not in ids:
            problems.append(f"고치지 않을 행이 바뀌었습니다: {cb[0][0]}번")
        elif diff != [STAGE] or ca[STAGE][1] != (True,):
            problems.append(f"{cb[0][0]}번 행에서 stage 칸 말고도 바뀌었거나 체크가 안 됐습니다: 칸 {diff}")
    added = sorted(set(a) - set(b))
    if added:
        problems.append(f"새로 생긴 행 {len(added)}개")
    if bo != ao:
        problems.append("표 밖의 글이 바뀌었습니다")
    print(json.dumps({"ok": not problems, "changed": changed, "problems": problems}, ensure_ascii=False, indent=1))
    return 0 if not problems else 1


if __name__ == "__main__":
    cmds = {"mine": cmd_mine, "build": cmd_build, "verify": cmd_verify}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(cmds[sys.argv[1]](*sys.argv[2:]))
