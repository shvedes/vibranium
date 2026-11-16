--==============================================================================
-- plugins/persistence.lua  -  Session save/restore (dashboard `s` backend)
--
-- Plugin: folke/persistence.nvim
--
-- The Snacks dashboard `s Restore Session` entry needs a session backend;
-- without this plugin it silently did nothing. Sessions store open buffers,
-- splits, tabs and cursor positions per working directory.
--==============================================================================

return {
  "folke/persistence.nvim",
  -- Must be eager: the dashboard opens before any BufReadPre fires, so an
  -- event-lazy spec meant require("persistence") failed on the dashboard
  -- and `s` silently did nothing.
  lazy = false,
  opts = {},
}
