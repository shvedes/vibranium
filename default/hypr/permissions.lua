hl.config({
  ecosystem = {
    enforce_permissions = true,
  },
})

hl.permission({
  binary = "/usr/bin/(grim|hyprpicker|hyprlock|(gpu-screen|w(f|l))-recorder)",
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
