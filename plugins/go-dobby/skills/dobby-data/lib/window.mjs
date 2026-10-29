// 사용법: node window.mjs facts {키}
//        node window.mjs new {키} [--until "YYYY-MM-DD HH:mm:ss"]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

export const META = process.env.ORCHESTRATION_META;
export const isTaskKey = (k) => /^TASK-/i.test(k);

export function die(msg) {
  console.error(msg);
  process.exit(1);
}

function requireMeta() {
  if (!META) die("ORCHESTRATION_META 환경 변수가 없습니다");
  return META;
}

export const orderDir = (key) => path.join(requireMeta(), key);
export const dataDir = (key) => path.join(orderDir(key), "data");
export const runsDir = (key) => path.join(dataDir(key), "runs");
export const specPath = (key) => path.join(dataDir(key), "spec.json");
export const exclusionsPath = () => path.join(requireMeta(), ".data", "exclusions.json");

export function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}
export function readJsonSafe(p) {
  try {
    return readJson(p);
  } catch {
    return null;
  }
}

/** 한국 시간 "YYYY-MM-DD HH:mm:00" (분 단위 버림). */
export function kstNow(withSeconds = false) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Seoul",
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
    }).formatToParts(new Date()).map((p) => [p.type, p.value])
  );
  const sec = withSeconds ? parts.second : "00";
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${sec}`;
}

export function runIdOf(ts) {
  return ts.replace(/[-: ]/g, "").replace(/^(\d{8})(\d{6})$/, "$1-$2");
}

export const DEFAULT_EXCLUSIONS = {
  uaContains: ["bot", "spider", "crawler", "externalads", "externalhit", "QA-browser", "Sogou", "Headless"],
  uaMustContainOneOf: ["Chrome/", "Safari/", "Firefox/", "CriOS/", "FxiOS/"],
  deviceIdContains: ["rc", "cdev"],
  userIds: [
    "a1a9d239cf8eea63d0d91138383b2176df525361",
    "fe0ca83d61925e6aeed504892c1d9eb6095a1948",
    "bf3a06656874e2bff281cb1e603438c0233d2749",
    "f642bb1172201f0dd496f33f7fbf0cb5b71a6990",
  ],
};

/** 공용 제외 규칙. 없으면 기본값으로 만든다(있으면 건드리지 않는다). */
export function loadExclusions() {
  const p = exclusionsPath();
  if (!fs.existsSync(p)) {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify(DEFAULT_EXCLUSIONS, null, 2) + "\n");
  }
  return readJson(p);
}

export function readSpec(key) {
  const p = specPath(key);
  if (!fs.existsSync(p)) die("명세가 없습니다");
  return readJson(p);
}

export function fingerprintOf(key) {
  loadExclusions();
  const ex = fs.readFileSync(exclusionsPath());
  const spec = fs.readFileSync(specPath(key));
  return createHash("sha256").update(ex).update("\n").update(spec).digest("hex").slice(0, 12);
}

/** runs/ 아래 회차를 이름순(= 시간순)으로. */
export function listRuns(key) {
  const dir = runsDir(key);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort()
    .map((runId) => {
      const runDir = path.join(dir, runId);
      return {
        runId,
        dir: runDir,
        window: readJsonSafe(path.join(runDir, "window.json")),
        done: fs.existsSync(path.join(runDir, "stats.json")),
      };
    });
}

/** stats.json 이 있는 마지막 회차. 도중에 실패한 회차는 없는 것으로 친다. */
export function lastCompletedRun(key) {
  const done = listRuns(key).filter((r) => r.done && r.window);
  return done.length ? done[done.length - 1] : null;
}

/** 마크다운 표 하나를 `## 제목` 아래에서 찾아 행 배열(칸 배열)로. 머리 줄과 구분 줄은 뺀다. */
function tableUnder(md, heading) {
  const lines = md.split("\n");
  const start = lines.findIndex((l) => l.trim() === `## ${heading}`);
  if (start < 0) return null;
  const rows = [];
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i].trim();
    if (l.startsWith("## ")) break;
    if (!l.startsWith("|")) continue;
    rows.push(l.replace(/^\||\|$/g, "").split("|").map((c) => c.trim()));
  }
  return rows.length >= 2 ? { head: rows[0], body: rows.slice(2) } : null;
}

const expandHome = (p) => (p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p);

function facts(key) {
  const dir = orderDir(key);
  const statusMd = fs.existsSync(path.join(dir, "status.md"))
    ? fs.readFileSync(path.join(dir, "status.md"), "utf8")
    : "";
  const phase = statusMd.match(/^- \*\*단계\*\*:\s*(.+)$/m)?.[1].trim() ?? null;

  const wt = tableUnder(statusMd, "워크트리 / 브랜치");
  const worktrees = (wt?.body ?? []).map(([repo, branch, p]) => ({
    repo, branch, path: p || null, exists: p ? fs.existsSync(expandHome(p)) : false,
  }));
  const withPath = worktrees.filter((w) => w.path);
  const worktreesGone = withPath.length > 0 && withPath.every((w) => !w.exists);
  const resolved = worktreesGone || phase === "해결" || phase === "종료";

  const rn = tableUnder(statusMd, "릴리즈 노트");
  const dateCol = rn ? rn.head.indexOf("배포일") : -1;
  const dates = dateCol >= 0
    ? rn.body.map((r) => r[dateCol]).filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d)).sort()
    : [];

  const cc = path.join(dir, "code-changes");
  const tsPath = path.join(dir, "track-scan.md");
  let trackScan = null;
  if (fs.existsSync(tsPath)) {
    const md = fs.readFileSync(tsPath, "utf8");
    const rows = [];
    for (const l of md.split("\n")) {
      const t = l.trim();
      if (!t.startsWith("|") || /^\|[-\s|]+\|$/.test(t) || t.startsWith("| 갈래")) continue;
      rows.push(t.replace(/^\||\|$/g, "").split("|").map((c) => c.trim()));
    }
    trackScan = { contact: /접촉 있음/.test(md) ? "접촉 있음" : "접촉 없음", rows };
  }

  return {
    key,
    isTask: isTaskKey(key),
    phase,
    resolved,
    liveDateFromReleaseNote: dates[0] ?? null,
    worktrees,
    codeChanges: fs.existsSync(cc) ? cc : null,
    trackScan,
    specExists: fs.existsSync(specPath(key)),
    runs: listRuns(key).length,
  };
}

function newRun(key, until) {
  if (isTaskKey(key)) die("TASK- 작업은 데이터 분석 대상이 아닙니다");
  const spec = readSpec(key);
  if (spec.kind === "not_measurable") die("측정 불가 명세입니다");
  if (until != null && !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(until)) {
    die(`--until 형식이 틀렸습니다: ${until} (YYYY-MM-DD HH:mm:ss)`);
  }
  const prev = lastCompletedRun(key);
  const fp = fingerprintOf(key);
  const to = until ?? kstNow();
  const from = prev ? prev.window.to : spec.startAt;
  if (to <= from) die(`수집할 새 기간이 없습니다 (${from} 이후)`);
  const reset = !prev || prev.window.fingerprint !== fp;
  const w = {
    runId: runIdOf(kstNow(true)),
    key,
    startAt: spec.startAt,
    from,
    to,
    dailyFrom: reset ? spec.startAt : from,
    reset,
    fingerprint: fp,
    previousRunId: prev?.runId ?? null,
  };
  const runDir = path.join(runsDir(key), w.runId);
  if (fs.existsSync(runDir)) die(`같은 회차 폴더가 이미 있습니다: ${runDir}`);
  fs.mkdirSync(runDir, { recursive: true });
  fs.writeFileSync(path.join(runDir, "window.json"), JSON.stringify(w, null, 2) + "\n");
  console.log(runDir);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [cmd, key, ...rest] = process.argv.slice(2);
  if (!key) die("사용법: node window.mjs facts|new {키} [--until \"YYYY-MM-DD HH:mm:ss\"]");
  if (cmd === "facts") {
    console.log(JSON.stringify(facts(key), null, 2));
  } else if (cmd === "new") {
    const i = rest.indexOf("--until");
    newRun(key, i >= 0 ? rest[i + 1] : undefined);
  } else {
    die(`모르는 명령입니다: ${cmd}`);
  }
}
