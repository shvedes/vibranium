--==============================================================================
-- plugins/mason.lua  -  Mason package manager (own spec, command-accessible)
--
-- Why this file exists: mason.nvim used to be listed only inside
-- lua/plugins/lspconfig.lua as a dependency, with setup() called from
-- lspconfig's config(). lazy.nvim only creates command stubs for top-level
-- specs that declare `cmd`, so before any file was opened `:Mason`,
-- `:MasonInstall` etc. did not exist at all -- you could not open Mason from
-- the dashboard (E492: Not an editor command: Mason).
--
-- Declaring the commands here makes lazy register stubs that load the plugin on
-- first use. The spec stays listed as a dependency of lspconfig too (lazy merges
-- specs by name, so it is one plugin either way) and `opts = {}` guarantees
-- setup() runs before the UI is opened, whether the load was triggered by
-- `:Mason` or by lspconfig loading on BufReadPre.
--==============================================================================

return {
  "mason-org/mason.nvim",
  cmd = {
    "Mason",
    "MasonInstall",
    "MasonUninstall",
    "MasonUninstallAll",
    "MasonUpdate",
    "MasonLog",
  },
  opts = {},
}
