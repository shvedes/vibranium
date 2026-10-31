hl.config({
  ecosystem = {
    -- Disabled by default.
    enforce_permissions = false,
  },
})

hl.permission({
  binary = "/usr/bin/(qs|quickshell|(gpu-screen|w(f|l))-recorder)",
  type = "screencopy",
  mode = "allow",
  -- LSP server freaks out if I don't
  -- add this here.
  allow = "",
})

hl.permission({
  binary = "/usr/(lib|libexec|lib64)/xdg-desktop-portal-hyprland",
  type = "screencopy",
  mode = "allow",
  allow = "",
})
