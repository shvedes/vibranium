-- Matches window titles ehat likely indicate attention-demanding dialogs
-- (e.g. confirmations, warnings, permissions, save prompts, errors).
-- Used to apply visual emphasis so these windows are harder to miss.
local warn_actions = "(Abrir guión del intérprete de órdenes|autenticar|confirmar|Vaciar la papelera)"
local warn_states = "(warning|atención|alert|error)"
local warn_misc = "((autorización|permiso)|requerido)"
local warn_save = "salir|guardar[\\s\\w]*\\?"

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

hl.window_rule({
  match = {
    class = "[Tt]hunar",
    title = "^()$",
  },
  border_color = ATTENTION,
  dim_around = true,
})

hl.window_rule({
  match = { class = "xdg-desktop-portal-gtk", title = "^()$" },
  border_color = ATTENTION,
  dim_around = true,
})
