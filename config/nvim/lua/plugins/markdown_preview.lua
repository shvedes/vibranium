--==============================================================================
-- plugins/markdown_preview.lua  -  Live Markdown preview in browser
--
-- Plugin: iamcco/markdown-preview.nvim
--
-- Opens a browser tab that renders a live preview of the current markdown
-- buffer. The preview auto-updates as you type.
--
-- Commands exposed:
--   :MarkdownPreviewToggle
--   :MarkdownPreview
--   :MarkdownPreviewStop
--
-- Only loads for markdown filetypes (ft = { "markdown" }).
-- Has a build step (npm install in the app/ directory) that runs on install.
-- Config function checks that npm is available and warns if not.
--==============================================================================

return {
  "iamcco/markdown-preview.nvim",
  build = "cd app && npm install",
  cmd = {
    "MarkdownPreviewToggle",
    "MarkdownPreview",
    "MarkdownPreviewStop",
  },
  ft = { "markdown" },
  init = function()
    vim.g.mkdp_filetypes = { "markdown" }
  end,
  config = function()
    if vim.fn.executable("npm") == 0 then
      vim.notify(
        "markdown-preview.nvim: npm not found",
        vim.log.levels.WARN
      )
    end
  end,
}
