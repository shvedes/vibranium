--==============================================================================
-- plugins/treesitter.lua  -  Treesitter parser installation and auto-attach
--
-- Plugin: nvim-treesitter/nvim-treesitter
--
-- On-demand installation of treesitter parsers. When a buffer is opened with
-- a filetype for which a parser exists but is not yet installed, this plugin
-- automatically downloads and compiles it.
--
-- The init function sets up an autocmd on FileType that:
--   1. Tries to register and start treesitter for the buffer's language.
--   2. If the parser is not installed, checks if nvim-treesitter knows about it.
--   3. Installs it asynchronously and attaches once done.
--
-- Commands exposed for manual management:
--   :TSInstall <lang>, :TSUninstall, :TSUpdate, :TSUpdateSync
--==============================================================================

return {
  "nvim-treesitter/nvim-treesitter",
  cmd = { "TSInstall", "TSUninstall", "TSUpdate", "TSUpdateSync" },
  build = ":TSUpdate",

  init = function()
    -- Attempt to register and start treesitter for a buffer and language.
    -- Returns true on success, false on failure.
    local function attach(buf, lang)
      local ok = pcall(vim.treesitter.language.register, lang, lang)
      if not ok then
        return false
      end
      return pcall(vim.treesitter.start, buf, lang)
    end

    -- Autocmd: on FileType, auto-install the parser if missing.
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("TreesitterAutoInstall", { clear = true }),
      callback = function(args)
        local buf = args.buf
        local lang = vim.treesitter.language.get_lang(args.match)
        if not lang or attach(buf, lang) then
          return  -- Already installed and attached.
        end

        -- Check if nvim-treesitter knows about this language.
        local ok, ts = pcall(require, "nvim-treesitter")
        if not ok then
          return
        end

        if not vim.tbl_contains(ts.get_available(), lang) then
          return  -- No parser available for this language.
        end

        -- Install the parser asynchronously and attach when done.
        ts.install(lang):await(function(err)
          if not err then
            vim.schedule(function()
              attach(buf, lang)
            end)
          end
        end)
      end,
    })
  end,
}
