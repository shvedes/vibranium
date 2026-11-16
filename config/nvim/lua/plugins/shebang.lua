--==============================================================================
-- plugins/shebang.lua  -  Automatic shebang insertion and chmod
--
-- Plugin: shvedes/shebang.nvim (custom/local plugin)
--
-- When creating a new file with a recognised extension (.sh, .py, etc.),
-- this plugin automatically inserts an appropriate shebang line based on
-- the filetype and sets the file to be executable (chmod +x).
--
-- Configuration:
--   cursor_offset = 1: leave cursor one line below the shebang.
--   auto_chmod = true: automatically chmod +x files with a shebang.
--   sh_is_bash = true: treat .sh files as bash (#!/bin/bash).
--   use_env = false: use /bin/bash instead of /usr/bin/env bash.
--   ignore_dirs = { "~/.config/nvim" }: skip this config directory
--     (prevents accidental shebangs on new Lua/Markdown files here).
--==============================================================================

return {
	"shvedes/shebang.nvim",
	event = "BufNewFile",
	opts = {
		cursor_offset = 1,
		auto_chmod = true,
		sh_is_bash = true,
		use_env = false,
		ignore_dirs = {
			"~/.local/share/vibranium",
			"~/.config/nvim",
		},
	},
}
