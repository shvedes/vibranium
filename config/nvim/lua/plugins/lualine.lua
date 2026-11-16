--==============================================================================
-- plugins/lualine.lua  -  Custom statusline and tabline via lualine.nvim
--
-- Plugin: nvim-lualine/lualine.nvim
--
-- This is the most heavily customised plugin spec. It defines:
--   1. A suite of helper functions for dynamic component rendering (mode
--      mapping, colour lookup, Aerial integration, LSP client names, file
--      size, filetype colour).
--   2. A multi-section tabline (tabs, filename, user@host, time).
--   3. A multi-section statusline (mode, branch, diff, Aerial symbol,
--      LSP clients, file size, filetype, diagnostics, progress).
--   4. Inactive sections are empty (no statusline clutter in unfocused windows).
--==============================================================================

-- Maps vim.fn.mode() return values to single-letter mode labels.
-- Covers every known mode string from Neovim's source.
-- Unknown modes fall through to "?" (the caller provides the fallback).
local mode_map = {
	["n"] = "N",
	["no"] = "N",
	["nov"] = "N",
	["noV"] = "N",
	["niI"] = "N",
	["niR"] = "N",
	["niV"] = "N",
	["nt"] = "N",
	["ntT"] = "N",
	["\22"] = "N",
	["i"] = "I",
	["ic"] = "I",
	["ix"] = "I",
	["R"] = "R",
	["Rc"] = "R",
	["Rx"] = "R",
	["Rv"] = "R",
	["Rvc"] = "R",
	["Rvx"] = "R",
	["c"] = "C",
	["cv"] = "C",
	["ce"] = "C",
	["s"] = "S",
	["S"] = "S",
	["\19"] = "S",
	["t"] = "T",
	["v"] = "V",
	["V"] = "V",
}

-- Cache for nvim_get_hl() results. Highlight groups only change on
-- :colorscheme, but color_from_hl()/color_from_section_hl() closures below
-- were re-querying them on every single statusline redraw (every cursor
-- move, mode change, etc). Cache and only invalidate on ColorScheme.
local hl_cache = {}
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("lualine_hl_cache", { clear = true }),
	callback = function()
		hl_cache = {}
	end,
})

-- `false` is the "looked up, no such group" sentinel so we don't repeat a
-- failed nvim_get_hl() call every redraw either.
local function cached_hl(name)
	local v = hl_cache[name]
	if v == nil then
		v = vim.api.nvim_get_hl(0, { name = name }) or false
		hl_cache[name] = v
	end
	return v or nil
end

-- Convert a 24-bit colour integer (from nvim_get_hl) into a hex colour string.
-- @param color_int (number|nil): the colour integer (e.g. 0xRRGGBB).
-- @return (string|nil): hex string like "#ff8800", or nil if input was nil.
local function hex(color_int)
	if not color_int then
		return nil
	end
	return ("#%06x"):format(color_int)
end

-- Look up the foreground colour of a highlight group as a hex string.
-- @param name (string): highlight group name (e.g. "Function").
-- @return (string|nil): hex colour string, or nil if the group has no fg.
local function hl_fg(name)
	local hl = cached_hl(name)
	return hl and hex(hl.fg) or nil
end

-- Get the background colour from the statusline area, falling back through
-- multiple groups for compatibility with transparent/opaque setups.
-- This is the colour used as the background for all lualine sections so they
-- appear seamless with the statusline.
-- @return (string|nil): hex colour string, or nil if none found.
local function get_statusline_bg()
	for _, name in ipairs({ "StatusLine", "StatusLineNC", "TabLine", "Normal" }) do
		local hl = cached_hl(name)
		if hl and hl.bg then
			return hex(hl.bg)
		end
	end
	return nil
end

-- Get the background colour lualine assigns to section b (branch, diff).
-- Lualine creates highlight groups at runtime named lualine_<section>_<mode>.
-- We query the normal-mode active-window group so diagnostics / tabline
-- sections can use the exact same bg as the branch component.
-- @return (string|nil): hex colour string, or nil if not found.
local function get_section_bg()
	local hl = cached_hl("lualine_b_normal")
	return hl and hex(hl.bg) or get_statusline_bg()
end

-- Create a dynamic colour function for a component based on an existing
-- highlight group's foreground colour, combined with the statusline background.
-- This makes all components adapt to any colourscheme automatically.
-- @param name (string): highlight group name for the foreground colour.
-- @param is_italic (boolean|nil): if true, add gui = "italic".
-- @return (function): returns { fg = ..., bg = ... } each time it is called.
local function color_from_hl(name, is_italic)
	return function()
		local color = { fg = hl_fg(name), bg = get_statusline_bg() }
		if is_italic then
			color.gui = "italic"
		end
		return color
	end
end

-- Like color_from_hl, but uses the section background (StatusLineNC) instead of
-- the main statusline background.  Use this for components that should visually
-- pop as a separate group (diagnostics, tabline sections, user@host).
-- @param name (string): highlight group name for the foreground colour.
-- @param is_italic (boolean|nil): if true, add gui = "italic".
-- @return (function): returns { fg = ..., bg = ... } each time it is called.
local function color_from_section_hl(name, is_italic)
	return function()
		local color = { fg = hl_fg(name), bg = get_section_bg() or get_statusline_bg() }
		if is_italic then
			color.gui = "italic"
		end
		return color
	end
end

-- Generic per-buffer memoization. `compute(bufnr)` runs once and the result
-- is reused until something calls .invalidate() for that buffer (or all
-- buffers, if called with no argument). Used below so component pairs
-- (label + value) read one cached value instead of recomputing twice per
-- redraw, and so the underlying work only reruns when the source data can
-- actually have changed, not on every statusline refresh.
local function make_buffer_cache(compute)
	local cache = {}
	return {
		get = function(bufnr)
			bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
			local entry = cache[bufnr]
			if entry == nil then
				entry = { value = compute(bufnr) }
				cache[bufnr] = entry
			end
			return entry.value
		end,
		invalidate = function(bufnr)
			if bufnr then
				cache[bufnr] = nil
			else
				cache = {}
			end
		end,
	}
end

-- Get the last (innermost) symbol from the Aerial outline for the current buffer.
-- Returns nil if Aerial is not loaded or the buffer has no symbols.
-- Cached per buffer and invalidated on cursor movement, since that's the
-- only thing that changes which symbol is "current" -- avoids querying
-- Aerial twice per redraw (once for kind, once for name) and on redraws
-- that aren't triggered by movement at all (e.g. DiagnosticChanged).
local aerial_cache = make_buffer_cache(function(_)
	local ok, aerial = pcall(require, "aerial")
	if not ok then
		return nil
	end
	local symbols = aerial.get_location(true)
	if not symbols or #symbols == 0 then
		return nil
	end
	return symbols[#symbols]
end)

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
	group = vim.api.nvim_create_augroup("lualine_aerial_cache", { clear = true }),
	callback = function(ev)
		aerial_cache.invalidate(ev.buf)
	end,
})

local function aerial_last_symbol()
	return aerial_cache.get()
end

-- Get the list of active LSP client names attached to the current buffer.
-- Returns nil if no clients are attached. Cached per buffer since clients
-- only change on attach/detach, not on every redraw -- was previously
-- being recomputed twice per redraw (once for the "lsp=" label, once for
-- the value).
local lsp_names_cache = make_buffer_cache(function(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if #clients == 0 then
		return nil
	end
	local names = {}
	for _, client in ipairs(clients) do
		table.insert(names, client.name)
	end
	return names
end)

vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
	group = vim.api.nvim_create_augroup("lualine_lsp_cache", { clear = true }),
	callback = function(ev)
		lsp_names_cache.invalidate(ev.buf)
	end,
})

local function lsp_client_names()
	return lsp_names_cache.get()
end

-- Suffixes for human-readable file size display.
local size_suffixes = { "b", "k", "m", "g" }
-- Highlight groups for file size at each threshold (small -> large).
local size_highlights = { "Comment", "DiagnosticOk", "DiagnosticWarn", "DiagnosticError" }

-- Compute file size info (human-readable text + highlight group). The file
-- on disk only changes on save, but this was previously calling
-- vim.fn.getfsize() -- a stat() syscall -- 3 times per redraw (label,
-- value, and value's color function). Cache per buffer instead.
local file_size_cache = make_buffer_cache(function(bufnr)
	local file = vim.api.nvim_buf_get_name(bufnr)
	if file == "" then
		return nil
	end
	local size = vim.fn.getfsize(file)
	if size <= 0 then
		return nil
	end

	-- Convert bytes to the appropriate unit (b/k/m/g).
	local i = 1
	while size > 1024 and i < #size_suffixes do
		size = size / 1024
		i = i + 1
	end

	local text = string.format(i == 1 and "%d%s" or "%.1f%s", size, size_suffixes[i])
	local hl = size_highlights[i] or "DiagnosticError"
	return { text = text, hl = hl }
end)

vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "BufEnter" }, {
	group = vim.api.nvim_create_augroup("lualine_filesize_cache", { clear = true }),
	callback = function(ev)
		file_size_cache.invalidate(ev.buf)
	end,
})

local function file_size_info()
	local info = file_size_cache.get()
	return info and info.text, info and info.hl
end

-- Suffixes used to find the filetype-specific highlight group for colouring.
local ft_suffixes = { "Function", "Keyword", "Statement", "Identifier", "Type" }

-- Pick a matching highlight group colour for the current buffer's filetype.
-- Many colourschemes define groups like "luaFunction", "pythonKeyword", etc.
-- @return (string|nil): hex colour string, or nil.
local function ft_color()
	local ft = vim.bo.filetype
	if ft == "" then
		return nil
	end
	for _, suffix in ipairs(ft_suffixes) do
		local fg = hl_fg(ft .. suffix)
		if fg then
			return fg
		end
	end
	return hl_fg("Function")
end

-- Diagnostic severity levels and their display configuration.
local diagnostic_labels = {
	{ letter = "E", hl = "DiagnosticError", severity = vim.diagnostic.severity.ERROR },
	{ letter = "W", hl = "DiagnosticWarn", severity = vim.diagnostic.severity.WARN },
	{ letter = "I", hl = "DiagnosticInfo", severity = vim.diagnostic.severity.INFO },
	{ letter = "H", hl = "DiagnosticHint", severity = vim.diagnostic.severity.HINT },
}

-- vim.diagnostic.count(bufnr) already returns counts for every severity in
-- one call, but the 4 count-label components below were each calling it
-- separately -- 4 full recounts of the buffer's diagnostics per redraw.
-- Cache the whole table once per buffer, invalidated only when diagnostics
-- actually change.
local diag_count_cache = make_buffer_cache(function(bufnr)
	return vim.diagnostic.count(bufnr)
end)

vim.api.nvim_create_autocmd("DiagnosticChanged", {
	group = vim.api.nvim_create_augroup("lualine_diag_cache", { clear = true }),
	callback = function(ev)
		diag_count_cache.invalidate(ev.buf)
	end,
})

-- Build the diagnostic components for lualine_y section.
-- Shows a letter (E/W/I/H) with the count in parentheses for each severity.
-- @return (table): lualine component list for the diagnostics section.
local function diagnostic_components()
	local components = {}
	for _, d in ipairs(diagnostic_labels) do
		table.insert(components, {
			function()
				return d.letter
			end,
			color = color_from_section_hl(d.hl),
			padding = #components == 0 and { left = 1, right = 0 } or { left = 0, right = 0 },
		})
		table.insert(components, {
			function()
				return "(" .. (diag_count_cache.get()[d.severity] or 0) .. ")"
			end,
			color = color_from_section_hl("Comment"),
			padding = { left = 0, right = 1 },
		})
	end
	return components
end

--==============================================================================
-- Plugin spec
--==============================================================================

return {
	"nvim-lualine/lualine.nvim",
	-- Load on these events so the statusline shows up as soon as a buffer opens.
	event = { "BufReadPost", "BufNewFile", "InsertEnter" },
	opts = {
		options = {
			-- No icons (text-only UI, faster and less noisy).
			icons_enabled = false,
			-- No fancy Unicode separators between sections.
			component_separators = { left = "", right = "" },
			section_separators = { left = "", right = "" },
			-- Disable statusline/winbar/tabline in the Snacks dashboard.
			disabled_filetypes = {
				statusline = { "snacks_dashboard" },
				winbar = { "snacks_dashboard" },
				tabline = { "snacks_dashboard" },
			},
			-- Always show the tabline, even with a single tab.
			always_show_tabline = true,
		},

		--==========================================================================
		-- TABLINE
		--==========================================================================
		tabline = {
			-- Left: total number of tabs.
			lualine_a = {
				{
					function()
						return tostring(vim.fn.tabpagenr("$"))
					end,
					padding = { left = 1, right = 1 },
				},
			},
			-- Center: list of all tab pages with filenames and indicators.
			lualine_b = {
				{
					function()
						local tabs = vim.api.nvim_list_tabpages()
						local current_tab = vim.api.nvim_get_current_tabpage()
						local parts = {}
						for _, tab in ipairs(tabs) do
							local is_active = tab == current_tab
							local win = vim.api.nvim_tabpage_get_win(tab)
							local bufnr = vim.api.nvim_win_get_buf(win)
							local name = vim.fn.bufname(bufnr)
							local ft = vim.bo[bufnr].filetype
							local filename = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
							-- Escape % signs for lualine format strings.
							filename = filename:gsub("%%", "%%%%")

							-- Show [+] for modified, [-] for readonly/unmodifiable.
							local indicators = ""
							if vim.bo[bufnr].modified then
								indicators = indicators .. "%#DiagnosticOk# [+]%*"
							end
							if vim.bo[bufnr].readonly or not vim.bo[bufnr].modifiable then
								indicators = indicators .. "%#DiagnosticError# [-]%*"
							end

							-- Highlight colour for the tab label: active tabs use a
							-- filetype-specific colour; inactive tabs use Comment.
							local tab_hl = "Comment"
							if is_active then
								local ft_hl_map = {
									python = "DiagnosticWarn",
									sh = "DiagnosticOk",
									bash = "DiagnosticOk",
									zsh = "DiagnosticOk",
									lua = "DiagnosticInfo",
								}
								tab_hl = ft_hl_map[ft] or "Normal"
							end
							table.insert(parts, "%#" .. tab_hl .. "#" .. filename .. "%*" .. indicators)
						end
						return table.concat(parts, " %#Comment#|%* ")
					end,
					color = color_from_section_hl("Normal"),
					padding = { left = 1, right = 1 },
				},
			},
			-- Right: user@host.
			lualine_y = {
				{
					function()
						return os.getenv("USER") or "user"
					end,
					color = color_from_section_hl("DiagnosticOk"),
					padding = { left = 1, right = 0 },
				},
				{
					function()
						return "@"
					end,
					color = color_from_section_hl("Normal"),
					padding = { left = 0, right = 0 },
				},
				{
					function()
						return vim.fn.hostname() or "host"
					end,
					color = color_from_section_hl("DiagnosticWarn"),
					padding = { left = 0, right = 1 },
				},
			},
			-- Far right: current time.
			lualine_z = {
				{
					function()
						return os.date("%I:%M %p")
					end,
					padding = { left = 1, right = 1 },
				},
			},
		},

		--==========================================================================
		-- STATUSLINE (active window)
		--==========================================================================
		sections = {
			-- Mode indicator (single letter).
			lualine_a = { {
				function()
					return mode_map[vim.fn.mode()] or "?"
				end,
			} },
			-- Git branch + diff stats.
			lualine_b = {
				{ "branch", padding = { left = 1, right = 1 } },
				{ "diff", symbols = { added = "+", modified = "~", removed = "-" }, padding = { left = 0, right = 1 } },
			},
			-- Aerial outline: current symbol kind + name.
			lualine_c = {
				{
					function()
						local last = aerial_last_symbol()
						return last and last.kind:sub(1, 1):lower() or ""
					end,
					color = color_from_hl("Include", true),
					padding = { left = 1, right = 0 },
				},
				{
					function()
						local last = aerial_last_symbol()
						return last and (":" .. last.name) or ""
					end,
					color = color_from_hl("Comment", true),
					padding = { left = 0, right = 1 },
				},
			},
			-- LSP clients, file size, filetype.
			lualine_x = {
				{
					function()
						return lsp_client_names() and "lsp=" or ""
					end,
					color = color_from_hl("Comment"),
					padding = { left = 0, right = 0 },
				},
				{
					function()
						local names = lsp_client_names()
						return names and table.concat(names, ",") or ""
					end,
					color = color_from_hl("DiagnosticInfo"),
					padding = { left = 0, right = 1 },
				},
				{
					function()
						return file_size_info() and "s=" or ""
					end,
					color = color_from_hl("Comment"),
					padding = { left = 0, right = 0 },
				},
				{
					function()
						return file_size_info() or ""
					end,
					color = function()
						local _, hl = file_size_info()
						return { fg = hl and hl_fg(hl) or nil, bg = get_statusline_bg() }
					end,
					padding = { left = 0, right = 1 },
				},
				{
					function()
						return vim.bo.filetype ~= "" and "ft=" or ""
					end,
					color = color_from_hl("Comment"),
					padding = { left = 0, right = 0 },
				},
				{
					function()
						return vim.bo.filetype
					end,
					color = function()
						return { fg = ft_color(), bg = get_statusline_bg() }
					end,
					padding = { left = 0, right = 1 },
				},
			},
			-- Diagnostics (E/W/I/H counts).
			lualine_y = diagnostic_components(),
			-- Progress (line/total percentage).
			lualine_z = {
				{
					"progress",
					fmt = function(s)
						return s:gsub("^%s+", "")
					end,
					padding = { left = 1, right = 1 },
				},
			},
		},
		-- Inactive windows: no statusline content at all (clean look).
		inactive_sections = {
			lualine_a = {},
			lualine_b = {},
			lualine_c = {},
			lualine_x = {},
			lualine_y = {},
			lualine_z = {},
		},
	},
}
