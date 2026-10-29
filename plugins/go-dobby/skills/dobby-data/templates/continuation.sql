-- continuation.sql — from 을 처음 한 시각 f 이후 withinHours 시간 안에 to 를 한 기기 수.
-- 결과 칸 순서(바꾸지 말 것): grp, name, from_devices, to_devices
WITH t AS (
  SELECT * FROM WADIZ_LIVE.WADITAG.TAGEVENT
  WHERE CREATEDAT >= '{{START}}' AND CREATEDAT < '{{TO}}' AND DEVICETYPE IN ({{DEVICE_TYPES}})
), excluded AS (
{{EXCLUDED}}
), base AS (
{{BASE}}
)
{{CONTINUATIONS}}
ORDER BY 1, 2
