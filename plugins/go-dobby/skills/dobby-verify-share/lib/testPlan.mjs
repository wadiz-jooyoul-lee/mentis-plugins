// mentis-dashboard-v2 src/lib/testPlan.ts(2352a8b)에서 타입 표기만 지워 옮긴 파일. 대시보드 계산이 바뀌면 같이 고친다.
import fs from "node:fs";
import path from "node:path";

/**
 * 설계 때 만든 테스트 계획(test-plan.md)을 검증 탭이 그릴 모양으로 나눈다.
 * 시나리오(S1·TC-1·시나리오 1)는 `- **항목**: 값` 줄을 항목별로 떼고, 나머지 `##` 절은 원문 그대로 둔다.
 */

                                                        

                            
                                
             
                
                    
                  
                
                    
                      
                                          
                
  

                                                          

                        
                       
                                       
                          
                            
     
                                                                               
                                            
     
                            
  

const SCENARIO_RE = /^(S\d+|TC-?\d+|시나리오\s*\d+)(?![\w])\s*[.:)]?\s*(?:[—–-]\s*)?(.*)$/;
const FIELD_RE = /^[-*]\s+\*\*(.+?)\*\*\s*[:：]?\s*(.*)$/;
/** go-dobby 의 판정(_v2_test_skip)과 같은 줄: `- **검증**: 필요 없음 — 이유` */
const SKIP_RE = /^- \*\*검증\*\*:[ \t]*필요 없음[ \t]*(?:[—–-]+[ \t]*)?(.*)$/m;

/** `## 제목` 단위로 자른다. 맨 앞 `# 제목` 은 문서 제목으로 따로 돌려준다. */
function splitHeadings(md        , level       )                                    {
  const re = level === 2 ? /^##\s+/m : /^###\s+/m;
  return md
    .split(re)
    .slice(1)
    .map((p) => {
      const nl = p.indexOf("\n");
      return {
        title: (nl === -1 ? p : p.slice(0, nl)).trim(),
        body: nl === -1 ? "" : p.slice(nl + 1).trim(),
      };
    });
}

function splitList(v        )           {
  return v
    .replace(/`/g, "")
    .split(/[,，、·\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 시나리오 본문을 항목별로 뗀다. 항목 아래 들여 쓴 줄은 그 항목에 붙인다. */
function parseScenario(id        , title        , body        )               {
  const fields              = [];
  const extra           = [];
  let cur                                            = null;
  const flush = () => {
    if (cur) fields.push({ label: cur.label, body: cur.lines.join("\n").trim() });
    cur = null;
  };
  for (const line of body.split("\n")) {
    const m = line.match(FIELD_RE);
    if (m) {
      flush();
      cur = { label: m[1].replace(/[:：]\s*$/, "").trim(), lines: m[2] ? [m[2]] : [] };
    } else if (cur && (line.trim() === "" || /^\s/.test(line))) {
      cur.lines.push(line.replace(/^ {2}/, ""));
    } else {
      flush();
      extra.push(line);
    }
  }
  flush();
  const pick = (label        ) => fields.find((f) => f.label === label)?.body ?? "";
  return {
    id,
    title,
    conds: splitList(pick("조건")).filter((c) => /^C\d+/i.test(c)),
    bundles: splitList(pick("번들")).filter((b) => b !== "—" && b !== "-"),
    fields: fields.filter((f) => f.label !== "조건" && f.label !== "번들"),
    extra: extra.join("\n").trim(),
  };
}

export function parseTestPlan(md        )           {
  const titleMatch = md.match(/^#\s+(.+)$/m);
  const sections                = [];
  const scenarios                 = [];
  for (const sec of splitHeadings(md, 2)) {
    const sm = sec.title.match(SCENARIO_RE);
    if (sm) {
      scenarios.push(parseScenario(sm[1], sm[2].trim(), sec.body));
      continue;
    }
    // `### S1` 처럼 한 단계 아래에 시나리오를 둔 계획도 있다.
    const subs = splitHeadings(sec.body, 3);
    const subScenarios = subs.filter((s) => SCENARIO_RE.test(s.title));
    if (subScenarios.length > 0) {
      const head = sec.body.split(/^###\s+/m)[0].trim();
      if (head) sections.push({ title: sec.title, body: head });
      for (const s of subs) {
        const m = s.title.match(SCENARIO_RE);
        if (m) scenarios.push(parseScenario(m[1], m[2].trim(), s.body));
        else sections.push({ title: s.title, body: s.body });
      }
      continue;
    }
    sections.push(sec);
  }
  // 첫 `##` 앞에 적는 "검증: 필요 없음" 줄은 절에 들지 않는다. 따로 읽어 검증 탭 맨 위에 보여 준다.
  const skip = md.split(/^##\s+/m)[0].match(SKIP_RE);
  // `##` 제목이 하나도 없는 계획은 본문 전체를 한 절로 보여 준다. 제목과 "검증: 필요 없음" 줄뿐이면 절을 만들지 않는다.
  if (sections.length === 0 && scenarios.length === 0) {
    const body = md.replace(/^#\s+.+$/m, "").replace(skip ? SKIP_RE : /^$/, "").trim();
    if (body || !skip) sections.push({ title: "테스트 계획", body });
  }
  return { title: titleMatch?.[1].trim() ?? null, sections, scenarios, skipReason: skip ? skip[1].trim() : null };
}

/** 오더 폴더의 test-plan.md 를 읽어 나눈다. 없으면 null. */
export function readTestPlan(orderDir        )                  {
  let md        ;
  try {
    md = fs.readFileSync(path.join(orderDir, "test-plan.md"), "utf8");
  } catch {
    return null;
  }
  if (!md.trim()) return null;
  return parseTestPlan(md);
}
