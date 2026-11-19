// mentis-dashboard-v2 src/lib/testSummary.ts(2352a8b)에서 타입 표기만 지워 옮긴 파일. 대시보드 계산이 바뀌면 같이 고친다.
import fs from "node:fs";
import path from "node:path";
import { parseReport,              } from "./parseReport.mjs";

/**
 * 한 오더의 테스트 회차를 전부 모아 "무엇을 확인했고 어느 회차에서 봤나"로 다시 묶는다.
 *
 * 회차 하나만 보면 "1회차에서 무엇을 봤고 2회차에서 무엇이 달라졌나"를 알 수 없다.
 * 재실행한 회차는 대개 앞 회차의 일부만 다시 돌리므로, 항목별로 합쳐 봐야 전체가 보인다.
 *
 * ⛔ 결과를 파일로 남기지 않는다. 실측 1.1ms(오더 41개·회차 76개 전부 44ms)라 볼 때마다
 * 새로 세는 편이 싸고, 저장하면 회차가 늘 때마다 어긋난다.
 */

                       
                       
             
                   
             
                
                                                       
              
               
               
               
                                                          
                      
     
                                  
    
                                                    
                                                        
     
                    
  

                        
                                  
              
                                                 
                  
                                  
               
                         
                 
                     
                   
                                                   
                            
                                    
               
  

                             
             
             
               
                           
                  
                                               
                   
  

/** 한 환경(dev·rc4…)의 회차만으로 센 결과. */
                          
                                                      
              
                  
                    
     
                                                         
                                                     
     
                              
                                            
               
               
               
  

                           
                        
                  
                                                
                     
                                           
                         
  

/**
 * 같은 곳인데 다르게 적힌 이름을 합친다.
 *
 * `cdev` 는 `dev.wadiz.io` 를 가리키는 다른 이름이다. 회차 본문에 주소를 앞에 쓰면
 * (`dev.wadiz.io (cdev)`) `dev` 로, 이름을 앞에 쓰면 (`cdev = https://dev.wadiz.io`)
 * `cdev` 로 갈려서, 같은 서버가 태그 두 개로 보인다.
 */
const ENV_ALIAS                         = { cdev: "dev" };

/**
 * 환경을 늘어놓는 차례 — 앞에서 뒤로 나아가는 순서다.
 * 여기 없는 이름(새 환경)은 뒤로, 환경 미상(빈 문자열)은 맨 뒤로 민다.
 */
const ENV_ORDER = ["local", "dev", "rc", "rc1", "rc2", "rc4", "stage", "live"];

/** ENV_ORDER 차례. 목록에 없으면 뒤로 민다. */
export function envRank(env        )         {
  if (!env) return ENV_ORDER.length + 1;
  const i = ENV_ORDER.indexOf(env);
  return i === -1 ? ENV_ORDER.length : i;
}

/** 회차에 적힌 환경 이름을 태그에 쓸 이름으로 고친다. */
export function normalizeEnv(raw        )         {
  const v = raw.trim().toLowerCase(); // 실측 `RC(rc.wadiz.kr)` 한 건만 대문자였다
  return v ? (ENV_ALIAS[v] ?? v) : "";
}

/**
 * 회차를 어느 환경에서 봤나(dev·rc4·stage…).
 *
 * 헬퍼가 `- **환경**:` 줄을 깔아 주기 전에 쌓인 회차는 표기가 제각각이다(실측 78개 중 40개만
 * 읽혔다). 아래를 다 받는다 — 값만 멀쩡히 들어 있지 라벨이 다를 뿐이다.
 *   `- **환경**: dev`  `- 환경: dev`  `- 환경: **dev**`  `대상 환경: rc4 어드민`  `| 환경 | dev |`
 */
export function findEnv(md        )         {
  const bullet = md.match(
    /^\s*[-*]?\s*\*{0,2}(?:대상\s*)?(?:환경|실행 환경|테스트 환경)\*{0,2}\s*[:：]\s*(.+)$/m
  );
  const table = md.match(/^\|\s*(?:환경|실행 환경|테스트 환경)\s*\|\s*([^|]+)\|/m);
  // 콜론 없이 한 문장 안에 끼워 쓴 회차가 있다 —
  // `실행: 2026-09-23 08:10~08:40 KST · 환경 rc4(rc4.wadiz.io) · 로그인 상태`.
  // 뒤가 **영문으로 시작할 때만** 잡는다. 「환경 설정」·「환경 변수」 같은 우리말 문장을 물면
  // 엉뚱한 값이 들어간다.
  const inline = md.match(/환경[ \t]+([A-Za-z][A-Za-z0-9.-]*)/);
  // 값 앞에도 꾸밈이 붙는다(`**dev**`, `` `rc4` ``).
  const raw = (bullet?.[1] ?? table?.[1] ?? inline?.[1] ?? "").trim().replace(/^[*`\s]+/, "");
  // 주소로 적은 회차가 있다 — 호스트 앞자리가 환경 이름이다(`https://stage.wadiz.io` → stage,
  // `www.wadiz.io` → 라이브).
  const host = raw.match(/^(?:https?:\/\/)?([A-Za-z0-9-]+)\.(?:[A-Za-z0-9-]+\.)*(?:io|kr|com)\b/);
  if (host) return host[1] === "www" ? "live" : host[1];
  // `rc4 (https://rc4.wadiz.io)` · `dev, 크롬 데스크톱, 창 너비 1440` 처럼 뒤에 설명이 붙는다.
  // 앞의 이름만 남긴다.
  const token = raw.split(/[\s,(—]/)[0].replace(/[*`'"]/g, "");
  if (/^라이브/.test(token)) return "live";
  if (/^로컬/.test(token)) return "local";
  // 환경 이름은 늘 영문이다. 우리말이 잡혔으면 설명 문장을 문 것이니 빈칸으로 둔다 —
  // 릴리즈 노트 환경 칸에 `빈` 같은 토막이 들어가는 것보다 낫다.
  return /^[A-Za-z][A-Za-z0-9]*$/.test(token) ? token : "";
}

/**
 * 대조 회차인가 — 고치기 전 코드를 보려고 돌린 회차.
 *
 * ⛔ **제목 줄과 환경 줄만** 본다. 본문까지 보면 「수정 전 코드였다면 …」 처럼 설명으로 쓴
 * 정상 회차까지 걸린다(실측: 머리 600자로 넓히면 92건 중 10건이 걸렸고 그중 9건이 멀쩡한
 * 회차였다). 좁히면 실측 92건 중 FE1-1979 4회차 한 건만 걸린다.
 *
 * 같은 라이브라도 FE1-1912 의 「라이브 검증 — GTM 태그 …」 는 진짜 배포 확인이라 안 걸린다.
 */
function isBaselineRun(md        )          {
  const title = md.split("\n", 1)[0] ?? "";
  const envLine =
    md.match(
      /^[ \t]*[-*]?[ \t]*\*{0,2}(?:대상[ \t]*)?(?:환경|실행 환경|테스트 환경)\*{0,2}[ \t]*[:：].*$/m
    )?.[0] ?? "";
  return /대조|수정 전/.test(envLine) || /대조/.test(title);
}

/**
 * status.md 에서 닫히는 조건 한 줄과 그것을 쪼갠 조건 항목을 **한 번 읽어** 같이 뽑는다.
 *
 * ⛔ 조건 항목은 `## 닫히는 조건 항목` 아래의 표만 본다. 문서 전체에서 `| C1 |` 를 찾으면
 * 다른 표(회귀 목록 등)의 행까지 조건으로 센다.
 */
function readClosing(dir        )   
                         
                                             
  {
  let md        ;
  try {
    md = fs.readFileSync(path.join(dir, "status.md"), "utf8");
  } catch {
    return { closing: null, conditions: [] };
  }
  const one = md.match(/^\s*-\s*\*\*닫히는 조건\*\*\s*[:：]\s*(.+)$/m);
  const conditions                                 = [];
  let inSection = false;
  for (const line of md.split("\n")) {
    if (/^##\s/.test(line)) {
      inSection = line.includes("닫히는 조건 항목");
      continue;
    }
    if (!inSection) continue;
    const m = line.match(/^\|\s*(C\d+)\s*\|\s*(.+?)\s*\|\s*$/);
    if (m) conditions.push({ id: m[1], text: m[2].trim() });
  }
  return { closing: one ? one[1].trim() : null, conditions };
}

/** `C1·C2` · `C1, C2` 어느 쪽으로 적혀 있어도 번호만 뽑는다. */
function parseConds(cell        )           {
  return [...cell.matchAll(/C\d+/g)].map((m) => m[0]);
}

export function summarizeRuns(orderDir        )                     {
  const runsDir = path.join(orderDir, "test-runs");
  let entries          ;
  try {
    entries = fs.readdirSync(runsDir).sort();
  } catch {
    return null;
  }

  const runs            = [];
  const parsed                                                                             = [];

  for (const id of entries) {
    const dir = path.join(runsDir, id);
    let file                    ;
    try {
      const mds = fs.readdirSync(dir).filter((f) => f.toLowerCase().endsWith(".md"));
      file = mds.find((f) => /result/i.test(f)) ?? mds[0];
    } catch {
      continue;
    }
    if (!file) continue;
    let md        ;
    try {
      md = fs.readFileSync(path.join(dir, file), "utf8");
    } catch {
      continue;
    }

    const { scenarios, counts } = parseReport(md);
    const m = id.match(/(\d{4})-?(\d{2})-?(\d{2})[-_ ]?(\d{2}):?(\d{2})/);
    const run          = {
      id,
      no: runs.length + 1,
      label: m ? `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}` : id,
      env: normalizeEnv(findEnv(md)),
      pass: counts.pass,
      fail: counts.fail,
      skip: counts.skip + counts.warn,
      hasSummary: fs.existsSync(path.join(dir, "summary.html")),
      baseline: isBaselineRun(md),
    };
    runs.push(run);
    parsed.push({ run, scenarios });
  }

  if (runs.length === 0) return null;

  const { closing, conditions: declared } = readClosing(orderDir);
  // 환경마다 따로 센다. 섞으면 rc4 실패가 뒤에 돈 dev 통과에 덮인다(실측: 회차 있는 오더 98개 중 46개가 여러 환경).
  const envNames = [...new Set(runs.map((r) => r.env))].sort((a, b) => envRank(a) - envRank(b));
  const envs               = envNames.map((env) => {
    const mine = parsed.filter((p) => p.run.env === env);
    const items = mergeItems(mine);
    return {
      env,
      runs: mine.map((p) => p.run),
      items,
      conditions: judgeConditions(declared, items),
      pass: items.filter((i) => i.verdict === "pass").length,
      fail: items.filter((i) => i.verdict === "fail").length,
      skip: items.filter((i) => i.verdict === "skip" || i.verdict === "warn").length,
    };
  });

  return { runs, envs, closing };
}

/** 한 환경의 회차들을 시나리오별로 합친다. */
function mergeItems(
  parsed                                                                            
)             {
  // 시나리오 번호 → 회차별 판정.
  // ⛔ 이름으로 묶으면 안 된다. 회차마다 같은 것을 다르게 적는다
  // (1회차 `홈 — 친구 활동 더보기` / 2회차 `/web/main`). 번호가 없을 때만 이름으로 묶는다.
  const seen = new Map 
           
     
                  
                   
                   
                      
                     
                          
                   
                                                              
                         
                       
     
   ();
  // 페이지(URL) → 회차별 판정. 번호가 바뀌어 안 묶인 재확인을 이어 붙이는 데 쓴다(아래 "해소" 판정).
  const byPage = new Map                                             ();

  for (const { run, scenarios } of parsed) {
    const no = run.no;
    for (const s of scenarios) {
      const num = (s.num || "").trim();
      const name = (s.check || s.page || "").trim();
      const key = num || name;
      if (!key) continue;
      const page = (s.page || "").trim();
      if (page && s.verdict !== "skip") byPage.set(page, [...(byPage.get(page) ?? []), { run: no, verdict: s.verdict }]);
      const cur = seen.get(key) ?? {
        num,
        name,
        page: "",
        conds: [],
        runs: [],
        verdicts: [],
        note: "",
        skipRuns: [],
        skipNote: "",
      };
      if (page) cur.page = page;
      // 이름·조건은 최근 회차 것으로 갱신한다(뒤 회차가 더 다듬어져 있는 편이다).
      if (name) cur.name = name;
      const conds = parseConds(s.cond || "");
      if (conds.length) cur.conds = conds;
      // 보류는 "이 회차에선 시험 안 함"이라 앞 회차 결과를 덮지 않는다. 보류는 한 번도 시험 안 한 항목뿐이다.
      if (s.verdict === "skip") {
        cur.skipRuns.push(no);
        cur.skipNote = (s.actual || s.evidence || s.expected || "").trim();
        seen.set(key, cur);
        continue;
      }
      cur.runs.push(no);
      cur.verdicts.push(s.verdict);
      if (s.verdict === "fail" || s.verdict === "warn") {
        cur.note = (s.actual || s.evidence || s.expected || "").trim();
      }
      seen.set(key, cur);
    }
  }

  return [...seen.values()].map((v) => {
    if (v.verdicts.length === 0) {
      return {
        num: v.num,
        conds: v.conds,
        name: v.name,
        runs: v.skipRuns,
        verdict: "skip"           ,
        changed: null,
        note: v.skipNote,
      };
    }
    const last = v.verdicts[v.verdicts.length - 1];
    const varied = new Set(v.verdicts).size > 1;
    const lastRun = v.runs[v.runs.length - 1];

    // 실패로 끝났더라도, **그 뒤 회차에서 같은 페이지를 다시 봐서 전부 통과**했으면 해소로 본다.
    //
    // 왜 필요한가: 이 묶음은 시나리오 **번호**를 키로 쓰는데, 재확인 회차가 번호를 새로
    // 매기는 일이 있다(FE1-1800: 3회차 `S4` 실패를 4회차가 `S1` 로 다시 매겨 통과).
    // 그러면 `S4` 키에는 실패 하나만 남아 **이미 고친 것이 영영 빨갛게 남는다**.
    // 번호를 물려받는 규칙은 dobby-test 에 들어갔지만(v0.2.59) 그 전에 쌓인 기록이 남아 있다.
    //
    // 페이지가 같다고 반드시 같은 확인은 아니므로, **뒤 회차가 하나라도 실패면 해소로 보지
    // 않는다**. 해소로 본 경우에는 왜 그렇게 봤는지를 note 에 적어 사람이 되짚을 수 있게 한다.
    const later = v.page ? (byPage.get(v.page) ?? []).filter((x) => x.run > lastRun) : [];
    const resolved =
      last === "fail" && later.length > 0 && later.every((x) => x.verdict === "pass");
    const resolvedNote = resolved
      ? `${lastRun}회차 실패 — ${later[later.length - 1].run}회차에 같은 페이지를 다시 확인해 통과했습니다.` +
        (v.note ? ` (당시 기록: ${v.note})` : "")
      : "";

    const untested = v.skipRuns.filter((n) => n > lastRun);
    const carriedNote =
      !resolved && last === "pass" && untested.length
        ? `${untested.join("·")}회차는 시험하지 않아 ${lastRun}회차 통과를 이어 씁니다.`
        : "";

    return {
      num: v.num,
      conds: v.conds,
      name: v.name,
      runs: resolved ? [...v.runs, ...later.map((x) => x.run)] : v.runs,
      verdict: resolved ? "pass" : last,
      changed: resolved ? [...v.verdicts, "pass"           ] : varied ? v.verdicts : null,
      note: resolved ? resolvedNote : carriedNote || v.note,
    };
  });
}

/** 조건마다 그것을 확인한 시나리오를 모아 판정을 합친다. */
function judgeConditions(declared                                , items            )                  {
  // 하나라도 실패면 실패, 보류가 섞였으면 보류, 전부 통과여야 통과다 — 통과가 제일 엄하다.
  return declared.map((c) => {
    const mine = items.filter((i) => i.conds.includes(c.id));
    const verdict          =
      mine.length === 0
        ? "unknown"
        : mine.some((i) => i.verdict === "fail")
          ? "fail"
          : mine.some((i) => i.verdict === "skip" || i.verdict === "warn")
            ? "skip"
            : "pass";
    return { id: c.id, text: c.text, items: mine.map((i) => i.num || i.name), verdict };
  });
}
