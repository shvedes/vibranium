if not Vibranium.Colors.red.normal then
  BorderAttention = "rgb(ff0000)"
else
  BorderAttention = Vibranium.Colors.red.normal
end

-- Local, file-only helper: three rules further down apply the exact same
-- two properties (a red-ish border + dimming everything else) keyed off
-- either a title or a class match. This doesn't go in lib/actions.lua
-- because it's specific to this file's BorderAttention variable, not a
-- general Hyprland concept -- not every repeated shape needs to become a
-- global library function, some just need a `local function` at the top
-- of the file that already uses them.
local function attention(match_key, pattern)
  hl.window_rule({
    match = { [match_key] = pattern },
    border_color = BorderAttention,
    dim_around = true,
  })
end

-- When using system instalation of glfw,
-- Minecraft window doesn't always set its class,
-- so we make it totally optional for cases
-- when the window was launched using Xwayland
-- for example, which will set its class.
hl.window_rule({
  match = {
    title = "Minecraft\\*?\\s+\\d+\\.\\d+(\\.\\d+)?",
  },
  tag = "+gameWindow",
})

hl.window_rule({
  match = { class = "(gamescope|osu\\!|cs(2|go_linux)|steam(_(app(_\\d+)?|proton)?))" },
  tag = "+gameWindow",
})

hl.window_rule({
  match = { class = "[\\w.]*?(.*\\.PrismLauncher|steam|heroic|lutris|prismlauncher|.*\\.RetroArch|dolphin-emu)" },
  tag = "+gameLauncher",
})

hl.window_rule({
  match = { class = "((google-)?chrom(e|ium)|brave-browser|microsoft-edge|vivaldi-stable|helium)" },
  tag = "+chromiumBasedBrowser",
})

hl.window_rule({
  match = { class = "(?i)(firefox|zen|librewolf)" },
  tag = "+firefoxBasedBrowser",
})

-- Broader categories built from narrower tags, so each underlying class
-- regex is matched once instead of repeated in every rule below.
hl.window_rule({
  match = { tag = "chromiumBasedBrowser" },
  tag = "+browserWindow",
})

hl.window_rule({
  match = { tag = "firefoxBasedBrowser" },
  tag = "+browserWindow",
})

hl.window_rule({
  match = { class = "[\\w.]*?(only|libre|s)office(?:-\\w+)*" },
  tag = "+officeWindow",
})

-- Some community themes may apply not only Hyprland colors, but also their
-- own settings, such as an opacity rule of 0.97 applied to all windows
-- using a special tag. Vibranium does not include such a rule by default,
-- but it is better to be prepared for these cases.
hl.window_rule({
  match = { title = ".* - YouTube - .*" },
  opaque = true,
})

-- Some applications benefit from automatically regaining focus after certain actions.
-- For example, when logging in through a browser, the original app window can take
-- focus again once the login is complete. This approach has worked well over time.
hl.window_rule({
  match = { class = "(?i)(discord|vesktop|spotify|equibop)" },
  tag = "+focusOnActivate",
})

hl.window_rule({
  match = { tag = "browserWindow" },
  tag = "+focusOnActivate",
})

hl.window_rule({
  match = { tag = "gameWindow" },
  tag = "+focusOnActivate",
})

hl.window_rule({
  match = { tag = "focusOnActivate" },
  focus_on_activate = true,
})

-- Make game windows opaque, allow tearing.
hl.window_rule({
  match = { tag = "gameWindow" },
  immediate = true,
  opaque = true,
})

-- Also fix Steam Login and EA Game Installer windows that appears almost over the screen.
hl.window_rule({
  match = {
    class = "([Ss]team|steam_proton)",
    title = "(Sign in to Steam|EA app installer)",
  },
  center = true,
})

-- hl.window_rule({
--   name = "Floating terminal",
--   match = { class = "org\\.vb\\.term\\.float" },
--   float = true,
--   center = true,
--   size = "monitor_w*0.7 monitor_h*0.7",
-- })

hl.window_rule({
  match = {
    class = "xdg-desktop-portal-gtk|[Tt]hunar|virt-manager",
    title = "^()$",
  },
  border_color = BorderAttention,
  stay_focused = true,
  dim_around = true,
})

hl.window_rule({
  match = { class = "gcr-prompter" },
  border_color = BorderAttention,
  stay_focused = true,
  dim_around = true,
})

-- Special rules for Vibranium utilities, running in a floating terminal window
hl.window_rule({
  name = "Floating Terminal (dimmed)",
  match = {
    class = "org\\.vb\\.term\\.float",

    -- All package management scripts
    -- And pretty much every TUI that Vibranium launches from its own UI.
    title = "(vb-(tui|font|webapp|update|pkg|setup|env|theme-(install|update)|util-yt-dlp).*|vb-update|wiremix|nmtui|impala|iwctl)",
    float = true,
  },

  size = "monitor_w*0.6 monitor_h*0.6",
  center = true,
  dim_around = true,
  stay_focused = true,
})

-- The notification pile animates itself: the cards fade in and out and the
-- pile slides into its new shape. A compositor animation on top of that would
-- animate the surface as well as its contents, so the pile is the one
-- layer-shell namespace here that asks for no animation.
--
-- Deliberately scoped to this one namespace rather than the wide
-- `^vibranium:.*$`. The wide form would silently change the compositor's
-- animation for the bar, the OSD and every island, which is a different
-- change's business entirely; a rule named for a feature has to be able to be
-- deleted with the feature, and one rule covering every surface cannot be.
hl.layer_rule({
  name = "Vibranium Notifications",
  match = { namespace = "^vibranium:notifications$" },
  no_anim = true,
})

hl.layer_rule({
  name = "Vibranium Status Bar Blur",
  match = { namespace = "^vibranium:bar$" },
  ignore_alpha = 0.2,
  blur = true
})

-- Display the privacy dots overlay above other overlays.
--
-- `order` counts DOWN: Hyprland sorts the surfaces of a layer by this value
-- in descending order and renders the list front to back, so the LOWEST
-- value ends up on top of the layer. The dots take -1, which puts them over
-- every overlay that does not ask for an order of its own.
hl.layer_rule({
  name = "Vibranium Privacy Indicator",
  match = { namespace = "^vibranium:privacy$" },
  above_lock = 1,
  order = -1
})

-- The color picker takes -2, one step over the dots, so the pick surface is
-- the topmost overlay on the screen.
--
-- The pick magnifies real pixels: the lens shows the captured frame, and the
-- frame is the screen as it was. Anything drawn over it is a hole in the
-- picture the user is aiming with - the dots would sit on top of the very
-- pixels the lens claims to show. The same reasoning puts the pick over the
-- menus and the tray: a full-screen pick that another overlay can cover is
-- a pick that samples the overlay.
hl.layer_rule({
  name = "Vibranium Color Picker",
  match = { namespace = "^vibranium:color-pick$" },
  order = -2
})

-- ============================================================================================================================= --

hl.window_rule({
  match = {
  title = "(?i)^("
    .. "Save\\s+as|"
    .. "(Open|Choose|All|Select|Save)\\s(?:\\w+\\s)?(?:Image|Folder.*|(?:All\\s)?Files?)|"
    .. "(Image|Video)\\sfile|"
    .. "Local\\sfile|"
    .. "File\\supload(.*)?|"
    .. "New\\sarchive"
    .. ")(\\s[-—].*)?$",
  },

  float = true,
  size = "monitor_w*0.6 monitor_h*0.6",
  dim_around = true,
  center = true,
})

hl.window_rule({
  match = {
    class = "^xdg-desktop-portal-gtk$",
    title = "^Warning: this site can see edits you make$",
  },

  float = true,
  size = "monitor_w*0.6 monitor_h*0.6",
  dim_around = true,
  center = true,
})

local thunar_re = "(Rename\\s.*|Create (New Folder|Document from template.*)|File Operation Progress|New\\s.*)"

-- Thunar special rules.
-- Keeps small contextual windows always visible and focused.
-- To revert, just tile the window.
hl.window_rule({
  name = "Thunar: File Operation",
  match = {
    class = "[Tt]hunar",
    title = thunar_re,
  },

  float = true,
  center = true,
  dim_around = true,
})

-- ============================================================================================================================= --

-- Avoid accidental dims on tiled windows.
hl.window_rule({
  match = {
    float = false
  },
  dim_around = false
})

-- ============================================================================================================================= --

-- Matches window titles that likely indicate attention-demanding dialogs
-- (e.g. confirmations, warnings, permissions, save prompts, errors).
-- Used to apply visual emphasis so these windows are harder to miss.
--
-- Try to exit GIMP with an unsaved file to see the effect.

local warn_actions = "(open shell script|authenticate|confirm|(empty\\s)?trash|delete)"
local warn_states = "(warning|attention|alert|error)"
local warn_misc = "(permission|quit|requ(ired|est))"
local warn_save = "save[\\s\\w]*\\?"

local warn_actions_classes = "(Pinentry-gtk)"
local warn_titles = string.format("(?i)(%s|%s|%s|%s)([\\s\\w]*)?\\??", warn_actions, warn_states, warn_misc, warn_save)
local warn_classes = string.format("(?i)(%s)([\\s\\w]*)?\\??", warn_titles)

attention("title", warn_titles)
attention("class", warn_classes)
attention("class", warn_actions_classes)
