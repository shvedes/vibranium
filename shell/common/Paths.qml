pragma Singleton

import QtCore
import Quickshell
import "text/StringUtils.js" as SU
import "text/FileUri.js" as FileUri

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
  readonly property string cacheHome: root.xdgCacheHome !== "" ? root.xdgCacheHome : String(StandardPaths.writableLocation(StandardPaths.GenericCacheLocation)).replace(/^file:\/\//, "")
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
  // settings pages, and the menu swaps in the pages Settings.menuPages()
  // derives from it.
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
    return SU.joinPath(root.themesUserRoot, theme)
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
  // Shared by WallpaperView and LockscreenSurfaceView. The empty and root
  // paths stay the bare scheme, which is the form the directory fields
  // compare against.
  function toFileUrl(path) {
    return FileUri.toUri(path, { blankNull: true, bareRoot: true })
  }

  // A `file:` URL as the canonical encoded file:// URL the Image loader
  // accepts. The remainder is decoded to a path and re-encoded per segment,
  // so an already-encoded "%23" and a raw "#" both land on "%23" instead of
  // one double-encoding or the other truncating at the fragment delimiter.
  function normalizeFileUrl(url) {
    return root.toFileUrl(FileUri.fromUri(url))
  }
}
