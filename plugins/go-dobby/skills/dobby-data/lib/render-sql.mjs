// 사용법: node render-sql.mjs check {키}       명세를 검사한다. 오류가 있으면 한 줄씩 출력하고 종료 코드 1
//        node render-sql.mjs render {회차 폴더}  queries/*.sql 을 쓰고 만든 파일 이름을 한 줄씩 출력
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { die, readJson, specPath, loadExclusions } from "./window.mjs";

const TEMPLATES = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "templates");
const KINDS = ["ab_test", "new_events", "before_after", "value_change", "not_measurable"];
const TS_RE = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export const DEFAULT_DEVICE_TYPES = ["PC_WEB", "MOBILE_WEB"];

// 스노우플레이크는 작은따옴표 문자열 안의 역슬래시를 이스케이프로 읽으므로 역슬래시를 먼저 겹친다
const q = (s) => `'${String(s).replace(/\\/g, "\\\\").replace(/'/g, "''")}'`;
const list = (xs) => xs.map(q).join(", ");

/** 이벤트 하나 → WHERE 조건. category → TAGID, action → ACTION, label → TAGLABEL. */
function cond(ev, alias = "") {
  const a = alias ? `${alias}.` : "";
  const parts = [`${a}TAGID = ${q(ev.category)}`];
  if (ev.action != null) parts.push(`${a}ACTION = ${q(ev.action)}`);
  if (ev.label != null) parts.push(`COALESCE(${a}TAGLABEL, '') = ${q(ev.label)}`);
  return `(${parts.join(" AND ")})`;
}

export function checkSpec(spec) {
  const errs = [];
  if (!spec || typeof spec !== "object") return ["명세가 JSON 객체가 아닙니다"];
  if (!KINDS.includes(spec.kind)) errs.push(`kind 가 ${KINDS.join(", ")} 중 하나가 아닙니다: ${spec.kind}`);
  if (spec.kind === "not_measurable") {
    if (!spec.reason) errs.push("not_measurable 명세에 reason 이 없습니다");
    return errs;
  }
  if (!DATE_RE.test(spec.liveDate ?? "")) errs.push(`liveDate 형식이 YYYY-MM-DD 가 아닙니다: ${spec.liveDate}`);
  if (!["릴리즈 노트", "Jira"].includes(spec.liveDateSource)) errs.push(`liveDateSource 는 "릴리즈 노트" 또는 "Jira" 여야 합니다: ${spec.liveDateSource}`);
  if (!TS_RE.test(spec.startAt ?? "")) errs.push(`startAt 형식이 YYYY-MM-DD HH:mm:ss 가 아닙니다: ${spec.startAt}`);
  if (spec.deviceTypes != null && (!Array.isArray(spec.deviceTypes) || spec.deviceTypes.length === 0)) {
    errs.push("deviceTypes 는 비어 있지 않은 배열이어야 합니다");
  }

  const events = Array.isArray(spec.events) ? spec.events : [];
  if (events.length === 0) errs.push("events 가 비어 있습니다");
  const names = new Set();
  for (const [i, ev] of events.entries()) {
    if (!ev?.name) errs.push(`events[${i}] 에 name 이 없습니다`);
    if (!ev?.category) errs.push(`events[${i}] 에 category 가 없습니다`);
    if (names.has(ev?.name)) errs.push(`이벤트 이름이 겹칩니다: ${ev.name}`);
    names.add(ev?.name);
  }
  const ref = (where, name) => {
    if (!names.has(name)) errs.push(`${where} 의 "${name}" 이(가) events 에 없습니다`);
  };

  if (!Array.isArray(spec.daily) || spec.daily.length === 0) errs.push("daily 에 이벤트가 하나 이상 있어야 합니다");
  else spec.daily.forEach((n) => ref("daily", n));

  if (spec.kind !== "new_events") {
    if (!spec.metric?.name) errs.push("metric.name 이 없습니다");
    if (!["up", "down"].includes(spec.metric?.direction)) errs.push("metric.direction 은 up 또는 down 이어야 합니다");
  }
  if (spec.kind === "ab_test") {
    const ab = spec.ab ?? {};
    if (!ab.assign) errs.push("ab.assign 이 없습니다");
    else ref("ab.assign", ab.assign);
    if (!ab.control || !ab.treatment) errs.push("ab.control 과 ab.treatment 가 필요합니다");
    else if (ab.control === ab.treatment) errs.push("ab.control 과 ab.treatment 가 같습니다");
    if (ab.ratio != null && !(Array.isArray(ab.ratio) && ab.ratio.length === 2 && ab.ratio.every((r) => r > 0))) {
      errs.push("ab.ratio 는 양수 두 개의 배열이어야 합니다");
    }
    if (!Array.isArray(ab.conversion) || ab.conversion.length === 0) errs.push("ab.conversion 이 비어 있습니다");
    else ab.conversion.forEach((n) => ref("ab.conversion", n));
  }
  if (spec.funnel != null) {
    if (!Array.isArray(spec.funnel.steps) || spec.funnel.steps.length === 0) errs.push("funnel.steps 가 비어 있습니다");
    else spec.funnel.steps.forEach((n) => ref("funnel.steps", n));
  }
  for (const [i, c] of (spec.continuations ?? []).entries()) {
    if (!c?.name) errs.push(`continuations[${i}] 에 name 이 없습니다`);
    ref(`continuations[${i}].from`, c?.from);
    ref(`continuations[${i}].to`, c?.to);
    if (!(c?.withinHours > 0)) errs.push(`continuations[${i}].withinHours 는 양수여야 합니다`);
  }
  // 실험이 아니면 첫 이어진 행동의 from 을 기준 기기로 함께 쓰므로 from 이 모두 같아야 한다
  const froms = new Set((spec.continuations ?? []).map((c) => c?.from));
  if (spec.kind !== "ab_test" && froms.size > 1) errs.push(`실험이 아니면 continuations 의 from 이 모두 같아야 합니다: ${[...froms].join(", ")}`);
  if (spec.kind === "before_after") {
    const ba = spec.beforeAfter ?? {};
    if (!["devices", "events"].includes(ba.unit)) errs.push("beforeAfter.unit 은 devices 또는 events 여야 합니다");
    ref("beforeAfter.numerator", ba.numerator);
    ref("beforeAfter.denominator", ba.denominator);
  }
  if (spec.kind === "value_change") {
    const vc = spec.valueChange ?? {};
    ref("valueChange.event", vc.event);
    if (!Array.isArray(vc.values) || vc.values.length === 0) errs.push("valueChange.values 가 비어 있습니다");
  }
  return errs;
}

/** 제외 기기 조회. 빈 목록의 조건 줄은 뺀다(IN () 은 문법 오류). */
function excludedBlock(ex, scopeFromDate, toDate, scope) {
  const ors = [];
  if (ex.deviceIdContains?.length) ors.push(`DEVICEID ILIKE ANY (${list(ex.deviceIdContains.map((s) => `%${s}%`))})`);
  if (ex.userIds?.length) ors.push(`USERID IN (${list(ex.userIds)})`);
  if (ex.uaContains?.length) ors.push(`USERAGENT ILIKE ANY (${list(ex.uaContains.map((s) => `%${s}%`))})`);
  if (ex.uaMustContainOneOf?.length) ors.push(`NOT (USERAGENT ILIKE ANY (${list(ex.uaMustContainOneOf.map((s) => `%${s}%`))}))`);
  const rule = ors.length ? `(${ors.join("\n      OR ")})` : "FALSE";
  return [
    "  SELECT DISTINCT DEVICEID FROM WADIZ_LIVE.WADITAG.TAGEVENT",
    `  WHERE CREATEDAT_DATE BETWEEN '${scopeFromDate}' AND '${toDate}' AND (${scope}) AND DEVICEID IS NOT NULL`,
    `    AND ${rule}`,
  ].join("\n");
}

/** "YYYY-MM-DD HH:mm:ss" 끼리의 차이만큼 앞당긴 시각. 시간대 없이 글자 그대로 계산한다. */
function shiftBack(startAt, to) {
  const ms = (s) => Date.parse(s.replace(" ", "T") + "Z");
  const d = new Date(ms(startAt) - (ms(to) - ms(startAt)));
  return d.toISOString().slice(0, 19).replace("T", " ");
}
const dateOf = (ts) => ts.slice(0, 10);

function fill(name, vars) {
  const sql = fs.readFileSync(path.join(TEMPLATES, `${name}.sql`), "utf8")
    .replace(/\{\{(\w+)\}\}/g, (m, k) => (k in vars ? vars[k] : m));
  const left = sql.match(/\{\{\w+\}\}/g);
  if (left) die(`${name}.sql 에 채우지 못한 자리가 남았습니다: ${[...new Set(left)].join(", ")}`);
  return sql;
}

export function render(runDir) {
  const w = readJson(path.join(runDir, "window.json"));
  const spec = readJson(specPath(w.key));
  const errs = checkSpec(spec);
  if (errs.length) die(`명세 오류:\n${errs.join("\n")}`);
  if (spec.kind === "not_measurable") die("측정 불가 명세입니다");
  const ex = loadExclusions();
  const ev = Object.fromEntries(spec.events.map((e) => [e.name, e]));
  const or = (ns, alias) => `(${ns.map((n) => cond(ev[n], alias)).join(" OR ")})`;
  // 제외 기기는 그 이벤트들의 category(TAGID) 줄 전체에서 찾는다(기준 쿼리와 같은 범위)
  const scope = (ns) => `TAGID IN (${list([...new Set(ns.map((n) => ev[n].category))])})`;
  const common = { START: w.startAt, TO: w.to, FROM: w.from, DEVICE_TYPES: list(spec.deviceTypes ?? DEFAULT_DEVICE_TYPES) };
  const toDate = dateOf(w.to);
  const out = {};

  // 일별 건수
  out.daily = fill("daily", {
    ...common,
    DAILY_EVENTS: spec.daily.map((n) => [
      `  SELECT CREATEDAT_DATE, DEVICEID, ${q(n)} name FROM WADIZ_LIVE.WADITAG.TAGEVENT`,
      `  WHERE CREATEDAT >= '${w.dailyFrom}' AND CREATEDAT < '${w.to}' AND DEVICETYPE IN (${common.DEVICE_TYPES}) AND ${cond(ev[n])}`,
    ].join("\n")).join("\n  UNION ALL\n"),
    EXCLUDED: excludedBlock(ex, dateOf(w.dailyFrom), toDate, scope(spec.daily)),
  });

  // 실험군 비교와, 단계·이어짐 표의 기준 기기
  const isAb = spec.kind === "ab_test";
  const assign = isAb ? cond(ev[spec.ab.assign]) : null;
  const baseScope = isAb ? scope([spec.ab.assign]) : null;
  const groups = isAb ? list([spec.ab.control, spec.ab.treatment]) : null;
  if (isAb) {
    out.ab = fill("ab", {
      ...common,
      EXCLUDED: excludedBlock(ex, dateOf(w.startAt), toDate, baseScope),
      ASSIGN: assign,
      GROUPS: groups,
      CONVERSION: or(spec.ab.conversion, "t"),
    });
  }
  const baseFor = (firstEvent) => isAb
    ? [
      "  SELECT DEVICEID, MAX(TAGLABEL) grp, MIN(CREATEDAT) first_at",
      `  FROM t WHERE ${assign} AND TAGLABEL IN (${groups})`,
      "    AND DEVICEID NOT IN (SELECT DEVICEID FROM excluded)",
      "  GROUP BY 1 HAVING COUNT(DISTINCT TAGLABEL) = 1",
    ].join("\n")
    : [
      "  SELECT DEVICEID, 'ALL' grp, MIN(CREATEDAT) first_at",
      `  FROM t WHERE ${cond(ev[firstEvent])}`,
      "    AND DEVICEID NOT IN (SELECT DEVICEID FROM excluded)",
      "  GROUP BY 1",
    ].join("\n");

  if (spec.funnel?.steps?.length) {
    const first = spec.funnel.steps[0];
    out.funnel = fill("funnel", {
      ...common,
      EXCLUDED: excludedBlock(ex, dateOf(w.startAt), toDate, baseScope ?? scope([first])),
      BASE: baseFor(first),
      STEPS: spec.funnel.steps.map((n, i) => [
        `SELECT b.grp, ${i + 1} step, ${q(n)} name, COUNT(DISTINCT b.DEVICEID) devices`,
        `FROM base b JOIN t ON t.DEVICEID = b.DEVICEID AND t.CREATEDAT >= b.first_at AND ${cond(ev[n], "t")}`,
        "GROUP BY 1",
      ].join("\n")).join("\nUNION ALL\n"),
    });
  }

  if (spec.continuations?.length) {
    const first = spec.continuations[0].from;
    out.continuation = fill("continuation", {
      ...common,
      EXCLUDED: excludedBlock(ex, dateOf(w.startAt), toDate, baseScope ?? scope([first])),
      BASE: baseFor(first),
      CONTINUATIONS: spec.continuations.map((c) => [
        `SELECT f.grp, ${q(c.name)} name, COUNT(DISTINCT f.DEVICEID) from_devices, COUNT(DISTINCT x.DEVICEID) to_devices`,
        "FROM (",
        "  SELECT b.DEVICEID, b.grp, MIN(t.CREATEDAT) from_at",
        `  FROM base b JOIN t ON t.DEVICEID = b.DEVICEID AND t.CREATEDAT >= b.first_at AND ${cond(ev[c.from], "t")}`,
        "  GROUP BY 1, 2",
        ") f",
        `LEFT JOIN t x ON x.DEVICEID = f.DEVICEID AND x.CREATEDAT >= f.from_at AND x.CREATEDAT < DATEADD(hour, ${Number(c.withinHours)}, f.from_at) AND ${cond(ev[c.to], "x")}`,
        "GROUP BY 1",
      ].join("\n")).join("\nUNION ALL\n"),
    });
  }

  if (spec.kind === "before_after" || spec.kind === "value_change") {
    let den, num, unit, names;
    if (spec.kind === "before_after") {
      den = cond(ev[spec.beforeAfter.denominator]);
      num = cond(ev[spec.beforeAfter.numerator]);
      unit = spec.beforeAfter.unit;
      names = [spec.beforeAfter.denominator, spec.beforeAfter.numerator];
    } else {
      const e = ev[spec.valueChange.event];
      den = cond(e);
      num = `(${cond(e)} AND COALESCE(TAGLABEL, '') IN (${list(spec.valueChange.values)}))`;
      unit = "events";
      names = [spec.valueChange.event];
    }
    const beforeStart = shiftBack(w.startAt, w.to);
    out["before-after"] = fill("before-after", {
      ...common,
      BEFORE_START: beforeStart,
      EXCLUDED: excludedBlock(ex, dateOf(beforeStart), toDate, scope(names)),
      DEN: den,
      NUM: num,
      AGGREGATE: unit === "devices"
        ? [
          ", d AS (",
          "  SELECT period, dtype, DEVICEID, MAX(is_den) den, MAX(is_num) num FROM x GROUP BY 1, 2, 3",
          ")",
          "SELECT period, dtype, SUM(den) den, SUM(IFF(den = 1 AND num = 1, 1, 0)) num",
          "FROM d GROUP BY GROUPING SETS ((period, dtype), (period)) ORDER BY 1, 2",
        ].join("\n")
        : [
          "SELECT period, dtype, SUM(is_den) den, SUM(is_num) num",
          "FROM x GROUP BY GROUPING SETS ((period, dtype), (period)) ORDER BY 1, 2",
        ].join("\n"),
    });
  }

  // 이상 기록 후보
  const days = Math.max(1, Math.ceil((Date.parse(w.to.replace(" ", "T") + "Z") - Date.parse(w.from.replace(" ", "T") + "Z")) / 86400000));
  out.anomaly = fill("anomaly", {
    ...common,
    DAILY_COND: or(spec.daily).slice(1, -1),
    EXCLUDED: excludedBlock(ex, dateOf(w.from), toDate, scope(spec.daily)),
    MIN_EVENTS: String(Math.max(50, days * 50)),
  });

  const qdir = path.join(runDir, "queries");
  fs.mkdirSync(qdir, { recursive: true });
  for (const [name, sql] of Object.entries(out)) {
    fs.writeFileSync(path.join(qdir, `${name}.sql`), sql);
    console.log(`${name}.sql`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [cmd, arg] = process.argv.slice(2);
  if (!arg) die("사용법: node render-sql.mjs check {키} | render {회차 폴더}");
  if (cmd === "check") {
    const p = specPath(arg);
    if (!fs.existsSync(p)) die("명세가 없습니다");
    let spec;
    try {
      spec = readJson(p);
    } catch (e) {
      die(`spec.json 을 JSON 으로 읽지 못했습니다: ${e.message}`);
    }
    const errs = checkSpec(spec);
    if (errs.length) {
      console.log(errs.join("\n"));
      process.exit(1);
    }
    console.log("ok");
  } else if (cmd === "render") {
    render(path.resolve(arg));
  } else {
    die(`모르는 명령입니다: ${cmd}`);
  }
}
