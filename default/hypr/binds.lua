local mainMod = "SUPER"

local directions = {
  { key = "J", dir = "left" },
  { key = "L", dir = "right" },
  { key = "I", dir = "up" },
  { key = "K", dir = "down" },
}

local arrows = {
  { key = "Left", dir = "left" },
  { key = "Right", dir = "right" },
  { key = "Up", dir = "up" },
  { key = "Down", dir = "down" },
}

local resize = {
  { key = "J", x = -40, y = 0 }, -- left
  { key = "L", x = 40, y = 0 }, -- right
  { key = "I", x = 0, y = -40 }, -- up
  { key = "K", x = 0, y = 40 }, -- down
}

local all_directions = {}

for _, d in ipairs(directions) do
  table.insert(all_directions, d)
end

for _, d in ipairs(arrows) do
  table.insert(all_directions, d)
end

-- ################# --
-- Window Management --
-- ################# --

-- Focus + Move
for _, d in ipairs(all_directions) do
  -- Focus
  hl.bind(mainMod .. " + " .. d.key, hl.dsp.focus({ direction = d.dir }), { description = "Focus " .. d.dir })

  -- Move
  hl.bind(
    mainMod .. " + SHIFT + " .. d.key,
    hl.dsp.window.move({ direction = d.dir }),
    { description = "Move window " .. d.dir }
  )
end

-- Resize Windows
for _, r in ipairs(resize) do
  local dir = nil

  for _, d in ipairs(directions) do
    if d.key == r.key then
      dir = d.dir
      break
    end
  end

  hl.bind("ALT + SHIFT + " .. r.key, hl.dsp.window.resize({ x = r.x, y = r.y, relative = true }), {
    repeating = true,
    description = "Resize window " .. dir,
  })
end

-- Close active
hl.bind(mainMod .. " + Q", hl.dsp.window.close(), { description = "Close active window" })

-- Kill active
hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.exec_raw("vb-core-force-kill"), { description = "Kill active window" })

-- Toggle fullscreen
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }), { description = "Toggle fullscreen" })
hl.bind("F11", hl.dsp.window.fullscreen({ mode = "fullscreen" }), { description = "Toggle fullscreen" })

-- Toggle floating
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.float("toggle"), { description = "Toggle floating" })

-- Toggle split
-- NOTE: I didn't find this exact dispatcher that
-- splits windows horizonally / vertically. Is it removed?
-- hl.bind()

-- #################### --
-- Workspace Management --
-- #################### --

-- Switch / Move to Workspaces
for i = 1, 10 do
  local key = i % 10

  -- Switch worksapce
  hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = i }), { description = "Workspace " .. i })

  -- Move to workspace
  hl.bind(
    mainMod .. " + SHIFT + " .. key,
    hl.dsp.window.move({ workspace = i }),
    { description = "Move to workspace " .. i }
  )
end

hl.bind("CTRL + " .. mainMod .. " + Right", hl.dsp.focus({ workspace = "next" }), { description = "Next workspace" })
hl.bind(
  "CTRL + " .. mainMod .. " + Left",
  hl.dsp.focus({ workspace = "previous" }),
  { description = "Previous workspace" }
)

-- Special worksapce
hl.bind(mainMod .. " + Minus", hl.dsp.workspace.toggle_special("scratchpad"), { description = "Toggle scratchpad" })
hl.bind(
  mainMod .. " + SHIFT + Minus",
  hl.dsp.window.move({ workspace = "special:scratchpad" }),
  { description = "Move to scratchpad" }
)

-- Toggle back and forth
hl.bind(mainMod .. " + TAB", hl.dsp.focus({ workspace = "previous_per_monitor" }))

-- ############# --
-- Other actions --
-- ############# --

-- Toggle emoji menu
hl.bind(mainMod .. " + period", hl.dsp.exec_raw("vb-menu-emoji"), { description = "Emoji picker" })

-- Toggle calculator
hl.bind("XF86Calculator", hl.dsp.exec_raw("vb-util-calc"), { description = "Toggle Calculator" })

-- Zoom
hl.bind(mainMod .. " + SHIFT + mouse_up", hl.dsp.exec_raw("vb-core-zoom --increase"), { description = "Zoom in" })
hl.bind(mainMod .. " + SHIFT + mouse_down", hl.dsp.exec_raw("vb-core-zoom --decrease"), { description = "Zoom out" })

-- Adjust window's volume
hl.bind(mainMod .. " + mouse_up", hl.dsp.exec_raw("vb-cmd-window-volume --down"), { description = "Window volume up" })
hl.bind(
  mainMod .. " + mouse_down",
  hl.dsp.exec_raw("vb-cmd-window-volume --up"),
  { description = "Window volume down" }
)

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Lock session on lid close (laptops)
-- Note: hypridle will handle the rest (e.g. sleep, players, etc)
hl.bind("switch:on:Lid Switch", hl.dsp.exec_raw("vb-cmd-lock-session"))

-- ######################## --
-- Custom Vibranium actions --
-- ######################## --

hl.bind(mainMod .. " + Return", hl.dsp.exec_raw("xdg-terminal-exec"), { description = "Open terminal" })
hl.bind(
  mainMod .. " + SHIFT + Return",
  hl.dsp.exec_raw("xdg-terminal-exec --app-id=org.vb.term.float"),
  { description = "Open floating terminal" }
)
hl.bind("CTRL + ALT + L", hl.dsp.exec_raw("vb-cmd-lock-session"), { description = "Lock session" })

hl.bind("CTRL + ALT + F", hl.dsp.exec_raw("vb-toggle-freeze"), { description = "Freeze window" }) -- Freeze active window (its pid)
hl.bind("CTRL + ALT + DELETE", hl.dsp.exec_raw("vb-core-launcher --power"), { description = "Logout menu" })
hl.bind(mainMod .. " + ALT + ESCAPE", hl.dsp.exec_raw("vb-core-launcher --power"), { description = "Logout menu" }) -- MacOS style

hl.bind("CTRL + ALT + W", hl.dsp.exec_raw("vb-core-wallpaper --next"), { description = "Change background" })
hl.bind("CTRL + ALT + T", hl.dsp.exec_raw("vb-theme-set"), { description = "Change theme" })

-- Basics
hl.bind(mainMod .. " + A", hl.dsp.exec_raw("vb-core-launcher"), { description = "App launcher" })
hl.bind("XF86Search", hl.dsp.exec_raw("vb-core-launcher"), { description = "App launcher" })
hl.bind("CTRL + ALT + C", hl.dsp.exec_raw("vb-core-color-picker"), { description = "Color picker" })

hl.bind("XF86Explorer", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" }) -- GUI file manager
hl.bind("XF86HomePage", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" }) -- GUI file manager
hl.bind(mainMod .. " + E", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" }) -- GUI file manager

-- Vibranium menus
hl.bind("CTRL + ALT + V", hl.dsp.exec_raw("vb-menu"), { description = "Vibranium menu" })
hl.bind("XF86Tools", hl.dsp.exec_raw("vb-menu"), { description = "Vibranium menu" })
hl.bind("CTRL + ALT + U", hl.dsp.exec_raw("vb-menu-utilities"), { description = "Utilities menu" })
hl.bind("CTRL + ALT + P", hl.dsp.exec_raw("vb-util-pass"), { description = "Password Manager" })

-- Brightness control
hl.bind(
  mainMod .. " + SHIFT + F11",
  hl.dsp.exec_raw("vb-core-brightness --up"),
  { description = "Brightness up", locked = true, repeating = true }
)
hl.bind(
  mainMod .. " + SHIFT + F10",
  hl.dsp.exec_raw("vb-core-brightness --down"),
  { description = "Brightness down", locked = true, repeating = true }
)
hl.bind(
  "XF86MonBrightnessUp",
  hl.dsp.exec_raw("vb-core-brightness --up"),
  { description = "Brightness up", locked = true, repeating = true }
)
hl.bind(
  "XF86MonBrightnessDown",
  hl.dsp.exec_raw("vb-core-brightness --down"),
  { description = "Brightness down", locked = true, repeating = true }
)

-- Clipboard management
hl.bind(mainMod .. " + V", hl.dsp.exec_raw("vb-core-clipboard --show"), { description = "Show clipboard" })
hl.bind(mainMod .. " + SHIFT + V", hl.dsp.exec_raw("vb-core-clipboard --clear"), { description = "Clear clipboard" })

-- Screen Recording
hl.bind("CTRL + ALT + R", hl.dsp.exec_raw("vb-menu-recording"), { description = "Record screen" })

-- Screenshots
hl.bind(
  mainMod .. " + SHIFT + S",
  hl.dsp.exec_raw("vb-core-screenshot --region"),
  { description = "Screenshot (region)" }
)
hl.bind(
  mainMod .. " + SHIFT + A",
  hl.dsp.exec_raw("vb-core-screenshot --window"),
  { description = "Screenshot (window)" }
)
hl.bind(
  mainMod .. " + SHIFT + Z",
  hl.dsp.exec_raw("vb-core-screenshot --screen"),
  { description = "Screenshot (screen)" }
)
hl.bind("Print", hl.dsp.exec_raw("vb-core-screenshot --screen"), { description = "Screenshot (screen)" })

-- Volume management
hl.bind(
  "XF86AudioLowerVolume",
  hl.dsp.exec_raw("vb-core-volume --volume-down"),
  { description = "Volume down", locked = true, repeating = true }
)
hl.bind(
  "XF86AudioRaiseVolume",
  hl.dsp.exec_raw("vb-core-volume --volume-up"),
  { description = "Volume up", locked = true, repeating = true }
)
hl.bind("XF86AudioMute", hl.dsp.exec_raw("vb-core-volume --volume-toggle"), { description = "Volume mute" })
hl.bind("XF86AudioMicMute", hl.dsp.exec_raw("vb-core-volume --microphone-toggle"), { description = "Mute microphone" })

-- In case if user doesn't have XF86AudioMicMute key
hl.bind(mainMod .. " + M", hl.dsp.exec_raw("vb-core-volume --microphone-toggle"), { description = "Mute microphone" })
hl.bind(
  mainMod .. " + SHIFT + XF86AudioMute",
  hl.dsp.exec_raw("vb-core-volume --microphone-toggle"),
  { description = "Mute microphone" }
)

-- Media management
hl.bind("XF86AudioNext", hl.dsp.exec_raw("vb-core-mediacontrol --next"), { description = "Next song", locked = true })
hl.bind(
  "XF86AudioPrev",
  hl.dsp.exec_raw("vb-core-mediacontrol --previous"),
  { description = "Prev song", locked = true }
)
hl.bind(
  "XF86AudioPlay",
  hl.dsp.exec_raw("vb-core-mediacontrol --toggle"),
  { description = "Play / Pause", locked = true }
)

-- Power profiles
hl.bind(mainMod .. " + B", hl.dsp.exec_raw("vb-core-power --next"), { description = "Next power profile" })

-- System monitoring
hl.bind(mainMod .. " + Grave", hl.dsp.exec_raw("vb-launch-tui -- nvtop"), { description = "Open nvtop" })
hl.bind(mainMod .. " + ESCAPE", hl.dsp.exec_raw("vb-launch-tui -- btop"), { description = "Open btop" }) -- < KDE Plasma-like
hl.bind("CTRL + SHIFT + ESCAPE", hl.dsp.exec_raw("vb-launch-tui -- btop"), { description = "Open btop" }) -- < MS Windows-like

-- Power
hl.bind("XF86PowerOff", hl.dsp.exec_raw("vb-core-launcher --power"), { description = "Toggle power menu" })
