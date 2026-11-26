hl.on("hyprland.start", function()
  hl.exec_cmd("vb-shell --warm-cache")
  hl.exec_cmd("vb-core-startup")
end)
