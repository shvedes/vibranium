hl.on("hyprland.start", function()
  hl.exec_cmd("vb-cursor-set --quiet")
  hl.exec_cmd("vb-refresh-dunst")
  hl.exec_cmd("vb-core-startup")

  hl.exec_cmd("systemctl --user import-environment $(env | cut -d'=' -f 1)")
  hl.exec_cmd("dbus-update-activation-environment --systemd --all")
  hl.exec_cmd("uwsm finalize")
end)
