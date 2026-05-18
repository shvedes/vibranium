-- This file is a set of rules
-- that always will be read and executed
-- upon Hyprland start. To make your own,
-- go to ~/.config/hypr/hyprland.conf.d/.

-- ================================== --

-- Automatically close special workspace
-- when focusing another workspace.
--
-- It is essentially the 'binds:hide_special_on_workspace_change:true'
-- setting, but it will also work in cases where a window with rules
-- focuses on its assigned workspace. The said configuration option
-- doesn't cover this.
hl.on("workspace.active", function()
  if hl.get_active_special_workspace() then
    hl.dsp.workspace.toggle_special("scratchpad")
  end
end)
