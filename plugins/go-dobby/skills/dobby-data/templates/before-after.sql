-- before-after.sql — 배포 전(startAt 앞 같은 길이)과 배포 뒤(startAt ~ to) 비교.
-- 결과 칸 순서(바꾸지 말 것): period, dtype, den, num
WITH t AS (
  SELECT * FROM WADIZ_LIVE.WADITAG.TAGEVENT
  WHERE CREATEDAT >= '{{BEFORE_START}}' AND CREATEDAT < '{{TO}}' AND DEVICETYPE IN ({{DEVICE_TYPES}})
), excluded AS (
{{EXCLUDED}}
), x AS (
  SELECT IFF(CREATEDAT < '{{START}}', 'before', 'after') period, DEVICETYPE dtype, DEVICEID,
    IFF({{DEN}}, 1, 0) is_den, IFF({{NUM}}, 1, 0) is_num
  FROM t WHERE ({{DEN}} OR {{NUM}})
    AND DEVICEID NOT IN (SELECT DEVICEID FROM excluded)
)
{{AGGREGATE}}
