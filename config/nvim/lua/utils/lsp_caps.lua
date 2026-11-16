--==============================================================================
-- utils/lsp_caps.lua  -  LSP client capabilities for blink.cmp
--
-- blink.cmp ships `require("blink.cmp").get_lsp_capabilities()`, but calling it
-- from the LSP server definitions means the completion engine is loaded as soon
-- as any file is opened: the require triggers lazy.nvim's loader, which runs
-- blink's full setup (native fuzzy library, keymaps, source providers). That
-- used to make the first file open ~3.5ms more expensive, even when the user
-- never enters insert mode.
--
-- The table below is blink's delta copied verbatim from
--   saghen/blink.cmp lua/blink/cmp/sources/lib/init.lua
--   function sources.get_lsp_capabilities(override, include_nvim_defaults)
-- for the commit pinned in .lazy-lock.json. Neovim deep-merges the table over
-- vim.lsp.protocol.make_client_capabilities() when it builds the client
-- (vim/lsp/client.lua), so it only needs to carry blink's additions.
--
-- Re-check this table when blinking.cmp is updated:
--   :lua vim.print(require("utils.lsp_caps").get())
--   :lua vim.print(require("blink.cmp").get_lsp_capabilities())
-- Both should print the same table.
--==============================================================================

local M = {}

--- Client capabilities advertised by blink.cmp.
--- @param override? lsp.ClientCapabilities extra capabilities merged on top.
--- @return lsp.ClientCapabilities
function M.get(override)
	return vim.tbl_deep_extend("force", {
		textDocument = {
			completion = {
				completionItem = {
					snippetSupport = true,
					commitCharactersSupport = false, -- TODO (upstream)
					documentationFormat = { "markdown", "plaintext" },
					deprecatedSupport = true,
					preselectSupport = false, -- TODO (upstream)
					tagSupport = { valueSet = { 1 } }, -- deprecated
					insertReplaceSupport = true, -- TODO (upstream)
					resolveSupport = {
						properties = {
							"documentation",
							"detail",
							"additionalTextEdits",
							"command",
							"data",
						},
					},
					insertTextModeSupport = {
						-- TODO: support adjustIndentation
						valueSet = { 1 }, -- asIs
					},
					labelDetailsSupport = true,
				},
				completionList = {
					itemDefaults = {
						"commitCharacters",
						"editRange",
						"insertTextFormat",
						"insertTextMode",
						"data",
					},
				},

				contextSupport = true,
				insertTextMode = 1, -- asIs
			},
		},
	}, override or {})
end

return M
