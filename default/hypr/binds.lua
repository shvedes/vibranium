local mainMod        = "SUPER"
local chassis_type   = os.getenv("CHASSIS_TYPE") or "desktop"

-- Direction keys: IJKL acts as a vim-style HJKL cluster shifted one column
-- right. Arrow keys are kept as a secondary mapping for the same actions.
local directions     = {
  { key = "J", dir = "left" },
  { key = "L", dir = "right" },
  { key = "I", dir = "up" },
  { key = "K", dir = "down" },
}

local arrows         = {
  { key = "Left",  dir = "left" },
  { key = "Right", dir = "right" },
  { key = "Up",    dir = "up" },
  { key = "Down",  dir = "down" },
}

-- Resize deltas paired to the same IJKL cluster as directions.
local resize         = {
  { key = "J", x = -40, y = 0 },   -- left
  { key = "L", x = 40,  y = 0 },   -- right
  { key = "I", x = 0,   y = -40 }, -- up
  { key = "K", x = 0,   y = 40 },  -- down
}

-- Merge directions and arrows into one sequence for binds that cover both.
local all_directions = {}
table.move(directions, 1, #directions, 1, all_directions)
table.move(arrows, 1, #arrows, #all_directions + 1, all_directions)

-- Shared replace ID for window management notifications. Using a fixed ID
-- collapses repeated presses into a single notification bubble.
local WIN_NOTIF = 33


-- Helpers


-- Returns true if the file at path exists and is readable.
local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- Escapes a string for safe interpolation inside single-quoted sh arguments.
-- POSIX sh provides no escape sequence inside single quotes; the standard
-- workaround is to close the quote, emit a quoted literal, then reopen:
-- ' becomes '\''
local function shell_quote(s)
  return (s:gsub("'", "'\\''"))
end


-- Window management


-- Focus and move windows in every bound direction, including arrow keys.
for _, d in ipairs(all_directions) do
  hl.bind(
    mainMod .. " + " .. d.key,
    hl.dsp.focus({ direction = d.dir }),
    { description = "Focus " .. d.dir }
  )
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
  for _, r in ipairs(resize) do
    local dir = ""
    for _, d in ipairs(directions) do
      if d.key == r.key then
        dir = d.dir; break
      end
    end

    hl.bind(
      r.key,
      hl.dsp.window.resize({ x = r.x, y = r.y, relative = true }),
      { repeating = true, description = "Resize " .. dir }
    )
  end

  hl.bind("Q", hl.dsp.submap("reset"), { description = "Exit resize mode" })
  hl.bind("Escape", hl.dsp.submap("reset"), { description = "Exit resize mode" })
  hl.bind("Return", hl.dsp.submap("reset"), { description = "Exit resize mode" })
  hl.bind("BackSpace", hl.dsp.submap("reset"), { description = "Exit resize mode" })
end)

hl.bind(
  mainMod .. " + R",
  function()
    if hl.get_active_window() == nil then return end
    hl.dispatch(hl.dsp.submap("resize"))
  end,
  { description = "Enter resize mode" }
)


-- Close / kill


-- Close the active window.
hl.bind(mainMod .. " + Q", hl.dsp.window.close(), { description = "Close active window" })

-- Force-kill the active window. Requires a second press within 1.5 seconds on
-- the same window to confirm. Switching windows between presses cancels the
-- operation to prevent accidentally killing the wrong process. The pending
-- state is cleaned up on config reload so stale timers never carry over.
--
-- State between first and second press: { pid, timer }. Nil otherwise.

local kill_confirm = nil
local in_submap = false

hl.on("keybinds.submap", function(name)
  in_submap = name ~= ""
end)

hl.on("config.reloaded", function()
  if in_submap then
    hl.dispatch(hl.dsp.submap("reset"))
    in_submap = false
  end

  if kill_confirm ~= nil then
    kill_confirm.timer:set_enabled(false)
    kill_confirm = nil
  end
end)

hl.bind(mainMod .. " + SHIFT + Q", function()
  local win = hl.get_active_window()

  if win == nil then return end

  local pid   = win.pid
  local title = win.initial_title

  if kill_confirm ~= nil then
    if kill_confirm.pid ~= pid then
      -- Active window changed since arming; abort to avoid killing the wrong window.
      kill_confirm.timer:set_enabled(false)
      kill_confirm = nil
      hl.dispatch(hl.dsp.exec_raw(
        "notify-send -r " .. WIN_NOTIF .. " -u critical -t 3000 'Window Killer' 'Aborted: active window changed'"
      ))
      return
    end

    -- Second press on the same window: confirmed, kill it.
    kill_confirm.timer:set_enabled(false)
    kill_confirm = nil

    hl.dispatch(hl.dsp.exec_raw(
      "notify-send -r " .. WIN_NOTIF .. " 'Window Killer'"
      .. " '<i><b>" .. shell_quote(title) .. "</b></i> was killed'"
    ))
    hl.dispatch(hl.dsp.window.kill())
    return
  end

  -- First press: arm the confirmation state and start the 3-second timeout.
  hl.dispatch(hl.dsp.exec_raw(
    "notify-send -r " .. WIN_NOTIF .. " -t 2000 'Window Killer' 'Confirm within 3 seconds'"
  ))

  local timer = hl.timer(function()
    kill_confirm = nil
  end, { timeout = 1500, type = "oneshot" })

  kill_confirm = { pid = pid, timer = timer }
end, { description = "Force kill active window" })


-- Window state


-- Toggle fullscreen for the active window.
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }), { description = "Toggle fullscreen" })

-- Toggle floating for the active window.
-- When a tiled window is switched to floating it often retains its full tiled
-- dimensions and extends off-screen. To avoid needing a manual resize and
-- reposition, the window is automatically resized to 70% of the monitor and centered.
hl.bind(mainMod .. " + SHIFT + F", function()
  local win = hl.get_active_window()
  if win == nil then return end

  local was_floating = win.floating
  hl.dispatch(hl.dsp.window.float())

  if not was_floating then
    local mon = hl.get_active_monitor()
    if mon == nil then return end

    local w = math.floor(mon.width * 0.7)
    local h = math.floor(mon.height * 0.7)

    hl.dispatch(hl.dsp.window.resize({ x = w, y = h }))
    hl.dispatch(hl.dsp.window.center())
  end
end, { description = "Toggle floating" })

-- Pin the active window so it follows across all workspaces.
-- If the window is tiled, it is first floated and shrunk to 50% of the
-- monitor to avoid it spanning the full screen while pinned.
hl.bind(mainMod .. " + SHIFT + P", function()
  local win = hl.get_active_window()
  if win == nil then return end

  local was_pinned = win.pinned
  local was_float  = win.floating

  if not was_pinned and not was_float then
    local mon = hl.get_active_monitor()
    if mon == nil then return end

    local w = math.floor(mon.width * 0.5)
    local h = math.floor(mon.height * 0.5)

    hl.dispatch(hl.dsp.window.float())
    hl.dispatch(hl.dsp.window.resize({ x = w, y = h }))
  end

  hl.dispatch(hl.dsp.window.pin())
end, { description = "Pin active window" })

-- Toggle the dwindle split direction for the active container.
hl.bind(mainMod .. " + S", function()
  if hl.get_config("general.layout") ~= "dwindle" then return end
  if hl.get_active_window() == nil then return end
  hl.dispatch(hl.dsp.layout("togglesplit"))
end, { description = "Toggle split direction" })

-- Toggle pseudo-tiled for the active window. No-op on floating windows to
-- avoid confusion, since pseudo-tile has no meaningful effect on floats.
hl.bind(mainMod .. " + T", function()
  if hl.get_config("general.layout") ~= "dwindle" then return end

  local win = hl.get_active_window()

  if win == nil then return end
  if win.floating then return end

  hl.dispatch(hl.dsp.window.pseudo())
end, { description = "Toggle pseudo-tile" })

-- Center the active floating window on its monitor.
hl.bind(mainMod .. " + C", hl.dsp.window.center(), { description = "Center floating window" })


-- Window management (groups)


-- Toggle group on the active window. No guard: this bind is valid even when
-- the window is not yet in a group, since its primary purpose is to create one.
hl.bind(mainMod .. " + G", hl.dsp.group.toggle(), { description = "Toggle group" })

-- Eject the active window from its group. Direction-less by design: "out" is
-- always relative to the group's tile slot, not a specific side.
hl.bind(mainMod .. " + SHIFT + G", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.window.move({ out_of_group = true }))
end, { description = "Eject window from group" })

-- Merge the active window into an existing group in the given direction.
-- Uses the directions table (IJKL) rather than all_directions — arrow key
-- fallbacks are not bound here because merge is a deliberate action that
-- should not be triggered by casual arrow use.
-- No group guard: the active window does not need to already be in a group
-- in order to be pushed into one.
for _, d in ipairs(directions) do
  hl.bind(
    mainMod .. " + CTRL + " .. d.key,
    function()
      local win = hl.get_active_window()
      if win == nil then return end
      hl.dispatch(hl.dsp.window.move({ into_or_create_group = d.dir }))
    end,
    { description = "Merge window into group " .. d.dir }
  )
end

-- Lock or unlock the active group so it stops accepting new members.
hl.bind(mainMod .. " + CTRL + G", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.lock_active())
end, { description = "Lock / unlock active group" })

-- Navigate group tabs. J = previous, L = next. The horizontal pair mirrors
-- the natural left/right reading order of tabs in the group bar.
-- I and K are intentionally unbound: tab order is linear, not spatial.

hl.bind("ALT + L", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.next())
end, { description = "Group: next tab" })

hl.bind("ALT + Grave", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.next())
end, { description = "Group: next tab" })

hl.bind("ALT + J", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.prev())
end, { description = "Group: previoue tab" })

hl.bind("ALT + SHIFT + Grave", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.prev())
end, { description = "Group: previous tab" })

-- Reorder tabs within the group. Shifting a tab changes its position in the
-- group bar without changing which window is focused.
-- I and K are intentionally unbound for the same reason as tab navigation.
hl.bind(mainMod .. " + CTRL + SHIFT + J", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.move_window({ back = true }))
end, { description = "Group: move tab backward" })

hl.bind(mainMod .. " + CTRL + SHIFT + L", function()
  local win = hl.get_active_window()
  if win == nil or win.group == nil then return end
  hl.dispatch(hl.dsp.group.move_window())
end, { description = "Group: move tab forward" })

-- Jump to a specific group tab by index.
for i = 1, 10 do
  hl.bind("ALT + " .. (i % 10), function()
    local win = hl.get_active_window()
    if win == nil or win.group == nil then return end
    -- Index out of range, do nothing.
    if i > win.group.size then return end
    hl.dispatch(hl.dsp.group.active({ index = i }))
  end, { description = "Group: jump to tab " .. i, non_consuming = true })
end


-- Workspace management

hl.bind(
  "CTRL + " .. mainMod .. " + Right",
  hl.dsp.focus({ workspace = "m+1" }),
  { description = "Next workspace" }
)
hl.bind(
  "CTRL + " .. mainMod .. " + Left",
  hl.dsp.focus({ workspace = "m-1" }),
  { description = "Previous workspace" }
)

-- Move between workspaces, including scratchpad.
-- Credit: https://www.reddit.com/user/pbo-sab/.
-- https://www.reddit.com/r/hyprland/comments/1t74dt6/comment/okm9qk2
local function move_and_toggle_sws(key)
  local sws = hl.get_active_special_workspace()
  local cw = hl.get_active_window()

  if cw then
    if sws then
      -- Move from special to normal and close the sws.
      hl.dispatch(hl.dsp.window.move({ workspace = key, follow = false }))
      hl.dispatch(hl.dsp.workspace.toggle_special("scratchpad"))
    else
      -- Move normally.
      hl.dispatch(hl.dsp.window.move({ workspace = key, follow = false }))
    end
  end
end

for i = 1, 10 do
  local key = i % 10
  local label = tostring(key == 0 and 10 or key)

  hl.bind(mainMod .. " + " .. key,
    hl.dsp.focus({ workspace = i }),
    { description = "Workspace " .. label }
  )

  hl.bind(mainMod .. " + SHIFT + " .. key, function()
    move_and_toggle_sws(i)
  end, {
    description = "Move to workspace " .. label
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


hl.bind(mainMod .. " + Return", hl.dsp.exec_raw("xdg-terminal-exec"),
  { description = "Open terminal" })
hl.bind(mainMod .. " + SHIFT + Return", hl.dsp.exec_raw("xdg-terminal-exec --app-id=org.vb.term.float"),
  { description = "Open floating terminal" })

hl.bind("CTRL + ALT + L", hl.dsp.exec_raw("vb-cmd-lock-session"), { description = "Lock session" })
hl.bind("switch:on:Lid Switch", hl.dsp.exec_raw("vb-cmd-lock-session"), { description = "Lock session on lid close" })

hl.bind("CTRL + ALT + DELETE", hl.dsp.exec_raw("vb-core-launcher --power"), { description = "Power menu" })
hl.bind(mainMod .. " + ALT + ESCAPE", hl.dsp.exec_raw("vb-core-launcher --power"), { description = "Power menu" })
hl.bind("XF86PowerOff", hl.dsp.exec_raw("vb-core-launcher --power"), { description = "Power menu" })

hl.bind("CTRL + ALT + W", hl.dsp.exec_raw("vb-core-wallpaper --next"), { description = "Change background" })
hl.bind("CTRL + ALT + T", hl.dsp.exec_raw("vb-theme-set"), { description = "Change theme" })

hl.bind(mainMod .. " + A", hl.dsp.exec_raw("vb-core-launcher"), { description = "App launcher" })
hl.bind("XF86Search", hl.dsp.exec_raw("vb-core-launcher"), { description = "App launcher" })
hl.bind("CTRL + ALT + C", hl.dsp.exec_raw("vb-core-color-picker"), { description = "Color picker" })

hl.bind("XF86Explorer", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" })
hl.bind("XF86HomePage", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" })
hl.bind(mainMod .. " + E", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "File manager" })

-- Freeze the active window's process (SIGSTOP/SIGCONT).
hl.bind("CTRL + ALT + F", function()
  if hl.get_active_window() == nil then return end
  hl.dispatch(hl.dsp.exec_raw("vb-toggle-freeze"))
end, { description = "Freeze window" })


-- Vibranium menus


hl.bind("CTRL + ALT + V", hl.dsp.exec_raw("vb-menu"), { description = "Vibranium menu" })
hl.bind("XF86Tools", hl.dsp.exec_raw("vb-menu"), { description = "Vibranium menu" })
hl.bind("CTRL + ALT + U", hl.dsp.exec_raw("vb-menu-utilities"), { description = "Utilities menu" })
hl.bind("CTRL + ALT + P", hl.dsp.exec_raw("vb-util-pass"), { description = "Password manager" })
hl.bind(mainMod .. " + period", hl.dsp.exec_raw("vb-menu-emoji"), { description = "Emoji picker" })

if chassis_type ~= "vm" then
  hl.bind("CTRL + ALT + R", hl.dsp.exec_raw("vb-menu-recording"), { description = "Record screen" })
end


-- Clipboard


hl.bind(mainMod .. " + V", hl.dsp.exec_raw("vb-core-clipboard --show"), { description = "Show clipboard" })
hl.bind(mainMod .. " + SHIFT + V", hl.dsp.exec_raw("vb-core-clipboard --clear"), { description = "Clear clipboard" })


-- Screenshots


hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_raw("vb-core-screenshot --region"),
  { description = "Screenshot (region)" })
hl.bind(mainMod .. " + SHIFT + Z", hl.dsp.exec_raw("vb-core-screenshot --screen"),
  { description = "Screenshot (screen)" })

hl.bind("Print", hl.dsp.exec_raw("vb-core-screenshot --screen"), { description = "Screenshot (screen)" })

hl.bind(mainMod .. " + SHIFT + A", function()
  if hl.get_active_window() == nil then return end
  hl.dispatch(hl.dsp.exec_raw("vb-core-screenshot --window"))
end, { description = "Screenshot (window)" })


-- Volume


hl.bind("XF86AudioLowerVolume", hl.dsp.exec_raw("vb-core-volume --volume-down"),
  { description = "Volume down", locked = true, repeating = true })
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_raw("vb-core-volume --volume-up"),
  { description = "Volume up", locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_raw("vb-core-volume --volume-toggle"),
  { description = "Volume mute" })
hl.bind("XF86AudioMicMute", hl.dsp.exec_raw("vb-core-volume --microphone-toggle"),
  { description = "Mute microphone" })

hl.bind(mainMod .. " + M", hl.dsp.exec_raw("vb-core-volume --microphone-toggle"),
  { description = "Mute microphone" })
hl.bind(mainMod .. " + SHIFT + XF86AudioMute", hl.dsp.exec_raw("vb-core-volume --microphone-toggle"),
  { description = "Mute microphone" })


-- Media


hl.bind("XF86AudioNext", hl.dsp.exec_raw("vb-core-mediacontrol --next"),
  { description = "Next track", locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_raw("vb-core-mediacontrol --previous"),
  { description = "Previous track", locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_raw("vb-core-mediacontrol --toggle"),
  { description = "Play / pause", locked = true })


-- Per-window volume


-- Scroll up/down over any window to adjust its PipeWire sink volume
-- independently of the global output volume.
hl.bind(mainMod .. " + mouse_up", function()
  if hl.get_active_window() == nil then return end
  hl.dispatch(hl.dsp.exec_raw("vb-cmd-window-volume --down"))
end, { description = "Window volume down" })

hl.bind(mainMod .. " + mouse_down", function()
  if hl.get_active_window() == nil then return end
  hl.dispatch(hl.dsp.exec_raw("vb-cmd-window-volume --up"))
end, { description = "Window volume up" })


-- Zoom


hl.bind(mainMod .. " + SHIFT + mouse_down", hl.dsp.exec_raw("vb-core-zoom --increase"),
  { description = "Zoom in" })
hl.bind(mainMod .. " + SHIFT + mouse_up", hl.dsp.exec_raw("vb-core-zoom --decrease"),
  { description = "Zoom out" })


-- Mouse drag and resize


hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })


-- Brightness (not applicable in VMs)


if chassis_type ~= "vm" then
  hl.bind(mainMod .. " + SHIFT + F11", hl.dsp.exec_raw("vb-core-brightness --up"),
    { description = "Brightness up", locked = true, repeating = true })
  hl.bind(mainMod .. " + SHIFT + F10", hl.dsp.exec_raw("vb-core-brightness --down"),
    { description = "Brightness down", locked = true, repeating = true })
  hl.bind("XF86MonBrightnessUp", hl.dsp.exec_raw("vb-core-brightness --up"),
    { description = "Brightness up", locked = true, repeating = true })
  hl.bind("XF86MonBrightnessDown", hl.dsp.exec_raw("vb-core-brightness --down"),
    { description = "Brightness down", locked = true, repeating = true })
end


-- Power profile


hl.bind(mainMod .. " + B", hl.dsp.exec_raw("vb-core-power --next"), { description = "Next power profile" })


-- Other


hl.bind("XF86Calculator", hl.dsp.exec_raw("vb-util-calc"), { description = "Toggle calculator" })


-- System monitoring


-- Launches a TUI binary inside a terminal, notifying if the binary is absent.
local function launch_tui(binary, command)
  if not file_exists(binary) then
    local name = binary:match("[^/]+$")
    hl.dispatch(hl.dsp.exec_raw(
      "notify-send -r " .. WIN_NOTIF .. " -u critical -t 5000"
      .. " 'Cannot launch system monitor'"
      .. " 'Missing dependency: <b>" .. name .. "</b>'"
    ))
    return
  end
  hl.dispatch(hl.dsp.exec_raw(command))
end

-- SUPER + ESCAPE and CTRL + SHIFT + ESCAPE are both inherited exceptions:
-- the former echoes macOS/GNOME activity-monitor conventions, the latter
-- echoes Windows Task Manager. Both are kept for cross-OS muscle memory.
hl.bind(mainMod .. " + ESCAPE", function()
  launch_tui("/usr/bin/btop", "vb-launch-tui -- btop")
end, { description = "System monitor (btop)" })

hl.bind("CTRL + SHIFT + ESCAPE", function()
  launch_tui("/usr/bin/btop", "vb-launch-tui -- btop")
end, { description = "System monitor (btop)" })

if chassis_type ~= "vm" then
  hl.bind(mainMod .. " + Grave", function()
    launch_tui("/usr/bin/nvtop", "vb-launch-tui -- nvtop")
  end, { description = "GPU monitor (nvtop)" })
end
