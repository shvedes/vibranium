Vb = {}

-- Closes all windows on every workspace.
-- Replaces vb-cmd-close-windows.
function Vb.CloseWindows()
  for _, win in ipairs(hl.get_windows()) do
    hl.dispatch(hl.dsp.window.close({
      window = "address:" .. win.address
    }))
  end
end

function Vb.FlashBorder(col)
  local win = hl.get_active_window()
  if not win then return end

  local addr = win.address

  -- This is probably the dumbest decision
  -- ever made, but if it works, it works, right?
  hl.window_rule({
    match = {
      tag = "FlashedBorder"
    },
    border_color = col
  })

  hl.dispatch(hl.dsp.window.tag({
    tag = "+FlashedBorder",
    window = "address:" .. addr
  }))

  hl.timer(function()
    -- Check if the window is still alive.
    if hl.get_window("address:" .. addr) then
      hl.dispatch(hl.dsp.window.tag({
        tag = "-FlashedBorder",
        window = "address:" .. addr
      }))
    end
  end, { timeout = 200, type = "oneshot" })
end
