--==============================================================================
-- plugins/todo_comments.lua  -  Highlight and search TODO/FIXME/HACK comments
--
-- Plugin: folke/todo-comments.nvim
--
-- Adds highlighting and a :TodoTrouble/:TodoLocList interface for comments
-- containing annotation keywords (TODO, FIXME, HACK, WARN, PERF, NOTE, etc.).
-- Uses treesitter to correctly identify comments (not string literals).
--
-- signs = false: disable the sign column glyphs (keeps the gutter clean).
-- The highlight and search features still work without signs.
--==============================================================================

return {
  "folke/todo-comments.nvim",
  opts = { signs = false },
  event = "BufReadPost",
  -- Stub commands so they work from an empty buffer / the dashboard. The
  -- telescope and fzf-lua variants are left out on purpose: neither plugin is
  -- installed, so those commands would only error.
  cmd = { "TodoQuickFix", "TodoLocList", "TodoTrouble" },
}
