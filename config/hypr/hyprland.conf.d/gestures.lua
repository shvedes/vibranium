-- Full documentation:
-- https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures

-- ###########################################################################
-- BASIC SYNTAX
-- ###########################################################################
--
-- hl.gesture({
--   fingers = 3,
--   direction = "...",
--   action = "...",
--   field1 = "...",
--   field2 = "..."
-- })
--
-- You can define as many gestures as you want.
--
-- ###########################################################################
-- DIRECTIONS
-- ###########################################################################
--
-- swipe                 - any swipe
-- horizontal            - left or right swipe
-- vertical              - up or down swipe
-- pinch                 - any pinch
-- pinchin               - pinch in
-- pinchout              - pinch out
-- left, right, up, down - specific swipe direction
--
-- ###########################################################################
-- ACTIONS
-- ###########################################################################
--
-- unset           - removes a previously defined gesture
-- workspace       - switch workspaces (swipe navigation)
-- move            - move the active window
-- resize          - resize the active window
-- special         - toggle special workspace (scratchpad)
-- close           - close the active window
-- fullscreen      - toggle fullscreen
-- float           - toggle floating mode
-- cursorZoom      - zoom into cursor
--
-- OR:
-- any Lua function (same idea as hl.bind dispatcher)
--
-- ###########################################################################
-- IMPORTANT NOTE ABOUT ACTIONS
-- ###########################################################################
--
-- "action" is NOT limited to predefined strings.
--
-- You can pass a Lua function instead.
-- This makes gestures as powerful as keybinds.
--
-- Example:
--
-- hl.gesture({
--   fingers = 3,
--   direction = "up",
--   action = function()
--     print("Gesture triggered")
--   end,
-- })
--
-- You can:
-- - run commands
-- - add conditions
-- - chain multiple actions
-- - interact with files, environment, etc.
--
-- ###########################################################################
-- AVAILABLE FIELDS
-- ###########################################################################
--
-- fingers         (number)    - number of fingers (2-9)
-- direction       (string)    - gesture direction
-- action          (string/fn) - action or Lua function
-- mods            (string)    - optional modifier (e.g. "SUPER", "CTRL")
-- scale           (number)    - animation speed multiplier
-- disable_inhibit (bool)      - ignore shortcut inhibitors
--
-- ###########################################################################

-- Workspace switching with 3-finger horizontal swipe:
--
hl.gesture({
  fingers = 3,
  direction = "horizontal",
  action = "workspace",
})

--
-- Close window with 4-finger swipe down:
--
hl.gesture({
  fingers = 4,
  direction = "down",
  action = "close",
})

--
-- Zoom with pinch gesture:
--
hl.gesture({
  fingers = 3,
  direction = "pinch",
  action = "cursorZoom",
})

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
