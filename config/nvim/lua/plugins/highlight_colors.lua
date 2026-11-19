--==============================================================================
-- plugins/hightlight_colors.lua  -  Inline color preview
--
-- Plugin: brenoprata10/nvim-highlight-colors
--
-- Detects color codes in buffer text (hex, rgb, hsl, named colors, etc.)
-- and renders a small color swatch (background highlight) behind each code.
--
-- Useful for CSS, SCSS, and any file containing color literals.
-- opts = {} means default configuration.
--==============================================================================

return {
  "brenoprata10/nvim-highlight-colors",
  event = { "BufReadPost", "BufNewFile" },
  opts = {}
}
