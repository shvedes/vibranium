--==============================================================================
-- plugins/hightlight_colors.lua  -  Inline colour preview
--
-- Plugin: brenoprata10/nvim-highlight-colors
--
-- Detects colour codes in buffer text (hex, rgb, hsl, named colours, etc.)
-- and renders a small colour swatch (background highlight) behind each code.
--
-- Useful for CSS, SCSS, and any file containing colour literals.
-- opts = {} means default configuration.
--==============================================================================

return {
  "brenoprata10/nvim-highlight-colors",
  event = { "BufReadPost", "BufNewFile" },
  opts = {}
}
