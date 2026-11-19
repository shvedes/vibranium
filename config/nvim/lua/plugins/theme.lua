--==============================================================================
-- plugins/theme.lua  -  Lazy.nvim specs for theme plugins (Vibranium-aware)
--
-- This file is consumed by lazy.nvim as part of the spec import. It returns
-- a list of plugin specs:
--   1. Every theme that has EVER been installed is included with lazy = true.
--      This prevents :Lazy clean from removing an old theme just because it
--      isn't the active one right now.
--   2. The active (current) theme is promoted to eager-load (lazy = false)
--      with high priority (1000) and an init function that runs setup() and
--      :colorscheme at load time.
--
-- The state file (from utils.theme) is read here, NOT the live neovim.lua.
-- This file sets up what lazy.nvim should KNOW about; the live apply (when
-- the host theme switches) is handled by utils.theme.watch/apply which
-- clones plugins directly and applies them bypassing lazy.
--==============================================================================

local theme = require("utils.theme")

-- Sync the state file before lazy starts processing specs.
-- This ensures every currently known theme is in the state.
theme.sync_state()

-- Read the source to get the active colorscheme and primary plugin spec.
local _, colorscheme, primary = theme.read_source()

-- URL and short name of the primary theme plugin.
local primary_url = primary and primary[1] or "folke/tokyonight.nvim"
local primary_name = primary and theme.sname(primary) or "tokyonight"

-- Build the specs table: every state entry => a lazy = true spec.
local specs = {}
local seen = {}

-- This is what actually keeps :Lazy clean from removing an old theme just
-- because it is no longer the active one. As long as the entry is part of
-- the returned spec, lazy.nvim considers it "in use".
for _, e in ipairs(theme.read_state()) do
  if not seen[e[1]] then
    seen[e[1]] = true
    table.insert(specs, { e[1], name = e.name, lazy = true })
  end
end

-- Promote the ACTIVE theme: find its state entry, set lazy = false,
-- and add an init function that calls setup() + :colorscheme.
local found = false
for _, s in ipairs(specs) do
  if s[1] == primary_url then
    s.lazy = false
    s.priority = 1000
    s.init = function()
      if primary and primary.opts then
        pcall(function() require(primary_name).setup(primary.opts) end)
      end
      pcall(vim.cmd.colorscheme, colorscheme)
    end
    found = true
    break
  end
end

-- If the active theme somehow isn't in the state yet, add it manually.
if not found then
  table.insert(specs, {
    primary_url,
    name = primary_name,
    lazy = false,
    priority = 1000,
    init = function()
      if primary and primary.opts then
        pcall(function() require(primary_name).setup(primary.opts) end)
      end
      pcall(vim.cmd.colorscheme, colorscheme)
    end,
  })
end

return specs
