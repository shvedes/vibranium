--==============================================================================
-- config/colorscheme.lua  -  Fallback colorscheme name
--
-- This file is consumed by lua/utils/theme.lua when the Vibranium host
-- theme integration is absent or its neovim.lua file cannot be loaded.
--
-- It must return a single string: the name of an installed colorscheme
-- plugin. The theme module falls back to "tokyonight" if even this file
-- is missing or returns something invalid.
--
-- Why a separate file instead of a variable in options.lua:
--   - theme.lua needs to load this as a Lua file (dofile), not require(),
--     because it is used BEFORE lazy.nvim finishes loading. dofile bypasses
--     the module cache and avoids accidentally pulling in plugin dependencies.
--   - Keeping it in its own file means the user can override it without
--     touching the rest of the config.
--==============================================================================

return "tokyonight"
