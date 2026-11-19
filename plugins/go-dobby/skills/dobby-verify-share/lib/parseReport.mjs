// mentis-dashboard-v2 src/lib/parseReport.ts(2352a8b)에서 타입 표기만 지워 옮긴 파일. 대시보드 계산이 바뀌면 같이 고친다.
/**
 * issue-test 결과 md를 구조화한다. (순수 함수, node 의존 없음 → 클라이언트에서 사용 가능)
 * 구 포맷(상단 불릿 + 시나리오 표)과 신 포맷(## 한눈 요약 + 시나리오별 결과(전체))을 모두 지원한다.
 */

                                                                    

                        
              
                                                      
               
               
                
                   
                 
                   
                   
                                               
                     
  

                                                        

                      
                
               
               
               
               
                                                
                  
  

                            
                
                   
                        
                 
                                              
                       
  

const META_RE = /^\s*-\s*\*\*(.+?)\*\*\s*[:：]\s*(.+?)\s*$/;

export function normalizeVerdict(raw        )          {
  const s = raw.replace(/\*/g, "").trim();
  // 한국어도 받는다. 회차의 절반가량이 `성공`·`건너뜀` 처럼 우리말로 적는다(실측: 성공 79건,
  // 통과 21건, 건너뜀 9건). ⛔ `정상`·`일치`·`확인됨` 같은 말은 넣지 않는다 — 판정이 아니라
  // "결과" 칸에 적은 관측값이라 판정으로 세면 틀린 집계가 된다.
  if (/❌|FAIL|실패/i.test(s)) return "fail";
  if (/⏭️|⏭|SKIP|건너뜀|미실행|미검증/i.test(s)) return "skip";
  if (/⚠️|⚠|주의|WARN/i.test(s)) return "warn";
  if (/✅|PASS|통과|성공/i.test(s)) return "pass";
  return "unknown";
}

/** 보류 = 준비가 모자라 못 한 것(`SKIP(미비)`, 옛 ⚠️). `SKIP(환경)`·`SKIP(위험)` 은 스킵이다. */
export function isHold(t                                          )          {
  return t.verdict === "warn" || (t.verdict === "skip" && /미비/.test(t.verdictRaw));
}

function splitRow(line        )           {
  const t = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return t.split("|").map((c) => c.trim());
}

/**
 * 헤더 셀에 특정 키워드가 포함된 컬럼의 인덱스를 찾는다.
 *
 * **키워드 순서가 우선순위다.** 왼쪽 컬럼이 이기게 하면 안 된다 —
 * `# | 유형 | 시나리오 | …` 에서 `유형`(기능/회귀 분류)이 `시나리오`보다 왼쪽이라
 * 항목 이름 자리에 "기능"·"회귀"가 들어왔다.
 */
function colIndex(headers          , ...keywords          )         {
  const clean = headers.map((h) => h.replace(/\*/g, ""));
  for (const k of keywords) {
    const i = clean.findIndex((h) => h.includes(k));
    if (i >= 0) return i;
  }
  return -1;
}

                                                                    

/**
 * 머리글에 쓰이는 이름들. 회차마다 제각각이라(20가지 넘음) 실제 파일에서 모아 넣었다.
 * 스킬이 표 골격을 고정한 뒤로는 앞의 표준 이름만 나오지만, 이미 쌓인 회차 75개를 읽으려면
 * 나머지가 필요하다 — 라벨만 다를 뿐 값은 멀쩡히 들어 있다.
 */
const COL = {
  num: ["#", "ID", "번호", "No."],
  // status.md `## 닫히는 조건 항목`의 C 번호. 헬퍼가 표를 깔아 준 뒤의 회차에만 있다.
  cond: ["조건"],
  page: ["페이지", "URL", "화면", "주소", "지면", "경로"],
  // ⛔ `유형`·`구분`은 넣지 않는다 — 기능/회귀 같은 분류 칸이지 항목 이름이 아니다.
  check: ["확인 항목", "확인", "시나리오", "무엇을", "항목", "대상", "이슈", "내용", "조작"],
  expected: ["기대", "예상"],
  actual: ["실제", "관측", "결과값"],
  verdict: ["판정"],
  evidence: ["근거", "증거", "비고"],
}         ;

/** 이 머리글이 "무엇을 테스트했나"를 가리키는가 — 결과 컬럼만 있는 표를 가려낼 때 쓴다. */
function isScenarioish(h        )          {
  return [...COL.num, ...COL.page, ...COL.check].some((k) => h.includes(k));
}

const SEP_CELL = /^:?-{1,}:?$/;
function isSepRow(cells          )          {
  return cells.length > 0 && cells.every((c) => SEP_CELL.test(c) || c === "");
}

/**
 * 표 블록. 머리글 **바로 아래가 구분선**이어야 표로 본다.
 * 이게 없으면 본문 문장에 `|`가 들어간 것을 머리글로 읽는다(실제 사례: 설명 문장 3개가
 * `|`로 이어진 줄을 시나리오 표로 잡았다).
 */
function tableAt(lines          , i        )                    {
  if (i + 1 >= lines.length || !lines[i + 1].trim().startsWith("|")) return null;
  if (!isSepRow(splitRow(lines[i + 1]))) return null;
  const headers = splitRow(lines[i]);
  let end = i + 1;
  for (let j = i + 2; j < lines.length; j++) {
    if (lines[j].trim().startsWith("|")) end = j;
    else break;
  }
  return { start: i, end, headers };
}

/**
 * 시나리오 표 블록을 찾는다.
 *
 * 1순위: "판정" 컬럼이 있는 표. 2순위: "결과" 컬럼 + 시나리오 성격의 표.
 * ⛔ **집계표는 건너뛴다** — `판정 | 건수` 처럼 회차 요약을 적은 표가 시나리오 표보다 위에
 * 있으면 그것을 잡아, 판정만 3줄 뜨고 나머지 칸이 모두 비어 보인다(실제 사례 2건).
 */
function isSummaryTable(headers          )          {
  return headers.some((h) => h.includes("건수") || h.includes("개수"));
}

/** 머리글이 표준 컬럼 몇 개를 짚는가 — 대안이 여럿일 때 더 자세한 쪽을 고르는 기준. */
function columnScore(headers          )         {
  return Object.values(COL).filter((names) => headers.some((h) => names.some((n) => h.includes(n))))
    .length;
}

const MARKER = "<!-- dobby:scenarios -->";

function findScenarioTable(lines          )                    {
  // 표식이 있으면 그 바로 뒤의 표가 정답이다. 헬퍼가 머리글을 고정해 깔아 주므로 추측할
  // 필요가 없다. 아래 추측 규칙은 표식이 없던 시절의 회차를 읽기 위해 남긴다.
  const mark = lines.findIndex((l) => l.trim() === MARKER);
  if (mark >= 0) {
    for (let i = mark + 1; i < lines.length && i <= mark + 3; i++) {
      if (!lines[i].trim().startsWith("|")) continue;
      const t = tableAt(lines, i);
      if (t) return t;
    }
  }

  let fallback                    = null;
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].trim().startsWith("|")) continue;
    const t = tableAt(lines, i);
    if (!t) continue;
    const headers = t.headers.map((h) => h.replace(/\*/g, ""));
    if (isSummaryTable(headers)) continue;
    if (headers.some((h) => h.includes("판정"))) return t;
    if (headers.some((h) => h.includes("결과")) && headers.some(isScenarioish)) {
      // 첫 번째가 아니라 **가장 자세한** 것을 고른다. `구분 | 결과` 같은 두 칸짜리가 위에
      // 있다고 해서 `# | 지면 | 확인 내용 | 결과` 를 버리면 안 된다.
      if (!fallback || columnScore(headers) > columnScore(fallback.headers)) fallback = t;
    }
  }
  return fallback;
}

function parseScenarios(lines          , table            )             {
  const { headers, start, end } = table;
  const idxNum = colIndex(headers, ...COL.num);
  const idxCond = colIndex(headers, ...COL.cond);
  const idxPage = colIndex(headers, ...COL.page);
  const idxCheck = colIndex(headers, ...COL.check);
  const idxExpected = colIndex(headers, ...COL.expected);
  // 판정 우선, 없으면 "결과"를 판정으로 쓴다. 그때는 "결과"를 실제값으로도 세지 않는다.
  const idxVerdict =
    colIndex(headers, ...COL.verdict) >= 0
      ? colIndex(headers, ...COL.verdict)
      : colIndex(headers, "결과");
  const idxActualRaw = colIndex(headers, ...COL.actual);
  const idxActual =
    idxActualRaw >= 0 ? idxActualRaw : colIndex(headers, ...COL.verdict) >= 0 ? colIndex(headers, "결과") : -1;
  const idxEvidence = colIndex(headers, ...COL.evidence);

  const at = (cells          , i        ) =>
    i >= 0 && i < cells.length ? cells[i] : "";

  const rows             = [];
  // start = 헤더, start+1 = 구분선, 이후가 데이터 행
  for (let i = start + 2; i <= end; i++) {
    const cells = splitRow(lines[i]);
    // 구분선(---만 있는 행) 스킵
    if (cells.every((c) => /^:?-{1,}:?$/.test(c) || c === "")) continue;
    rows.push({
      num: at(cells, idxNum),
      cond: at(cells, idxCond),
      page: at(cells, idxPage),
      check: at(cells, idxCheck),
      expected: at(cells, idxExpected),
      actual: at(cells, idxActual),
      evidence: at(cells, idxEvidence),
      verdict: normalizeVerdict(at(cells, idxVerdict)),
      verdictRaw: at(cells, idxVerdict),
    });
  }
  return rows;
}

function countVerdicts(scenarios            )         {
  const counts         = { total: 0, pass: 0, fail: 0, skip: 0, warn: 0, unknown: 0 };
  for (const s of scenarios) {
    counts.total++;
    if (s.verdict === "pass") counts.pass++;
    else if (s.verdict === "fail") counts.fail++;
    else if (s.verdict === "skip") counts.skip++;
    else if (s.verdict === "warn") counts.warn++;
    else counts.unknown++;
  }
  return counts;
}

/**
 * 표가 없는 신 포맷 대비 — 집계 요약 한 줄("PASS 2 / FAIL 0 / SKIP 4",
 * "통과 2 · 실패 0 · 스킵 4" 등)에서 직접 카운트를 뽑는다. PASS·FAIL을 모두 포함한
 * 줄만 요약으로 인정한다(개별 시나리오 헤딩의 "— PASS" 오탐 방지).
 */
function findSummaryCounts(lines          )                {
  for (const line of lines) {
    if (!/(PASS|통과)/i.test(line) || !/(FAIL|실패)/i.test(line)) continue;
    const n = (re        ) => {
      const m = line.match(re);
      return m ? parseInt(m[1], 10) : 0;
    };
    const pass = n(/(?:PASS|통과)\s*[:：]?\s*(\d+)/i);
    const fail = n(/(?:FAIL|실패)\s*[:：]?\s*(\d+)/i);
    const skip = n(/(?:SKIP|스킵)\s*[:：]?\s*(\d+)/i);
    const warn = n(/(?:WARN|주의)\s*[:：]?\s*(\d+)/i);
    const total = pass + fail + skip + warn;
    if (total > 0) return { total, pass, fail, skip, warn, unknown: 0 };
  }
  return null;
}

/**
 * 표가 없을 때 시나리오 헤딩("### TC-1 … — PASS")·판정 불릿("- 판정: PASS")에서 카운트한다.
 * 요약 라인이 없을 때의 폴백.
 */
function countHeadingVerdicts(lines          )         {
  const counts         = { total: 0, pass: 0, fail: 0, skip: 0, warn: 0, unknown: 0 };
  const HEAD = /^#{2,4}\s+.+?\s*[—–-]\s*\*{0,2}(PASS|FAIL|SKIP|WARN|주의|통과|실패|스킵)\b/i;
  const BULLET = /^\s*[-*]\s*\*{0,2}판정\*{0,2}\s*[:：]\s*\*{0,2}(PASS|FAIL|SKIP|WARN|주의|통과|실패|스킵)\b/i;
  for (const line of lines) {
    const m = line.match(HEAD) ?? line.match(BULLET);
    if (!m) continue;
    const v = normalizeVerdict(m[1]);
    counts.total++;
    if (v === "pass") counts.pass++;
    else if (v === "fail") counts.fail++;
    else if (v === "skip") counts.skip++;
    else if (v === "warn") counts.warn++;
  }
  return counts;
}

export function parseReport(md        )               {
  const lines = md.split("\n");

  // 제목: 첫 번째 # 헤딩
  let titleIdx = lines.findIndex((l) => /^#\s+/.test(l));
  const title =
    titleIdx >= 0 ? lines[titleIdx].replace(/^#\s+/, "").trim() : "";

  const table = findScenarioTable(lines);
  const scenarios = table ? parseScenarios(lines, table) : [];
  let counts = countVerdicts(scenarios);
  // 표가 없어 집계가 비면(신 포맷) 요약 라인 → 헤딩/판정 불릿 순으로 카운트를 보정한다.
  if (counts.total === 0) {
    const alt = findSummaryCounts(lines) ?? countHeadingVerdicts(lines);
    if (alt.total > 0) counts = alt;
  }

  // 메타 수집 범위: 표 시작 전(표 없으면 "변경 요약" 헤딩 전, 그것도 없으면 전체)
  let metaEnd = lines.length;
  if (table) metaEnd = table.start;
  else {
    const changeIdx = lines.findIndex((l) => /^##\s+변경\s*요약/.test(l));
    if (changeIdx >= 0) metaEnd = changeIdx;
  }

  const meta             = [];
  const dropIdx = new Set        ();
  if (titleIdx >= 0) dropIdx.add(titleIdx);
  for (let i = 0; i < metaEnd; i++) {
    const m = lines[i].match(META_RE);
    if (m) {
      meta.push({ label: m[1].trim(), value: m[2].trim() });
      dropIdx.add(i);
    }
  }
  // 시나리오 표 라인 제거
  if (table) {
    for (let i = table.start; i <= table.end; i++) dropIdx.add(i);
    // 표 바로 위의 "## 시나리오..." 헤딩도 제거(중복 방지)
    for (let i = table.start - 1; i >= 0; i--) {
      const t = lines[i].trim();
      if (t === "") continue;
      if (/^<!--.*-->$/.test(t)) { dropIdx.add(i); continue; } // 표 자리 표시(<!-- dobby:scenarios -->)
      if (/^##+\s*시나리오/.test(t)) dropIdx.add(i);
      break;
    }
  }

  const restMarkdown = lines
    .filter((_, i) => !dropIdx.has(i))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return { title, meta, scenarios, counts, restMarkdown };
}

/** 카운트로 종합 판정을 낸다. */
export function overallStatus(counts        )   
                
                
                                          
  {
  if (counts.total === 0)
    return { label: "결과 없음", color: "default", status: "warning" };
  // 판정을 하나도 못 읽었으면 "통과"라고 하지 않는다. 종전에는 fail 이 0이라는 이유로
  // 전부 unknown 인 회차까지 초록 "통과"로 보여 줬다.
  if (counts.pass === 0 && counts.fail === 0 && counts.skip === 0 && counts.warn === 0)
    return { label: "판정 못 읽음", color: "default", status: "warning" };
  if (counts.fail === 0)
    return { label: "통과", color: "success", status: "success" };
  if (counts.pass > 0)
    return { label: "부분 통과", color: "warning", status: "warning" };
  return { label: "실패", color: "error", status: "error" };
}
