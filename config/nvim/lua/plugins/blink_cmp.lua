--==============================================================================
-- plugins/blink_cmp.lua  -  Completion engine (blink.cmp)
--
-- Plugin: saghen/blink.cmp
--
-- A Rust-native completion engine providing asynchronous autocompletion
-- from multiple sources (LSP, path, buffer, snippets). Replaces nvim-cmp.
--
-- Key features (VSCode-like):
--   - Ghost text inline preview + auto-show menu on typing / trigger chars.
--   - LSP + VSCode snippets (friendly-snippets via native vim.snippet).
--   - Signature help + auto-brackets on function accept + docs auto-show.
--   - Custom sort order: LSP/snippets first, path, buffer last.
--   - Kind column: filled [x] pills, VSCode semantics in theme colors.
--     No trailing space; highlight is BlinkCmpKindFilled_<Kind> (custom
--     groups, so transparency clearing never wipes them). Restyled here
--     rather than in the colorscheme so it survives theme switches.
--   - Completion/docs/signature/cmdline popups are borderless with an
--     opaque NormalFloat/Pmenu bg pinned in config() (BlinkCmpMenu,
--     BlinkCmpDoc, BlinkCmpSignatureHelp); menu Border groups carry a
--     FloatBorder fg so a future border style draws without a halo.
--   - Tab/S-Tab/Enter navigation with snippet support (binds kept).
--   - Cmdline and search (/, ?) share one behavior: same menu, keymap and
--     selection settings; only the source list differs (buffer for search).
--   - <A-j>/<A-k> for completion navigation (binds kept).
--   - Auto-hides the menu when typing non-keyword characters.
--   - Filters out Keyword-type items from LSP (reduces noise).
--   - LSP tuning: buffer fallback on empty results, 0-length trigger-
--     character completion, prefetch on insert, faster resolve/timeout.
--==============================================================================

-- Reopens the completion menu after accepting a path.
-- If the character before the cursor is "/" or "\", blink.show() re-triggers
-- to offer completions for the newly created path segment.
local function reopen_path()
	local col = vim.fn.col(".")
	if col > 1 then
		local char = vim.api.nvim_get_current_line():sub(col - 1, col - 1)
		if char == "/" or char == "\\" then
			require("blink.cmp").show()
		end
	end
end

return {
	"saghen/blink.cmp",
	-- Load only when completion can actually be used. BufReadPre/BufNewFile used
	-- to be here too, which meant the engine (native fuzzy library, sources,
	-- keymaps) was set up on every file open instead of on first insert --
	-- ~3.5ms paid by users who never enter insert mode.
	event = { "InsertEnter", "CmdlineEnter" },
	dependencies = {
		"saghen/blink.lib",
		-- VSCode snippet collection (console.log, for-loops, etc.). Blink's
			-- built-in snippets source (native vim.snippet) picks these up
			-- automatically; no extra setup() call needed.
		"rafamadriz/friendly-snippets",
	},
	build = function()
		-- Build the Rust native library if cargo is available.
		if vim.fn.executable("cargo") == 1 then
			pcall(function()
				require("blink.cmp").build():pwait()
			end)
		end
	end,
	opts = {
		--==========================================================================
		-- Sorting
		--==========================================================================
		fuzzy = {
			-- Force the Rust matcher; fall back silently instead of warning
			-- if a prebuilt binary isn't available for the platform.
			implementation = "prefer_rust",
			-- Boost items used recently/frequently across sessions.
			frecency = { enabled = true },
			-- Boost items matching nearby words in the buffer.
			use_proximity = true,
			sorts = {
				"exact",
				function(a, b)
					-- Matches the order documented at the top of this file:
					-- snippets/LSP first, path below them, buffer words last.
					local p = { snippets = 1, lsp = 1, path = 2, buffer = 3 }
					local pa = p[a.source_id] or 99
					local pb = p[b.source_id] or 99
					if pa ~= pb then
						return pa < pb
					end
				end,
				"score",
				"sort_text",
			},
		},

		--==========================================================================
		-- Cmdline completion
		--==========================================================================
		cmdline = {
			keymap = {
				preset = "inherit",
				["<Up>"] = { "select_prev", "fallback" },
				["<Down>"] = { "select_next", "fallback" },
				-- Inheriting the insert-mode <CR> here would only fill in the
				-- selected text (cmp.accept() doesn't submit a cmdline), so
				-- picking a command/search suggestion needed <CR> twice: once
				-- to accept, once to actually run it. Accept and submit in one
				-- press instead.
				["<CR>"] = {
					function(cmp)
						-- Only accept if an item was explicitly selected (via Tab
						-- or the arrow keys below). Never auto-accept the top
						-- match just because the menu happens to be open —
						-- otherwise e.g. the "/" inside ":s/pattern/repl/" pops
						-- up buffer-word completion, and a plain <CR> to submit
						-- the substitute command silently replaces the pattern
						-- with whatever unrelated word was on top of that list.
						if not cmp.is_visible() or not cmp.get_selected_item() then
							return false
						end
						cmp.accept()
						-- accept() only edits the cmdline text; schedule a real
						-- <CR> right after so the command/search actually runs.
						vim.schedule(function()
							local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
							vim.api.nvim_feedkeys(cr, "n", false)
						end)
						return true
					end,
					"fallback",
				},
			},
			-- A single static source list is wrong here: the "cmdline" source
			-- disables itself outside "/"/"?", so search ("/","?") was falling
			-- through to "path" only and showing nothing for ordinary text
			-- searches. Branch on cmdtype instead so search gets buffer-word
			-- completion while everything else (menu, keymap, selection
			-- behavior below) stays identical between ":" and "/".
			sources = {
				default = function()
					local t = vim.fn.getcmdtype()
					if t == "/" or t == "?" then
						return { "buffer" }
					end
					return { "cmdline", "path" }
				end,
			},
			completion = {
				-- Open the menu as soon as items are available, not just in the
				-- command-line window (q:). Default is cmdwin only.
				menu = { auto_show = true, border = "none" },
				list = {
					-- preselect off: with it on, the first select_next() call only
					-- advances past the pre-highlighted item instead of inserting it,
					-- so Tab always lands one item ahead of what's highlighted.
					selection = { preselect = false, auto_insert = true },
				},
			},
		},
		--==========================================================================
		-- Completion menu configuration
		--==========================================================================
		-- Snippets: native vim.snippet engine (Neovim 0.10+). Tab / S-Tab
			-- below jump between tabstops; friendly-snippets above supplies
			-- the VSCode snippet collection.
		snippets = { preset = "default" },

		-- VSCode-like signature help while typing function arguments.		signature = { enabled = true, window = { border = "none" } },

		completion = {
			-- VSCode-like docs beside the menu. auto_show with a short
				-- delay so it doesn't flash on every keystroke.
			documentation = {
				window = { border = "none" },
				auto_show = true,
				auto_show_delay_ms = 250,
			},
			menu = {
				border = "none",
				draw = {
					components = {
						kind_icon = {
							ellipsis = false,
							text = function(ctx)
								-- Map LSP CompletionItemKind names to short text labels.
								local map = {
									Snippet = "[s]",
									Function = "[f]",
									Method = "[f]",
									Constructor = "[f]",
									Variable = "[v]",
									Field = "[v]",
									Property = "[v]",
									Class = "[c]",
									Struct = "[c]",
									Interface = "[c]",
									Module = "[m]",
									Namespace = "[m]",
									Keyword = "[k]",
									File = "[p]",
									Folder = "[p]",
									Text = "[t]",
									Enum = "[e]",
									Constant = "[C]",
									Operator = "[o]",
									Reference = "[r]",
									Value = "[v]",
									TypeParameter = "[T]",
									Unit = "[u]",
								}
								local short = map[ctx.kind] or ("[" .. ctx.kind:sub(1, 1):lower() .. "]")
								return short
							end,						highlight = function(ctx)
								-- Filled pill: solid bg in the kind color, dark text on top.
								-- Custom groups are built in config() below
								-- (BlinkCmpKindFilled_<Kind>) so transparency
								-- clearing never wipes them. Fall back to the
								-- default kind highlight if the filled one is missing.
								local filled = "BlinkCmpKindFilled_" .. (ctx.kind or "")
								local ok = pcall(vim.api.nvim_get_hl, 0, { name = filled })
								if ok then
									local hl = vim.api.nvim_get_hl(0, { name = filled })
									if hl and (hl.bg or hl.background) then
										return { { group = filled, priority = 20000 } }
									end
								end
								return { { group = ctx.kind_hl, priority = 20000, reverse = true } }
							end,
						},
					},
				},
			},

			-- Cap rendering work: LSP servers on large projects can return
			-- hundreds of candidates, most of which are never scrolled to.
			list = {
				max_items = 60,
				-- VSCode-like: preselect the top match so Tab/<CR> accepts
				-- it immediately. Kept safe by the keymap below: <CR>
				-- only accepts when an item is selected, and Tab
				-- explicitly inserts the selection.
				selection = { preselect = true, auto_insert = true },
				cycle = { from_bottom = true, from_top = true },
			},
			accept = {
				-- Don't stall the accept on a slow LSP resolve request.
				resolve_timeout_ms = 80,
				create_undo_point = true,
				-- VSCode-like: func( -> func(|) with cursor inside.
				auto_brackets = { enabled = true },
			},
			trigger = {
				-- Warm the LSP request as soon as insert mode starts instead
				-- of waiting for the first keystroke.
				prefetch_on_insert = true,
				show_on_keyword = true,
				show_on_backspace = false,
				show_on_backspace_in_keyword = false,
				show_on_backspace_after_accept = false,
				show_on_backspace_after_insert_enter = false,
				show_on_insert = false,
				-- Trigger characters (`.`, `::`, `->`, ...) must open the menu here:
				-- the lsp provider below advertises a 0-keyword-length window for
				-- `trigger_character` contexts precisely so `obj.` lists members,
				-- and with this off that branch was unreachable (nothing else can
				-- start a trigger_character context). Keep the watchdog below in
				-- sync: it must NOT cancel on `.`/`_`/`-` or the menu closes the
				-- instant it opens.
				show_on_trigger_character = true,
				show_on_accept_on_trigger_character = true,
				show_on_insert_on_trigger_character = false,
			},
			ghost_text = { enabled = true },
		},

		--==========================================================================
		-- Sources
		--==========================================================================
		sources = {
			-- VSCode shows suggestions after a single character.
				min_keyword_length = 1,
			default = { "lsp", "snippets", "path", "buffer" },
			providers = {
				lsp = {
					-- Filter out Keyword kind items (e.g. "if", "return", "for")
					-- from LSP completions. These are noisy and rarely what you want.
					transform_items = function(_, items)
						local Keyword = require("blink.cmp.types").CompletionItemKind.Keyword
						return vim.tbl_filter(function(i)
							return i.kind ~= Keyword
						end, items)
					end,
					-- 0 for trigger-character/manual invocations (e.g. right after
					-- "." or "::") so member completions show with no keyword
					-- typed yet; otherwise fall back to the global min length.
					min_keyword_length = function(ctx)
						if ctx.trigger.initial_kind == "trigger_character" or ctx.trigger.initial_kind == "manual" then
							return 0
						end
						-- Fall back to the global sources.min_keyword_length instead of
						-- repeating the number, so changing it once stays consistent.
						return require("blink.cmp.config").sources.min_keyword_length
					end,
					-- Don't let a slow/unresponsive LSP block the menu.
					timeout_ms = 1500,
					-- If the LSP returns nothing (e.g. outside any symbol scope),
					-- fall back to buffer words instead of showing an empty menu.
					fallbacks = { "buffer" },
				},
				path = { min_keyword_length = 0, score_offset = 5 },
			},
		},

		--==========================================================================
		-- Keymaps (preset = "none" for full customisation)
		--==========================================================================
		keymap = {
			preset = "none",
			["<Tab>"] = {
				function(cmp)
					-- Cmdline mode: Tab shows/selects next.
					if vim.fn.getcmdtype() ~= "" then
						if cmp.is_visible() then
							cmp.select_next()
						else
							cmp.show()
						end
						return true
					end
					-- Snippet navigation.
					if cmp.snippet_active() then
						return cmp.snippet_forward()
					end
					-- Completion visible: insert and move to next.
					if cmp.is_visible() then
						local accepted = cmp.insert_next()
						-- Tab-accepting a directory should offer the next path segment,
						-- same as <CR> does below.
						if accepted then
							vim.schedule(reopen_path)
						end
						return accepted
					end
					-- After a path separator, trigger completion.
					local col = vim.fn.col(".")
					local char = col > 1 and vim.api.nvim_get_current_line():sub(col - 1, col - 1) or ""
					if char == "/" or char == "\\" then
						cmp.show()
						return true
					end
					return false
				end,
				"fallback",
			},
			["<S-Tab>"] = {
				function(cmp)
					if cmp.snippet_active() then
						return cmp.snippet_backward()
					end
					if cmp.is_visible() then
						return cmp.insert_prev()
					end
					return false
				end,
				"fallback",
			},
			["<CR>"] = {
				function(cmp)
					-- Only accept when something was explicitly selected via
					-- Tab/<A-j>/<A-k>/arrows. An open-but-unselected menu means
					-- <CR> should just do whatever <CR> normally does
					-- (newline / fallback), not silently insert the top match.
					if not cmp.is_visible() or not cmp.get_selected_item() then
						return false
					end
					cmp.accept()
					-- After accepting, re-open if we're now inside a path.
					vim.schedule(reopen_path)
					return true
				end,
				"fallback",
			},
			-- preset = "none" means these have to be spelled out: without them
			-- there is no way to manually show the menu or dismiss it (and with
			-- auto_insert/preview text active, <C-e> is the documented escape).
			["<C-space>"] = { "show", "fallback" },
			["<C-e>"] = { "cancel", "fallback" },
			["<A-j>"] = { "select_next", "fallback" },
			["<A-k>"] = { "select_prev", "fallback" },
			["<Down>"] = { "select_next", "fallback" },
			["<Up>"] = { "select_prev", "fallback" },
		},
	},

	config = function(_, opts)
		require("blink.cmp").setup(opts)

		-- Build solid-bg pill highlights for the [x] kind column only.
		-- VSCode semantics, colorscheme colors: each LSP kind maps to a
		-- category (function/type/variable/...) and we steal the fg from
		-- that category's standard group (Function/Type/Identifier/...),
		-- so pills mean the same thing on every theme but still match it.
		-- Creates BlinkCmpKindFilled_<Kind> with bg=<category fg>,
		-- fg=dark, bold. Rebuilt on ColorScheme so theme switches keep
		-- the fill. Names are custom so utils/transparent.lua never clears them.
		local function kind_fg_hex(src)
				-- Blink's BlinkCmpKind* groups are usually links (e.g. to
				-- Function/Keyword). nvim_get_hl without link resolution only
				-- returns { link = ... }, so follow the chain via synIDtrans.
				local ok, hid = pcall(vim.fn.hlID, src)
				if not ok or hid == 0 then
					return nil
				end
				local trans = vim.fn.synIDtrans(hid)
				local fg = vim.fn.synIDattr(trans, "fg#")
				if fg and fg ~= "" and fg ~= "NONE" then
					return fg
				end
				return nil
			end

			local function build_filled_kind_hls()
			local dark = "#1a1b26"
			-- VSCode-style categories, each bound to a standard
				-- colorscheme group so the hue comes from the theme:
				-- functions -> Function (blue), types -> Type (yellow),
				-- variables -> Identifier, constants -> Constant,
				-- keywords/snippets -> Keyword (purple), strings -> String
				-- (green), numbers -> Number, paths -> Directory, etc.
				local vscode_src = {
					Snippet = "Keyword", Function = "Function", Method = "Function",
					Constructor = "Function", Variable = "Identifier", Field = "Identifier",
					Property = "Identifier", Value = "Identifier", Key = "Identifier",
					Class = "Type", Struct = "Type", Interface = "Type",
					Enum = "Type", TypeParameter = "Type", Array = "Type",
					Object = "Type", Module = "Include", Namespace = "Include",
					Package = "Include", Keyword = "Keyword", File = "Directory",
					Folder = "Directory", Text = "String", String = "String",
					Constant = "Constant", EnumMember = "Constant", Null = "Constant",
					Number = "Number", Boolean = "Boolean", Unit = "Number",
					Operator = "Operator", Reference = "Special", Event = "Special",
				}
				-- All kinds used by the text() map above, plus every LSP kind
				-- blink might send (so the fallback short label still gets a fill).
				local kinds = {
					"Snippet", "Function", "Method", "Constructor", "Variable", "Field",
					"Property", "Class", "Struct", "Interface", "Module", "Namespace",
					"Keyword", "File", "Folder", "Text", "Enum", "EnumMember", "Constant",
					"Operator", "Reference", "Value", "TypeParameter", "Unit", "Array",
					"Boolean", "Event", "Key", "Null", "Number", "Object", "Package", "String",
				}
				for _, kind in ipairs(kinds) do
					-- Category color first (VSCode meaning), theme's own
					-- per-kind color as fallback if the category group has no fg.
					local fg_hex = kind_fg_hex(vscode_src[kind] or "Special")
						or kind_fg_hex("BlinkCmpKind" .. kind)
					if fg_hex then
						vim.api.nvim_set_hl(0, "BlinkCmpKindFilled_" .. kind, {
							fg = dark,
							bg = fg_hex,
							bold = true,
						})
					end
				end
				-- Opaque popup background: blink's menu inherits Pmenu/Normal,
				-- which is transparent here. Pin the menu groups to the
				-- colorscheme's NormalFloat bg so suggestions stay readable.
				-- Custom BlinkCmpKindFilled_* names above are untouched by
					-- utils/transparent.lua, and neither is NormalFloat/Pmenu.
				local normalfloat_bg = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("NormalFloat")), "bg#")
				if normalfloat_bg == "" or normalfloat_bg == "NONE" then
					normalfloat_bg = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("Pmenu")), "bg#")
				end
				if normalfloat_bg and normalfloat_bg ~= "" and normalfloat_bg ~= "NONE" then
					vim.api.nvim_set_hl(0, "BlinkCmpMenu", { bg = normalfloat_bg })
					vim.api.nvim_set_hl(0, "BlinkCmpDoc", { bg = normalfloat_bg })
					vim.api.nvim_set_hl(0, "BlinkCmpSignatureHelp", { bg = normalfloat_bg })
					-- Border groups carry a visible fg so any future border
					-- style draws: same bg as the menu (no halo), fg from
					-- FloatBorder. (fg == bg is why solid/dotted looked
					-- like "no difference".)
					local border_fg = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("FloatBorder")), "fg#")
					if border_fg == "" or border_fg == "NONE" then
						border_fg = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("Comment")), "fg#")
					end
					if border_fg == "" or border_fg == "NONE" then
						border_fg = "#808080"
					end
					vim.api.nvim_set_hl(0, "BlinkCmpMenuBorder", { bg = normalfloat_bg, fg = border_fg })
					vim.api.nvim_set_hl(0, "BlinkCmpDocBorder", { bg = normalfloat_bg, fg = border_fg })
					vim.api.nvim_set_hl(0, "BlinkCmpSignatureHelpBorder", { bg = normalfloat_bg, fg = border_fg })
				end
			end

		build_filled_kind_hls()
		vim.api.nvim_create_autocmd("ColorScheme", {
			group = vim.api.nvim_create_augroup("blink_cmp_kind_fill", { clear = true }),
			callback = function()
				-- Blink defines its Kind hls on ColorScheme; defer so ours derive from the new values.
				vim.schedule(build_filled_kind_hls)
			end,
		})

		-- Watchdog: hide the completion menu when typing non-keyword characters.
		vim.api.nvim_create_autocmd("TextChangedI", {
			group = vim.api.nvim_create_augroup("blink_cmp_menu_watchdog", { clear = true }),
			callback = function()
				local blink = require("blink.cmp")
				if not blink.is_visible() then
					return
				end

				local col = vim.fn.col(".")
				local char = col > 1 and vim.api.nvim_get_current_line():sub(col - 1, col - 1) or ""
				-- `%w` alone is alphanumerics: it used to cancel on `_`, `-` and `.`,
				-- so the menu died on every underscore of a snake_case identifier and
				-- immediately after the `.` that is supposed to trigger member
				-- completion. Keep everything that can occur inside an identifier or
				-- a path segment (blink's keyword set plus / . \ -).
				if not char:match("[%w_./\\\\-]") then
					blink.cancel()
				end
			end,
		})
	end,
}
