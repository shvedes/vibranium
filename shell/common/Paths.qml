pragma Singleton

import Quickshell
import QtCore

// Resolved XDG/Vibranium paths. Mirrors default/uwsm/env fallbacks so the
// shell works identically under uwsm and bare sessions.
Singleton {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string xdgConfigHome: Quickshell.env("XDG_CONFIG_HOME")
  readonly property string xdgCacheHome: Quickshell.env("XDG_CACHE_HOME")
  readonly property string vibraniumCache: Quickshell.env("VIBRANIUM_CACHE")
  readonly property string vibraniumState: Quickshell.env("VIBRANIUM_STATE")
  readonly property string vibraniumHome: Quickshell.env("VIBRANIUM")
  readonly property string vibraniumRuntime: Quickshell.env("VIBRANIUM_RUNTIME")

  // XDG home with native fallback: explicit env wins, otherwise the
  // platform default. writableLocation may return a file:// URL on some
  // builds, so strip the scheme to keep a plain path.
  readonly property string configHome: root.xdgConfigHome !== "" ? root.xdgConfigHome : String(StandardPaths.writableLocation(StandardPaths.ConfigLocation)).replace(/^file:\/\//, "")
  readonly property string cacheHome: root.xdgCacheHome !== "" ? root.xdgCacheHome : String(StandardPaths.writableLocation(StandardPaths.CacheLocation)).replace(/^file:\/\//, "")
  readonly property string themesUserRoot: root.configHome + "/vibranium/themes"

  // Shell-managed settings, edited by components themselves.
  readonly property string settingsFile: root.configHome + "/vibranium/settings.json"

  // Schema-driven settings catalog: single source of truth for every
  // managed option and its generated menu pages. One file next to the
  // shell that reads it: settings `pages` plus menu `menus`.
  readonly property string settingsSchemaDir: root.vibraniumHome + "/shell/common/settings"
  // The path that means "the settings bundle" to the menu. The menu renders
  // the live bundle the store builds, not this file's text, so the file is a
  // handle rather than a source: the pickers open it to route into the
  // settings pages, and the menu swaps in Settings.menuBundleText().
  // Doubles as the menu bundle file: MenuLib.parseBundle reads `menus`
  // from this same document, with an optional #page fragment selecting
  // the entry (main, utilities) instead of the settings index.
  readonly property string settingsCatalogPath: root.settingsSchemaDir + "/catalog.jsonc"
  readonly property string settingsBundlePath: root.settingsCatalogPath

  // Validated KEY=VAL projection - the single bash contract. Rendered by
  // the shell from schema + user settings on boot, atomic-swapped on each
  // change, and restored by a watcher if deleted or tampered with live.
  readonly property string runtimeEnvFile: root.vibraniumRuntime + "/settings.env"

  // Active theme name lives here, written by vb-theme-set.
  readonly property string themeNameFile: root.vibraniumState + "/theme.name"

  // Generated theme payload (colors.json, backgrounds/, ...).
  readonly property string themeStateDir: root.vibraniumState + "/theme"
  // Screenshots output dir. Bash used ${XDG_PICTURES_DIR:-$HOME}/Screenshots;
  // Quickshell.env reads the same session env, null falls back to $HOME
  // so the resolved path always matches the bash tool's choice.
  readonly property string screenshotsDir: {
    const xdg = Quickshell.env("XDG_PICTURES_DIR")
    return (xdg !== null && xdg !== "" ? xdg : root.home) + "/Screenshots"
  }
  readonly property string screenshotFallbackDir:
    root.vibraniumCache + "/screenshot-clipboard-fallbacks"
  readonly property string themeBackgroundsDir: root.themeStateDir + "/backgrounds"
  readonly property string themeColorsFile: root.themeStateDir + "/qs.json"

  // Per-theme wallpaper pointer, owned by the shell's Wallpaper singleton.
  //   wallpaper.json: { "<theme>": "<rel-path|abs-path>" }
  // A plain JSON document, with no symlink and no side file anywhere in
  // the theme payload. Watch-driven on disk; atomic-writes echo deduped.
  // Stored at $VIBRANIUM_STATE/wallpaper.json (outside theme payload so
  // an atomic theme swap does not wipe per-theme memory).
  readonly property string wallpaperStateJson: root.vibraniumState + "/wallpaper.json"

  function userThemesDir(theme) {
    return root.themesUserRoot + "/" + theme
  }

  // User-level AppLauncher plugins; scanned after the built-in root.
  readonly property string launcherUserPluginsDir: root.configHome + "/vibranium/shell/AppLauncher/plugins"

  // Drun cache - most-used sorting, cached across sessions. JSON at
  // $XDG_CACHE_HOME/vibranium/druncache.json.
  readonly property string drunCacheFile: root.cacheHome + "/vibranium/druncache.json"

  // Hyprland native configs (managed by HyprlandSettings via HyprlandEditor.js)
  readonly property string hyprInputFile: root.configHome + "/hypr/hyprland.conf.d/input.lua"
  readonly property string hyprAppearanceFile: root.configHome + "/hypr/hyprland.conf.d/look-and-feel.lua"
  readonly property string hyprAdvancedFile: root.configHome + "/hypr/hyprland.conf.d/advanced.lua"
  readonly property string hyprSmartGapsFile: root.configHome + "/hypr/hyprland.conf.d/smart-gaps.lua"
  readonly property string hyprAnimationsFile: root.configHome + "/hypr/hyprland.conf.d/animations.lua"

  function userBackgroundsDir(theme) {
    return root.userThemesDir(theme) + "/backgrounds"
  }

  // Absolute path to encoded file:// URL, one encodeURIComponent per
  // segment so spaces, "#" and unicode survive (encodeURI leaves those).
  // Shared by WallpaperView and LockscreenSurfaceView.
  function toFileUrl(path) {
    const parts = String(path ?? "").split("/")
    let url = "file://"
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === "") continue
      url += "/" + encodeURIComponent(parts[i])
    }
    return url
  }
}
