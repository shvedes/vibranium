--==============================================================================
-- config/keymaps.lua  -  All global keymaps in one place
--
-- Every user-facing mapping lives here (nothing buffer-local, nothing split
-- across plugin specs). All callbacks `require()` inside the function body so
-- this file loads fast and never forces a plugin to load at startup.
-- Leader is set in config/options.lua, which init.lua loads before this file.
--==============================================================================

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
end

--==============================================================================
-- 1. File explorer (Snacks, already enabled in plugins/snacks.lua)
--==============================================================================

map("n", "<leader>e", function()
  require("snacks").explorer()
end, "Explorer (cwd)")
map("n", "<leader>E", function()
  require("snacks").explorer({ cwd = vim.fn.stdpath("config") })
end, "Explorer (config)")

--==============================================================================
-- 2. Picker (Snacks, enabled in plugins/snacks.lua)
--    Mirrors the dashboard f/g/r keys so they work outside the dashboard too.
--==============================================================================

map("n", "<leader>ff", function()
  require("snacks").picker.files()
end, "Find file")
map("n", "<leader>fg", function()
  require("snacks").picker.grep()
end, "Find text (grep)")
map("n", "<leader>fr", function()
  require("snacks").picker.recent()
end, "Recent files")

--==============================================================================
-- 3. Sessions (persistence.nvim, see plugins/persistence.lua)
--    Backend for the dashboard `s Restore Session` entry.
--==============================================================================

map("n", "<leader>qs", function()
  require("persistence").load()
end, "Restore session (cwd)")
map("n", "<leader>ql", function()
  require("persistence").load({ last = true })
end, "Restore last session")
map("n", "<leader>qd", function()
  require("persistence").stop()
end, "Stop session save")

--==============================================================================
-- 4. Git hunks (gitsigns, see plugins/gitsigns.lua)
--==============================================================================

map("n", "]h", function()
  require("gitsigns").nav_hunk("next")
end, "Next hunk")
map("n", "[h", function()
  require("gitsigns").nav_hunk("prev")
end, "Prev hunk")
map("n", "<leader>hs", "<cmd>Gitsigns stage_hunk<CR>", "Stage hunk")
map("n", "<leader>hr", "<cmd>Gitsigns reset_hunk<CR>", "Reset hunk")
map("n", "<leader>hp", "<cmd>Gitsigns preview_hunk<CR>", "Preview hunk")
map("n", "<leader>hb", "<cmd>Gitsigns blame_line<CR>", "Blame line")
map("n", "<leader>gb", function()
  require("gitsigns").toggle_current_line_blame()
end, "Toggle inline blame")

--==============================================================================
-- 5. TODO comments (todo-comments.nvim, see plugins/todo_comments.lua)
--==============================================================================

map("n", "]t", function()
  require("todo-comments").jump_next()
end, "Next TODO")
map("n", "[t", function()
  require("todo-comments").jump_prev()
end, "Prev TODO")
map("n", "<leader>ft", "<cmd>TodoTrouble<CR>", "TODO list")
