--==============================================================================
-- utils/transparent.lua  -  Remove backgrounds from highlight groups
--
-- Design goal: force bg="NONE" and ctermbg="NONE" on every highlight group
-- listed in `config.groups`, plus extras added via:
--   - setup({ extra_groups = {...} })
--   - g:transparent_groups (runtime variable, monitored via dictwatcher)
--   - clear_prefix("PrefixName") -- clears every group starting with a prefix
--
-- The terminal background shows through, making Neovim truly transparent.
--
-- A cache file (stdpath("data")/transparent_cache) persists the toggle state
-- across restarts so you don't have to re-enable transparency every session.
--
-- Autocommands on ColorScheme, FileType, and VimEnter re-clear groups after
-- any event that might redefine highlights (e.g. a colorscheme change).
-- Multiple deferred calls (500ms/1s/3s/5s) handle async highlight redefinitions
-- from plugins like bufferline, lualine, etc.
--==============================================================================

-- Prevent xiyaowong/transparent.nvim from loading if it's still in the
-- lazy-lock.json as a leftover. Can be removed once the old plugin dir is gone.
vim.g.loaded_transparent = 1

-- Module table returned at EOF so require("transparent") works from other
-- configs and plugins.
local M = {}

-- Shorthand aliases to avoid typing vim.api / vim.fn everywhere in the hot loop.
local api, fn = vim.api, vim.fn

-- vim.islist was added in Neovim 0.10; fall back to vim.tbl_islist for older versions.
local islist = vim.islist or vim.tbl_islist

--==============================================================================
-- Default configuration
--==============================================================================

-- Default set of highlight groups whose background will be cleared.
-- These cover the vast majority of syntax and UI groups in any colorscheme.
-- Users can extend or override via M.setup().
local config = {
  groups = {
    'Normal', 'NormalNC', 'Comment', 'Constant', 'Special', 'Identifier',
    'Statement', 'PreProc', 'Type', 'Underlined', 'Todo', 'String', 'Function',
    'Conditional', 'Repeat', 'Operator', 'Structure', 'LineNr', 'NonText',
    'SignColumn', 'CursorLine', 'CursorLineNr', 'StatusLine', 'StatusLineNC',
    'EndOfBuffer',
  },
  -- Additional groups added at runtime via setup({ extra_groups = {...} }).
  extra_groups = {},
  -- Groups that should NEVER have their background removed.
  -- StatusLine and friends keep their background so the status area stays opaque.
  exclude_groups = {
    'StatusLine', 'StatusLineNC', 'TabLine', 'TabLineFill', 'WinBar', 'WinBarNC',
  },
  -- Callback fired after every clear cycle (also fires User TransparentClear event).
  on_clear = function() end,
}

--==============================================================================
-- State persistence (cache file)
--==============================================================================

-- Persistence cache: remembers whether transparency was enabled in the
-- previous session so the state survives restarts.
-- File location: stdpath("data")/transparent_cache
-- Contents: a single line "true" or "false".
local cache_path = fn.stdpath("data") .. "/" .. "transparent_cache"
local cache = {
  read = function()
    -- pcall because the file may not exist on first run.
    local ok, lines = pcall(fn.readfile, cache_path)
    -- Only set true if file exists, has content, and first line is exactly "true".
    vim.g.transparent_enabled = ok and #lines > 0 and vim.trim(lines[1]) == "true"
  end,
  write = function()
    local value = tostring(vim.g.transparent_enabled)
    -- Only touch the disk when the stored value actually changes. M.toggle()
    -- runs on module load with the value read from this very file, so without
    -- this guard every start paid for a writefile() of an unchanged value
    -- (measured ~2.5ms -- roughly 15% of total startup).
    local ok, lines = pcall(fn.readfile, cache_path)
    if ok and #lines > 0 and vim.trim(lines[1]) == value then
      return
    end
    fn.mkdir(fn.stdpath("data"), "p")
    fn.writefile({ value }, cache_path)
  end,
}

-- Read cache on module load (before lazy.nvim) so the toggle state survives
-- restarts even if lazy resets some state.
if vim.g.transparent_enabled == nil then
  cache.read()
end

-- Track prefixes registered via clear_prefix() for dynamic group matching.
local group_prefixes = {}

--==============================================================================
-- clear_group -- Core helper that removes backgrounds from highlight groups
--==============================================================================

-- Removes the background attribute from one or more highlight groups.
-- @param group (string|table): single group name or list of group names.
-- Groups listed in config.exclude_groups are skipped.
-- Only modifies groups that currently have a background set (checks prev.background
-- / prev.bg / prev.ctermbg). Preserves all other attributes (foreground, bold,
-- italic, etc.) by extending the existing attributes table.
local function clear_group(group)
  local groups = type(group) == "string" and { group } or group
  for _, v in ipairs(groups) do
    if not vim.tbl_contains(config.exclude_groups, v) then
      local ok, prev = pcall(api.nvim_get_hl_by_name, v, true)
      if ok and (prev.background or prev.bg or prev.ctermbg) then
        local attrs = vim.tbl_extend("force", prev, { bg = "NONE", ctermbg = "NONE" })
        -- Remove the internal "true" key that nvim_get_hl_by_name sometimes returns.
        attrs[true] = nil
        api.nvim_set_hl(0, v, attrs)
      end
    end
  end
end

--==============================================================================
-- clear -- Internal batch clear (private)
--==============================================================================

-- Clears all groups in:
--   1. config.groups (the defaults)
--   2. config.extra_groups (added via setup)
--   3. g:transparent_groups (runtime variable, added by other configs)
--   4. Every highlight group matching each registered prefix (via getcompletion)
--
-- This is called multiple times with delays (see M.clear) because some plugins
-- redefine their highlights ASYNC after the initial clear, undoing our work.
local function clear()
  if not vim.g.transparent_enabled then
    return
  end
  clear_group(config.groups)
  clear_group(config.extra_groups)
  clear_group(type(vim.g.transparent_groups) == "table" and vim.g.transparent_groups or {})
  for _, prefix in ipairs(group_prefixes) do
    clear_group(fn.getcompletion(prefix, "highlight"))
  end
end

--==============================================================================
-- M.clear -- Public clear entry point (called by autocommands)
--==============================================================================

-- Calls the private clear() four additional times with increasing delays.
-- This is necessary because many UI plugins (bufferline, lualine, neo-tree, etc.)
-- redefine their highlights asynchronously after a ColorScheme event.
-- After the clear cycle, fires:
--   - User Autocommand "TransparentClear" (for other plugins to hook into)
--   - config.on_clear() callback (if set via setup)
function M.clear()
  if not vim.g.transparent_enabled then
    return
  end
  clear()
  vim.defer_fn(clear, 500)
  vim.defer_fn(clear, 1e3)
  vim.defer_fn(clear, 3e3)
  vim.defer_fn(clear, 5e3)
  api.nvim_exec_autocmds("User", { pattern = "TransparentClear", modeline = false })
  config.on_clear()
end

--==============================================================================
-- M.toggle -- Enable / disable / toggle transparency
--==============================================================================

-- @param opt (nil|boolean): nil = flip, true = enable, false = disable.
-- After toggling, re-applies the current colorscheme. This is the cleanest
-- approach because:
--   - A colorscheme plugin redefines ALL highlights from scratch.
--   - Our autocommand on ColorScheme fires immediately after, clearing backgrounds.
--   - The result is a pristine transparent state.
-- If no colorscheme is loaded yet, falls back to M.clear() directly.
function M.toggle(opt)
  if opt == nil then
    vim.g.transparent_enabled = not vim.g.transparent_enabled
  else
    vim.g.transparent_enabled = opt
  end
  cache.write()
  if vim.g.colors_name then
    pcall(vim.cmd.colorscheme, vim.g.colors_name)
  else
    M.clear()
  end
end

--==============================================================================
-- M.handle_groups_changed -- Callback for g:transparent_groups watcher
--==============================================================================

-- When g:transparent_groups is updated at runtime (e.g. by a plugin init file),
-- this function clears only the NEWLY ADDED groups (those not in the old list).
-- This avoids redundantly re-clearing groups that were already handled.
-- @param new (table): the new value of g:transparent_groups.
-- @param old (table): the old value of g:transparent_groups.
function M.handle_groups_changed(new, old)
  old = old or {}
  new = new or {}
  if type(old) == "table" and type(new) == "table" and islist(old) and islist(new) then
    clear_group(vim.tbl_filter(function(v)
      return not vim.tbl_contains(old, v)
    end, new))
  else
    vim.notify("g:transparent_groups must be a list")
  end
end

--==============================================================================
-- M.clear_prefix -- Clear all groups whose name starts with a prefix
--==============================================================================

-- Useful for plugins that define dynamic highlights based on icons/names:
--   - BufferLine GitIcon*            -> clear_prefix("BufferLine")
--   - NeoTree*                       -> clear_prefix("NeoTree")
--   - lualine_*_DevIcon*             -> clear_prefix("lualine")
-- Uses vim.fn.getcompletion(prefix, "highlight") to discover all matching groups.
-- @param prefix (string): the highlight group prefix to match.
function M.clear_prefix(prefix)
  if not prefix or prefix == "" then
    return
  end
  if not vim.tbl_contains(group_prefixes, prefix) then
    table.insert(group_prefixes, prefix)
  end
  clear_group(fn.getcompletion(prefix, "highlight"))
end

--==============================================================================
-- M.setup -- Override default configuration
--==============================================================================

-- @param opts (table): configuration overrides.
--   Example:
--     require("transparent").setup({
--       extra_groups = { "NormalFloat", "NvimTreeNormal" },
--       exclude_groups = { "CursorLine" },
--       on_clear = function() print("Cleared!") end,
--     })
-- Uses vim.validate (with fallback for pre-0.11) to catch typos early.
function M.setup(opts)
  opts = opts or {}
  if vim.fn.has("nvim-0.11") == 1 then
    vim.validate("opts", opts, "table")
    vim.validate("groups", opts.groups, "table", true)
    vim.validate("extra_groups", opts.extra_groups, "table", true)
    vim.validate("exclude_groups", opts.exclude_groups, "table", true)
    vim.validate("on_clear", opts.on_clear, "function", true)
  else
    vim.validate({
      opts = { opts, "t" },
      groups = { opts.groups, "t", true },
      extra_groups = { opts.extra_groups, "t", true },
      exclude_groups = { opts.exclude_groups, "t", true },
      on_clear = { opts.on_clear, "f", true },
    })
  end
  config = vim.tbl_extend("force", config, opts)
end

-- Expose clear_group publicly for advanced use cases e.g. custom autocmd callbacks.
M.clear_group = clear_group

--==============================================================================
-- Autocommands -- trigger clear() whenever highlights might change
--==============================================================================

-- Events:
--   - ColorScheme: every :colorscheme change redefines highlights.
--   - FileType: some plugins set highlights per filetype.
--   - VimEnter: initial load after all plugins are in.
-- Using a named augroup with { clear = true } means sourcing this file again
-- replaces old autocommands cleanly (no duplicates).
local augroup = api.nvim_create_augroup("transparent_builtin", { clear = true })

api.nvim_create_autocmd({ "ColorScheme", "FileType", "VimEnter" }, {
  group = augroup,
  callback = M.clear,
})

--==============================================================================
-- Watch g:transparent_groups for runtime changes
--==============================================================================

-- dictwatcheradd fires whenever the variable is SET. We use it so other configs
-- can push groups onto g:transparent_groups at any point (before or after this
-- module loads) and the new groups will be cleared automatically.
-- pcall guards against the function being unavailable on older Neovim versions.
pcall(function()
  fn.dictwatcheradd("g:", "transparent_groups", function(_, _, new, old)
    M.handle_groups_changed(new, old)
  end)
end)

--==============================================================================
-- User commands -- manual control at the : command line
--==============================================================================

-- :TransparentEnable   -> enable transparency
-- :TransparentDisable  -> disable transparency
-- :TransparentToggle   -> flip the state
-- Each command calls M.toggle(), which persists the state and re-applies
-- the colorscheme for a clean visual result.
api.nvim_create_user_command("TransparentEnable", function()
  M.toggle(true)
end, {})

api.nvim_create_user_command("TransparentDisable", function()
  M.toggle(false)
end, {})

api.nvim_create_user_command("TransparentToggle", function()
  M.toggle()
end, {})

-- Enable or disable transparency based on the persisted cache value.
-- The cache was read earlier in this file (at cache.read()), so
-- vim.g.transparent_enabled reflects the previous session's state:
--   true  -> transparency was on, keep it on
--   false -> transparency was off, keep it off
-- This makes the toggle state survive restarts.
M.toggle(vim.g.transparent_enabled)

-- Return the module table so require("transparent") works from other configs/plugins.
return M
