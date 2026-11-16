--==============================================================================
-- config/commands.lua  -  Command-line aliases for common typos
--
-- Defines short/capitalised aliases for frequently mistyped commands:
--   :W -> :w, :Q -> :q, :Wq -> :wq, :E -> :edit, :Vs -> :vsplit, ...
--
-- Each alias is registered TWICE, because the two registration mechanisms
-- cover different failure modes:
--
--   1. User commands (:command Q q) - execute natively when <CR> is pressed,
--      so :Q<CR> works even while blink.cmp's cmdline completion is active.
--      blink.cmp takes over the <CR> key and submits the raw command-line
--      text itself, which bypasses Vim's abbreviation-on-<CR> expansion
--      (typing :Q slowly opens the completion menu -> <CR> -> E492).
--
--   2. Abbreviations (cnoreabbrev Q q) - kept so :Q<Space> still expands
--      inline as before. A bare user command would reject the trailing
--      space with "E488: Trailing characters".
--
-- User commands with -bang handle the ! variants (:Q! -> :q!).
-- The argument aliases pass arguments through (:E src/foo.py -> :edit ...).
--==============================================================================

-- Alias definitions: { name, target command, nvim_create_user_command opts }
--   bang  - accept a trailing ! and append it to the target
--   nargs - "*" passes arguments through; 0 (default) takes none
--   complete - completion type offered after the alias
local aliases = {
  -- Write / quit family: no arguments, all with bang variants.
  { "Q", "q", { bang = true } },
  { "Qa", "qa", { bang = true } },
  { "QA", "qa", { bang = true } },
  { "W", "w", { bang = true } },
  { "Wq", "wq", { bang = true } },
  { "WQ", "wq", { bang = true } },
  { "Wqa", "wqa", { bang = true } },
  { "WQA", "wqa", { bang = true } },
  { "Wqall", "wqall", { bang = true } },
  { "WQall", "wqall", { bang = true } },

  -- Edit / explore family: arguments passed through.
  -- (No :Ex here: netrw is disabled in options.lua, so :Explore does not
  -- exist and the old alias died with E492. :Ex is registered below.)
  { "E", "e", { nargs = "*", complete = "file" } },
  { "Vs", "vsplit", { nargs = "*", complete = "file" } },
  { "Sp", "split", { nargs = "*", complete = "file" } },
  { "Tabe", "tabedit", { nargs = "*", complete = "file" } },
  { "Bd", "bd", { nargs = "*", complete = "buffer" } },
}

-- :LspInfo vanished with Neovim 0.12: nvim-lspconfig's plugin file returns
-- early whenever the core :lsp command exists (0.12 added :lsp enable/disable/
-- restart/stop), and core has no `info` subcommand -- so :LspInfo simply does
-- not exist. Re-create it as the modern equivalent (an alias upstream itself
-- uses).
vim.api.nvim_create_user_command("LspInfo", function()
  vim.cmd("checkhealth vim.lsp")
end, { desc = "LSP client info (:checkhealth vim.lsp)" })

-- :Ex opens the file explorer (Snacks). Registered separately because its
-- target is a Lua function, not a plain Ex command, so it does not fit the
-- alias table above; `:Ex <dir>` opens the explorer at that directory.
vim.api.nvim_create_user_command("Ex", function(args)
  local path = vim.trim(args.args)
  require("snacks").explorer(path ~= "" and { cwd = vim.fn.expand(path) } or nil)
end, { nargs = "?", complete = "dir" })

-- Abbreviations for inline expansion (:Q<Space> -> :q<Space>).
-- These only expand while typing; they do NOT expand reliably on <CR>
-- when a completion plugin owns the command line.
for _, alias in ipairs(aliases) do
  vim.cmd.cnoreabbrev(alias[1], alias[2])
end

-- User commands for reliable execution on <CR>.
for _, alias in ipairs(aliases) do
  local name, target, opts = alias[1], alias[2], alias[3]
  vim.api.nvim_create_user_command(name, function(args)
    -- Build the real command: target + optional ! + optional arguments.
    local cmd = target .. (args.bang and "!" or "")
    if args.args ~= "" then
      cmd = cmd .. " " .. args.args
    end
    vim.cmd(cmd)
  end, {
    bang = opts.bang or false,
    nargs = opts.nargs or 0,
    complete = opts.complete,
  })
end