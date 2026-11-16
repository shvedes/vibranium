--==============================================================================
-- plugins/conform.lua  -  Code formatting via conform.nvim
--
-- Plugin: stevearc/conform.nvim
--
-- Provides a unified formatting interface that dispatches to language-specific
-- formatters (stylua, ruff, gofumpt, prettier, shfmt, etc.).
--
-- Features:
--   - Format on save (BufWritePre) with a 200ms timeout.
--   - LSP fallback disabled by default (only explicit formatters run auto).
--   - :ConformInfo command to see which formatters apply.
--   - <leader>cf maps to manual format with LSP fallback.
--==============================================================================

return {
  "stevearc/conform.nvim",
  event = { "BufWritePre" },
  cmd = { "ConformInfo" },
  keys = {
    {
      "<leader>cf",
      function()
        require("conform").format({ async = true, lsp_fallback = true })
      end,
      desc = "Format buffer",
    },
  },
  opts = {
    format_on_save = {
      -- 200ms timed out on prettierd cold start, leaving half-formatted
      -- saves. 500ms is still snappy and covers it.
      timeout_ms = 500,
      -- LSP fallback is off for auto-format: only explicit formatters run.
      -- To use LSP as a fallback formatter, set this to true.
      lsp_fallback = false,
    },
    -- Custom formatter definitions.
    formatters = {
      shfmt = {
        inherit = false,
        command = "shfmt",
        -- --indent 0 means "indent with tabs", which is what
        -- config/autocmds.lua sets for sh/bash (expandtab = false, tabstop 4).
        -- It used to pass --indent 2, so every save rewrote the file to two
        -- spaces while the editor kept inserting tabs: mixed indentation in
        -- the same file depending on which side touched the line last.
        args = { "--indent", "0", "--case-indent", "--space-redirects" },
      },
    },
    -- Formatter assignments by filetype.
    -- Every formatter listed for a filetype runs, in order -- conform does not
    -- pick "the first available one". Chains that are meant as fallbacks
    -- (prettierd -> prettier) therefore set `stop_after_first = true`, which
    -- stops the chain as soon as one of them succeeds. Unavailable formatters
    -- are skipped (see :ConformInfo).
    formatters_by_ft = {
      lua = { "stylua" },
      -- Import ordering first, then lint autofixes, then formatting last so the
      -- formatted result is what lands on disk (organizing after formatting
      -- used to re-flow the import block unformatted).
      python = { "ruff_organize_imports", "ruff_fix", "ruff_format" },
      rust = { "rustfmt", lsp_format = "fallback" },
      -- goimports rewrites the file gofmt-style, so it has to run before
      -- gofumpt, otherwise gofumpt's stricter formatting is undone.
      go = { "goimports", "gofumpt" },
      javascript = { "prettierd", "prettier", stop_after_first = true },
      javascriptreact = { "prettierd", "prettier", stop_after_first = true },
      typescript = { "prettierd", "prettier", stop_after_first = true },
      typescriptreact = { "prettierd", "prettier", stop_after_first = true },
      json = { "prettierd", "prettier", stop_after_first = true },
      jsonc = { "prettierd", "prettier", stop_after_first = true },
      yaml = { "prettierd", "prettier", stop_after_first = true },
      markdown = { "prettierd", "prettier", stop_after_first = true },
      css = { "prettierd", "prettier", stop_after_first = true },
      scss = { "prettierd", "prettier", stop_after_first = true },
      sh = { "shfmt" },
      bash = { "shfmt" },
      -- Fallback for filetypes without an explicit formatter above (toml,
      -- html, etc.): run the LSP formatter instead of silently skipping.
      -- "_" only applies when no ft entry matched; explicit chains above
      -- are untouched.
      ["_"] = { lsp_format = "fallback" },
    },
  },
}
