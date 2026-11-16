--==============================================================================
-- plugins/snacks.lua  -  Snacks.nvim: dashboard + notifier + indent guides
--
-- Plugin: folke/snacks.nvim
--
-- A mega-plugin providing many optional mini-features. Only a few are enabled:
--   1. Dashboard: a visually appealing startup screen with quick-action keys.
--   2. Notifier: an in-editor notification system (replaces vim.notify).
--   3. Indent: vertical indent guides with scope-aware highlighting.
--
-- All other features (animate, bigfile, bufdelete, git, input,
-- picker, scroll, terminal, zen, etc.) are explicitly disabled to keep
-- startup fast and avoid overlap with dedicated plugins.
--
-- The explorer is the only file browser: netrw is disabled in options.lua and
-- no tree/oil plugin is installed, so without it `nvim .` and `:e <dir>`
-- opened an empty buffer with no listing. Snacks already loads at startup for
-- the dashboard, so enabling it costs only its (cheap) setup.
--
-- The dashboard uses a preset with keys:
--   f  Find file      n  New file     g  Find text (grep)
--   r  Recent files   c  Config       s  Restore session
--   m  Mason          l  Lazy         q  Quit
-- Its header is the ASCII banner defined at the top of this file.
--==============================================================================

--==============================================================================
-- Banner
--
-- The dashboard header art lives here rather than in a banner.txt in the config
-- root (that file only rendered while it happened to exist). Every line is
-- padded to the block's full width at load time: the `header` section centres
-- each line on its own, so unequal line widths would knock the art out of
-- alignment. The padding is computed instead of stored as trailing spaces
-- because the save-time whitespace trim in config/autocmds.lua strips trailing
-- whitespace from every line of this file.
--==============================================================================

local banner = {
  " ███▄    █ ▓█████  ▒█████   ██▒   █▓ ██▓ ███▄ ▄███▓",
  " ██ ▀█   █ ▓█   ▀ ▒██▒  ██▒▓██░   █▒▓██▒▓██▒▀█▀ ██▒",
  "▓██  ▀█ ██▒▒███   ▒██░  ██▒ ▓██  █▒░▒██▒▓██    ▓██░",
  "▓██▒  ▐▌██▒▒▓█  ▄ ▒██   ██░  ▒██ █░░░██░▒██    ▒██",
  "▒██░   ▓██░░▒████▒░ ████▓▒░   ▒▀█░  ░██░▒██▒   ░██▒",
  "░ ▒░   ▒ ▒ ░░ ▒░ ░░ ▒░▒░▒░    ░ ▐░  ░▓  ░ ▒░   ░  ░",
  "░ ░░   ░ ▒░ ░ ░  ░  ░ ▒ ▒░    ░ ░░   ▒ ░░  ░      ░",
  "   ░   ░ ░    ░   ░ ░ ░ ▒       ░░   ▒ ░░      ░",
  "         ░    ░  ░    ░ ░        ░   ░         ░",
  "                                ░",
}

local banner_width = 0
for _, line in ipairs(banner) do
  banner_width = math.max(banner_width, vim.api.nvim_strwidth(line))
end
for i, line in ipairs(banner) do
  banner[i] = line .. string.rep(" ", banner_width - vim.api.nvim_strwidth(line))
end

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    -- Disabled features (the majority)
    animate      = { enabled = false },
    bigfile      = { enabled = true },
    bufdelete    = { enabled = false },
    debug        = { enabled = false },
    dim          = { enabled = false },
    explorer     = { enabled = true },
    gh           = { enabled = false },
    git          = { enabled = false },
    gitbrowse    = { enabled = false },
    image        = { enabled = false },
    input        = { enabled = false },
    keymap       = { enabled = false },
    layout       = { enabled = false },
    lazygit      = { enabled = false },
    picker       = { enabled = true },
    profiler     = { enabled = false },
    quickfile    = { enabled = false },
    rename       = { enabled = false },
    scope        = { enabled = false },
    scratch      = { enabled = false },
    scroll       = { enabled = false },
    statuscolumn = { enabled = false },
    terminal     = { enabled = false },
    toggle       = { enabled = false },
    words        = { enabled = false },
    zen          = { enabled = false },

    -- Dashboard: startup screen with quick-action keys.
    dashboard = {
      enabled = true,
      sections = {
        { section = "header" },
        { section = "keys", gap = 1, padding = 1 },
        { section = "startup", icon = "" },
      },
      preset = {
        header = table.concat(banner, "\n"),
        keys = {
          { icon = "", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
          { icon = "", key = "n", desc = "New File", action = ":ene | startinsert" },
          { icon = "", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('live_grep')" },
          { icon = "", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
          { icon = "", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
          -- Explicit load (not section = "session"): the section variant
          -- silently does nothing when no session file exists. This notifies
          -- instead, so `s` never feels dead. Persistence itself is eager
          -- (see plugins/persistence.lua) so require() works from the dashboard.
          {
            icon = "",
            key = "s",
            desc = "Restore Session",
            action = function()
              -- load() returns nothing either way (nil on success too),
              -- so check readability first instead of trusting its return.
              local p = require("persistence")
              local file = p.current()
              if vim.fn.filereadable(file) == 0 then
                file = p.current({ branch = false })
              end
              if vim.fn.filereadable(file) == 0 then
                vim.notify("No session to restore", vim.log.levels.WARN)
                return
              end
              p.load()
            end,
          },
          -- Mason has its own spec with `cmd` stubs (lua/plugins/mason.lua), so
          -- the command exists here even though no file is open yet.
          { icon = "", key = "m", desc = "Mason", action = ":Mason" },
          { icon = "", key = "l", desc = "Lazy", action = ":Lazy", enabled = package.loaded.lazy ~= nil },
          { icon = "", key = "q", desc = "Quit", action = ":qa" },
        },
      },
    },

    -- Notifier: replaces the default vim.notify with a snack-style popup.
    notifier = {
      enabled = true,
      timeout = 5000,
      icons = {
        error = "Error: ",
        warn = "Warning: ",
        info = "Info: ",
        debug = "Debug: ",
        trace = "Trace: ",
      },
    },

    -- Indent guides: scope-aware vertical lines for indentation depth.
    indent = {
      enabled = true,
      only_scope = true,  -- Only show guides for the current scope.
    },

    -- Border style for notification popups.
    styles = {
      notification = { border = "single" },
      notification_history = { border = "single" },
    },
  },
}
