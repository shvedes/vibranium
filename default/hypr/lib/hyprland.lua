#!/usr/bin/lua

-- Shared notification replace-ID for window management messages.
-- A fixed ID collapses repeated triggers into a single notification bubble
-- instead of spawning a new one each time.
WIN_NOTIF = 33

-- Returns true if the file at path exists and is readable.
local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- Escapes a string for safe interpolation inside single-quoted sh arguments.
-- POSIX sh provides no escape sequence inside single quotes; the standard
-- workaround is to close the quote, emit a quoted literal apostrophe, then
-- reopen: ' becomes '\''
function Hypr.Helpers.ShellQuote(s)
  return (s:gsub("'", "'\\''"))
end

-- Centers a floating window at 70 % of its monitor dimensions.
-- No-op if the window is not floating.
function Hypr.Helpers.CenterFloatingWindow(win)
  if not win.floating then return end

  local mon = hl.get_active_monitor()
  if mon == nil then return end

  local w = math.floor(mon.width * 0.7)
  local h = math.floor(mon.height * 0.7)

  hl.dispatch(hl.dsp.window.resize({ x = w, y = h }))
  hl.dispatch(hl.dsp.window.center())
end

-- Moves the active window to a numbered workspace, collapsing any open
-- special workspace first so the move is always visible.
-- Credit: https://www.reddit.com/user/pbo-sab/
-- https://www.reddit.com/r/hyprland/comments/1t74dt6/comment/okm9qk2
function Hypr.Helpers.MoveAndToggleScratchpad(key)
  local sws = hl.get_active_special_workspace()
  local cw  = hl.get_active_window()

  if cw then
    if sws then
      -- Move from special workspace to normal and close the sws.
      hl.dispatch(hl.dsp.window.move({ workspace = key, follow = false }))
      hl.dispatch(hl.dsp.workspace.toggle_special("scratchpad"))
    else
      -- Move normally.
      hl.dispatch(hl.dsp.window.move({ workspace = key, follow = false }))
    end
  end
end

-- Mutable state for the force-kill confirmation flow.
KillConfirm = nil

-- Tags a window with a temporary border color backed by a window rule.
-- The rule is re-created on every call; Hyprland overwrites the previous one.
local function apply_border_tag(addr, tag, col)
  hl.window_rule({ match = { tag = tag }, border_color = col })
  hl.dispatch(hl.dsp.window.tag({ tag = "+" .. tag, window = "address:" .. addr }))
end

-- Removes a border tag, returning the window to its normal border color.
local function remove_border_tag(addr, tag)
  if hl.get_window("address:" .. addr) then
    hl.dispatch(hl.dsp.window.tag({ tag = "-" .. tag, window = "address:" .. addr }))
  end
end

-- Force-kills the active window with a two-press confirmation.
-- First press arms a 1.5 s timer and holds the border red for its duration.
-- A second press on the same window confirms. Switching windows between presses
-- aborts (removing the red border) to prevent killing the wrong process.
function Hypr.Helpers.ForceKillWindow()
  local win = hl.get_active_window()
  if win == nil then return end

  local pid   = win.pid
  local title = win.initial_title
  local addr  = win.address

  if KillConfirm ~= nil then
    if KillConfirm.pid ~= pid then
      -- Active window changed since arming; abort and remove the red border.
      KillConfirm.timer:set_enabled(false)
      remove_border_tag(KillConfirm.addr, "KillArmed")
      KillConfirm = nil

      hl.dispatch(hl.dsp.exec_raw(
        "notify-send -r " ..
        WIN_NOTIF .. " -t 4000 'Kill Cancelled' 'The active window changed before confirmation'"
      ))
      return
    end

    -- Second press on the same window: confirmed, kill it.
    -- Tag removal is skipped — the window is about to die.
    KillConfirm.timer:set_enabled(false)
    KillConfirm = nil

    hl.dispatch(hl.dsp.exec_raw(
      "notify-send -r " .. WIN_NOTIF .. " 'Window Force-Killed'"
      .. " '<b>" .. Hypr.Helpers.ShellQuote(title) .. "</b> was forcefully terminated'"
    ))
    hl.dispatch(hl.dsp.window.kill())
    return
  end

  -- First press: tag the border red and arm the timeout.
  apply_border_tag(addr, "KillArmed", Vibranium.Colors.red.bright)

  local timer = hl.timer(function()
    -- Confirmation window expired; remove the red border and disarm.
    remove_border_tag(addr, "KillArmed")
    KillConfirm = nil
  end, { timeout = 1500, type = "oneshot" })

  KillConfirm = { pid = pid, addr = addr, timer = timer }
end

-- Closes all windows on every workspace.
-- Replaces vb-cmd-close-windows.
function Hypr.Helpers.CloseWindows()
  for _, win in ipairs(hl.get_windows()) do
    hl.dispatch(hl.dsp.window.close({
      window = "address:" .. win.address
    }))
  end
end

function Hypr.Helpers.FlashBorder(col)
  local win = hl.get_active_window()
  if not win then return end

  local addr = win.address

  apply_border_tag(addr, "FlashedBorder", col)

  hl.timer(function()
    remove_border_tag(addr, "FlashedBorder")
  end, { timeout = 200, type = "oneshot" })
end

-- Launches a TUI binary inside a terminal, sending a critical notification
-- if the binary is absent rather than silently failing.
-- Depends on: file_exists, WIN_NOTIF
function Hypr.Helpers.LaunchTUI(binary, command)
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

function Hypr.Helpers.WindowToggleFreeze()
  local win = hl.get_active_window()
  if not win then return end

  local target_pid = win.pid

  -- State field in /proc stat: 'T' means already SIGSTOP'd.
  -- Greedy match on last ')' so comm fields containing parens don't misparse.
  local state
  local sf = io.open("/proc/" .. target_pid .. "/stat", "r")
  if sf then
    local s = sf:read("l")
    sf:close()
    state = s and s:match(".*%)%s+(%a)")
  end

  local sig, verb
  if state == "T" then
    sig  = "CONT"
    verb = "restored"
  else
    sig  = "STOP"
    verb = "suspended"
  end

  hl.dispatch(hl.dsp.exec_cmd("kill -" .. sig .. " " .. target_pid))
  hl.dispatch(hl.dsp.exec_cmd(string.format(
    "notify-send -r 3 'PID Freezer' '<b>%s</b> %s'",
    win.title:gsub("'", "'\\''"),
    verb
  )))
end

-- Hyprland (via the Wayland fractional-scale protocol) quantizes monitor
-- scale to multiples of 1/120, on top of requiring the scale to divide
-- both monitor dimensions into whole logical pixels. A scale of k/120
-- satisfies both requirements exactly when k divides
--
-- 120 * gcd(width, height), so valid k values are the divisors of that
-- number, this is checked with plain integer division, no float epsilon
-- needed.
local SCALE_DENOMINATOR = 120

-- Lowest scale allowed. Prevents stepping down into impractically tiny
-- logical resolutions, and as a side effect keeps scale from ever
-- reaching zero or negative.
local SCALE_MIN = 0.5

-- Highest scale allowed, prevents stepping up into impractically huge
-- logical resolutions
local SCALE_MAX = 3.0

-- Greatest common divisor of two integers
local function Gcd(a, b)
  while b ~= 0 do
    a, b = b, a % b
  end
  return a
end

-- Steps the active monitor's scale to the next value that is both a
-- multiple of 1/120 and divides the monitor resolution into whole
-- logical pixels. direction must be 1 to increase scale or -1 to
-- decrease it.
function Hypr.Helpers.ScaleStep(direction)
  local monitor = hl.get_active_monitor()
  if monitor == nil then
    return
  end

  local width = math.floor(monitor.width + 0.5)
  local height = math.floor(monitor.height + 0.5)

  -- The number every valid k must divide
  local valid_multiple = SCALE_DENOMINATOR * Gcd(width, height)

  local k_min = math.ceil(SCALE_MIN * SCALE_DENOMINATOR)
  local k_max = math.floor(SCALE_MAX * SCALE_DENOMINATOR)

  -- Snap the current scale onto the nearest 1/120 multiple first, so
  -- this still behaves correctly even if the scale was set to something
  -- off grid by another tool
  local k = math.floor((monitor.scale * SCALE_DENOMINATOR) + 0.5)

  local new_scale = nil

  while true do
    k = k + direction

    if k < k_min or k > k_max then
      break
    end

    if valid_multiple % k == 0 then
      new_scale = k / SCALE_DENOMINATOR
      break
    end
  end

  if new_scale == nil then
    return
  end

  hl.monitor({
    output = monitor.name,
    scale = string.format("%.10f", new_scale),
  })

  hl.notification.create({
    text = string.format("Display scale: %.4g", new_scale),
    timeout = 1.5,
  })
end
