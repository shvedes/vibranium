-- Keep these global so they can be reused in hyprland.conf.d

mainMod = "SUPER"
chassis_type = os.getenv("CHASSIS_TYPE") or "desktop"

-- Direction keys: IJKL acts as a vim-style HJKL cluster shifted one column
-- right. Arrow keys are kept as a secondary mapping for the same actions.
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

-- Resize deltas paired to the same IJKL cluster as directions.
local resize = {
  { key = "J", x = -40, y = 0 }, -- left
  { key = "L", x = 40, y = 0 }, -- right
  { key = "I", x = 0, y = -40 }, -- up
  { key = "K", x = 0, y = 40 }, -- down
}

-- Same deltas as resize, but bound to arrow keys so the resize submap
-- is reachable without the IJKL cluster (e.g. on a laptop or numpad layout).
local resize_arrows = {
  { key = "Left", x = -40, y = 0 }, -- left
  { key = "Right", x = 40, y = 0 }, -- right
  { key = "Up", x = 0, y = -40 }, -- up
  { key = "Down", x = 0, y = 40 }, -- down
}

-- Merge directions and arrows into one sequence for binds that cover both.
local all_directions = {}
table.move(directions, 1, #directions, 1, all_directions)
table.move(arrows, 1, #arrows, #all_directions + 1, all_directions)

-- Window management

-- Focus and move windows in every bound direction, including arrow keys.
for _, d in ipairs(all_directions) do
  hl.bind(mainMod .. " + " .. d.key, hl.dsp.focus({ direction = d.dir }), { description = "Focus " .. d.dir })
  hl.bind(
    mainMod .. " + SHIFT + " .. d.key,
    hl.dsp.window.move({ direction = d.dir }),
    { description = "Move window " .. d.dir }
  )
end

-- Resize

-- Resize submap: SUPER + R enters the submap; inside, bare IJKL resize the
-- active window with repeating enabled.
-- Q (quit) / Escape / Return / Backspace to exit the resize mode.

hl.define_submap("resize", function()
  -- IJKL bindings.
  for _, r in ipairs(resize) do
    local dir = ""
    for _, d in ipairs(directions) do
      if d.key == r.key then
        dir = d.dir
        break
      end
    end

    hl.bind(
      r.key,
      hl.dsp.window.resize({ x = r.x, y = r.y, relative = true }),
      { repeating = true, description = "Resize " .. dir }
    )
  end

  local function exit_resize_mode()
    Hypr.Helpers.FlashBorder()
    Hypr.Act.submap("reset")
  end

  -- Arrow key bindings: same deltas as the IJKL cluster above.
  -- Direction label is resolved from the arrows table to reuse the mapping.
  for _, r in ipairs(resize_arrows) do
    local dir = ""
    for _, a in ipairs(arrows) do
      if a.key == r.key then
        dir = a.dir
        break
      end
    end

    hl.bind(
      r.key,
      hl.dsp.window.resize({ x = r.x, y = r.y, relative = true }),
      { repeating = true, description = "Resize " .. dir }
    )
  end

  hl.bind("Q", exit_resize_mode, { description = "Exit resize mode" })
  hl.bind("Escape", exit_resize_mode, { description = "Exit resize mode" })
  hl.bind("Return", exit_resize_mode, { description = "Exit resize mode" })
  hl.bind("BackSpace", exit_resize_mode, { description = "Exit resize mode" })
  hl.bind(mainMod .. " + R", exit_resize_mode, { description = "Exit resize mode" })
end)

hl.bind(
  mainMod .. " + R",
  Hypr.Guard.window(function()
    Hypr.Helpers.FlashBorder()
    Hypr.Act.submap("resize")
  end),
  { description = "Enter resize mode" }
)

-- Close / kill

-- Close the active window.
hl.bind(mainMod .. " + Q", hl.dsp.window.close(), { description = "Close active window" })

-- Kill the active window.
hl.bind(mainMod .. " + SHIFT + Q", Hypr.Helpers.ForceKillWindow, { description = "Force kill active window" })

-- Window state

-- Toggle fullscreen for the active window.
hl.bind(
  mainMod .. " + F",
  Hypr.Guard.window(function(win)
    Hypr.Act.window.fullscreen({ mode = "fullscreen" })
    Hypr.Helpers.CenterFloatingWindow(win)
  end),
  { description = "Toggle fullscreen" }
)

-- Toggle floating for the active window.
-- When a tiled window is switched to floating it often retains its full tiled
-- dimensions and extends off-screen. To avoid needing a manual resize and
-- reposition, the window is automatically resized to 65% of the monitor and centered.
hl.bind(
  mainMod .. " + SHIFT + F",
  Hypr.Guard.window(function(win)
    Hypr.Act.window.float()
    Hypr.Helpers.CenterFloatingWindow(win)
  end),
  { description = "Toggle floating" }
)

-- Pin the active window so it follows across all workspaces.
-- If the window is tiled, it is first floated and shrunk to 50% of the
-- monitor to avoid it spanning the full screen while pinned.
-- Remembers whether a window was tiled before we pinned it.
-- Keyed by win.address, so it survives across multiple windows.
local pin_memory = {}

hl.bind(
  mainMod .. " + SHIFT + P",
  Hypr.Guard.window(function(win)
    if win.pinned then
      -- Unpinning
      local prev = pin_memory[win.address]
      pin_memory[win.address] = nil

      Hypr.Helpers.FlashBorder()
      Hypr.Act.window.pin()

      -- Only restore to tiled if we're the ones who floated it.
      if prev and prev.was_tiled then
        Hypr.Act.window.float({ action = "unset" })
      end
    else
      -- Pinning
      pin_memory[win.address] = { was_tiled = not win.floating }

      if not win.floating then
        local mon = hl.get_active_monitor()
        if mon == nil then
          return
        end

        -- mon.width/height are physical pixels; divide by scale for logical coords.
        local lw = math.floor(mon.width / mon.scale)
        local lh = math.floor(mon.height / mon.scale)
        local w = math.floor(lw * 0.5)
        local h = math.floor(lh * 0.5)

        Hypr.Act.window.float()
        Hypr.Act.window.resize({ x = w, y = h })
      end

      Hypr.Act.window.pin()
      Hypr.Helpers.FlashBorder()
    end
  end),
  { description = "Pin active window" }
)

-- Toggle the dwindle split direction for the active container.
hl.bind(mainMod .. " + S", function()
  -- if hl.get_config("general.layout") ~= "dwindle" then return end
  local ws = hl.get_active_workspace()
  if ws == nil then
    return
  end

  -- Dwindle-only dispatcher
  if ws.tiled_layout ~= "dwindle" then
    return
  end

  -- I love complications hehe
  if hl.get_active_window() == nil then
    return
  end

  Hypr.Act.layout("togglesplit")
end, { description = "Toggle split direction (dwindle)", auto_consuming = true })

-- Toggle pseudo-tiled for the active window. No-op on floating windows to
-- avoid confusion, since pseudo-tile has no meaningful effect on floats.
hl.bind(mainMod .. " + T", function()
  if hl.get_config("general.layout") ~= "dwindle" then
    return
  end

  local win = hl.get_active_window()

  if win == nil then
    return
  end
  if win.floating then
    return
  end

  Hypr.Act.window.pseudo()
end, { description = "Toggle pseudo-tile" })

-- Center the active floating window on its monitor.
hl.bind(mainMod .. " + C", hl.dsp.window.center(), { description = "Center floating window" })

-- Window management (groups)

-- Toggle group on the active window. No guard: this bind is valid even when
-- the window is not yet in a group, since its primary purpose is to create one.
hl.bind(mainMod .. " + G", hl.dsp.group.toggle(), { description = "Toggle group" })

-- Eject the active window from its group. Direction-less by design: "out" is
-- always relative to the group's tile slot, not a specific side.
hl.bind(
  mainMod .. " + SHIFT + G",
  Hypr.Guard.window(function(win)
    if win.group == nil then
      return
    end
    Hypr.Act.window.move({ out_of_group = true })
  end),
  { description = "Eject window from group" }
)

-- Merge the active window into an existing group in the given direction.
for _, d in ipairs(all_directions) do
  hl.bind(
    mainMod .. " + CTRL + " .. d.key,
    Hypr.Guard.window(function()
      Hypr.Act.window.move({ into_or_create_group = d.dir })
    end),
    { description = "Merge window into group " .. d.dir }
  )
end

-- Lock or unlock the active group so it stops accepting new members.
hl.bind(mainMod .. " + CTRL + G", hl.dsp.group.lock_active(), {
  description = "Lock / unlock active group",
})

-- Navigate group tabs. J = previous, L = next. The horizontal pair mirrors
-- the natural left/right reading order of tabs in the group bar.
-- I and K are intentionally unbound: tab order is linear, not spatial.

-- Set non_consuming for these two, so some windows like
-- vb-pkg-install can detect alt-j/k shortcuts. Not a good solution at the moment;
-- I'll change it later.

hl.bind("ALT + L", hl.dsp.group.next(), {
  description = "Group: next tab",
  non_consuming = true,
})

hl.bind("ALT + J", hl.dsp.group.prev(), {
  description = "Group: previous tab",
  non_consuming = true,
})

hl.bind("ALT + TAB", hl.dsp.group.next(), {
  description = "Group: next tab",
  non_consuming = false,
})

hl.bind("ALT + SHIFT + Grave", hl.dsp.group.prev(), {
  description = "Group: previous tab",
  non_consuming = false,
})

hl.bind(mainMod .. " + CTRL + SHIFT + J", hl.dsp.group.move_window({ back = true }), {
  description = "Group: move tab backward",
  non_consuming = false,
})

hl.bind(mainMod .. " + CTRL + SHIFT + L", hl.dsp.group.move_window(), {
  description = "Group: move tab forward",
  non_consuming = false,
})

-- Jump to a specific group tab by index.
for i = 1, 10 do
  hl.bind(
    "ALT + " .. (i % 10),
    Hypr.Guard.window(function(win)
      -- If currnt window is not in a group - pass the shortcut directly.
      -- ALT + N is usually consumed by browsers, so it have to be useful.
      -- hl.dsp.send_shortcut() leaves a bug where the keys are being repeatedly
      -- pressed after the key release.
      if win.group == nil then
        Hypr.Act.send_key_state({ mods = "ALT", key = i, state = "down" })
        Hypr.Act.send_key_state({ mods = "ALT", key = i, state = "up" })
        return
      end

      if win.group.size == 1 then
        Hypr.Act.send_key_state({ mods = "ALT", key = i, state = "down" })
        Hypr.Act.send_key_state({ mods = "ALT", key = i, state = "up" })
        return
      end

      -- Index out of range for the current group; do nothing.
      if i > win.group.size then
        return
      end

      Hypr.Act.group.active({ index = i })
    end),
    { description = "Group: jump to tab " .. i, non_consuming = false }
  )
end

-- Workspace management

hl.bind(mainMod .. "+ ALT + Right", hl.dsp.focus({ workspace = "m+1" }), { description = "Next workspace" })
hl.bind(mainMod .. "+ ALT + Left", hl.dsp.focus({ workspace = "m-1" }), { description = "Previous workspace" })

-- Move between workspaces, including scratchpad.
-- Credit: https://www.reddit.com/user/pbo-sab/.
-- https://www.reddit.com/r/hyprland/comments/1t74dt6/comment/okm9qk2

for i = 1, 10 do
  local key = i % 10
  local label = tostring(key == 0 and 10 or key)

  hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = i }), { description = "Workspace " .. label })

  hl.bind(mainMod .. " + SHIFT + " .. key, function()
    Hypr.Helpers.MoveAndToggleScratchpad(i)
  end, {
    description = "Move to workspace " .. label,
  })
end

hl.bind(
  mainMod .. " + Minus",
  hl.dsp.workspace.toggle_special("scratchpad"),
  { description = "Toggle special workspace" }
)
hl.bind(
  mainMod .. " + SHIFT + Minus",
  hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }),
  { description = "Move to special workspace" }
)

-- Cycle back to the previously focused
-- workspace on the same monitor.
hl.bind(
  mainMod .. " + TAB",
  hl.dsp.focus({ workspace = "previous_per_monitor" }),
  { description = "Previous workspace (this monitor)" }
)

-- Vibranium

hl.bind(mainMod .. " + Return", hl.dsp.exec_raw("xdg-terminal-exec"), { description = "Open terminal" })

hl.bind("CTRL + ALT + L", hl.dsp.exec_raw("vb-shell lockscreen lock"), { description = "Lock session" })
hl.bind("switch:on:Lid Switch", hl.dsp.exec_raw("vb-shell lockscreen lock"), { description = "Lock session on lid close" })

hl.bind("CTRL + ALT + C", hl.dsp.exec_raw("vb-shell colorPicker pick"), { description = "Power menu" })
hl.bind("CTRL + ALT + DELETE", hl.dsp.exec_raw("vb-shell power toggle"), { description = "Power menu" })
hl.bind(mainMod .. " + ALT + ESCAPE", hl.dsp.exec_raw("vb-shell power toggle"), { description = "Power menu" })
hl.bind("XF86PowerOff", hl.dsp.exec_raw("vb-shell power toggle"), { description = "Power menu" })

hl.bind("CTRL + ALT + W", hl.dsp.exec_raw("vb-shell wallpaper next"), { description = "Change background" })
hl.bind("CTRL + ALT + T", hl.dsp.exec_raw("vb-shell themePicker toggle"), { description = "Change theme" })

hl.bind(mainMod .. " + A", hl.dsp.exec_raw("vb-shell appLauncher toggle"), { description = "App launcher" })
hl.bind("XF86Search", hl.dsp.exec_raw("vb-shell appLauncher toggle"), { description = "App launcher" })

hl.bind(mainMod .. " + E", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" })

-- Vibranium menus

hl.bind("CTRL + ALT + V", hl.dsp.exec_raw("vb-shell menu openFile $VIBRANIUM/default/vibranium/menus/main.jsonc" ), { description = "Vibranium menu" })
hl.bind("XF86Tools", hl.dsp.exec_raw("vb-shell menu openFile $VIBRANIUM/default/vibranium/menus/main.jsonc"), { description = "Vibranium menu" })
hl.bind("CTRL + ALT + U", hl.dsp.exec_raw("vb-shell menu openFile $VIBRANIUM/default/vibranium/menus/utilities.jsonc"), { description = "Utilities menu" })
hl.bind("CTRL + ALT + P", hl.dsp.exec_raw("qs -p \"$VIBRANIUM/shell\" ipc call pass open"), { description = "Password manager" })
hl.bind(mainMod .. " + period", hl.dsp.exec_raw("vb-shell menu toggleFile \"$VIBRANIUM/shell/features/pickers/emoji/emojis.jsonc\""), { description = "Emoji picker" })

if chassis_type ~= "vm" then
  hl.bind("CTRL + ALT + R", hl.dsp.exec_raw("qs -p \"$VIBRANIUM/shell\" ipc call recording toggle"), { description = "Record screen" })
end

-- Clipboard

hl.bind(mainMod .. " + V", hl.dsp.exec_raw("qs -p \"$VIBRANIUM/shell\" ipc call clipboard toggle"), { description = "Show clipboard" })
hl.bind(mainMod .. " + SHIFT + V", hl.dsp.exec_raw("qs -p \"$VIBRANIUM/shell\" ipc call clipboard clear"), { description = "Clear clipboard" })

-- Screenshots

hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_raw("vb-shell screenshots picker"), { description = "Screenshots: open overlay" })
hl.bind("Print", hl.dsp.exec_raw("vb-shell screenshots picker"), { description = "Screenshots: open overlay" })

-- Volume

hl.bind(
  "XF86AudioLowerVolume",
  hl.dsp.exec_raw("vb-shell audio voldown"),
  { description = "Volume down", locked = true, repeating = true }
)
hl.bind(
  "XF86AudioRaiseVolume",
  hl.dsp.exec_raw("vb-shell audio volup"),
  { description = "Volume up", locked = true, repeating = true }
)
hl.bind("XF86AudioMute", hl.dsp.exec_raw("vb-shell audio voltoggle"), { description = "Volume mute" })
hl.bind("XF86AudioMicMute", hl.dsp.exec_raw("vb-shell audio mictoggle"), { description = "Mute microphone" })

hl.bind(
  mainMod .. " + SHIFT + XF86AudioMute",
  hl.dsp.exec_raw("vb-shell audio mictoggle"),
  { description = "Mute microphone" }
)

-- Media

hl.bind("XF86AudioNext", hl.dsp.exec_raw("vb-core-mediacontrol --next"), { description = "Next track", locked = true })
hl.bind(
  "XF86AudioPrev",
  hl.dsp.exec_raw("vb-core-mediacontrol --previous"),
  { description = "Previous track", locked = true }
)
hl.bind(
  "XF86AudioPlay",
  hl.dsp.exec_raw("vb-core-mediacontrol --toggle"),
  { description = "Play / pause", locked = true }
)

-- Zoom

hl.bind(mainMod .. " + SHIFT + mouse_up", hl.dsp.exec_raw("vb-core-zoom --increase"), { description = "Zoom in" })
hl.bind(mainMod .. " + SHIFT + mouse_down", hl.dsp.exec_raw("vb-core-zoom --decrease"), { description = "Zoom out" })
hl.bind(mainMod .. " + SHIFT + mouse:274", hl.dsp.exec_raw("vb-core-zoom --reset"), { description = "Reset zoom level" })

-- Mouse drag and resize

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Brightness

if chassis_type ~= "vm" then
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
end

-- Power profile

hl.bind(mainMod .. " + B", hl.dsp.exec_raw("vb-shell powerProfile next"), { description = "Next power profile" })

-- System monitoring

-- SUPER + ESCAPE and CTRL + SHIFT + ESCAPE are both inherited exceptions:
-- the former echoes macOS/GNOME activity-monitor conventions, the latter
-- echoes Windows Task Manager. Both are kept for cross-OS muscle memory.
hl.bind(mainMod .. " + ESCAPE", function()
  Hypr.Helpers.LaunchTUI("/usr/bin/btop", "vb-launch-tui -- btop")
end, { description = "System monitor (btop)" })

hl.bind("CTRL + SHIFT + ESCAPE", function()
  Hypr.Helpers.LaunchTUI("/usr/bin/btop", "vb-launch-tui -- btop")
end, { description = "System monitor (btop)" })

if chassis_type ~= "vm" then
  hl.bind(mainMod .. " + Grave", function()
    Hypr.Helpers.LaunchTUI("/usr/bin/nvtop", "vb-launch-tui -- nvtop")
  end, { description = "GPU monitor (nvtop)" })
end
