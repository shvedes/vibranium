--==============================================================================
-- utils/theme.lua  -  Live colorscheme install/apply via Vibranium
--
-- When the host desktop theme changes, Vibranium (a host-level theme manager)
-- atomically swaps the symlink at ~/.local/state/vibranium/theme/ and
-- writes a new neovim.lua file containing a lazy.nvim spec list for the
-- corresponding colorscheme plugin.
--
-- This module:
--   1. Reads neovim.lua from the Vibranium theme directory.
--   2. Filters out the LazyVim/LazyVim entry (would drag in the entire distro).
--   3. Returns the remaining specs, identifies the primary colorscheme plugin.
--   4. Falls back to lua/config/colorscheme.lua -> "tokyonight" if Vibranium
--      is absent.
--   5. Maintains a state file (stdpath("state")/vibranium-theme-state.lua) that
--      records every theme plugin ever installed. This prevents :Lazy clean
--      from treating an out-of-favour theme as an orphan.
--   6. Provides a file-system watcher that detects symlink swaps and reapplies
--      the colorscheme live (no restart required).
--==============================================================================

local M = {}

local uv = vim.uv or vim.loop

-- Path to the Vibranium host-theme symlink directory.
local THEME_LINK = vim.fn.expand("~/.local/state/vibranium/theme")
-- The actual neovim.lua spec file inside that directory.
local SOURCE_FILE = THEME_LINK .. "/neovim.lua"
-- Static fallback file shipping with this config.
local FALLBACK_FILE = vim.fn.stdpath("config") .. "/lua/config/colorscheme.lua"
-- lazy.nvim plugin root directory (where installed plugins live on disk).
local LAZY_ROOT = vim.fn.stdpath("data") .. "/lazy"
-- State file: outside the config directory on purpose. The config is versioned;
-- the state file is local install-history bookkeeping that should NOT travel
-- with the repo (avoids conflicts when sharing config across machines).
local STATE_FILE = vim.fn.stdpath("state") .. "/vibranium-theme-state.lua"

--==============================================================================
-- Helpers
--==============================================================================

-- Wrapper around vim.notify that schedules the notification to avoid issues
-- with async context (e.g. inside a libuv callback).
local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "theme" })
  end)
end

-- Derive a short name from a lazy.nvim spec table.
-- If the spec has an explicit .name, use it. Otherwise, extract the slug
-- from the URL (the part after the last "/") and strip common suffixes.
-- @param spec (table): a lazy.nvim spec entry (e.g. { "folke/tokyonight.nvim" })
-- @return (string): short plugin name (e.g. "tokyonight")
function M.sname(spec)
  if type(spec) ~= "table" then
    return "?"
  end
  if spec.name then
    return spec.name
  end
  -- A spec that is not a `{ "owner/repo" }` table (the host file is written by
  -- another program, so its shape is not guaranteed) must not throw: this ran
  -- during lazy.nvim startup via lua/plugins/theme.lua, where an error takes
  -- the whole config down.
  if type(spec[1]) ~= "string" then
    return "?"
  end
  local slug = spec[1]:match("[^/]+$") or spec[1]
  return (slug:gsub("%.nvim$", ""):gsub("%.lua$", ""))
end

--==============================================================================
-- State file management
--==============================================================================

-- The state file is an append-only record of every theme repo this framework
-- has ever installed, keyed by URL. lua/plugins/theme.lua turns every entry
-- here into a real lazy.nvim spec (with lazy = true), which prevents :Lazy clean
-- from treating an out-of-favour themes as orphans on the next restart.

-- Read the state file. Returns an empty table if the file does not exist or is invalid.
function M.read_state()
  local ok, entries = pcall(dofile, STATE_FILE)
  if not ok or type(entries) ~= "table" then
    return {}
  end
  return entries
end

-- Write the state file as a Lua table literal suitable for dofile().
-- @param entries (table): list of { url, name = ... } entries.
function M.write_state(entries)
  local lines = { "return {" }
  for _, e in ipairs(entries) do
    local parts = { string.format("%q", e[1]) }
    if e.name then
      table.insert(parts, string.format("name = %q", e.name))
    end
    table.insert(lines, "  { " .. table.concat(parts, ", ") .. " },")
  end
  table.insert(lines, "}")
  local f = io.open(STATE_FILE, "w")
  if not f then
    notify("theme.lua: could not write " .. STATE_FILE, vim.log.levels.ERROR)
    return
  end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

-- Merge new specs into the state without duplicating existing entries.
-- @param specs (table): list of spec tables from neovim.lua.
-- @return (table): updated entries table.
local function merge_into_state(specs)
  local entries = M.read_state()
  local seen = {}
  for _, e in ipairs(entries) do
    seen[e[1]] = true
  end
  local changed = false
  for _, s in ipairs(specs) do
    if not seen[s[1]] then
      seen[s[1]] = true
      table.insert(entries, { s[1], name = s.name or M.sname(s) })
      changed = true
    end
  end
  if changed then
    M.write_state(entries)
  end
  return entries
end

--==============================================================================
-- Source file loading
--==============================================================================

-- Load and execute a Lua file, returning its result.
-- Like dofile() but with error handling that returns nil + error message
-- instead of throwing.
-- @param path (string): absolute path to the Lua file.
-- @return (any, string|nil): the file's return value, or nil + error message.
local function load_lua_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local chunk, load_err = loadfile(path)
  if not chunk then
    return nil, load_err
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end
  return result
end

--==============================================================================
-- Identifying the primary colorscheme plugin
--==============================================================================

-- Among the non-LazyVim specs, identify which one actually provides the
-- colorscheme. The naive "first entry" approach broke when a theme's
-- neovim.lua listed an override plugin (e.g. lualine/bufferline theming)
-- before the colorscheme repo itself.
--
-- Strategy: colorscheme names are conventionally the plugin name (or the
-- plugin name plus a variant suffix, e.g. "tokyonight" -> "tokyonight-storm").
-- Match the spec name against the known colorscheme name.
--
-- @param specs (table): filtered list of non-LazyVim specs.
-- @param colorscheme (string|nil): the colorscheme name from LazyVim opts.
-- @return (table|nil): the primary spec, or nil if none found.
local function pick_primary(specs, colorscheme)
  if #specs == 0 then
    return nil
  end
  if colorscheme then
    for _, s in ipairs(specs) do
      local n = M.sname(s)
      if n == colorscheme or colorscheme:sub(1, #n) == n then
        return s
      end
    end
  end
  if #specs == 1 then
    return specs[1]
  end
  -- Fallback: warn and guess the first entry.
  notify(
    ("theme.lua: %d plugin entries in neovim.lua, none of their names match colorscheme %q -- guessing %s. If this is wrong, check the neovim.lua ordering."):format(
      #specs,
      colorscheme or "?",
      M.sname(specs[1])
    ),
    vim.log.levels.WARN
  )
  return specs[1]
end

--==============================================================================
-- Cache for read_source results (invalidated on theme change)
--==============================================================================

local cache = nil

function M.invalidate_cache()
  cache = nil
end

-- Diagnostics already reported, keyed by message. Declared here (before every
-- function that uses it) so these are upvalues, not globals: a `local` declared
-- further down the chunk would not be in scope for the functions above it.
local reported = {}

-- Read and parse the source neovim.lua file (or fallback).
-- @return (table): plugins array (every non-LazyVim entry).
-- @return (string): colorscheme name to pass to :colorscheme.
-- @return (table|nil): the primary spec entry (needs installing/loading),
--   or nil if we fell back to a bare name with nothing to clone.
-- @return (boolean): true when the source file exists but could not be parsed.
--   That is almost always a half-written file caught by the leading-edge
--   watcher, so callers should skip this cycle instead of applying the
--   fallback colorscheme (which would flash on every theme switch).
function M.read_source()
  if cache then
    return cache[1], cache[2], cache[3], cache[4]
  end

  local plugins, colorscheme, primary = {}, nil, nil
  local source_exists = vim.fn.filereadable(SOURCE_FILE) == 1
  local transient = false

  -- Try to load the Vibranium neovim.lua.
  local spec, err = load_lua_file(SOURCE_FILE)
  if err then
    transient = source_exists
    local key = "neovim.lua load error"
    if not reported[key] then
      reported[key] = true
      notify("theme.lua: neovim.lua failed to load: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  if type(spec) == "table" and #spec > 0 then
    for _, entry in ipairs(spec) do
      -- Only real spec tables (`{ "owner/repo", ... }`) are usable. Anything
      -- else in the list -- a bare string, a number, a nested table without a
      -- repo -- used to reach M.sname() and crash lazy.nvim's startup.
      if type(entry) == "table" and type(entry[1]) == "string" then
        if entry[1] == "LazyVim/LazyVim" then
          -- Extract the colorscheme name from LazyVim's opts (if any).
          colorscheme = entry.opts and entry.opts.colorscheme
        else
          table.insert(plugins, entry)
        end
      else
        local key = "unusable spec entry"
        if not reported[key] then
          reported[key] = true
          notify(
            ("theme.lua: neovim.lua has an entry that is not a plugin spec (%s) -- ignoring it"):format(
              type(entry) == "table" and vim.inspect(entry) or tostring(entry)
            ),
            vim.log.levels.WARN
          )
        end
      end
    end
  end
  -- NOTE: an unusable entry is ignored (and warned about), deliberately not
  -- treated as `transient`: transient freezes live switching until restart,
  -- which would hide a host-format change instead of surfacing it.

  if #plugins > 0 or colorscheme then
    primary = pick_primary(plugins, colorscheme)
    colorscheme = colorscheme or (primary and M.sname(primary))
  else
    -- neovim.lua missing/empty/invalid: fall back to the user's own fallback
    -- file (lua/config/colorscheme.lua), then to "tokyonight".
    local ok, fallback = pcall(dofile, FALLBACK_FILE)
    if ok and type(fallback) == "string" and #fallback > 0 then
      colorscheme = fallback
    else
      colorscheme = "tokyonight"
    end
  end

  cache = { plugins, colorscheme, primary, transient }
  return plugins, colorscheme, primary, transient
end

-- Sync the state file with the current source. Called by plugins/theme.lua
-- during lazy setup so the state is up to date before lazy processes spec.
function M.sync_state()
  local plugins = M.read_source()
  merge_into_state(plugins)
  -- Always track tokyonight.nvim as the hard fallback regardless of what
  -- the current theme's neovim.lua says.
  merge_into_state({ { "folke/tokyonight.nvim", name = "tokyonight" } })
end

--==============================================================================
-- Apply the colorscheme (runtime, bypassing lazy.nvim's loader)
--==============================================================================

-- Some colorscheme plugins depend on a separate palette/helper repo.
-- Since we are going through lazy.nvim's loader during initial setup but NOT
-- during live apply (we clone directly), we need to wire up dependencies
-- ourselves -- best effort, with notification on failure.
local function link_dependencies(primary)
  if not primary or not primary.dependencies then
    return
  end
  for _, dep in ipairs(primary.dependencies) do
    local dep_spec = type(dep) == "table" and dep or { dep }
    local dep_name = M.sname(dep_spec)
    local dep_dir = LAZY_ROOT .. "/" .. dep_name
    if vim.fn.isdirectory(dep_dir) == 1 then
      vim.opt.rtp:prepend(dep_dir)
    else
      notify(
        ("theme.lua: %s depends on %s, which isn't installed yet -- run :Lazy sync and restart"):format(
          M.sname(primary),
          dep_name
        ),
        vim.log.levels.WARN
      )
    end
  end
end

-- Confirm that one of candidate names actually has a colors/*.{lua,vim} file
-- on the runtimepath before calling :colorscheme. Calling it blind and
-- swallowing the error is how this used to fail silently.
-- @param candidates (table): list of candidate colorscheme names.
-- @return (string|nil): the first valid name found, or nil.
local function resolve_colorscheme_name(candidates)
  for _, name in ipairs(candidates) do
    if name and #vim.fn.globpath(vim.o.rtp, "colors/" .. name .. ".{lua,vim}", false, true) > 0 then
      return name
    end
  end
  return nil
end

-- Color names shipped by a plugin's colors/ directory.
-- Theme names and colorscheme names do not always match (everforest-nvim
-- ships colors/everforest.lua), so the host spec alone is not enough.
local function colors_names_from_dir(dir)
  local names = {}
  for _, file in ipairs(vim.fn.glob(dir .. "/colors/*.{lua,vim}", false, true)) do
    names[#names + 1] = vim.fn.fnamemodify(file, ":t:r")
  end
  return names
end

-- Resolve a candidate to a colorscheme that is really reachable, putting the
-- plugin directory on the runtimepath on the way. Three attempts, cheapest
-- first: the names we were given, the names the plugin actually ships, and an
-- installed plugin dir that is not on the rtp yet (the case where the host
-- spec is absent and lua/config/colorscheme.lua supplies the fallback).
local function resolve_reachable(candidates, dir)
  local resolved = resolve_colorscheme_name(candidates)
  if resolved then
    return resolved
  end

  local shipped = colors_names_from_dir(dir)
  for _, name in ipairs(shipped) do
    candidates[#candidates + 1] = name
  end
  resolved = resolve_colorscheme_name(candidates)
  if resolved then
    return resolved
  end

  for _, candidate in ipairs(candidates) do
    local hits = vim.fn.glob(LAZY_ROOT .. "/*/colors/" .. candidate .. ".{lua,vim}", false, true)
    if #hits > 0 then
      local root = hits[1]:match("^(.*)[/\\]colors[/\\]")
      if root then
        vim.opt.rtp:prepend(root)
        return resolve_colorscheme_name(candidates) or candidate
      end
    end
  end
  return nil
end

-- Finish applying the colorscheme: add to rtp, link deps, run setup(),
-- then call :colorscheme.
local function finish_apply(primary, dir, colorscheme)
  if dir then
    vim.opt.rtp:prepend(dir)
  end
  link_dependencies(primary)

  local candidates = { colorscheme }
  if primary then
    table.insert(candidates, M.sname(primary))
  end
  local resolved = resolve_reachable(candidates, dir or (primary and (LAZY_ROOT .. "/" .. M.sname(primary)) or ""))

  if not resolved then
    -- Only once per candidate set: this used to fire on every single theme
    -- switch, which made a transient mismatch (or a color name that simply
    -- does not match the plugin name) look like a permanent error.
    local key = table.concat(candidates, ",")
    if not reported[key] then
      reported[key] = true
      notify(
        ("theme.lua: no colors/*.{lua,vim} found for [%s]; this theme probably needs its own setup()/load() call"):format(
          key
        ),
        vim.log.levels.WARN
      )
    end
    return
  end

  if primary and primary.opts then
    local ok, err = pcall(function()
      require(M.sname(primary)).setup(primary.opts)
    end)
    if not ok then
      notify(("theme.lua: %s.setup() failed: %s"):format(M.sname(primary), err), vim.log.levels.WARN)
    end
  end

  local ok, err = pcall(vim.cmd.colorscheme, resolved)
  if not ok then
    notify(("theme.lua: :colorscheme %s failed: %s"):format(resolved, err), vim.log.levels.ERROR)
  end
end

-- Re-entrancy guard: prevents overlapping apply cycles (the fs watcher can
-- fire while an async clone is still running).
local applying = false
-- Set when a switch arrives while `applying` is still true. Without this the
-- second switch was simply dropped: the poll only fires when the file mtime
-- changes, so switching twice inside one clone window left the first theme on
-- screen until the next host switch.
local pending = false

-- One apply cycle. Returns true when it started an async clone; the clone's
-- callback then owns the `applying` flag. Every other path is synchronous.
local function apply_now()
  local plugins, colorscheme, primary, transient = M.read_source()
  if transient then
    -- The spec is mid-write; the watcher's trailing apply will retry once the
    -- host has finished. Applying the fallback here would flash the wrong
    -- colorscheme on every switch.
    return false
  end
  merge_into_state(plugins)

  if not primary then
    -- No plugin to install; just apply the colorscheme name directly.
    finish_apply(nil, nil, colorscheme)
    return false
  end

  local name = M.sname(primary)
  local dir = LAZY_ROOT .. "/" .. name

  if vim.fn.isdirectory(dir) == 1 then
    -- Already installed; apply immediately.
    finish_apply(primary, dir, colorscheme)
    return false
  end

  -- Clone the plugin repo asynchronously.
  notify(("theme.lua: installing %s..."):format(name))
  vim.system({ "git", "clone", "--depth", "1", "https://github.com/" .. primary[1] .. ".git", dir }, {}, function(obj)
    vim.schedule(function()
      -- The flag has to be released on every path, including a failing clone or
      -- a theme module that throws while being applied -- otherwise every later
      -- switch silently turns into a no-op until restart.
      local ok, err = pcall(function()
        if obj.code ~= 0 and vim.fn.isdirectory(dir) == 0 then
          notify(
            ("theme.lua: git clone failed for %s: %s"):format(primary[1], obj.stderr or "unknown error"),
            vim.log.levels.ERROR
          )
          return
        end
        if primary.build then
          notify(
            ("theme.lua: %s declares a build step (%s); running it best-effort, may need :Lazy build after restart if it's not a plain shell command"):format(
              name,
              tostring(primary.build)
            ),
            vim.log.levels.WARN
          )
          if type(primary.build) == "string" and not primary.build:match("^:") then
            vim.system({ "sh", "-c", primary.build }, { cwd = dir })
          end
        end
        finish_apply(primary, dir, colorscheme)
      end)
      applying = false
      if not ok then
        notify(("theme.lua: applying %s failed: %s"):format(name, tostring(err)), vim.log.levels.ERROR)
      end
      if pending then
        pending = false
        M.apply()
      end
    end)
  end)
  return true
end

-- M.apply: the main entry point for live theme switching.
-- Reads the source, clones the plugin if not already installed (async via
-- vim.system), then applies the colorscheme.
function M.apply()
  if applying then
    -- Remember it instead of ignoring it: see `pending` above.
    pending = true
    return
  end
  applying = true

  local ok, async = pcall(apply_now)
  if not ok then
    -- A malformed neovim.lua or a theme that throws must not wedge the
    -- switcher into ignoring every future theme change.
    applying = false
    notify(("theme.lua: apply failed: %s"):format(tostring(async)), vim.log.levels.ERROR)
  elseif not async then
    applying = false
  end
  if not applying and pending then
    pending = false
    -- Schedule so a pathological burst of switches cannot recurse.
    vim.schedule(function()
      M.apply()
    end)
  end
end

--==============================================================================
-- File-system watcher -- detect theme switches live
--==============================================================================

-- Set once so repeated UIEnter events (one per attached UI) can't stack
-- watchers: each extra watcher would double every timer and re-apply twice.
local watching = false

function M.watch()
  if watching then
    return
  end
  watching = true

  local apply_at = 0      -- hrtime (ms) of the last apply we kicked off
  local INSTANT_MS = 250  -- apply straight away if nothing was applied recently
  local TRAILING_MS = 100 -- otherwise collapse the rest of the burst into one
  local trailing

  local function run()
    apply_at = uv.hrtime() / 1e6
    M.invalidate_cache()
    M.apply()
  end

  local function trigger()
    local now = uv.hrtime() / 1e6
    if now - apply_at > INSTANT_MS then
      -- Leading edge: a real switch applies on the next main-loop tick instead
      -- of waiting for a debounce window to expire (measured cost of an apply
      -- is ~3ms, so reacting immediately is cheap).
      apply_at = now
      vim.schedule(run)
      return
    end
    -- Burst: the host rewrites the spec and flips links while switching. One
    -- trailing apply after the burst guarantees the final state is the one
    -- that lands, without re-applying on every individual write.
    if trailing then
      trailing:stop()
      trailing:close()
    end
    trailing = uv.new_timer()
    trailing:start(
      TRAILING_MS,
      0,
      vim.schedule_wrap(function()
        if trailing then
          trailing:close()
          trailing = nil
        end
        run()
      end)
    )
  end

  -- Watch only what this module consumes. The previous version watched the
  -- whole ~/.local/state/vibranium tree recursively, so writing wallpaper.json,
  -- monitors, nightshift or any of the ~20 sibling theme files re-applied the
  -- colorscheme for nothing.
  local function watch_path(dir, matches)
    if vim.fn.isdirectory(dir) == 0 then
      return
    end
    local fs = uv.new_fs_event()
    if not fs then
      return
    end
    local ok, err = pcall(fs.start, fs, dir, {}, function(fs_err, filename)
      if fs_err then
        return
      end
      -- filename can be nil on some platforms; triggering then is the old
      -- behavior, i.e. the safe direction.
      if filename == nil or matches(filename) then
        trigger()
      end
    end)
    if not ok then
      notify("theme.lua: fs_event watch failed for " .. dir .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end

  -- Inside the theme directory only the spec file matters...
  watch_path(THEME_LINK, function(name)
    return name:match("neovim%.lua$") ~= nil
  end)
  -- ...and in the parent only the theme entry itself (an atomic symlink flip
  -- replaces it, which a watch on the entry alone would not survive).
  local theme_entry = vim.fn.fnamemodify(THEME_LINK, ":t")
  watch_path(vim.fn.fnamemodify(THEME_LINK, ":h"), function(name)
    return name == theme_entry
  end)

  -- Poll fallback for filesystems where fs_event is unreliable (WSL, Docker,
  -- network mounts). Timestamp is compared with nanosecond precision: the old
  -- seconds-only comparison missed a switch that happened in the same second
  -- as the previous check, and a missing file used to fire one spurious apply.
  local function stamp()
    local st = uv.fs_stat(SOURCE_FILE)
    return st and (st.mtime.sec * 1000000000 + st.mtime.nsec) or nil
  end

  local last_stamp = stamp()
  local poll = uv.new_timer()
  poll:start(
    2000, -- start after 2s
    2000, -- every 2s; each tick costs ~5us, and dropping this to 10s would
          -- trade that for a 10s worst-case switch latency
    vim.schedule_wrap(function()
      local now_stamp = stamp()
      if now_stamp and now_stamp ~= last_stamp then
        last_stamp = now_stamp
        trigger()
      end
    end)
  )
end

return M
