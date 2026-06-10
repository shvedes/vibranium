hl.config({
  dwindle = {
    force_split = 2,
    preserve_split = true,
    special_scale_factor = 0.98,
  },

  misc = {
    disable_autoreload = true,
    disable_hyprland_logo = true,
    disable_xdg_env_checks = true,
    disable_watchdog_warning = true,
    disable_splash_rendering = true,
    allow_session_lock_restore = true,
    disable_hyprland_guiutils_check = true,
    font_family = "Cascadia Code",
    enable_anr_dialog = true,
    vrr = 2,
  },

  binds = {
    hide_special_on_workspace_change = true,
    scroll_event_delay = 0,
  },

  ecosystem = {
    no_update_news = true,
    enforce_permissions = false,
  },

  render = {
    cm_auto_hdr = 0,
    send_content_type = false,
    cm_enabled = false,
  },

  debug = {
    vfr = true,
  },

  general = {
    resize_on_border = true,
    allow_tearing = true,
  },

  group = {
    insert_after_current = false
  },

  scrolling = {
    column_width = 0.5,
  },
})
