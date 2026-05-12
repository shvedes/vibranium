-- Matches window titles that likely indicate attention-demanding dialogs
-- (e.g. confirmations, warnings, permissions, save prompts, errors).
-- Used to apply visual emphasis so these windows are harder to miss.
local warn_actions = "(open shell script|authenticate|confirm|(empty\\s)?trash|delete)"
local warn_states = "(warning|attention|alert|error)"
local warn_misc = "(permission|quit|requ(ired|est))"
local warn_save = "save[\\s\\w]*\\?"

local warn_actions_classes = "(Pinentry-gtk)"
local warn_titles = string.format("(?i)(%s|%s|%s|%s)([\\s\\w]*)?\\??", warn_actions, warn_states, warn_misc, warn_save)
local warn_classes = string.format("(?i)(%s)([\\s\\w]*)?\\??", warn_titles)

-- The ATTENTION global is declared in active theme's hyprland.lua

hl.window_rule({
  match = { title = warn_titles },
  border_color = ATTENTION,
  dim_around = true,
})

hl.window_rule({
  match = { title = warn_classes },
  border_color = ATTENTION,
  dim_around = true,
})

hl.window_rule({
  match = { class = warn_actions_classes },
  border_color = ATTENTION,
  dim_around = true,
})
