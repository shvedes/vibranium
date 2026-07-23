#!/usr/bin/lua

-- ============================================================================
-- Vibranium / Hyprland action helpers
--
-- `hl` is Hyprland's own Lua API (bind/dispatch/config/window_rule/etc.) --
-- Vibranium doesn't define it, it's injected by the host process. Everything
-- in THIS file is Vibranium's sugar layer on top of `hl`, added purely to
-- cut down repetition across binds.lua / window-rules.lua / animations/*.lua.
--
-- Quick Lua notes for context (skip if this is old news to you):
--
--   - Lua has exactly one compound data type: the TABLE. `{1, 2, 3}` is an
--     array; `{ key = value }` is a dictionary. You can mix both in the same
--     table. `Hypr.Guard` below is just a table whose values are
--     functions -- there's no separate "module" or "class" concept in Lua,
--     people just use tables for that.
--
--   - Functions are values, same as in JS. `local f = function() end` and
--     `function Foo.bar() end` are literally the same thing; the second is
--     sugar for `Foo.bar = function() end`.
--
--   - A CLOSURE is a function that keeps access to variables from the scope
--     it was created in, even after that scope has returned. `Guard.window`
--     below doesn't run your logic itself -- it returns a brand-new function
--     that "remembers" the `fn` you gave it. That's the whole trick behind
--     every helper in this file that "wraps" something.
--
--   - `...` is Lua's vararg syntax: "however many extra arguments were
--     passed, capture all of them". It's used below purely so the wrappers
--     don't silently drop arguments if Hyprland's callback signature ever
--     changes.
-- ============================================================================

-- Namespace bootstrap. This used to live in a separate lib/globals.lua, but
-- splitting "create the tables" from "populate the tables" across two files
-- only matters if something might load them out of order -- and init.lua
-- now sources this file first, explicitly, by name:
--
--   source(VIBRANIUM .. "/lib/actions.lua")
--   source(VIBRANIUM .. "/lib/hyprland.lua")

Vibranium = Vibranium or {}
Vibranium.Utils = Vibranium.Utils or {}
Vibranium.Colors = Vibranium.Colors or {}

Hypr = Hypr or {}
Hypr.Helpers = Hypr.Helpers or {}

-- Everything below lives on `Hypr`, never on `Vibranium`. init.lua sources
-- ~/.config/vibranium/current/theme/colors.lua between this file loading and
-- binds.lua/window-rules.lua loading, and that generated file reassigns the
-- whole `Vibranium` global (`Vibranium = { Colors = {...} }`) rather than
-- setting `Vibranium.Colors` in place -- reasonable for a file that gets
-- regenerated fresh on every theme switch, but it means anything hung on
-- `Vibranium` before that point is discarded, not merged. `Hypr` is never
-- touched by theme loading, which is why `Hypr.Helpers.*` has always safely
-- survived from this file all the way through to binds.lua. Any new
-- namespace added here should go on `Hypr` for the same reason.

Hypr.Guard = {}
Hypr.Rule = {}
Hypr.Anim = {}
Hypr.Act = {}

-- ----------------------------------------------------------------------------
-- Guard.* -- "only run this if there's an active window/monitor/workspace"
--
-- This is the single most repeated shape in binds.lua:
--
--   hl.bind(mainMod .. " + Q", function()
--     local win = hl.get_active_window()
--     if win == nil then return end
--     hl.dispatch(hl.dsp.window.close())
--   end)
--
-- becomes:
--
--   hl.bind(mainMod .. " + Q", Hypr.Guard.window(function(win)
--     Hypr.Act.window.close()
--   end))
--
-- Guard.window(fn) doesn't call fn. It returns a NEW function that, when
-- Hyprland eventually calls it on keypress, fetches the active window,
-- bails out silently if there isn't one, and only then calls your fn with
-- the window as its first argument. This is the closure trick: the
-- returned function still "has" fn in scope, even though Guard.window
-- itself finished executing long ago.
-- ----------------------------------------------------------------------------

function Hypr.Guard.window(fn)
  return function(...)
    local win = hl.get_active_window()
    if win == nil then
      return
    end
    return fn(win, ...)
  end
end

function Hypr.Guard.monitor(fn)
  return function(...)
    local mon = hl.get_active_monitor()
    if mon == nil then
      return
    end
    return fn(mon, ...)
  end
end

function Hypr.Guard.workspace(fn)
  return function(...)
    local ws = hl.get_active_workspace()
    if ws == nil then
      return
    end
    return fn(ws, ...)
  end
end

-- ----------------------------------------------------------------------------
-- Act.* -- dispatch shortcuts
--
-- Raw Hyprland dispatch is always two calls glued together:
--
--   hl.dispatch(hl.dsp.window.move({ direction = "left" }))
--
-- `hl.dsp.window.move(...)` builds a description of an action; `hl.dispatch`
-- actually fires it. That split makes sense when you're passing a
-- dispatcher straight to hl.bind() as a value (no split needed there --
-- Hyprland stores the description and dispatches it itself on keypress).
-- But INSIDE a custom callback function (anywhere you needed a guard clause,
-- or extra logic), you always want it fired immediately, so the split is
-- just noise. Act.* fires it in one step.
--
-- `wrap_dispatch` is a tiny factory: give it one of Hyprland's `hl.dsp.*`
-- builder functions, get back a function that builds AND fires in one go.
-- This is the same closure idea as Guard.* above, just applied to
-- eliminate typing instead of eliminating a null-check.
-- ----------------------------------------------------------------------------

local function wrap_dispatch(dsp_fn)
  return function(...)
    return hl.dispatch(dsp_fn(...))
  end
end

Hypr.Act.window = {
  move = wrap_dispatch(hl.dsp.window.move),
  resize = wrap_dispatch(hl.dsp.window.resize),
  close = wrap_dispatch(hl.dsp.window.close),
  kill = wrap_dispatch(hl.dsp.window.kill),
  float = wrap_dispatch(hl.dsp.window.float),
  fullscreen = wrap_dispatch(hl.dsp.window.fullscreen),
  pin = wrap_dispatch(hl.dsp.window.pin),
  pseudo = wrap_dispatch(hl.dsp.window.pseudo),
  center = wrap_dispatch(hl.dsp.window.center),
  drag = wrap_dispatch(hl.dsp.window.drag),
  tag = wrap_dispatch(hl.dsp.window.tag),
}

Hypr.Act.group = {
  toggle = wrap_dispatch(hl.dsp.group.toggle),
  next = wrap_dispatch(hl.dsp.group.next),
  prev = wrap_dispatch(hl.dsp.group.prev),
  lock_active = wrap_dispatch(hl.dsp.group.lock_active),
  move_window = wrap_dispatch(hl.dsp.group.move_window),
  active = wrap_dispatch(hl.dsp.group.active),
}

Hypr.Act.workspace = {
  toggle_special = wrap_dispatch(hl.dsp.workspace.toggle_special),
}

Hypr.Act.focus = wrap_dispatch(hl.dsp.focus)
Hypr.Act.layout = wrap_dispatch(hl.dsp.layout)
Hypr.Act.submap = wrap_dispatch(hl.dsp.submap)
Hypr.Act.send_key_state = wrap_dispatch(hl.dsp.send_key_state)
Hypr.Act.send_shortcut = wrap_dispatch(hl.dsp.send_shortcut)
Hypr.Act.exec_raw = wrap_dispatch(hl.dsp.exec_raw)
Hypr.Act.exec_cmd = wrap_dispatch(hl.dsp.exec_cmd)

-- ----------------------------------------------------------------------------
-- Rule.* -- window-rule shorthand
--
-- window-rules.lua repeats this exact two-line shape over and over:
--
--   hl.window_rule({ match = { class = "..." }, tag = "+someTag" })
--
-- and its counterpart, styling everything that carries a tag:
--
--   hl.window_rule({ match = { tag = "someTag" }, opaque = true, ... })
--
-- Rule.tag_class / Rule.tag_title / Rule.by_tag just name those two shapes
-- so the *intent* ("tag windows of this class" vs "style windows with this
-- tag") is visible at the call site instead of buried in a raw table.
-- ----------------------------------------------------------------------------

-- Shallow-merges two tables (b's keys win on conflict). Used so
-- tag_class/tag_title can accept an optional second match criterion
-- (e.g. Minecraft's rule matches both class AND title).
local function merge(a, b)
  local out = {}
  for k, v in pairs(a) do
    out[k] = v
  end
  if b then
    for k, v in pairs(b) do
      out[k] = v
    end
  end
  return out
end

function Hypr.Rule.tag_class(class_pattern, tag_name, extra_match)
  hl.window_rule({
    match = merge({ class = class_pattern }, extra_match),
    tag = "+" .. tag_name,
  })
end

function Hypr.Rule.tag_title(title_pattern, tag_name, extra_match)
  hl.window_rule({
    match = merge({ title = title_pattern }, extra_match),
    tag = "+" .. tag_name,
  })
end

-- tag_by_tag(from_tag, to_tag): windows already carrying `from_tag` also get
-- `to_tag`. This is how window-rules.lua builds up broader categories from
-- narrower ones (e.g. every chromiumBasedBrowser AND every firefoxBasedBrowser
-- window also becomes a browserWindow, and every browserWindow also becomes
-- focusOnActivate) without re-matching the underlying class regex each time.
function Hypr.Rule.tag_by_tag(from_tag, to_tag)
  hl.window_rule({
    match = { tag = from_tag },
    tag = "+" .. to_tag,
  })
end

-- by_tag(tag, props): apply `props` to every window carrying `tag`.
-- This is stage two of the "tag first, style second" pattern -- e.g.
-- tag_class(browserClasses, "browserWindow") followed by
-- by_tag("browserWindow", { focus_on_activate = true }).
function Hypr.Rule.by_tag(tag, props)
  local rule = { match = { tag = tag } }
  for k, v in pairs(props) do
    rule[k] = v
  end
  hl.window_rule(rule)
end

-- ----------------------------------------------------------------------------
-- Anim.* -- data-driven animation presets
--
-- Every file in animations/ is currently a wall of near-identical
-- hl.curve(...) / hl.animation(...) calls with different numbers. Anim.apply
-- turns a preset into plain data (two arrays) and does the repetitive calls
-- for you -- adding a new preset becomes "copy a table", not "copy code".
--
-- preset shape:
-- {
--   layer_rules = { { match = {...}, animation = "slide" }, ... },  -- optional
--   curves      = { { "curveName", { type = "bezier", points = {...} } }, ... },
--   animations  = { { leaf = "border", enabled = true, speed = 5.0, bezier = "curveName" }, ... },
-- }
-- ----------------------------------------------------------------------------

function Hypr.Anim.apply(preset)
  for _, lr in ipairs(preset.layer_rules or {}) do
    hl.layer_rule(lr)
  end

  for _, c in ipairs(preset.curves or {}) do
    -- `c` is a 2-slot array: { name, opts }. Lua doesn't distinguish
    -- "positional" table entries from named ones -- c[1]/c[2] just mean
    -- "the first thing in this table" / "the second thing in this table".
    hl.curve(c[1], c[2])
  end

  for _, a in ipairs(preset.animations or {}) do
    hl.animation(a)
  end
end
