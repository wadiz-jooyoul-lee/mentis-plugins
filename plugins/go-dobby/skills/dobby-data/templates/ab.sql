-- ab.sql — 실험군 비교. 매 회차 startAt 부터 다시 센다.
-- 결과 칸 순서(바꾸지 말 것): grp, dtype, devices, converted
WITH t AS (
  SELECT * FROM WADIZ_LIVE.WADITAG.TAGEVENT
  WHERE CREATEDAT >= '{{START}}' AND CREATEDAT < '{{TO}}' AND DEVICETYPE IN ({{DEVICE_TYPES}})
), excluded AS (
{{EXCLUDED}}
), elig AS (
  SELECT DEVICEID, MAX(TAGLABEL) grp, MIN(CREATEDAT) first_at, MAX(DEVICETYPE) dtype
  FROM t WHERE {{ASSIGN}} AND TAGLABEL IN ({{GROUPS}})
    AND DEVICEID NOT IN (SELECT DEVICEID FROM excluded)
  GROUP BY 1 HAVING COUNT(DISTINCT TAGLABEL) = 1
), out AS (
  SELECT e.DEVICEID, MAX(IFF({{CONVERSION}}, 1, 0)) conv
  FROM elig e LEFT JOIN t ON t.DEVICEID = e.DEVICEID AND t.CREATEDAT >= e.first_at
  GROUP BY 1
)
SELECT grp, dtype, COUNT(*) devices, SUM(conv) converted
FROM elig JOIN out USING (DEVICEID)
GROUP BY ROLLUP (grp, dtype) ORDER BY 1, 2
