// 사용법: node stats.mjs run {회차 폴더}    stats.json 을 쓰고 summary.json 을 다시 만든다
//        node stats.mjs oneline {키} "{문장}"  summary.json 의 oneLine 만 바꾼다
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { die, readJson, readJsonSafe, specPath, dataDir, listRuns } from "./window.mjs";

/** 연결 도구 응답 원문 → 줄 배열. 값은 문자열로 오므로 숫자 칸은 쓰는 곳에서 Number() 로 바꾼다. */
export function rowsOf(file) {
  let v = JSON.parse(fs.readFileSync(file, "utf8"));
  // 도구 응답이 [{ type: "text", text: "{…}" }] 꼴로 감싸여 있으면 벗긴다
  if (Array.isArray(v) && v.length && typeof v[0]?.text === "string") v = JSON.parse(v[0].text);
  if (typeof v === "string") v = JSON.parse(v);
  // 0줄이면 스노우플레이크가 data 칸을 빼고 numRows: 0 만 돌려준다
  const empty = v?.result_set?.resultSetMetaData?.numRows === 0;
  const data = Array.isArray(v) ? v : v?.result_set?.data ?? v?.data ?? (empty ? [] : null);
  if (!Array.isArray(data)) die(`결과 파일에서 줄을 찾지 못했습니다: ${file}`);
  return data.map((r) => (Array.isArray(r) ? r : Object.values(r)).map((c) => (c === "" ? null : c)));
}
const num = (c) => (c == null ? 0 : Number(c));
const str = (c) => (c == null ? null : String(c));

function erf(x) {
  // Abramowitz-Stegun 7.1.26
  const s = Math.sign(x), a = Math.abs(x), t = 1 / (1 + 0.3275911 * a);
  const y = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-a * a);
  return s * y;
}
const normCdf = (z) => 0.5 * (1 + erf(z / Math.SQRT2));

export function twoProp(x1, n1, x2, n2) {          // 1 = 비교 대상, 2 = 대상
  if (!(n1 > 0) || !(n2 > 0)) return { p1: null, p2: null, changeRate: null, p: null };
  const p1 = x1 / n1, p2 = x2 / n2, pp = (x1 + x2) / (n1 + n2);
  const se = Math.sqrt(pp * (1 - pp) * (1 / n1 + 1 / n2));
  const z = se === 0 ? 0 : (p2 - p1) / se;
  return { p1, p2, changeRate: p1 === 0 ? null : (p2 - p1) / p1, p: 2 * (1 - normCdf(Math.abs(z))) };
}
export function requiredN(p1, p2) {                 // 실험군 하나에 필요한 기기 수. 유의수준 5%, 검정력 80%
  if (p1 == null || p2 == null || p1 === p2) return null;
  const za = 1.959964, zb = 0.841621, pb = (p1 + p2) / 2;
  return Math.ceil((za * Math.sqrt(2 * pb * (1 - pb)) + zb * Math.sqrt(p1 * (1 - p1) + p2 * (1 - p2))) ** 2 / (p1 - p2) ** 2);
}
export function srmP(nA, nB, ratio = [1, 1]) {      // 실험군 균형 카이제곱(자유도 1)
  const tot = nA + nB, eA = tot * ratio[0] / (ratio[0] + ratio[1]), eB = tot - eA;
  if (!(eA > 0) || !(eB > 0)) return null;
  const chi = (nA - eA) ** 2 / eA + (nB - eB) ** 2 / eB;
  return 1 - erf(Math.sqrt(chi / 2));
}
export function badge({ p, changeRate, direction, nMin, need, zeroDays, srm }) {
  if (zeroDays.length > 0 || (srm != null && srm < 0.01)) return "수집 이상";
  if (p == null) return "수집 확인";                               // new_events
  const better = direction === "down" ? changeRate < 0 : changeRate > 0;
  if (p < 0.05) return better ? "성과 있음" : "나빠짐";
  if (need != null && nMin < need) return "판단 이르다";
  return "차이 없음";
}

const round = (v, d = 6) => (v == null || !Number.isFinite(v) ? null : Number(v.toFixed(d)));
const side = (label, x, n) => ({ label, x, n, value: n > 0 ? round(x / n) : null });

/** 비교 대상과 대상 한 쌍 → 변화율·p·필요 표본. */
function compareOf(compare, target) {
  const t = twoProp(compare.x, compare.n, target.x, target.n);
  return {
    target, compare,
    changeRate: round(t.changeRate, 4),
    p: round(t.p, 4),
    requiredN: requiredN(t.p1, t.p2),
    // 비교 비율이 0 이라 변화율이 없을 때도 방향은 정해야 배지를 붙일 수 있다
    diff: t.p1 == null ? null : t.p2 - t.p1,
    pRaw: t.p,                                       // 배지는 반올림 전 값으로 정한다
  };
}
function badgeOf(c, direction, extra = { zeroDays: [], srm: null }) {
  // 한 실험군이 통째로 비어도 수집 이상이 먼저다
  if (extra.zeroDays.length > 0 || (extra.srm != null && extra.srm < 0.01)) return "수집 이상";
  if (c.p == null) return "판단 이르다";                             // 한쪽 표본이 0 이다
  return badge({
    p: c.pRaw ?? c.p, changeRate: c.changeRate ?? c.diff, direction,
    nMin: Math.min(c.target.n, c.compare.n), need: c.requiredN, ...extra,
  });
}

/** 이 회차의 결과 파일들 → stats.json 내용(일별·비율·표·이상 후보). */
function runStats(runDir, w, spec) {
  const res = (name) => {
    const f = path.join(runDir, "results", `${name}.json`);
    return fs.existsSync(f) ? rowsOf(f) : null;
  };
  const daily = res("daily");
  if (!daily) die("results/daily.json 이 없습니다");
  const s = {
    runId: w.runId, from: w.from, to: w.to, dailyFrom: w.dailyFrom, reset: w.reset, fingerprint: w.fingerprint,
    daily: daily.map(([d, name, n]) => ({ date: str(d).slice(0, 10), name: str(name), n: num(n) })),
    headline: null, segments: [], tables: { funnel: [], continuations: [], groups: [] }, srmP: null,
    anomalies: (res("anomaly") ?? []).map(([deviceid, ua, dtype, n, days]) => ({ deviceid: str(deviceid), ua: str(ua), dtype: str(dtype), n: num(n), days: num(days) })),
  };
  const direction = spec.metric?.direction ?? "up";

  if (spec.kind === "ab_test") {
    const rows = res("ab");
    if (!rows) die("results/ab.json 이 없습니다");
    const ab = rows.map(([grp, dtype, devices, converted]) => ({ grp: str(grp), dtype: str(dtype), devices: num(devices), converted: num(converted) }));
    const total = (g) => ab.find((r) => r.grp === g && r.dtype == null) ?? { devices: 0, converted: 0 };
    const C = total(spec.ab.control), T = total(spec.ab.treatment);
    s.headline = { metric: spec.metric.name, ...compareOf(side(spec.ab.control, C.converted, C.devices), side(spec.ab.treatment, T.converted, T.devices)) };
    s.srmP = round(srmP(C.devices, T.devices, spec.ab.ratio ?? [1, 1]), 4);
    const dtypes = [...new Set(ab.filter((r) => r.grp != null && r.dtype != null).map((r) => r.dtype))].sort();
    s.segments = dtypes.map((dt) => {
      const g = (grp) => ab.find((r) => r.grp === grp && r.dtype === dt) ?? { devices: 0, converted: 0 };
      const c = compareOf(side(spec.ab.control, g(spec.ab.control).converted, g(spec.ab.control).devices),
        side(spec.ab.treatment, g(spec.ab.treatment).converted, g(spec.ab.treatment).devices));
      return { name: dt, ...c, badge: badgeOf(c, direction) };
    });
    s.tables.groups = [spec.ab.control, spec.ab.treatment].map((g) => {
      const r = total(g);
      return { grp: g, devices: r.devices, converted: r.converted, rate: r.devices > 0 ? round(r.converted / r.devices) : null };
    });
  } else if (spec.kind === "before_after" || spec.kind === "value_change") {
    const rows = res("before-after");
    if (!rows) die("results/before-after.json 이 없습니다");
    const ba = rows.map(([period, dtype, den, n]) => ({ period: str(period), dtype: str(dtype), den: num(den), num: num(n) }));
    const pick = (period, dt) => ba.find((r) => r.period === period && r.dtype === dt) ?? { den: 0, num: 0 };
    const B = pick("before", null), A = pick("after", null);
    s.headline = { metric: spec.metric.name, ...compareOf(side("배포 전", B.num, B.den), side("배포 뒤", A.num, A.den)) };
    const dtypes = [...new Set(ba.filter((r) => r.dtype != null).map((r) => r.dtype))].sort();
    s.segments = dtypes.map((dt) => {
      const b = pick("before", dt), a = pick("after", dt);
      const c = compareOf(side("배포 전", b.num, b.den), side("배포 뒤", a.num, a.den));
      return { name: dt, ...c, badge: badgeOf(c, direction) };
    });
  }

  const funnel = res("funnel");
  if (funnel) s.tables.funnel = funnel.map(([grp, step, name, devices]) => ({ grp: str(grp), step: num(step), name: str(name), devices: num(devices) }));
  const cont = res("continuation");
  if (cont) {
    s.tables.continuations = cont.map(([grp, name, fromD, toD]) => ({
      grp: str(grp), name: str(name), fromDevices: num(fromD), toDevices: num(toD),
      rate: num(fromD) > 0 ? round(num(toD) / num(fromD)) : null,
    }));
  }
  return s;
}

const addDays = (date, n) => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
function dateRange(from, to) {
  const out = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}

/** 모든 완료 회차 → summary.json. 일별은 마지막 reset 회차부터 더하고, 비율은 최근 회차 값만 쓴다. */
function buildSummary(key, spec) {
  const runs = listRuns(key).filter((r) => r.done && r.window)
    .map((r) => ({ ...r, stats: readJson(path.join(r.dir, "stats.json")) }));
  if (runs.length === 0) return null;
  const last = runs[runs.length - 1];
  const lastReset = runs.map((r) => r.window.reset).lastIndexOf(true);
  const merged = new Map();
  for (const r of runs.slice(Math.max(0, lastReset))) {
    for (const row of r.stats.daily) {
      const k = `${row.date}\t${row.name}`;
      merged.set(k, (merged.get(k) ?? 0) + row.n);
    }
  }
  const coveredUntil = last.window.to;
  const startDate = spec.startAt.slice(0, 10);
  const untilDate = coveredUntil.slice(0, 10);
  const lastDataDate = coveredUntil.endsWith("00:00:00") ? addDays(untilDate, -1) : untilDate;
  const series = spec.daily;
  const rows = dateRange(startDate, lastDataDate).map((date) => ({
    date, values: Object.fromEntries(series.map((n) => [n, merged.get(`${date}\t${n}`) ?? 0])),
  }));
  const fullDays = dateRange(addDays(startDate, 1), addDays(untilDate, -1));
  const zeroDays = [];
  for (const date of fullDays) for (const n of series) if (!(merged.get(`${date}\t${n}`) > 0)) zeroDays.push({ date, name: n });

  const direction = spec.metric?.direction ?? "up";
  const health = { zeroDays, srmP: last.stats.srmP, fingerprint: last.window.fingerprint, anomalyCandidates: last.stats.anomalies.length };
  let headline = last.stats.headline;
  let verdict;
  if (spec.kind === "new_events") {
    const counts = fullDays.map((d) => merged.get(`${d}\t${series[0]}`) ?? 0);
    const avg = counts.length ? counts.reduce((a, b) => a + b, 0) / counts.length : null;
    headline = { metric: spec.metric?.name ?? `${series[0]} 하루 건수`, target: { label: "하루 평균", value: round(avg, 2), n: counts.length }, compare: null, changeRate: null, p: null, requiredN: null };
    verdict = badge({ p: null, changeRate: null, direction, nMin: 0, need: null, zeroDays, srm: null });
  } else {
    verdict = badgeOf(headline, direction, { zeroDays, srm: health.srmP });
  }
  const clean = (h) => (h ? (({ diff, pRaw, ...rest }) => rest)(h) : h);
  const prev = readJsonSafe(path.join(dataDir(key), "summary.json"));
  return {
    key,
    kind: spec.kind,
    title: spec.title ?? null,
    liveDate: spec.liveDate,
    startAt: spec.startAt,
    coveredUntil,
    runs: runs.length,
    lastRunId: last.runId,
    verdict,
    headline: clean(headline),
    segments: last.stats.segments.map(clean),
    daily: { series, rows },
    tables: last.stats.tables,
    history: runs.map((r) => ({
      runId: r.runId, coveredUntil: r.window.to,
      changeRate: r.stats.headline?.changeRate ?? null, p: r.stats.headline?.p ?? null,
      verdict: r.runId === last.runId ? verdict : r.stats.verdict ?? null,
    })),
    oneLine: prev?.oneLine ?? "",
    health,
  };
}

function writeAtomic(p, obj) {
  const tmp = `${p}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n");
  fs.renameSync(tmp, p);
}

function run(runDir) {
  const w = readJson(path.join(runDir, "window.json"));
  const spec = readJson(specPath(w.key));
  const stats = runStats(runDir, w, spec);
  writeAtomic(path.join(runDir, "stats.json"), stats);
  const summary = buildSummary(w.key, spec);
  // 이 회차의 배지를 회차 기록에도 남겨 다음 회차의 history 가 읽게 한다
  writeAtomic(path.join(runDir, "stats.json"), { ...stats, verdict: summary.verdict });
  writeAtomic(path.join(dataDir(w.key), "summary.json"), summary);
  console.log(JSON.stringify({ verdict: summary.verdict, headline: summary.headline, health: summary.health }, null, 2));
}

function oneline(key, text) {
  const p = path.join(dataDir(key), "summary.json");
  const s = readJsonSafe(p);
  if (!s) die("summary.json 이 없습니다");
  writeAtomic(p, { ...s, oneLine: text });
  console.log("ok");
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [cmd, a, b] = process.argv.slice(2);
  if (cmd === "run" && a) run(path.resolve(a));
  else if (cmd === "oneline" && a && b != null) oneline(a, b);
  else die("사용법: node stats.mjs run {회차 폴더} | oneline {키} \"{문장}\"");
}
