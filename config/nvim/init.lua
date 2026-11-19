--==============================================================================
-- init.lua  -  Neovim entry point
--
-- Execution order on startup:
--   0. Enables vim.loader (bytecode cache) before any require() happens.
--   1. This file is the first Lua file Neovim runs (~/.config/nvim/init.lua).
--   2. Loads config files sequentially (order matters for some settings).
--   3. Loads all autocommands from the single file lua/config/autocmds.lua
--      (which also registers the template system).
--
-- Rationale:
--   - `commands` first: command aliases like `:W` -> `:w` should exist
--     before any plugin or mapping references them.
--   - `transparent` early: sets up highlight groups and autocommands; needs
--     to be ready before any colorscheme triggers.
--   - `options` mid: standard vim.opt settings that plugins may depend on.
--   - `lazy` last: lazy.nvim bootstrap and plugin loading; everything above
--     must be available before lazy processes plugin specs.
--   - `autocmds` last: requires lua/config/autocmds.lua which holds every
--     autocommand, including the template auto-loader for lua/templates/.
--==============================================================================

-- Enable the Lua bytecode loader before anything else is required.
-- Every `require()` (this config, lazy.nvim, and every plugin) otherwise
-- re-compiles the source on each launch; the loader caches the bytecode under
-- stdpath("cache")/luac. Measured: ~13% faster startup (22.6ms -> 19.7ms).
vim.loader.enable()

-- Command aliases: :W -> :w, :Q -> :q, etc. (user commands + abbreviations).
-- Loaded first so they are available immediately at the : command line.
require("config.commands")

-- Transparency module (a utility): sets up highlight clearing, autocommands,
-- and user commands (:TransparentToggle etc.). Must precede options/theme
-- so it can hook into ColorScheme events from the very start.
require("utils.transparent")

-- Editor options: leader keys, UI settings, indentation, search, editing
-- behavior and performance tweaks. Contains no LSP-specific settings on
-- purpose -- those would preload vim.lsp/vim.diagnostic on every start.
require("config.options")

-- Package manager bootstrap and plugin loading via lazy.nvim.
-- This call blocks until lazy is set up, then processes all plugin specs
-- under lua/plugins/. The theme.lua plugin spec (handled inside lazy) drives
-- the live colorscheme install/apply logic.
require("config.lazy")

-- All autocommands live in a single file: lua/config/autocmds.lua.
-- Each section is self-contained (own augroup, no cross-dependencies).
-- The last section auto-loads the template system from lua/templates/.
require("config.autocmds")

-- All global keymaps live in lua/config/keymaps.lua (nothing buffer-local,
-- nothing split across plugin specs). Loaded last so leader (options.lua)
-- and lazy.nvim are ready; callbacks require plugins lazily on keypress.
require("config.keymaps")
