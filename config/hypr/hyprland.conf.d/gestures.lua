-- Full documentation:
-- https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures

-- Workspace switching with 3-finger horizontal swipe:
hl.gesture({
  fingers = 3,
  direction = "horizontal",
  action = "workspace",
})

-- Close window with 4-finger swipe down:
hl.gesture({
  fingers = 4,
  direction = "down",
  action = "close",
})

-- Zoom with pinch gesture:
hl.gesture({
  fingers = 3,
  direction = "pinch",
  action = "cursorZoom",
})

-- Example function:
-- hl.gesture({
--   fingers = 3,
--   direction = "up",
--   action = function()
--     local hour = os.date("*t").hour
--     if hour < 12 then
--       hl.dsp.exec_raw("notify-send 'Morning gesture'")()
--     else
--       hl.dsp.exec_raw("notify-send 'Evening gesture'")()
--     end
--   end,
-- })
