// Probe: Paths and FilePresence, the two common/ singletons whose contracts
// are about DERIVATION rather than about a value on this host.
//
// Paths is pure string derivation over Quickshell.env plus a StandardPaths
// fallback, so a literal proves nothing: what matters is the invariant between
// a derived path and the root it came from (containment, no doubled separator,
// no trailing separator) and that every catalog entry names a schema that
// actually exists. The driver launches this probe a second time with
// XDG_CONFIG_HOME and XDG_CACHE_HOME empty, which is the only way the
// StandardPaths fallback in Paths.qml:22-23 is ever executed - a source read
// cannot tell whether the scheme strip and the fallback actually produce a
// plain path.
//
// FilePresence is the opposite: one watcher per path, N observers, and a
// verdict that has to survive the file appearing and disappearing underneath
// it. It is driven against a `mktemp -d` the driver hands over in VB_FP_TMP,
// so every file the probe writes is inside a directory the driver removes, and
// every file the probe creates it removes itself.
//
// The probe runs one step per tick rather than straight out of
// Component.onCompleted: deleting a file is a Process, and a Process needs an
// event loop turn to report its exit. ##DONE## is printed from finish(), never
// from a step, so a step that throws cannot fake a finished run - it prints
// probe.error first and the driver asserts that key is absent.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.common

Item {
  id: probe
  width: 1
  height: 1

  // A value containing a newline is escaped so one KV stays one line and the
  // parser never sees a split record.
  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }

  // The temp directory the driver created. Every path this probe reads or
  // writes is inside it; nothing here ever names a path outside it.
  readonly property string tmp: String(Quickshell.env("VB_FP_TMP") ?? "")

  // env mode is the normal session; fallback mode is the launch with the two
  // XDG home variables emptied, which is what reaches StandardPaths.
  readonly property bool fallbackMode: Paths.xdgConfigHome === "" && Paths.xdgCacheHome === ""

  property var steps: []
  property int stepIndex: 0
  property int ran: 0
  property bool waitingProcess: false
  property bool finished: false

  // Deleting a file is the one mutation FileView cannot make. stdout and stderr
  // stay null on purpose: nothing reads them, and a closed channel cannot fill a
  // pipe and wedge the child.
  Process {
    id: rmProc
    running: false
  }

  // atomicWrites would replace the target with a writer-owned temp file, so the
  // probe's own file would briefly exist twice and could survive a kill.
  FileView {
    id: writer
    atomicWrites: false
    printErrors: false
  }

  Timer {
    id: ticker
    interval: 20
    repeat: true
    running: false
    onTriggered: probe.step()
  }

  Component.onCompleted: {
    buildSteps()
    ticker.running = true
  }

  // ---------------------------------------------------------------------
  // Step machine. A step that throws stops the run and reports; a Process step
  // parks the machine until the child is reaped, so a verdict is read after
  // the file is really gone and not while rm is still working on it.
  // ---------------------------------------------------------------------
  function step() {
    if (probe.finished) return
    if (probe.waitingProcess) {
      // The step index is NOT advanced here: the step that started the child
      // already consumed its own index, and the step after it is the one that
      // was waiting for the file to be gone.
      if (rmProc.running) return
      probe.waitingProcess = false
      return
    }
    if (probe.stepIndex >= probe.steps.length) {
      finish()
      return
    }
    const fn = probe.steps[probe.stepIndex]
    probe.stepIndex++
    probe.ran++
    try {
      fn()
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
      finish()
    }
  }

  function finish() {
    if (probe.finished) return
    probe.finished = true
    ticker.running = false
    kv("probe.steps.planned", probe.steps.length)
    kv("probe.steps.ran", probe.ran)
    console.log("##DONE##")
  }

  // rmPath is a step: it starts the child and parks the machine.
  function rmPath(path) {
    rmProc.command = ["rm", "-f", "--", path]
    rmProc.running = true
    probe.waitingProcess = true
  }

  function writeFile(path, text) {
    writer.path = ""
    writer.path = path
    writer.setText(text)
    return writer.waitForJob()
  }

  // under() is the containment check the whole Paths contract rests on: a
  // derived path is under its root when it is the root, a separator and at
  // least one more segment. String containment, not a fixed literal, because
  // every root is host-dependent.
  function under(root, path) {
    return String(path).indexOf(String(root) + "/") === 0
  }

  // Every path Paths derives by concatenating onto a root. The hygiene loop
  // below walks exactly this set and the driver walks the same names, so a new
  // derived property has to be added in both places to be covered.
  readonly property var derived: ({
    configHome: Paths.configHome,
    cacheHome: Paths.cacheHome,
    themesUserRoot: Paths.themesUserRoot,
    settingsFile: Paths.settingsFile,
    settingsBundlePath: Paths.settingsBundlePath,
    settingsCatalogPath: Paths.settingsCatalogPath,
    settingsSchemaDir: Paths.settingsSchemaDir,
    runtimeEnvFile: Paths.runtimeEnvFile,
    themeNameFile: Paths.themeNameFile,
    themeStateDir: Paths.themeStateDir,
    themeBackgroundsDir: Paths.themeBackgroundsDir,
    themeColorsFile: Paths.themeColorsFile,
    wallpaperStateJson: Paths.wallpaperStateJson,
    screenshotsDir: Paths.screenshotsDir,
    screenshotFallbackDir: Paths.screenshotFallbackDir,
    launcherUserPluginsDir: Paths.launcherUserPluginsDir,
    drunCacheFile: Paths.drunCacheFile,
    hyprInputFile: Paths.hyprInputFile,
    hyprAppearanceFile: Paths.hyprAppearanceFile,
    hyprAdvancedFile: Paths.hyprAdvancedFile,
    hyprSmartGapsFile: Paths.hyprSmartGapsFile,
    hyprAnimationsFile: Paths.hyprAnimationsFile
  })

  // The raw env reads. A root is whatever the session says, so the
  // no-trailing-separator rule does not apply to these; the doubled-separator
  // rule still does, because a root carrying one would double it again in every
  // path derived from it.
  readonly property var roots: ({
    home: Paths.home,
    vibraniumHome: Paths.vibraniumHome,
    xdgConfigHome: Paths.xdgConfigHome,
    xdgCacheHome: Paths.xdgCacheHome,
    vibraniumCache: Paths.vibraniumCache,
    vibraniumState: Paths.vibraniumState,
    vibraniumRuntime: Paths.vibraniumRuntime
  })

  // The roots the driver needs as values rather than as booleans: it stats the
  // catalog against settingsSchemaDir and audits the derived files by path.
  // A flat name/value block, not an assertion.
  readonly property string values: [
    "configHome", Paths.configHome,
    "cacheHome", Paths.cacheHome,
    "vibraniumHome", Paths.vibraniumHome,
    "settingsSchemaDir", Paths.settingsSchemaDir,
    "settingsBundlePath", Paths.settingsBundlePath,
    "settingsCatalogPath", Paths.settingsCatalogPath,
    "drunCacheFile", Paths.drunCacheFile,
    "runtimeEnvFile", Paths.runtimeEnvFile,
    "screenshotsDir", Paths.screenshotsDir,
    "wallpaperStateJson", Paths.wallpaperStateJson,
    "themeColorsFile", Paths.themeColorsFile
  ].join("\n")

  // Every FILE Paths derives, plus every catalog entry. The driver stats this
  // list before and after the run: a probe that wrote to the user's settings or
  // cache, or to a schema in the repo, shows up as a changed signature.
  readonly property var auditFiles: [
    Paths.settingsFile, Paths.settingsCatalogPath,
    Paths.runtimeEnvFile, Paths.themeNameFile, Paths.themeColorsFile,
    Paths.wallpaperStateJson, Paths.drunCacheFile, Paths.hyprInputFile,
    Paths.hyprAppearanceFile, Paths.hyprAdvancedFile, Paths.hyprSmartGapsFile,
    Paths.hyprAnimationsFile
  ]

  function buildSteps() {
    const pathsSteps = [
      pathsReachability,
      pathRoots,
      pathFallback,
      pathDerivation,
      separatorHygiene,
      catalogContract,
      functionContract
    ]
    if (probe.fallbackMode) {
      // The second launch exists to reach the StandardPaths branch. The
      // filesystem half would only re-observe the same temp directory, so it
      // does not run.
      probe.steps = pathsSteps.concat([fallbackSummary])
      return
    }
    probe.steps = pathsSteps.concat([
      presenceTag,
      verdictRule,
      trackContract,
      refcountContract,
      reprobeContract,
      reprobeAfterDelete,
      refreshContract,
      staleHandleContract,
      diagnosticsContract,
      validationContract,
      validationCleanup
    ])
  }

  // ---------------------------------------------------------------------
  // Paths
  // ---------------------------------------------------------------------
  function pathsReachability() {
    kv("paths.exists", typeof Paths)
    kv("fp.exists", typeof FilePresence)
    kv("probe.mode", probe.fallbackMode ? "fallback" : "env")
    kv("probe.tmpdir", probe.tmp)
    kv("paths.values", probe.values)
    kv("paths.auditFiles", probe.auditFiles.join("\n"))
  }

  // Host-dependent, so only shape is asserted: non-empty, absolute, and exactly
  // the value the session carries.
  function pathRoots() {
    kv("root.home.nonEmpty", Paths.home !== "")
    kv("root.home.absolute", Paths.home.charAt(0) === "/")
    kv("root.home.matchesEnv", Paths.home === Quickshell.env("HOME"))
    kv("root.vibraniumHome.nonEmpty", Paths.vibraniumHome !== "")
    kv("root.vibraniumHome.absolute", Paths.vibraniumHome.charAt(0) === "/")
    kv("root.vibraniumHome.matchesEnv", Paths.vibraniumHome === Quickshell.env("VIBRANIUM"))
    kv("root.vibraniumState.nonEmpty", Paths.vibraniumState !== "")
    kv("root.vibraniumState.matchesEnv", Paths.vibraniumState === Quickshell.env("VIBRANIUM_STATE"))
    kv("root.vibraniumCache.nonEmpty", Paths.vibraniumCache !== "")
    kv("root.vibraniumCache.matchesEnv", Paths.vibraniumCache === Quickshell.env("VIBRANIUM_CACHE"))
    kv("root.vibraniumRuntime.nonEmpty", Paths.vibraniumRuntime !== "")
    kv("root.vibraniumRuntime.matchesEnv", Paths.vibraniumRuntime === Quickshell.env("VIBRANIUM_RUNTIME"))
  }

  // Which branch of the ternary in Paths.qml:22-23 actually ran, and whether
  // what came back is a plain path. The two halves are mutually exclusive by
  // construction, so exactly one of each pair is true in either launch.
  function pathFallback() {
    kv("paths.xdgConfigHome.isEmpty", Paths.xdgConfigHome === "")
    kv("paths.xdgCacheHome.isEmpty", Paths.xdgCacheHome === "")
    kv("paths.configHome.usedXdgEnv", Paths.xdgConfigHome !== "" && Paths.configHome === Paths.xdgConfigHome)
    kv("paths.configHome.usedFallback", Paths.xdgConfigHome === "" && Paths.configHome !== "")
    kv("paths.cacheHome.usedXdgEnv", Paths.xdgCacheHome !== "" && Paths.cacheHome === Paths.xdgCacheHome)
    kv("paths.cacheHome.usedFallback", Paths.xdgCacheHome === "" && Paths.cacheHome !== "")
    // ConfigLocation is not application-scoped, so the platform default is the
    // XDG config home itself and the fallback lands where a bare session would.
    kv("paths.configHome.fallbackIsXdgRoot",
      Paths.configHome === Quickshell.env("XDG_CONFIG_HOME") || Paths.configHome === Paths.home + "/.config")
    // CacheLocation IS application-scoped, so the fallback is
    // $HOME/.cache/<appname>, not $XDG_CACHE_HOME. Recorded, never asserted
    // true; the driver notes the contradiction with Paths.qml:23 and :110.
    kv("paths.cacheHome.fallbackIsXdgRoot",
      Paths.cacheHome === Quickshell.env("XDG_CACHE_HOME") || Paths.cacheHome === Paths.home + "/.cache")
    kv("paths.cacheHome.fallbackValue", Paths.cacheHome)
    // The scheme strip the source comment promises must actually be applied in
    // whichever branch ran, or every path derived from these roots is a URL.
    kv("paths.configHome.noFileScheme", Paths.configHome.indexOf("file://") === -1)
    kv("paths.cacheHome.noFileScheme", Paths.cacheHome.indexOf("file://") === -1)
    kv("paths.configHome.isAbsolute", Paths.configHome.charAt(0) === "/")
    kv("paths.cacheHome.isAbsolute", Paths.cacheHome.charAt(0) === "/")
  }

  // Every derived path against the root it was derived from: containment, not
  // equality to a literal, plus the literal suffix the derivation appends -
  // that suffix is what tells a right root from a wrong one.
  function pathDerivation() {
    kv("derive.settingsFile.under", under(Paths.configHome, Paths.settingsFile))
    kv("derive.settingsFile.suffix", Paths.settingsFile === Paths.configHome + "/vibranium/settings.json")
    kv("derive.themesUserRoot.under", under(Paths.configHome, Paths.themesUserRoot))
    kv("derive.themesUserRoot.suffix", Paths.themesUserRoot === Paths.configHome + "/vibranium/themes")
    kv("derive.launcherUserPluginsDir.under", under(Paths.configHome, Paths.launcherUserPluginsDir))
    kv("derive.hyprInputFile.under", under(Paths.configHome, Paths.hyprInputFile))
    kv("derive.hyprAppearanceFile.under", under(Paths.configHome, Paths.hyprAppearanceFile))
    kv("derive.hyprAdvancedFile.under", under(Paths.configHome, Paths.hyprAdvancedFile))
    kv("derive.hyprSmartGapsFile.under", under(Paths.configHome, Paths.hyprSmartGapsFile))
    kv("derive.hyprAnimationsFile.under", under(Paths.configHome, Paths.hyprAnimationsFile))
    kv("derive.hyprFiles.sharedDir", [Paths.hyprInputFile, Paths.hyprAppearanceFile, Paths.hyprAdvancedFile,
      Paths.hyprSmartGapsFile, Paths.hyprAnimationsFile].every(p => p.indexOf("/hyprland.conf.d/") > 0))

    kv("derive.settingsSchemaDir.under", under(Paths.vibraniumHome, Paths.settingsSchemaDir))
    kv("derive.settingsSchemaDir.suffix", Paths.settingsSchemaDir === Paths.vibraniumHome + "/shell/common/settings")
    // The bundle path is the unified catalog: the menu opens it to mean
    // "the settings pages" (bare) or a menu page (#main, #utilities), and
    // the menu renders the live bundle rather than the file's text.
    kv("derive.settingsBundlePath.under", under(Paths.vibraniumHome, Paths.settingsBundlePath))
    kv("derive.settingsBundlePath.suffix", Paths.settingsBundlePath === Paths.vibraniumHome + "/shell/common/settings/catalog.jsonc")
    kv("derive.settingsBundlePath.underSettingsDir", Paths.settingsBundlePath.indexOf("/shell/common/settings/") > 0)
    kv("derive.settingsBundlePath.isTheCatalog", Paths.settingsBundlePath === Paths.settingsSchemaDir + "/catalog.jsonc")
    kv("derive.settingsCatalogPath.under", under(Paths.vibraniumHome, Paths.settingsCatalogPath))
    kv("derive.settingsCatalogPath.suffix", Paths.settingsCatalogPath === Paths.vibraniumHome + "/shell/common/settings/catalog.jsonc")
    kv("derive.settingsCatalogPath.equalsBundle", Paths.settingsCatalogPath === Paths.settingsBundlePath)

    kv("derive.runtimeEnvFile.under", under(Paths.vibraniumRuntime, Paths.runtimeEnvFile))
    kv("derive.runtimeEnvFile.suffix", Paths.runtimeEnvFile === Paths.vibraniumRuntime + "/settings.env")
    kv("derive.themeNameFile.under", under(Paths.vibraniumState, Paths.themeNameFile))
    kv("derive.themeNameFile.suffix", Paths.themeNameFile === Paths.vibraniumState + "/theme.name")
    kv("derive.themeStateDir.under", under(Paths.vibraniumState, Paths.themeStateDir))
    kv("derive.wallpaperStateJson.under", under(Paths.vibraniumState, Paths.wallpaperStateJson))
    // wallpaper.json is deliberately outside the theme payload, or an atomic
    // theme swap would take per-theme memory with it.
    kv("derive.wallpaperStateJson.outsideTheme", Paths.wallpaperStateJson.indexOf(Paths.themeStateDir) !== 0)
    kv("derive.themeBackgroundsDir.under", under(Paths.themeStateDir, Paths.themeBackgroundsDir))
    kv("derive.themeBackgroundsDir.suffix", Paths.themeBackgroundsDir === Paths.themeStateDir + "/backgrounds")
    kv("derive.themeColorsFile.under", under(Paths.themeStateDir, Paths.themeColorsFile))
    kv("derive.themeColorsFile.suffix", Paths.themeColorsFile === Paths.themeStateDir + "/qs.json")

    // cacheHome is the cache root; drunCacheFile is the one cache path derived
    // from it rather than from $VIBRANIUM_CACHE.
    kv("derive.drunCacheFile.under", under(Paths.cacheHome, Paths.drunCacheFile))
    kv("derive.drunCacheFile.suffix", Paths.drunCacheFile === Paths.cacheHome + "/vibranium/druncache.json")
    kv("derive.screenshotFallbackDir.under", under(Paths.vibraniumCache, Paths.screenshotFallbackDir))
    kv("derive.screenshotFallbackDir.suffix", Paths.screenshotFallbackDir === Paths.vibraniumCache + "/screenshot-clipboard-fallbacks")

    // screenshotsDir follows XDG_PICTURES_DIR when the session sets it and $HOME
    // when it does not, which is the choice the bash screenshot tool makes.
    const pictures = Quickshell.env("XDG_PICTURES_DIR")
    const picturesRoot = (pictures !== null && pictures !== "") ? String(pictures) : Paths.home
    kv("derive.screenshotsDir.under", under(picturesRoot, Paths.screenshotsDir))
    kv("derive.screenshotsDir.suffix", Paths.screenshotsDir === picturesRoot + "/Screenshots")
    kv("derive.screenshotsDir.picturesRoot", picturesRoot)
  }

  // The classic string-concatenation bug: a doubled or a trailing separator in a
  // derived path. One KV per property, so a failure names the property.
  function separatorHygiene() {
    for (const name in probe.derived) {
      const p = String(probe.derived[name])
      kv("sep." + name + ".noDoubleSlash", p.indexOf("//") === -1)
      kv("sep." + name + ".noTrailingSlash", p.length > 0 && p.charAt(p.length - 1) !== "/")
      kv("sep." + name + ".absolute", p.charAt(0) === "/")
    }
    for (const name in probe.roots) {
      const p = String(probe.roots[name])
      kv("root." + name + ".nonEmpty", p !== "")
      kv("root." + name + ".absolute", p.charAt(0) === "/")
      kv("sep." + name + ".noDoubleSlash", p.indexOf("//") === -1)
    }
  }

  // The catalog is the one place in Paths where a name can silently go
  // stale. A single unified file leaves no per-page name to go stale -
  // the probe checks the shape: one jsonc file under the schema dir.
  function catalogContract() {
    const file = Paths.settingsCatalogPath
    kv("catalog.count", 1)
    kv("catalog.nonEmpty", file !== "")
    kv("catalog.underSchemaDir", under(Paths.settingsSchemaDir, file))
    kv("catalog.isJsonc", file.slice(-6) === ".jsonc")
    kv("catalog.named", file.length > file.lastIndexOf("/") + 1)
    kv("catalog.equalsBundle", file === Paths.settingsBundlePath)
    show("catalog.files", [file])
  }

  // The three functions. userThemesDir is the base the theme pickers compose
  // from; userBackgroundsDir composes on top of it; toFileUrl is the only way
  // the shell hands a path to Image.source, so its encoding is a contract.
  function functionContract() {
    const theme = "gruvbox-dark"
    kv("fn.userThemesDir.underRoot", under(Paths.themesUserRoot, Paths.userThemesDir(theme)))
    kv("fn.userThemesDir.suffix", Paths.userThemesDir(theme) === Paths.themesUserRoot + "/" + theme)
    kv("fn.userThemesDir.absolute", Paths.userThemesDir(theme).charAt(0) === "/")
    kv("fn.userThemesDir.noDoubleSlash", Paths.userThemesDir(theme).indexOf("//") === -1)
    // An empty theme name is not rejected, it concatenates. Recorded so the
    // shape is visible from the suite and not only from the source.
    kv("fn.userThemesDir.emptyThemeTrailingSlash", Paths.userThemesDir("").slice(-1) === "/")

    kv("fn.userBackgroundsDir.suffix", Paths.userBackgroundsDir(theme) === Paths.userThemesDir(theme) + "/backgrounds")
    kv("fn.userBackgroundsDir.underUserThemes", under(Paths.userThemesDir(theme), Paths.userBackgroundsDir(theme)))
    kv("fn.userBackgroundsDir.absolute", Paths.userBackgroundsDir(theme).charAt(0) === "/")

    kv("fn.toFileUrl.encodes", Paths.toFileUrl("/tmp/a b/c#d.png") === "file:///tmp/a%20b/c%23d.png")
    kv("fn.toFileUrl.noRawSpace", Paths.toFileUrl("/tmp/a b.png").indexOf(" ") === -1)
    kv("fn.toFileUrl.unicode", Paths.toFileUrl("/x/\u00e9\u4e2d.png") === "file:///x/%C3%A9%E4%B8%AD.png")
    kv("fn.toFileUrl.empty", Paths.toFileUrl("") === "file://")
    kv("fn.toFileUrl.null", Paths.toFileUrl(null) === "file://")
    kv("fn.toFileUrl.undefined", Paths.toFileUrl(undefined) === "file://")
    kv("fn.toFileUrl.dropsEmptySegments", Paths.toFileUrl("/a/b/") === "file:///a/b")
    kv("fn.toFileUrl.dropsDoubledSeparator", Paths.toFileUrl("/a//b") === "file:///a/b")
    // Round trip: what Image.source is handed has to name the file the path
    // named, or the wallpaper resolves to nothing with no error.
    kv("fn.toFileUrl.roundTrips", decodeFileUrl(Paths.toFileUrl(Paths.settingsFile)) === Paths.settingsFile)
    kv("fn.toFileUrl.roundTripsSpaces",
      decodeFileUrl(Paths.toFileUrl(Paths.screenshotsDir + "/shot 1.png")) === Paths.screenshotsDir + "/shot 1.png")
  }

  function decodeFileUrl(url) {
    const parts = String(url).slice("file://".length).split("/")
    let out = ""
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === "") continue
      out += "/" + decodeURIComponent(parts[i])
    }
    return out
  }

  // ---------------------------------------------------------------------
  // FilePresence
  // ---------------------------------------------------------------------
  readonly property string presentPath: probe.tmp + "/present.txt"
  readonly property string absentPath: probe.tmp + "/absent.txt"
  readonly property string emptyPath: probe.tmp + "/empty.txt"
  readonly property string peersPath: probe.tmp + "/peers.txt"
  readonly property string refcountPath: probe.tmp + "/refcount.txt"
  readonly property string stalePath: probe.tmp + "/stale.txt"
  readonly property string spacedPath: probe.tmp + "/a b.txt"
  readonly property string longPath: probe.tmp + "/" + "x".repeat(200) + ".txt"
  readonly property string latePath: probe.tmp + "/late.txt"

  // Every path this probe opens, watches or writes. The driver checks each one
  // is under the directory it handed over, which is the machine-checked form of
  // "the probe wrote nothing outside its temp dir".
  readonly property var tempIoPaths: [
    probe.presentPath, probe.absentPath, probe.emptyPath, probe.peersPath,
    probe.refcountPath, probe.stalePath, probe.spacedPath, probe.longPath,
    probe.latePath, probe.tmp + "/never-existed", probe.tmp
  ]

  property var hPresent: null
  property var hAbsent: null
  property var hEmpty: null
  property var hDir: null
  property var hLate: null
  property int revisionBeforeDelete: 0
  property var live: []

  function keep(handle) {
    probe.live.push(handle)
    return handle
  }

  function dropAll() {
    let all = true
    for (let i = 0; i < probe.live.length; i++) {
      // A handle released by its own section answers false here; only a handle
      // that was never released counts as a leak.
      if (FilePresence.diagnostics()[String(probe.live[i].path)] !== undefined) {
        FilePresence.release(probe.live[i])
      }
    }
    probe.live = []
    all = Object.keys(FilePresence.diagnostics()).length === 0
    return all
  }

  // The shell names this singleton by its tag, so the tag is a wire value, not
  // a label. Every tagged singleton in the shell spells it lowerCamelCase.
  function presenceTag() {
    kv("fp.tag", FilePresence.tag)
    kv("fp.tag.isString", typeof FilePresence.tag === "string")
    kv("fp.tag.nonEmpty", FilePresence.tag !== "")
    kv("fp.tag.camelCase", /^[a-z][A-Za-z0-9]*$/.test(FilePresence.tag))
    kv("fp.tag.noPathChars", FilePresence.tag.indexOf("/") === -1)
    kv("fp.rev.isNumber", typeof FilePresence.rev === "number")
    kv("fp.rev.start", FilePresence.rev)
    kv("fp.entries.isObject", typeof FilePresence._entries === "object")
    kv("fp.entries.startsEmpty", Object.keys(FilePresence._entries).length === 0)
    kv("fp.diag.isFunction", typeof FilePresence.diagnostics === "function")
    kv("fp.trackedPathCount.start", Object.keys(FilePresence._entries).length)
  }

  // The rule, exercised with no filesystem at all. ok is whether the read cycle
  // completed and text is what it produced: a read that did not complete is
  // inactive, never active, and only completed non-empty content is present.
  function verdictRule() {
    kv("verdict.okTrue.nonEmpty", FilePresence.verdict(true, "x") === true)
    kv("verdict.okTrue.padded", FilePresence.verdict(true, "  a  ") === true)
    kv("verdict.okTrue.utf8", FilePresence.verdict(true, "\u00e9\u4e2d") === true)
    kv("verdict.okTrue.empty", FilePresence.verdict(true, "") === false)
    kv("verdict.okTrue.whitespace", FilePresence.verdict(true, "  \n\t ") === false)
    kv("verdict.okTrue.newlineOnly", FilePresence.verdict(true, "\n") === false)
    kv("verdict.okFalse.nonEmpty", FilePresence.verdict(false, "x") === false)
    kv("verdict.okFalse.empty", FilePresence.verdict(false, "") === false)
    // ok must be the boolean true, not merely truthy: a read cycle that
    // reported 1 has not completed.
    kv("verdict.ok.isOne", FilePresence.verdict(1, "x") === false)
    kv("verdict.ok.isStringTrue", FilePresence.verdict("true", "x") === false)
    kv("verdict.ok.isNull", FilePresence.verdict(null, "x") === false)
    kv("verdict.ok.isUndefined", FilePresence.verdict(undefined, "x") === false)
    kv("verdict.ok.isObject", FilePresence.verdict({}, "x") === false)
    kv("verdict.ok.missing", FilePresence.verdict() === false)
    // A non-string text is not text, whatever the load claimed.
    kv("verdict.text.isNull", FilePresence.verdict(true, null) === false)
    kv("verdict.text.isUndefined", FilePresence.verdict(true, undefined) === false)
    kv("verdict.text.isNumber", FilePresence.verdict(true, 5) === false)
    kv("verdict.text.isArray", FilePresence.verdict(true, ["a"]) === false)
    kv("verdict.text.isObject", FilePresence.verdict(true, {}) === false)
    kv("verdict.returnsBool.true", typeof FilePresence.verdict(true, "x") === "boolean")
    kv("verdict.returnsBool.false", typeof FilePresence.verdict(false, "x") === "boolean")
  }

  // The core: an existing non-empty file is present, a missing one is not, and
  // an existing but EMPTY one is not either - absence is read from the trimmed
  // text, not from the load's success flag.
  function trackContract() {
    probe.hPresent = keep(FilePresence.track("probe-a", probe.presentPath))
    kv("track.present.isObject", probe.hPresent !== null && typeof probe.hPresent === "object")
    kv("track.present.present", probe.hPresent.present === true)
    kv("track.present.owner", probe.hPresent.owner === "probe-a")
    kv("track.present.path", probe.hPresent.path === probe.presentPath)
    kv("track.present.revisionIsNumber", typeof probe.hPresent.revision === "number")
    kv("track.present.revisionAtLeastOne", probe.hPresent.revision >= 1)

    probe.hAbsent = keep(FilePresence.track("probe-a", probe.absentPath))
    kv("track.absent.isObject", probe.hAbsent !== null && typeof probe.hAbsent === "object")
    kv("track.absent.present", probe.hAbsent.present === false)
    kv("track.absent.revisionIsZero", probe.hAbsent.revision === 0)

    probe.hEmpty = keep(FilePresence.track("probe-a", probe.emptyPath))
    kv("track.empty.isObject", probe.hEmpty !== null)
    kv("track.empty.present", probe.hEmpty.present === false)
    kv("track.empty.revisionIsZero", probe.hEmpty.revision === 0)

    // A directory is a path the tracker accepts and reports inactive: not a
    // throw, and not a null handle.
    probe.hDir = keep(FilePresence.track("probe-a", probe.tmp))
    kv("track.directory.isObject", probe.hDir !== null)
    kv("track.directory.present", probe.hDir.present === false)
    kv("track.directory.diag", FilePresence.diagnostics()[probe.tmp].present)
  }

  // The count follows the path, not the consumer: two owners of one path share
  // one watcher and one prober, and the path stops being tracked only when the
  // last of them lets go.
  function refcountContract() {
    const a = FilePresence.track("owner-one", probe.refcountPath)
    const b = FilePresence.track("owner-two", probe.refcountPath)
    keep(a)
    keep(b)
    kv("refcount.handlesDistinct", a !== b)
    kv("refcount.ownersDistinct", a.owner !== b.owner)
    const diag = FilePresence.diagnostics()[probe.refcountPath]
    kv("refcount.diag.watchers", diag.watchers)
    kv("refcount.diag.probes", diag.probes)
    kv("refcount.diag.observers", diag.observers)
    kv("refcount.diag.present", diag.present)
    kv("refcount.oneWatcherForTwo", diag.watchers === 1 && diag.probes === 1 && diag.observers === 2)
    kv("refcount.bothHandlesPresent", a.present === true && b.present === true)

    kv("refcount.release.first", FilePresence.release(b))
    const afterOne = FilePresence.diagnostics()[probe.refcountPath]
    kv("refcount.afterOne.observers", afterOne.observers)
    kv("refcount.afterOne.watchers", afterOne.watchers)
    kv("refcount.afterOne.stillPresent", afterOne.present)
    // The released handle keeps the verdict it was last handed; only the
    // observer count moves. A released handle is not a promise, so nothing
    // reads it - but it must not read as a flipped verdict either.
    kv("refcount.afterOne.releasedHandleVerdict", b.present)
    kv("refcount.afterOne.holderStillPresent", a.present === true)

    kv("refcount.release.second", FilePresence.release(a))
    kv("refcount.afterTwo.entryGone", FilePresence.diagnostics()[probe.refcountPath] === undefined)
    kv("refcount.doubleRelease", FilePresence.release(a))
    kv("refcount.release.nonHandle", FilePresence.release({}))
    kv("refcount.release.null", FilePresence.release(null))
    kv("refcount.release.undefined", FilePresence.release(undefined))

    // Track and release the same path repeatedly: the count has to return to
    // where it started and no watcher may be left behind.
    const base = FilePresence.diagnostics()[probe.absentPath].observers
    let cycled = true
    for (let i = 0; i < 5; i++) {
      const h = FilePresence.track("cycle-" + i, probe.absentPath)
      if (h === null) { cycled = false; break }
      if (FilePresence.diagnostics()[probe.absentPath].observers !== base + 1) cycled = false
      if (FilePresence.release(h) !== true) cycled = false
      if (FilePresence.diagnostics()[probe.absentPath].observers !== base) cycled = false
    }
    kv("refcount.cycle.allClean", cycled)
    kv("refcount.cycle.backToBase", FilePresence.diagnostics()[probe.absentPath].observers === base)
    kv("refcount.cycle.oneWatcherStill", FilePresence.diagnostics()[probe.absentPath].watchers === 1)
  }

  // The purpose of the type: a tracked path that gains and then loses its
  // content.
  //
  // The write and the re-read happen inside one tick, before the watcher can be
  // delivered an event, so reprobe's own return value is deterministic here.
  // The delete cannot be: the rm needs event loop turns, and the watcher will
  // have published the same verdict by then. So the delete direction is
  // asserted on the verdict, on the revision having advanced, and on reprobe
  // being settled afterwards.
  //
  // A file that is present and is then emptied in place is the same shape of
  // transition, but it is already covered as a first-class case by track.empty
  // (an existing, successfully loaded, zero-byte file reads absent) and by the
  // pure verdict() cases, so only one flip is driven through reprobe here.
  function reprobeContract() {
    probe.hLate = keep(FilePresence.track("probe-late", probe.latePath))
    kv("reprobe.trackedAbsent", probe.hLate.present === false)
    kv("reprobe.initialRevision", probe.hLate.revision)

    kv("reprobe.writeOk", writeFile(probe.latePath, "late content\n"))
    const before = probe.hLate.revision
    kv("reprobe.create.returned", FilePresence.reprobe(probe.latePath))
    kv("reprobe.create.present", probe.hLate.present === true)
    kv("reprobe.create.revisionAdvanced", probe.hLate.revision > before)
    kv("reprobe.create.idempotent", FilePresence.reprobe(probe.latePath))
    kv("reprobe.create.stillPresent", probe.hLate.present === true)
    kv("reprobe.create.diagPresent", FilePresence.diagnostics()[probe.latePath].present)

    probe.revisionBeforeDelete = probe.hLate.revision
    rmPath(probe.latePath)
  }

  function reprobeAfterDelete() {
    FilePresence.reprobe(probe.latePath)
    kv("reprobe.delete.present", probe.hLate.present === false)
    kv("reprobe.delete.revisionAdvanced", probe.hLate.revision > probe.revisionBeforeDelete)
    kv("reprobe.delete.diagPresent", FilePresence.diagnostics()[probe.latePath].present)
    kv("reprobe.delete.settled", FilePresence.reprobe(probe.latePath))
    kv("reprobe.delete.stillAbsent", probe.hLate.present === false)
    kv("reprobe.unknownPath", FilePresence.reprobe(probe.tmp + "/never-existed"))
    kv("reprobe.emptyPath", FilePresence.reprobe(""))
    kv("reprobe.nullPath", FilePresence.reprobe(null))
    kv("reprobe.numberPath", FilePresence.reprobe(7))
    kv("reprobe.undefinedPath", FilePresence.reprobe(undefined))
    FilePresence.release(probe.hLate)
  }

  // refresh() answers the verdict that a read produced; reprobe() answers
  // whether the verdict moved. Each has to do what its name says.
  function refreshContract() {
    const present = keep(FilePresence.track("probe-refresh", probe.presentPath))
    kv("refresh.present", FilePresence.refresh(present))
    kv("refresh.present.stillPresent", present.present === true)
    kv("refresh.absent", FilePresence.refresh(probe.hAbsent))
    kv("refresh.absent.stillAbsent", probe.hAbsent.present === false)
    kv("refresh.null", FilePresence.refresh(null))
    kv("refresh.undefined", FilePresence.refresh(undefined))

    // Two observers of one path follow the same verdict: the fast path is
    // path-scoped, not handle-scoped.
    const a = keep(FilePresence.track("peer-a", probe.peersPath))
    const b = keep(FilePresence.track("peer-b", probe.peersPath))
    kv("refresh.peers.startEqual", a.present === b.present)
    kv("refresh.peers.startPresent", a.present)
    kv("refresh.peers.diagObservers", FilePresence.diagnostics()[probe.peersPath].observers)
    kv("refresh.peers.diagWatchers", FilePresence.diagnostics()[probe.peersPath].watchers)
    writeFile(probe.peersPath, "now it has content\n")
    kv("refresh.peerA.afterFill", FilePresence.refresh(a))
    kv("refresh.peers.agreeAfter", a.present === b.present && a.present === true)
    kv("refresh.peers.revisionsAgree", a.revision === b.revision)
    kv("refresh.peers.releasedBoth", FilePresence.release(a) && FilePresence.release(b))
    kv("refresh.peers.entryGone", FilePresence.diagnostics()[probe.peersPath] === undefined)
  }

  // A released handle is stale: refresh has to answer false rather than throw or
  // resurrect the entry it used to point at.
  function staleHandleContract() {
    const stale = keep(FilePresence.track("probe-stale", probe.stalePath))
    kv("refresh.stale.beforeRelease", FilePresence.refresh(stale))
    kv("refresh.stale.release", FilePresence.release(stale))
    kv("refresh.stale.afterRelease", FilePresence.refresh(stale))
    kv("refresh.stale.entryGone", FilePresence.diagnostics()[probe.stalePath] === undefined)
  }

  // diagnostics() is a stable key set, because a consumer reads these fields by
  // name and a renamed key reads as undefined rather than as an error.
  function diagnosticsContract() {
    const all = FilePresence.diagnostics()
    const keys = Object.keys(all).sort()
    kv("diag.trackedPaths", keys.length)
    const entry = all[probe.presentPath]
    kv("diag.keySet", Object.keys(entry).sort().join(","))
    kv("diag.entryFields", ["watchers", "probes", "observers", "present", "revision"].every(k => k in entry))
    kv("diag.isObject", typeof all === "object")
    kv("diag.isStableAcrossCalls", JSON.stringify(all) === JSON.stringify(FilePresence.diagnostics()))
    kv("diag.valueTypes", typeof entry.watchers === "number" && typeof entry.probes === "number"
      && typeof entry.observers === "number" && typeof entry.present === "boolean"
      && typeof entry.revision === "number")
    kv("diag.observersMatch", entry.observers === FilePresence._entries[probe.presentPath].handles.length)
    show("diag.presentPath", entry)
  }

  // Every argument shape the contract names, asserted to answer rather than
  // throw. A throw lands in probe.error, which the driver requires to be absent,
  // so "none of them throw" is enforced by the driver as a whole.
  function validationContract() {
    const observersBefore = FilePresence.diagnostics()[probe.presentPath].observers
    kv("validate.blankOwner", FilePresence.track("", probe.presentPath))
    kv("validate.nullOwner", FilePresence.track(null, probe.presentPath))
    kv("validate.numberOwner", FilePresence.track(7, probe.presentPath))
    kv("validate.objectOwner", FilePresence.track({}, probe.presentPath))
    kv("validate.nullPath", FilePresence.track("probe-a", null))
    kv("validate.emptyPath", FilePresence.track("probe-a", ""))
    kv("validate.numberPath", FilePresence.track("probe-a", 7))
    kv("validate.undefinedPath", FilePresence.track("probe-a", undefined))
    kv("validate.noArgs", FilePresence.track())
    kv("validate.rejectsLeftNoObservation",
      FilePresence.diagnostics()[probe.presentPath].observers === observersBefore)

    // A path with a space is a legal path, not a broken one.
    const spaced = keep(FilePresence.track("probe-a", probe.spacedPath))
    kv("validate.spacedPath.tracked", spaced !== null)
    kv("validate.spacedPath.present", spaced.present === false)
    kv("validate.spacedPath.diag", FilePresence.diagnostics()[probe.spacedPath].present)
    kv("validate.spacedPath.released", FilePresence.release(spaced))
    kv("validate.spacedPath.entryGone", FilePresence.diagnostics()[probe.spacedPath] === undefined)

    // A 200-character basename is legal, and still not a throw.
    const long = keep(FilePresence.track("probe-a", probe.longPath))
    kv("validate.longPath.tracked", long !== null)
    kv("validate.longPath.present", long.present === false)
    kv("validate.longPath.diag", FilePresence.diagnostics()[probe.longPath].present)
    kv("validate.longPath.released", FilePresence.release(long))
    kv("validate.longPath.entryGone", FilePresence.diagnostics()[probe.longPath] === undefined)
  }

  function validationCleanup() {
    // The probe's own file has to be gone before the run reports, or the driver
    // would be asserting a cleanup the probe did not perform.
    const verify = keep(FilePresence.track("probe-late-verify", probe.latePath))
    kv("cleanup.lateFileRemoved", verify.present === false)
    kv("cleanup.lateHandleReleased", FilePresence.release(verify))
    kv("cleanup.everyHandleReleased", dropAll())
    kv("cleanup.noTrackedPaths", Object.keys(FilePresence.diagnostics()).length)
    kv("cleanup.entriesEmpty", Object.keys(FilePresence._entries).length)
    kv("cleanup.revAdvanced", FilePresence.rev > 0)
    kv("cleanup.tmpdir", probe.tmp)
    kv("fp.pathsUsed", probe.tempIoPaths.join("\n"))
  }

  // The fallback launch stops here: it has no filesystem work to do.
  function fallbackSummary() {
    kv("fp.summary.skipped", "fallback launch")
  }
}
