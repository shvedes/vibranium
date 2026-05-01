-- Full documentation: https://wiki.hypr.land/Configuring/Basics/Monitors
--
-- Everything is defined via hl.monitor({...})
-- Only `output` is strictly required. Everything else has defaults.

-- =========================================================
-- BASICS
-- =========================================================

-- hl.monitor({
--   output = "DP-1",            -- required: monitor name (get via `hyprctl monitors`)
--
--   mode = "1920x1080@144",    -- resolution + refresh rate
--                              -- special values: "preferred", "highrr", "highres"
--
--   position = "0x0",          -- layout position (XxY, top-left origin)
--                              -- can be negative (e.g. "0x-1080")
--                              -- auto placement: "auto", "auto-left", "auto-right", etc.
--
--   scale = 1,                 -- scaling factor (1, 1.5, 2, ...)
--                              -- must divide resolution cleanly (or you'll get warnings)
-- })

-- Layout notes:
-- - All monitors exist in one virtual space
-- - position is relative to top-left corner
-- - monitors must NOT overlap
-- - position is affected by scale and transform

-- =========================================================
-- COMMON OPTIONS
-- =========================================================

--   disabled = false,          -- disable this monitor entirely

--   transform = 0,             -- rotation / flip:
--                              -- 0 normal
--                              -- 1 90°
--                              -- 2 180°
--                              -- 3 270°
--                              -- 4-7 flipped variants

--   mirror = "DP-2",           -- mirror another output
--                              -- note: no re-render, just copy (can look stretched)

--   bitdepth = 8,              -- 8 or 10 (10-bit color)
--                              -- may break screen capture / some apps

--   vrr = 0,                   -- variable refresh rate (adaptive sync)

-- =========================================================
-- COLOR / HDR (optional, ignore if you don't need it)
-- =========================================================

--   cm = "srgb",               -- color management preset:
--                              -- "srgb" (default), "wide", "dcip3", "hdr" (experimental)

--   sdr_eotf = "default",      -- SDR transfer function:
--                              -- "default", "srgb", "gamma22"

--   sdrbrightness = 1.0,       -- SDR brightness in HDR mode
--   sdrsaturation = 1.0,       -- SDR saturation in HDR mode

--   icc = "/path/to/file.icm", -- absolute path to ICC profile
--                              -- note: breaks HDR compatibility

-- =========================================================
-- RESERVED AREA (for bars, docks, etc.)
-- =========================================================

--   reserved_area = 0,         -- reserve pixels on all sides

--   -- OR per-side:
--   reserved_area = {
--     top = 10,
--     bottom = 10,
--     left = 0,
--     right = 0,
--   },

-- =========================================================
-- HDR / LUMINANCE (advanced, usually leave defaults)
-- =========================================================

--   supports_hdr = 0,          -- -1 = off, 0 = auto, 1 = force on
--   supports_wide_color = 0,   -- same logic

--   sdr_min_luminance = 0.2,
--   sdr_max_luminance = 80,

--   min_luminance = -1,
--   max_luminance = -1,
--   max_avg_luminance = -1,

-- =========================================================
-- EXAMPLES
-- =========================================================

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

-- =========================================================

hl.monitor({
  output = "",
  mode = "preffered",
  position = "auto",
  scale = "auto",
})
