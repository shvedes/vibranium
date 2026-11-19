--==============================================================================
-- config/lazy.lua  -  lazy.nvim bootstrap and plugin setup
--
-- Responsibilities:
--   1. Clone lazy.nvim (if not already installed) into stdpath("data")/lazy/.
--   2. Add lazy.nvim to the runtimepath.
--   3. Call lazy.setup() with the plugin spec entry point (lua/plugins/).
--   4. Register a UIEnter autocmd that triggers the live theme watcher.
--
-- The plugin spec loader processes ALL files under lua/plugins/*.lua.
-- Each file returns either a single spec table or a list of spec tables.
-- lazy.nvim merges them and handles installation, loading, and dependencies.
--
-- The theme.lua plugin spec (loaded by lazy via lua/plugins/theme.lua)
-- is special: it reads the Vibranium host-theme neovim.lua at runtime and
-- returns the appropriate colorscheme spec for lazy to install.
-- The UIEnter autocmd then starts the fs watcher that detects host theme
-- switches and applies them live.
--==============================================================================

-- Path to the lazy.nvim plugin manager directory.
-- stdpath("data") resolves to ~/.local/share/nvim/ (or platform equivalent).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

-- Bootstrap: clone lazy.nvim if it is not already present on disk.
-- Uses a shallow clone (blob:none filter, stable branch) for speed.
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		-- Clone failed: display error and exit so the user can fix connectivity.
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end

-- Add lazy.nvim to the runtimepath so its modules (lazy, lazy.view, etc.)
-- are available for immediate require().
vim.opt.rtp:prepend(lazypath)

-- Configure and start lazy.nvim.
-- The `spec` entry point tells lazy to import all specs from lua/plugins/.
require("lazy").setup({
	-- Import all plugin specs from lua/plugins/*.lua as a single collection.
	spec = { { import = "plugins" } },

	-- Custom lockfile path: stored next to init.lua so it can be versioned.
	lockfile = vim.fn.stdpath("config") .. "/.lazy-lock.json",

	-- Auto-install missing plugins (true) and use habamax as the temporary
	-- colorscheme during the initial installation process (before the actual
	-- theme plugin is downloaded).
	install = { missing = true, colorscheme = { "habamax" } },

	-- UI border style and window title for the lazy.nvim dashboard.
	ui = { border = "single", title = "Manage Plugins" },

	-- Periodically check for plugin updates (notify = false means no pop-up;
	-- the check runs silently and the user can see pending updates via :Lazy).
	checker = { enabled = true, notify = false },

	-- Detect when the spec changes and show a notification (silent here).
	change_detection = { enabled = true, notify = false },

	-- Disable lazy.nvim's own require profiling (no overhead).
	profiling = { loader = false, require = false },

	-- Disable the README viewer (not needed).
	readme = { enabled = false },

	-- Development mode (commented out): clones repos into a local_plugins
	-- directory for local editing.
	-- dev = {
	--   path = function()
	--     return vim.fn.stdpath("config") .. "/lua/local_plugins"
	--   end,
	-- },
})

-- After the first UI paint (UIEnter), start the live theme watcher.
-- This polls and fs-watches the Vibranium host-theme symlink at
-- ~/.local/state/vibranium/theme/neovim.lua so that when the host
-- theme changes, the Neovim colorscheme updates without a restart.
vim.api.nvim_create_autocmd("UIEnter", {
	callback = function()
		require("utils.theme").watch()
	end,
})
