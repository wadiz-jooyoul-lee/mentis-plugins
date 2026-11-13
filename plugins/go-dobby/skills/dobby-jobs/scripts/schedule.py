#!/usr/bin/env python3
"""팀 이슈 조사 예약. 대시보드와 오피스가 함께 부른다.
  schedule.py status        지금 상태를 JSON 으로 출력
  schedule.py tick          평일 9시 이후 오늘 성공 기록이 없으면 시작(1분마다 불러도 됨)
  schedule.py run           사람이 누른 실행. 이미 돌고 있으면 시작하지 않음
  schedule.py _work         (내부) 실제 조사. 위 둘이 백그라운드로 띄운다"""
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
RUN_HOUR, RETRY_MIN, MAX_TRIES = 9, 30, 3


def load_config():
    """config.env 는 읽기만 한다. 이미 환경에 있는 값이 우선."""
    p = f"{HOME}/.config/go-dobby/config.env"
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            m = re.match(r'^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=["\']?(.*?)["\']?\s*$', line)
            if m and m.group(1) not in os.environ:
                os.environ[m.group(1)] = m.group(2).replace("$HOME", HOME)


load_config()
META = os.environ.get("ORCHESTRATION_META_PATH") or os.environ.get("ORCHESTRATION_META") or f"{HOME}/work/orchestration-meta"
RT = f"{META}/.dobby-jobs"
LOCK, LOG = f"{RT}/lock", f"{RT}/run.log"
os.makedirs(RT, exist_ok=True)


def read(name, default=None):
    try:
        return json.load(open(f"{RT}/{name}"))
    except Exception:
        return default


def write(name, v):
    tmp = f"{RT}/{name}.tmp"
    json.dump(v, open(tmp, "w"), ensure_ascii=False)
    os.replace(tmp, f"{RT}/{name}")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def running():
    """실행 중 표시(폴더)가 있고 그 프로세스가 살아 있으면 실행 중. 죽었으면 표시를 치운다."""
    if not os.path.isdir(LOCK):
        return None
    info = read("lock/info.json", {})
    if info.get("pid") and alive(info["pid"]):
        return info
    if not info and os.path.getmtime(LOCK) > datetime.now().timestamp() - 60:
        return {"startedAt": None}  # 막 만들어져 아직 기록 전
    shutil.rmtree(LOCK, ignore_errors=True)
    return None


def next_auto(now, last_ok_day):
    d = now
    while True:
        due = d.replace(hour=RUN_HOUR, minute=0, second=0, microsecond=0)
        if d.weekday() < 5 and d.strftime("%Y-%m-%d") != last_ok_day and due >= now.replace(hour=0, minute=0):
            return max(due, now) if d.date() == now.date() else due
        d = (d + timedelta(days=1)).replace(hour=0, minute=0)


def status():
    now = datetime.now()
    st = read("state.json", {})
    last_ok = st.get("lastSuccess")
    tries = st.get("tries", {})
    return {
        "running": running(),
        "lastSuccess": last_ok,
        "lastMode": st.get("lastMode"),
        "lastError": st.get("lastError"),
        "triesToday": tries.get("count", 0) if tries.get("day") == now.strftime("%Y-%m-%d") else 0,
        "nextAuto": next_auto(now, (last_ok or "")[:10]).strftime("%Y-%m-%d %H:%M"),
        "log": LOG,
        "latest": os.path.join(os.environ.get("ORCHESTRATION_DOCS_ROOT", f"{HOME}/work/repos/docs"), "_dobby-jobs/latest.json"),
    }


def start(by):
    try:
        os.mkdir(LOCK)  # 폴더 만들기는 한쪽만 성공한다. 대시보드와 오피스가 동시에 불러도 한 번만 돈다
    except FileExistsError:
        return False
    now = datetime.now()
    st = read("state.json", {})
    day = now.strftime("%Y-%m-%d")
    t = st.get("tries", {})
    st["tries"] = {"day": day, "count": (t.get("count", 0) if t.get("day") == day else 0) + 1, "at": now.isoformat(timespec="minutes")}
    write("state.json", st)
    log = open(LOG, "w")
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_work", by], stdout=log, stderr=log,
                         stdin=subprocess.DEVNULL, start_new_session=True, env=os.environ.copy())
    write("lock/info.json", {"pid": p.pid, "by": by, "startedAt": now.isoformat(timespec="minutes")})
    return True


def tick():
    now = datetime.now()
    if now.weekday() >= 5 or now.hour < RUN_HOUR or running():
        return "기다림"
    st = read("state.json", {})
    day = now.strftime("%Y-%m-%d")
    if (st.get("lastSuccess") or "")[:10] == day:
        return "오늘 이미 조사함"
    t = st.get("tries", {})
    if t.get("day") == day:
        if t.get("count", 0) >= MAX_TRIES:
            return "오늘 시도 횟수를 다 씀"
        if datetime.fromisoformat(t["at"]) > now - timedelta(minutes=RETRY_MIN):
            return "다시 시도 대기"
    return "시작함" if start("자동") else "기다림"


def work(by):
    st = read("state.json", {})
    since = st.get("lastSuccess")
    until = datetime.now().strftime("%Y-%m-%d %H:%M")
    mode = "daily" if since else "baseline"
    print(f"[{until}] {by} 조사 시작 · {mode} · {since or '처음'} 부터", flush=True)
    r = subprocess.run([sys.executable, f"{HERE}/collect.py", mode, since or until, until])
    st = read("state.json", {})
    if r.returncode == 0:
        st.update(lastSuccess=until, lastMode=mode, lastError=None)
        write("state.json", st)
        if os.environ.get("DOBBY_JOBS_NO_SUMMARY"):
            print("수집 성공. 요약은 건너뜁니다", flush=True)
            shutil.rmtree(LOCK, ignore_errors=True)
            return
        print("수집 성공. 요약을 씁니다", flush=True)
        claude = f"{HOME}/.local/bin/claude" if os.path.exists(f"{HOME}/.local/bin/claude") else "claude"
        # 요약은 덧붙이는 일이라 실패해도 조사는 성공으로 둔다
        subprocess.run(["nice", "-n", "19", claude, "-p", "/dobby-jobs summarize", "--permission-mode", "bypassPermissions",
                        "--add-dir", os.environ.get("ORCHESTRATION_DOCS_ROOT", f"{HOME}/work/repos/docs")], timeout=1800)
    else:
        st["lastError"] = f"{until} 수집 실패(종료 코드 {r.returncode}). 기록: {LOG}"
        write("state.json", st)
    shutil.rmtree(LOCK, ignore_errors=True)
    print("끝", flush=True)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        print(json.dumps(status(), ensure_ascii=False))
    elif cmd == "tick":
        print(json.dumps({"result": tick()}, ensure_ascii=False))
    elif cmd == "run":
        ok = not running() and start("수동")
        print(json.dumps({"result": "시작함" if ok else "이미 실행 중"}, ensure_ascii=False))
    elif cmd == "_work":
        work(sys.argv[2] if len(sys.argv) > 2 else "수동")
