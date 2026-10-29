-- funnel.sql — 단계별 기기 수. 기준 기기의 첫 시각 이후 그 단계 이벤트를 한 번이라도 한 기기 수.
-- 결과 칸 순서(바꾸지 말 것): grp, step, name, devices
WITH t AS (
  SELECT * FROM WADIZ_LIVE.WADITAG.TAGEVENT
  WHERE CREATEDAT >= '{{START}}' AND CREATEDAT < '{{TO}}' AND DEVICETYPE IN ({{DEVICE_TYPES}})
), excluded AS (
{{EXCLUDED}}
), base AS (
{{BASE}}
)
{{STEPS}}
ORDER BY 1, 2
