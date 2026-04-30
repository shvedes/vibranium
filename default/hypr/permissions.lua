hl.config({
  ecosystem = {
    enforce_permissions = true,
  },
})

-- Deny all by default
-- hl.permission({ binary = "", type = "screencopy", mode = "deny" })

hl.permission({
  binary = "/usr/bin/(grim|hyprpicker|hyprlock|(gpu-screen|w(f|l))-recorder)",
  type = "screencopy",
  mode = "allow",
})

hl.permission({ binary = "/usr/(lib|libexec|lib64)/xdg-desktop-portal-hyprland", type = "screencopy", mode = "allow" })
