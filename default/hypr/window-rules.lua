hl.window_rule({
  match = {
    class = "^Minecraft\\*\\s\\d\\.\\d\\d?"
  },
  tag = "+gameWindow",
})

hl.window_rule({
  match = {
    class = "(gamescope|osu\\!|cs(2|go_linux)|steam(_(app(_\\d+)?|proton)?))",
  },
  tag = "+gameWindow",
})

hl.window_rule({
  match = {
    class = "[\\w.]*?(.*\\.PrismLauncher|steam|heroic|lutris|prismlauncher|.*\\.RetroArch|dolphin-emu)",
  },
  tag = "+gameLauncher",
})

hl.window_rule({
  match = {
    class = "((google-)?chrom(e|ium)|brave-browser|microsoft-edge|vivaldi-stable|helium)",
  },
  tag = "+chromiumBasedBrowser",
})

hl.window_rule({
  match = {
    class = "(?i)(firefox|zen|librewolf)",
  },
  tag = "+firefoxBasedBrowser",
})

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

-- Some Omarchy themes may apply not only Hyprland colors, but also their
-- own settings. By default, Omarchy applies an opacity rule of 0.97 to all
-- windows, using a special tag, and disables opacity for windows with
-- specific titles. Vibranium does not include such a rule by default, but
-- it is better to be prepared for these cases.
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
  opaque = true
})

hl.window_rule({
  match = { tag = "focusOnActivate" },
  focus_on_activate = true,
})

-- Make game windows opaque, allow tearing (fullscreen only).
hl.window_rule({
  match = { tag = "gameWindow" },
  immediate = true,
  opaque = true,
})

-- Also fix Steam's login window that appears almost over the screen.
hl.window_rule({
  match = {
    class = "[Ss]team",
    title = "Sign in to Steam",
  },
  center = true,
})

hl.window_rule({
  name = "Floating terminal",
  match = { class = "org\\.vb\\.term\\.float" },
  float = true,
  center = true,
  size = "monitor_w*0.7 monitor_h*0.7",
})

-- Thunar special rules.
-- Keeps small contextual windows always visible and focused.
-- To revert, just tile the window.
hl.window_rule({
  name = "Thunar: File Operation",
  match = {
    class = "[Tt]hunar",
    title = '^(Rename "(.*?)"|Create New Folder|File Operation Progress|New\\s.*)$',
  },
  float = true,
  center = true,
  dim_around = true,
})

-- Special rules for Vibranium utilities, running in a floating terminal window
hl.window_rule({
  name = "Floating Terminal (dimmed)",
  match = {
    class = "org\\.vb\\.term\\.float",

    -- All package management scripts
    -- And pretty much every TUI that can be launched by clicking on a Waybar module.
    title =
    "(vb-(tui|font|webapp|update|pkg|setup|env|theme-install).*|bluetui|vb-update|wiremix|nmtui|impala|iwctl|pass)",
    float = true,
  },

  size = "monitor_w*0.7 monitor_h*0.7",
  center = true,
  dim_around = true,
  stay_focused = true,
})
