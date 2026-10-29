-- daily.sql — 일별 건수. dailyFrom 부터 센다(reset 이 아니면 지난 회차 끝부터).
-- 결과 칸 순서(바꾸지 말 것): d, name, n
WITH ev AS (
{{DAILY_EVENTS}}
), excluded AS (
{{EXCLUDED}}
)
SELECT TO_VARCHAR(CREATEDAT_DATE, 'YYYY-MM-DD') d, name, COUNT(*) n
FROM ev WHERE DEVICEID NOT IN (SELECT DEVICEID FROM excluded)
GROUP BY 1, 2 ORDER BY 1, 2
