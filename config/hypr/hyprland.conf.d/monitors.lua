-- Full documentation: https://wiki.hypr.land/Configuring/Basics/Monitors

-- Single monitor:
-- hl.monitor({
--   output = "DP-1",
--   mode = "2560x1440@144",
--   position = "0x0",
--   scale = "auto",
--   vrr = 1,
-- })

-- Dual monitor (second on the right):
-- hl.monitor({
--   output = "HDMI-A-1",
--   mode = "1920x1080@60",
--   position = "2560x0",
--   scale = "auto",
-- })

-- Disabled monitor example:
-- hl.monitor({
--   output = "DP-2",
--   disabled = true,
-- })
