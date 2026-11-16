--==============================================================================
-- plugins/gitsigns.lua  -  Git signs in the gutter
--
-- Plugin: lewis6991/gitsigns.nvim
--
-- Shows Git status indicators in the sign column:
--   +  added lines
--   ~  modified lines
--   -  removed lines (shown on the line above)
-- Also provides :Gitsigns stage/reset/blame hunk operations.
--
-- opts = {} means default configuration.
-- Lazy-loaded on BufReadPre/BufNewFile (attaches when a buffer is opened).
--==============================================================================

return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  -- `cmd` gives lazy a stub so :Gitsigns exists before any file is opened
  -- (event-only specs have no commands until the event fires).
  cmd = "Gitsigns",
  opts = {
    -- Word-level diff inside preview hunks (line diff alone hides what changed).
    word_diff = true,
    -- Inline blame off by default (toggle with <leader>gb in keymaps.lua).
    current_line_blame = false,
    current_line_blame_opts = { delay = 500 },
    preview_config = { border = "single" },
  },
}
