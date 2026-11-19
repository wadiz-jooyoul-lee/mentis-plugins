// 오더의 테스트 계획과 회차 결과를 환경별 최종 판정으로 합쳐 검증 결과 페이지(HTML)를 만든다.
// 사용법: node build.mjs {오더 폴더} {출력 html} [환경,환경…]  — 표준 출력에 환경별 요약 JSON 한 줄.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { summarizeRuns } from "./lib/testSummary.mjs";
import { readTestPlan } from "./lib/testPlan.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const [, , orderDir, outPath, envArg] = process.argv;
if (!orderDir || !outPath) {
  console.error("사용법: node build.mjs {오더 폴더} {출력 html} [환경,환경…]");
  process.exit(2);
}

const summary = summarizeRuns(orderDir);
if (!summary) {
  console.error("회차 결과가 없습니다: " + path.join(orderDir, "test-runs"));
  process.exit(3);
}
const want = envArg ? envArg.split(",").map((s) => s.trim()).filter(Boolean) : null;
const envs = summary.envs
  .filter((e) => e.env && (!want || want.includes(e.env)))
  .map((e) => ({
    env: e.env,
    pass: e.pass,
    fail: e.fail,
    skip: e.skip,
    conditions: e.conditions,
    items: e.items.map((i) => ({ num: i.num, name: i.name, verdict: i.verdict, note: i.note })),
  }));
if (envs.length === 0) {
  console.error("고른 환경의 회차가 없습니다. 있는 환경: " + summary.envs.map((e) => e.env || "미상").join(", "));
  process.exit(4);
}

const plan = readTestPlan(orderDir) ?? { title: null, sections: [], scenarios: [], skipReason: null };
const key = path.basename(path.resolve(orderDir));
let title = key;
try {
  const m = fs.readFileSync(path.join(orderDir, "status.md"), "utf8").match(/^- \*\*제목\*\*:\s*(.+)$/m);
  if (m) title = m[1].trim();
} catch {}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
// Jira 이슈 키면 이슈 링크를 건다. TASK- 키는 Jira 이슈가 없어 글자만 둔다.
const jiraBase = (process.env.JIRA_BASE_URL || "").replace(/\/+$/, "");
const keyLink = jiraBase && /^[A-Z][A-Z0-9]+-\d+$/.test(key)
  ? `<a href="${esc(jiraBase)}/browse/${esc(key)}" target="_blank" rel="noreferrer">${esc(key)}</a>`
  : esc(key);
const data = JSON.stringify({ closing: summary.closing, plan, envs }).replace(/</g, "\\u003c");
const marked = fs.readFileSync(path.join(here, "lib/marked.min.js"), "utf8");
const html = fs
  .readFileSync(path.join(here, "template.html"), "utf8")
  .replace("__KEYLINK__", () => keyLink)
  .replaceAll("__KEY__", () => esc(key))
  .replace("__TITLE__", () => esc(title))
  .replace("__ENVS__", () => esc(envs.map((e) => e.env).join(", ")))
  .replace("__MARKED__", () => marked)
  .replace("__DATA__", () => data);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, html);

console.log(
  JSON.stringify({
    key,
    title,
    scenarios: plan.scenarios.length,
    envs: envs.map((e) => ({
      env: e.env,
      items: e.items.length,
      pass: e.pass,
      fail: e.fail,
      skip: e.skip,
      conditions: e.conditions.length,
      met: e.conditions.filter((c) => c.verdict === "pass").length,
      notPassed: e.items.filter((i) => i.verdict !== "pass").map((i) => i.num || i.name),
    })),
  }),
);
