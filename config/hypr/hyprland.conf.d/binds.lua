-- Full binds documentation:
-- https://wiki.hypr.land/Configuring/Basics/Binds

-- Below are some optional binds that you can enable by uncommenting them.

-- ======================================================================= --

-- Cycle through the available window layouts.
local function cycle_layout()
    -- Layouts are cycled in the order defined here.
    local layouts = {
        "dwindle",
        "master",
        "scrolling",
        "monocle",
    }

    -- Create a lookup table for each layout's index.
    local layout_index = {}

    for index, name in ipairs(layouts) do
        layout_index[name] = index
    end

    -- Get the currently active layout.
    local current, err = hl.get_config("general.layout")

    -- Stop if the current layout cannot be retrieved.
    if err then
        return
    end

    -- Find the current layout's index.
    -- Default to 0 if the layout is not in the list.
    local current_index = layout_index[current] or 0

    -- Calculate the next index, wrapping back to the first layout.
    local next_index = (current_index % #layouts) + 1
    local next_layout = layouts[next_index]

    -- Apply the new layout.
    hl.config({ ["general.layout"] = next_layout })

    -- Display a notification showing the active layout.
    hl.dispatch(
        hl.dsp.exec_raw(
            "notify-send -t 2000 -r 100 'Hyprland' 'Current layout: "
                .. next_layout
                .. "'"
        )
    )
end

-- SUPER + SHIFT + D: Cycle window layouts.
hl.bind(mainMod .. " + SHIFT + D", cycle_layout, { description = "Cycle window layout" })

-- Or of you want to launch the terminal in a floating window.
-- hl.bind(mainMod .. " + SHIFT + Return", hl.dsp.exec_raw("xdg-terminal-exec --app-id=org.vb.term.float"), { description = "Open terminal (floating)" })

-- Bind file manager to extra keys on the keyboard.
-- hl.bind("XF86HomePage", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "Open file manager" })
-- hl.bind("XF86Explorer", hl.dsp.exec_raw("vb-launch-cmd -- thunar"), { description = "Open file manager" })

-- You can take screenshots directly by a key press.
-- hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_raw("vb-shell screenshots region"), { description = "Screenshots: capture region" })
-- hl.bind(mainMod .. " + SHIFT + Z", hl.dsp.exec_raw("vb-shell screenshots screen"), { description = "Screenshots: capture screen" })

-- If you're keyboard doesn't have XF86AudioMicMute.
hl.bind(mainMod .. " + M", hl.dsp.exec_raw("vb-shell audio mictoggle"), { description = "Mute microphone" })

-- Maybe you need to adjust display scale live!
-- ============================================

hl.bind(mainMod .. " + CTRL + equal", function()
  Hypr.Helpers.ScaleStep(1)
end, { description = "Increase active display scale" })

hl.bind(mainMod .. " + CTRL + minus", function()
  Hypr.Helpers.ScaleStep(-1)
end, { description = "Decrease active display scale" })

hl.bind(mainMod .. " + CTRL + 0", function()
  Hypr.Helpers.ScaleStep(0)
end, { description = "Reset active display scale" })

-- Or maybe you want to adjust per-window volume by scrolling over them:
-- =====================================================================
hl.bind(
  mainMod .. " + mouse_down",
  Hypr.Guard.window(function()
    Hypr.Act.exec_raw("vb-cmd-window-volume --down")
  end),
  { description = "Window volume down" }
)

hl.bind(
  mainMod .. " + mouse_up",
  Hypr.Guard.window(function()
    Hypr.Act.exec_raw("vb-cmd-window-volume --up")
  end),
  { description = "Window volume up" }
)


-- Temporary freeze window's PID?
hl.bind("CTRL + ALT + F", function()
  Hypr.Helpers.WindowToggleFreeze()
end, { description = "Freeze window" })
