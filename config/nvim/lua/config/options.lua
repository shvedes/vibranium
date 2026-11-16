--==============================================================================
-- config/options.lua  -  Core Neovim editor options and globals
--
-- Every vim.opt and vim.g assignment in this config. Settings are grouped
-- by category for readability. This file is required early in init.lua
-- so that all plugins see the intended defaults on load.
--
-- Conventions used:
--   - opts commented out with `--` are intentionally disabled but kept as
--     documentation of alternatives the author considered.
--   - Leader keys are set before anything else since plugins read them at
--     require() time.
--==============================================================================

local opt = vim.opt
local g = vim.g

-- ===== LEADERS =====

-- Global leader key used by most plugin and user mappings.
-- Space is the modern convention, freeing the traditional \ for other uses.
g.mapleader = " "

-- Leader for filetype-local mappings. Also used as a fallback by some plugins.
g.maplocalleader = "\\"

-- ===== UI =====

-- Show absolute line numbers in the gutter.
opt.number = true

-- Show line numbers relative to the current cursor line (disabled, see above).
-- opt.relativenumber = true

-- Visually highlight the line the cursor is currently on.
opt.cursorline = true

-- Always reserve a column for signs (LSP diagnostics, Git signs, etc.).
-- "yes" avoids horizontal text shift when signs appear/disappear.
opt.signcolumn = "yes"

-- Enable 24-bit true colour. Required for modern terminal colour schemes.
opt.termguicolors = true

-- Enable soft line wrapping (text wraps at window edge).
opt.wrap = true

-- When wrapping, break only at word boundaries, not mid-word.
opt.linebreak = true

-- Minimum lines above/below the cursor (disabled; set dynamically in autocmds).
-- opt.scrolloff = 30

-- Minimum columns left/right of the cursor when side-scrolling.
-- Was 80: in a window narrower than ~160 columns that pins the cursor to the
-- middle of the screen the moment anything side-scrolls, and in the nowrap
-- windows that actually do (LSP hovers, help, quickfix) it made horizontal
-- scrolling nearly impossible. 8 keeps context without fighting the cursor.
opt.sidescrolloff = 8

-- New horizontal splits appear below the current window.
opt.splitbelow = true

-- New vertical splits appear to the right of the current window.
opt.splitright = true

-- Use a single global statusline instead of one per window.
-- Requires Neovim 0.7+. Combined with lualine for the actual content.
opt.laststatus = 3

-- Hide the command line when not in use (cleaner UI).
-- Requires Neovim 0.9+. The cmdheight is temporarily raised during command input.
opt.cmdheight = 0

-- Don't show -- INSERT -- (statusline already indicates mode).
-- opt.showmode = false

-- Maximum height of the pop-up menu (completion, etc.).
-- opt.pumheight = 10

-- Completion menu behaviour: show menu, show one item, don't auto-select.
opt.completeopt = { "menu", "menuone", "noselect" }

-- ===== INDENTATION =====

-- Expand tabs into spaces (soft tabs).
opt.expandtab = true

-- Number of spaces inserted/removed by indent commands (<<, >>).
opt.shiftwidth = 4

-- Visual width of a Tab character when it appears in the file.
opt.tabstop = 4

-- Number of spaces inserted by Tab in insert mode / removed by Backspace.
opt.softtabstop = 4

-- Enable smart auto-indentation (copies indent from previous line, plus
-- some language-specific heuristics).
opt.smartindent = true

-- Round indentation to multiples of shiftwidth in visual/normal mode.
opt.shiftround = true

-- Preserve indentation of wrapped lines (keeps visual indent consistent).
opt.breakindent = true

-- ===== SEARCH =====

-- Ignore case in search patterns by default.
opt.ignorecase = true

-- Override ignorecase if the pattern contains uppercase characters.
opt.smartcase = true

-- Show matches while typing the search pattern.
opt.incsearch = true

-- Highlight all matches of the search pattern.
opt.hlsearch = true

-- Live preview of the :substitute command (disabled; may be slow on large files).
-- opt.inccommand = "split"

-- ===== EDITING =====

-- Persist undo history across editing sessions (requires undo directory).
opt.undofile = true

-- Enable mouse support in all modes (n/v/i/c/t).
opt.mouse = "a"

-- Use the system clipboard for all yank/delete/put operations (no " register).
opt.clipboard = "unnamedplus"

-- Allow the cursor to be positioned where there is no actual character in
-- visual block mode. Essential for block-editing past end-of-line.
opt.virtualedit = "block"

-- Ask for confirmation before closing a modified buffer (instead of failing).
opt.confirm = true

-- updatetime in milliseconds. Lower values make CursorHold fire faster
-- (useful for LSP diagnostics, Git signs, etc.). Default is 4000ms.
opt.updatetime = 100

-- Timeout for mapped key sequences (milliseconds). Lower feels snappier.
opt.timeoutlen = 300

-- Automatically read a file when it is changed outside of Neovim.
opt.autoread = true

-- ===== FILES =====

-- Disable swap files (modern Neovim is stable enough; undofile covers recovery).
opt.swapfile = false

-- Backup files (disabled; undofile serves a similar purpose).
-- opt.backup = false
-- opt.writebackup = false

-- Allow switching away from a modified buffer without writing (historical).
-- opt.hidden = true

-- ===== FOLDING =====

-- Start with all folds open (no collapsed code on startup).
opt.foldlevel = 99
opt.foldlevelstart = 99

-- Enable folding based on 'foldmethod' (defaults to 'manual' or 'indent').
opt.foldenable = true

-- ===== WHITESPACE =====

-- Show whitespace characters (tabs, trailing spaces, non-breakable spaces).
opt.list = true

-- Visual characters for whitespace display.
--   tab  = "> "  shows tabs as > followed by space
--   trail = "."  shows trailing spaces as dots
--   nbsp = "?"   shows non-breaking spaces as ?
opt.listchars = {
  tab = "> ",
  trail = ".",
  nbsp = "?",
}

-- Characters used in fold columns, status lines, etc.
-- Here: replace the ~ at end-of-buffer with a space (cleaner look).
opt.fillchars = {
  eob = " ",
}

-- ===== PERFORMANCE =====

-- Don't redraw during macro playback (disabled; modern terminals handle it).
-- opt.lazyredraw = true

-- Stop syntax highlighting past column N (disabled; files are small enough).
-- opt.synmaxcol = 300

-- ===== QUALITY OF LIFE =====

-- Shorter completion messages (disabled; defaults are fine).
-- opt.shortmess:append("c")

-- Skip the intro/message screen (disabled; not needed with dashboard).
-- opt.shortmess:append("I")

-- Keep the viewport stable when jumping to tags/locations (disabled).
-- opt.jumpoptions = "view"

-- Don't persist editor options in session files (disabled).
-- opt.sessionoptions:remove("options")

-- Better diff alignment across hunks (requires Neovim 0.9+).
-- linematch:60 limits the cost of the alignment algorithm.
opt.diffopt:append("linematch:60")

-- ===== MODERN FEATURES (Neovim 0.11+) =====

-- Border style around floating windows. "single" is a thin line.
opt.winborder = "single"

-- Tabline visibility (disabled; lualine's tabline handles this).
-- opt.showtabline = 0

-- Opacity (0-100) for floating windows. Lower = more transparent background.
opt.winblend = 30

-- Opacity for the completion pop-up menu. 0 = fully opaque.
opt.pumblend = 0

-- Preserve the visible screen content when splitting windows.
opt.splitkeep = "screen"

-- Suppress "written" and file info messages (e.g. "282L, 7005B") after :w.
vim.opt.shortmess:append({
  W = true,  -- "written"
  F = true,  -- file info
})

-- ===== GLOBALS =====

-- Disable netrw (the built-in file explorer) since a plugin like
-- neo-tree or oil.nvim replaces it. Must be set BEFORE lazy loads plugins.
g.loaded_netrw = 1
g.loaded_netrwPlugin = 1

-- Disable provider modules to speed up startup.
-- These are used for :python3, :ruby, :node, :perl integration.
-- Only uncomment if you actually use the respective language runtime.
g.loaded_perl_provider = 0
g.loaded_ruby_provider = 0
g.loaded_node_provider = 0
g.loaded_python3_provider = 0

-- ===== DIAGNOSTICS / LSP =====
-- Deliberately empty. Both settings used to live here and cost ~4.5ms of
-- startup: this file is required before lazy.nvim, so touching vim.lsp or
-- vim.diagnostic pulls their whole module trees in on every launch (vim.lsp
-- alone is ~2.7ms).
--
--   * Semantic tokens are already enabled by default by Neovim itself
--     (vim/lsp/semantic_tokens.lua ends with `M.enable(true)`), so the old
--     `vim.lsp.semantic_tokens.enable(true)` call only forced the requires.
--   * Diagnostic config is applied by lua/plugins/lspconfig.lua, which loads
--     on BufReadPre -- before any server can attach and publish diagnostics.
--     Keeping a copy here only preloaded vim.diagnostic for nothing.
