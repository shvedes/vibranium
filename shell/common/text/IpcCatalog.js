// The single public description of the shell IPC surface.
//
// This is a `.pragma library`: everything below is plain data or a function
// that returns plain data. No Qt, no QML object references, no closures in the
// records. Python never sees an object from here - it asks the router for
// canonical descriptors over the wire.
//
// Adding a feature target in a later batch is a localized edit: append one
// `target(...)` record to `targets`, and (when the target needs intermediate
// help) add its `branches` entries. Nothing else in the module has to change.
// Native functions absent from this table are deliberately not published.
.pragma library

// --- record builders -------------------------------------------------------
// Each builder returns a fresh, ordinary object. The records are the public
// contract; the builders are only a way to keep the table readable.
function arg(name, type, extra) {
  var a = { name: name, type: type }
  if (extra) {
    var keys = Object.keys(extra)
    for (var i = 0; i < keys.length; i++) a[keys[i]] = extra[keys[i]]
  }
  return a
}

function opt(words) { return { optional: words } }
// An unordered, optional set of literal keywords. The matcher consumes any
// run of them in any order and publishes the concrete spellings as
// `args.flags`.
function flags(words) { return { flags: words } }
function rep(name, type, extra) {
  var a = arg(name, type, extra)
  a.repeat = true
  return a
}

// A row is {id, words, summary, arguments, options, output, notes, examples,
// route}. Compat rows also carry a fixed `reply` adapter descriptor.
function row(id, words, summary, extra) {
  var r = {
    id: id,
    words: words,
    summary: summary,
    arguments: [],
    options: [],
    output: { kind: "none", summary: "" },
    notes: [],
    examples: [],
    route: "gateway"
  }
  var i, w
  for (i = 0; i < words.length; i++) {
    w = words[i]
    if (typeof w === "object" && w !== null && typeof w.name === "string") r.arguments.push(w)
    else if (typeof w === "object" && w !== null && w.optional) {
      r.options = r.options.concat(w.optional)
    }
  }
  if (extra) {
    var keys = Object.keys(extra)
    for (i = 0; i < keys.length; i++) r[keys[i]] = extra[keys[i]]
  }
  return r
}

function target(id, title, summary, rows, branches, extra) {
  var t = {
    id: id,
    title: title,
    summary: summary,
    rows: rows,
    branches: branches || {}
  }
  if (extra) {
    var keys = Object.keys(extra)
    for (var i = 0; i < keys.length; i++) t[keys[i]] = extra[keys[i]]
  }
  return t
}

// Short row constructors for the retained surface. `out` is an output record;
// `reply` is the compat adapter described in 01A.
function gateway(id, words, summary, extra) {
  return row(id, words, summary, extra)
}
function query(id, words, summary, out, adapter, extra) {
  var e = { output: out, route: "compat", reply: { kind: adapter } }
  if (adapter === "settings-get") e.reply = { kind: "json", rejectErrorField: true }
  if (extra) {
    var keys = Object.keys(extra)
    for (var i = 0; i < keys.length; i++) e[keys[i]] = extra[keys[i]]
  }
  return row(id, words, summary, e)
}
function action(id, words, summary, extra) {
  // An order has no result to print: success is the exit status. Rows that
  // really return a projection use query(), not action().
  var e = { output: { kind: "none", summary: "" }, route: "compat", reply: { kind: "action" } }
  if (extra) {
    var keys = Object.keys(extra)
    for (var i = 0; i < keys.length; i++) e[keys[i]] = extra[keys[i]]
  }
  return row(id, words, summary, e)
}

// The verbs injected once into every target by the router. They are listed in
// the catalog so help and validation see one surface; their `route` marks them
// as router-owned rather than owner-supplied closures.
function commonRows() {
  return [
    row("help", ["help", opt([arg("path", "ref", { repeat: true })])],
      "Describe this target, a branch, or a command", {
        output: { kind: "record", summary: "Canonical descriptor" },
        notes: ["'help' is available before and after the target name"],
        examples: ["vb-shell TARGET help"],
        route: "injected"
      }),
    row("status", ["status"],
      "Show the target's current status", {
        output: { kind: "text", summary: "" },
        notes: [],
        examples: ["vb-shell TARGET status"],
        route: "injected"
      }),
    row("ping", ["ping"],
      "Check that the target responds", {
        output: { kind: "text", summary: "`pong` while the owner is resident" },
        notes: [],
        examples: ["vb-shell TARGET ping"],
        route: "injected"
      })
  ]
}

// The complete, case-sensitive suffix vocabulary for `bar module <MODULE> opt`.
// Declaring it as an enum is what keeps the fixed `opt list` branch ahead of
// `opt <KEY>` in the router: `list` is not a valid key, so the generic row
// cannot capture it. The owner still rejects keys that are not in the table
// for the specific module.
var IPC_OPTION_KEYS = [
  "RightClick", "MiddleClick", "LeftClick", "Percent", "Title", "Flash",
  "ShowMic", "MicRightClick", "MicMiddleClick", "Seconds", "SecondsTooltip",
  "FullDate", "MoonPhase", "ShowTemp", "Unit", "RefreshMinutes", "Verbose",
  "HeavyWarning", "Temperature", "Elapsed"
]

// --- the retained surface --------------------------------------------------
// These are the only native targets published in batch A. The rows mirror the
// literal UnitIpc help descriptions of the installed handlers; summaries that
// were inaccurate in those blocks are corrected here.

var targets = [
  target("shell", "Shell", "Inspect the shell and run diagnostics", [
    query("shell.doctor", ["doctor"], "Show boot audit warnings as JSON",
      { kind: "table", summary: "Audit warnings", columns: [{ key: "warning", heading: "Warning" }] }, "json")
  ], {}),

  target("boot", "Boot", "Inspect startup and unit lifecycle", [
    query("boot.state", ["state"], "Show the current unit lifecycle state as JSON",
      { kind: "value", summary: "Lifecycle snapshot" }, "json"),
    query("boot.timeline", ["timeline"], "Show the startup event timeline as JSON",
      { kind: "value", summary: "Event timeline" }, "json")
  ], {}),

  target("log", "Log", "Read the shell diagnostic log", [], {}),

  target("keybindings", "Keybindings", "View Hyprland keybindings", [
    action("keybindings.open", ["open"], "Show the cheatsheet"),
    action("keybindings.close", ["close"], "Hide the cheatsheet"),
    action("keybindings.toggle", ["toggle"], "Toggle the cheatsheet"),
    action("keybindings.refresh", ["refresh"], "Rescan Hyprland keybindings")
  ], {}),

  target("settings", "Settings", "Read and write shell settings", [
    query("settings.get", ["get", arg("key", "string")], "Read one stored value as JSON",
      { kind: "value", summary: "Stored value" }, "settings-get"),
    query("settings.dump", ["dump"], "Show all stored values as JSON",
      { kind: "value", summary: "Store dump" }, "json"),
    action("settings.set", ["set", arg("key", "string"),
      arg("json", "json", { summary: "One JSON value of any type, e.g. `true` or `\"text\"`. Pass as one quoted argv token" })],
      "Write one JSON value", {
        notes: ["The token is one parsed JSON value; quote a JSON string so it stays data"],
        examples: ["vb-shell settings set demo.key '\"text\"'"]
      }),
    action("settings.toggle", ["toggle", arg("key", "string")], "Flip a boolean key"),
    action("settings.reload", ["reload"], "Reload settings from disk"),
    action("settings.fonts.reload", ["fonts", "reload"], "Rescan installed system fonts", {
      parentHidden: true,
      route: "gateway",
      reply: { kind: "none" },
      output: { kind: "none", summary: "" },
      notes: ["Bridges to the resident font picker; it does not change the stored font"],
      examples: ["vb-shell settings fonts reload"]
    }),
    gateway("settings.fonts", ["fonts", opt([arg("ACTION", "ref")])],
      "Manage installed system fonts", {
        helpOnly: true,
        notes: ["The only action is 'reload'; it rescans installed fonts without changing the stored font"],
        examples: ["vb-shell settings fonts reload", "vb-shell settings fonts help"]
      })
  ], {
    fonts: {
      summary: "Manage installed system fonts",
      notes: ["'reload' rescans installed fonts; it does not change the stored font"],
      examples: ["vb-shell settings fonts reload"],
      commands: ["settings.fonts.reload"]
    }
  }),

  target("systemFont", "System font", "Read the system font configuration", [
    query("systemFont.dump", ["dump"], "Show the current font configuration as JSON",
      { kind: "record", summary: "Font configuration" }, "json")
  ], {}),

  target("state", "State", "Vibranium shell state & runtime queries", [
    query("state.get", ["get", arg("slot", "string")], "Read one slot as JSON",
      { kind: "value", summary: "Slot value" }, "json"),
    action("state.set", ["set", arg("slot", "string"),
      arg("json", "json", { summary: "One JSON value for the slot, e.g. `false` or a JSON object. Pass as one quoted argv token" })],
      "Write one JSON slot", {
        notes: ["The token is parsed once; a JSON string needs its own quotes inside the argv quotes"],
        examples: ["vb-shell state set demo.slot '{\"count\":1}'"]
      }),
    query("state.dump", ["dump"], "Show all slots as JSON",
      { kind: "value", summary: "Slot dump" }, "json")
  ], {}),

  target("watch", "Watch", "Watch files that drive the shell", [], {}),

  target("notifications", "Notifications", "Manage desktop notifications", [
    action("notifications.dnd.enable", ["dnd", "enable"], "Turn do-not-disturb on", {
      parentHidden: true,
      examples: ["vb-shell notifications dnd enable"]
    }),
    action("notifications.dnd.disable", ["dnd", "disable"], "Turn do-not-disturb off", {
      parentHidden: true,
      examples: ["vb-shell notifications dnd disable"]
    }),
    action("notifications.dnd.toggle", ["dnd", "toggle"], "Flip do-not-disturb", {
      parentHidden: true,
      examples: ["vb-shell notifications dnd toggle"]
    }),
    query("notifications.dnd.get", ["dnd", "get"], "Show do-not-disturb state",
      { kind: "text", summary: "`on` or `off`, including forced DND" }, "text", {
        parentHidden: true,
        examples: ["vb-shell notifications dnd get"]
      }),
    gateway("notifications.dnd", ["dnd"], "Enable, disable, toggle or read do-not-disturb", {
      helpOnly: true,
      examples: ["vb-shell notifications dnd enable", "vb-shell notifications dnd toggle",
        "vb-shell notifications dnd get"]
    }),
    query("notifications.history", ["history"], "Show notification history",
      { kind: "value", summary: "History entries" }, "json"),
    action("notifications.clear", ["clear"], "Clear this session's history"),
    action("notifications.dismiss.visible", ["dismiss", "visible"],
      "Dismiss visible notifications", {
        parentHidden: true,
        examples: ["vb-shell notifications dismiss visible"]
      }),
    action("notifications.dismiss.all", ["dismiss", "all"],
      "Dismiss every notification, including buffered ones", {
        parentHidden: true,
        examples: ["vb-shell notifications dismiss all"]
      }),
    gateway("notifications.dismiss.id", ["dismiss", arg("id", "int")],
      "Dismiss one notification by ID", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        examples: ["vb-shell notifications dismiss 12"]
      }),
    gateway("notifications.dismiss", ["dismiss"], "Dismiss notifications by scope or ID", {
      helpOnly: true,
      examples: ["vb-shell notifications dismiss visible", "vb-shell notifications dismiss all",
        "vb-shell notifications dismiss 12"]
    })
  ], {
    dnd: {
      summary: "Enable, disable, toggle or read do-not-disturb",
      usage: "vb-shell notifications dnd <ACTION>",
      examples: ["vb-shell notifications dnd enable", "vb-shell notifications dnd get"],
      commands: ["notifications.dnd.enable", "notifications.dnd.disable",
        "notifications.dnd.toggle", "notifications.dnd.get"]
    },
    dismiss: {
      summary: "Dismiss notifications by scope or ID",
      examples: ["vb-shell notifications dismiss 12", "vb-shell notifications dismiss visible",
        "vb-shell notifications dismiss all"],
      commands: ["notifications.dismiss.visible", "notifications.dismiss.all",
        "notifications.dismiss.id"]
    }
  }),

  target("osd", "OSD", "Show on-screen display overlays", [
    action("osd.flash", ["flash",
      arg("json", "json", { summary: "One JSON payload for the OSD: an object with `kind`, `value`, `label`, `icon` and `muted`, or a bare string used as the label. Pass as one quoted argv token" })],
      "Flash the OSD with a JSON payload", {
        examples: ["vb-shell osd flash '\"hello\"'",
          "vb-shell osd flash '{\"kind\":\"volume\",\"value\":50,\"label\":\"hello\"}'"]
      }),
    action("osd.hide", ["hide"], "Hide the OSD")
  ], {}, {
    status: {
      summary: "Show the OSD's current state",
      examples: ["vb-shell osd status"]
    }
  }),

  target("pass", "Pass", "Manage password-store entries", [
    action("pass.open", ["open"], "Open the password manager page"),
    action("pass.close", ["close"], "Close the password manager page"),
    action("pass.toggle", ["toggle"], "Toggle the password manager page"),
    action("pass.copy", ["copy", arg("path", "string")], "Copy line 1 of an entry to the clipboard", {
      notes: ["Never returns password text"],
      examples: ["vb-shell pass copy work/email", "vb-shell pass copy github.com/alice"]
    })
  ], {}),

  target("polkit", "Polkit", "Handle authentication prompts", [
    action("polkit.cancel", ["cancel"], "Cancel the current authentication prompt")
  ], {}, {
    status: {
      summary: "Show the authentication prompt state",
      examples: ["vb-shell polkit status"]
    }
  }),

  target("power", "Power menu", "Open the session power menu", [
    action("power.open", ["open"], "Open the power menu"),
    action("power.close", ["close"], "Close the power menu"),
    action("power.toggle", ["toggle"], "Toggle the power menu")
  ], {}),

  target("themePicker", "Theme picker", "Browse and apply themes", [
    action("themePicker.open", ["open"], "Open the theme picker overlay"),
    action("themePicker.close", ["close"], "Close the theme picker overlay"),
    action("themePicker.refresh", ["refresh"], "Rescan folders for new themes"),
    action("themePicker.toggle", ["toggle"], "Toggle the theme picker overlay")
  ], {}),

  target("themeRemover", "Theme remover", "Uninstall community themes", [
    action("themeRemover.open", ["open"], "Open the theme remover panel"),
    action("themeRemover.close", ["close"], "Close the theme remover panel"),
    action("themeRemover.refresh", ["refresh"], "Rescan folders for new themes"),
    action("themeRemover.toggle", ["toggle"], "Toggle the theme remover panel")
  ], {}),

  target("wallpaper", "Wallpaper", "Manage the desktop wallpaper", [
    action("wallpaper.refresh", ["refresh"], "Rescan wallpaper folders"),
    action("wallpaper.next", ["next"], "Select the next wallpaper"),
    action("wallpaper.prev", ["prev"], "Select the previous wallpaper"),
    action("wallpaper.set", ["set", arg("path", "string")], "Set the wallpaper from a path"),
    query("wallpaper.get", ["get"], "Show the current wallpaper path",
      { kind: "text", summary: "Absolute path" }, "text"),
    action("wallpaper.drop", ["drop", arg("uri", "string")], "Set a wallpaper from a drag URI")
  ], {}, {
    status: {
      summary: "Show the current wallpaper state",
      examples: ["vb-shell wallpaper status"]
    }
  }),

  target("wallpaperPicker", "Wallpaper picker", "Choose per-theme wallpapers", [
    action("wallpaperPicker.open", ["open"], "Open the wallpaper picker"),
    action("wallpaperPicker.close", ["close"], "Close the wallpaper picker"),
    action("wallpaperPicker.toggle", ["toggle"], "Toggle the wallpaper picker")
  ], {}),

  target("recording", "Recording", "Record the screen", [
    action("recording.start", ["start", opt(["region"])], "Start a recording", {
      options: [{ name: "region", summary: "Pick a screen region to record" }]
    }),
    action("recording.stop", ["stop"], "Stop a recording"),
    action("recording.toggle", ["toggle"], "Start or stop a recording", {
      reply: { kind: "action", exceptions: { vm: "unsupported" } }
    }),
    action("recording.open", ["open"], "Start or stop recording depending on the current state"),
    action("recording.close", ["close"], "Close the recording panel")
  ], {}),

  target("timer", "Timer", "Run a countdown timer", [
    action("timer.start", ["start", arg("N", "string")],
      "Start a timer from a duration", {
        parentHidden: true,
        usage: "start <N>",
        examples: ["vb-shell timer start 600", "vb-shell timer start 90s"]
      }),
    action("timer.start.minutes", ["start", "minutes", arg("N", "int")],
      "Start a timer from minutes", {
        parentHidden: true,
        usage: "start minutes <N>",
        examples: ["vb-shell timer start minutes 5"]
      }),
    gateway("timer.start.branch", ["start"],
      "Start a timer from seconds or minutes", {
        helpOnly: true,
        examples: ["vb-shell timer start 600", "vb-shell timer start minutes 5"]
      }),
    action("timer.stop", ["stop"], "Stop the timer")
  ], {
    start: {
      summary: "Start a timer from seconds or minutes",
      usage: "vb-shell timer start",
      examples: ["vb-shell timer start 600", "vb-shell timer start minutes 5"],
      commands: ["timer.start", "timer.start.minutes"]
    }
  }),

  target("powerProfile", "Power profile", "Choose the system power profile", [
    action("powerProfile.next", ["next"], "Cycle to the next profile"),
    action("powerProfile.prev", ["prev"], "Cycle to the previous profile"),
    action("powerProfile.set", ["set", arg("profile", "string")], "Switch to a named profile"),
    query("powerProfile.get", ["get"], "Show the current power profile",
      { kind: "text", summary: "Profile name" }, "text"),
    query("powerProfile.list", ["list"], "List available power profiles",
      { kind: "lines", summary: "" }, "lines")
  ], {}),

  target("privacy", "Privacy indicators", "Check microphone, camera and screen sharing", [], {}),

  target("screenshots", "Screenshots", "Capture and annotate screenshots", [
    action("screenshots.capture", ["capture", flags(["plain", "copy", "save"]),
      arg("TARGET", "enum", { values: ["screen", "region"] })],
      "Capture the screen or a selected region", {
        usage: "capture [plain|copy|save] screen|region",
        output: { kind: "none", summary: "" },
        notes: ["'plain' skips the annotator even when auto-annotate is on",
          "'copy' always copies the capture to the clipboard",
          "'save' always saves the capture to disk",
          "The modifiers may appear in any order before 'screen' or 'region'"],
        examples: ["vb-shell screenshots capture screen",
          "vb-shell screenshots capture plain save screen",
          "vb-shell screenshots capture copy region"]
      }),
    action("screenshots.picker", ["picker"], "Choose region or screen"),
    action("screenshots.annotate", ["annotate", arg("path", "string")], "Open the annotation editor"),
    query("screenshots.last", ["last"], "Show the path of the last capture",
      { kind: "text", summary: "Pathname" }, "text")
  ], {}),

  target("tools", "Tools", "Standalone shell utilities", [
    gateway("tools.picker.pick", ["picker", "pick", opt(["silent"]), opt(["logical"])],
      "Pick a screen region", {
        parentHidden: true,
        output: { kind: "record", summary: "{pending} while selecting, then {x,y,w,h} in real pixels" },
        options: [
          { name: "silent", summary: "Hide the live dimensions beside the cursor" },
          { name: "logical", summary: "Return desktop coordinates in logical pixels" }
        ],
        examples: ["vb-shell tools picker pick", "vb-shell tools picker pick silent",
          "vb-shell tools picker pick logical"]
      }),
    action("tools.picker.stop", ["picker", "stop"], "Stop the active region picker", {
      parentHidden: true,
      examples: ["vb-shell tools picker stop"]
    }),
    gateway("tools.picker", ["picker"], "Pick a screen region", {
      helpOnly: true,
      notes: ["One picker is live at a time; a second pick observes that one",
        "'stop' dismisses the picker without a selection"],
      examples: ["vb-shell tools picker pick", "vb-shell tools picker stop"]
    })
  ], {
    picker: {
      summary: "Pick a screen region",
      examples: ["vb-shell tools picker pick", "vb-shell tools picker stop"],
      commands: ["tools.picker.pick", "tools.picker.stop"]
    }
  }, {
    status: {
      summary: "Show whether a region picker is active",
      output: { kind: "record", summary: "{picker}" },
      examples: ["vb-shell tools status"]
    }
  }),

  target("session", "Session", "Lock, log out, suspend, reboot or power off", [
    action("session.lock", ["lock"], "Lock the session"),
    action("session.lockForSleep", ["lockForSleep"], "Lock the session for sleep without suspending"),
    action("session.logout", ["logout"], "End the session"),
    action("session.suspend", ["suspend"], "Suspend the session"),
    action("session.reboot", ["reboot"], "Reboot the machine", {
      reply: { kind: "action", exceptions: { confirmation_required: "refused" } }
    }),
    action("session.reboot.firmware", ["reboot", "firmware"],
      "Reboot into UEFI firmware setup", {
        usage: "reboot firmware",
        reply: { kind: "action", exceptions: { confirmation_required: "refused" } }
      }),
    action("session.poweroff", ["poweroff"], "Power off the machine")
  ], {}, {
    status: {
      summary: "Show session lock and power state",
      examples: ["vb-shell session status"]
    }
  }),

  target("systemUpdates", "System updates", "Check for and apply system updates", [
    action("systemUpdates.refresh", ["refresh"], "Check for available updates again"),
    action("systemUpdates.update", ["update", arg("mode", "string"),
      arg("packages", "json", { allowEmptyString: true,
        summary: "JSON array of package names, e.g. [\"pkg\"]. Pass as one quoted argv token" })],
      "Apply a system update with a package list", {
        notes: ["'aur' selects AUR; other legacy modes select the repositories",
          "A bare package name is not JSON: pass one quoted JSON array token, e.g. '[\"pkg\"]'",
          "An empty string is the legacy explicit empty package list"],
        examples: ["vb-shell systemUpdates update aur '[\"artcraft-launcher-bin\"]'"]
      }),
    gateway("systemUpdates.dump", ["dump"], "Show the current merged update rows", {
      parentHidden: true,
      reply: { kind: "json" },
      output: { kind: "table", summary: "Package rows", columns: [
        { key: "name", heading: "Name" }, { key: "current", heading: "Current" },
        { key: "candidate", heading: "Candidate" }, { key: "repository", heading: "Repository" },
        { key: "size", heading: "Size" }, { key: "source", heading: "Source" }
      ] },
      notes: ["Read-only: no refresh, controller demand or update is started",
        "An empty state is 'No entries.' in text and '[]' in JSON"],
      examples: ["vb-shell systemUpdates dump"]
    }),
    gateway("systemUpdates.dump.all", ["dump", "all"], "Show merged official and AUR update rows", {
      parentHidden: true,
      reply: { kind: "json" },
      output: { kind: "table", summary: "Package rows", columns: [
        { key: "name", heading: "Name" }, { key: "current", heading: "Current" },
        { key: "candidate", heading: "Candidate" }, { key: "repository", heading: "Repository" },
        { key: "size", heading: "Size" }, { key: "source", heading: "Source" }
      ] },
      notes: ["The merged in-memory rows are returned as-is, in their current order",
        "Read-only: no refresh, controller demand or update is started"],
      examples: ["vb-shell systemUpdates dump all"]
    }),
    gateway("systemUpdates.dump.aur", ["dump", "aur"], "Show AUR-only update rows", {
      parentHidden: true,
      reply: { kind: "json" },
      output: { kind: "table", summary: "AUR package rows", columns: [
        { key: "name", heading: "Name" }, { key: "current", heading: "Current" },
        { key: "candidate", heading: "Candidate" }, { key: "repository", heading: "Repository" },
        { key: "size", heading: "Size" }, { key: "source", heading: "Source" }
      ] },
      notes: ["Only the AUR source's last parsed rows are returned; no refresh is started",
        "An empty state is 'No entries.' in text and '[]' in JSON"],
      examples: ["vb-shell systemUpdates dump aur"]
    }),
    gateway("systemUpdates.dump.BUCKET", ["dump", opt([arg("BUCKET", "enum", { values: ["all", "aur"] })])],
      "Show current update rows by source", {
        helpOnly: true,
        notes: ["Buckets are 'all' and 'aur'; bare 'dump' means the merged rows",
          "Every form is read-only: no controller demand or update is started"],
        examples: ["vb-shell systemUpdates dump", "vb-shell systemUpdates dump aur"]
      })
  ], {
    dump: {
      summary: "Show the current update rows without refreshing",
      notes: ["'dump' and 'dump all' show merged rows; 'dump aur' shows AUR rows only"],
      examples: ["vb-shell systemUpdates dump all", "vb-shell systemUpdates dump aur"],
      commands: ["systemUpdates.dump", "systemUpdates.dump.all", "systemUpdates.dump.aur"]
    }
  }),

  target("printers", "Printers", "Manage CUPS printers and jobs", [
    action("printers.refresh", ["refresh"], "Refresh printers and jobs"),
    action("printers.connect", ["connect", arg("name", "string")], "Set the user default printer"),
    action("printers.hold", ["hold", arg("printer", "string"), arg("jobid", "string")], "Hold a job", {
      parentHidden: true,
      examples: ["vb-shell printers hold HP-LaserJet 12"]
    }),
    action("printers.release", ["release", arg("printer", "string"), arg("jobid", "string")], "Release a job", {
      parentHidden: true,
      examples: ["vb-shell printers release HP-LaserJet 12"]
    }),
    action("printers.cancel", ["cancel", arg("printer", "string"), arg("jobid", "string")], "Cancel a job", {
      parentHidden: true,
      examples: ["vb-shell printers cancel HP-LaserJet 12"]
    }),
    action("printers.dismiss", ["dismiss", arg("jobid", "string")], "Clear a finished entry"),
    action("printers.clear", ["clear"], "Clear all finished entries"),
    action("printers.rename", ["rename", arg("name", "string"), arg("label", "string")], "Set a printer's display name"),
    action("printers.remove", ["remove", arg("name", "string")], "Delete a printer queue"),
    gateway("printers.config", ["config", opt([arg("name", "string")])], "Open print settings", {
      output: { kind: "none", summary: "" }
    }),
    gateway("printers.job", ["job", opt([arg("ACTION", "ref")]), opt([arg("TARGET", "ref")])],
      "Hold, release or cancel one queued job", {
        helpOnly: true,
        notes: ["A job action takes a printer name and a job id; 'dismiss' takes only a job id",
          "An 'ok' reply acknowledges submission, not CUPS success"],
        examples: ["vb-shell printers hold HP-LaserJet 12", "vb-shell printers cancel HP-LaserJet 12"]
      })
  ], {
    job: {
      summary: "Operate one queued job",
      notes: ["The three verbs take the same printer name and job id; they stay separately dispatchable"],
      examples: ["vb-shell printers hold HP-LaserJet 12", "vb-shell printers release HP-LaserJet 12",
        "vb-shell printers cancel HP-LaserJet 12"],
      commands: ["printers.hold", "printers.release", "printers.cancel"]
    }
  }),

  // --- batch B: apps, launcher and audio (gateway routes) -------------------
  // These are owner commands, not native IpcHandlers. They are registered by
  // the resident facades through IpcRouter and never reach arbitrary members
  // of a registered object.
  target("app", "Apps", "Manage Vibranium's Quickshell apps", [
    gateway("app.list", ["list"], "List all known apps", {
      output: { kind: "table", summary: "", columns: [
        { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
        { key: "description", heading: "Description" }, { key: "open", heading: "Open" }
      ] },
      notes: [],
      examples: ["vb-shell app list"]
    }),
    gateway("app.open", ["open", arg("ID", "enum", { values: ["audioMixer", "imageViewer"] })],
      "", {
        labelSummary: "Open an app by ID",
        arguments: [],
        output: { kind: "none", summary: "" },
        notes: [],
        examples: ["vb-shell app open audioMixer"]
      }),
    gateway("app.close", ["close", rep("ID", "enum", { values: ["audioMixer", "imageViewer"] })],
      "Close apps by ID", {
        arguments: [],
        output: { kind: "none", summary: "" },
        notes: [],
        examples: ["vb-shell app close audioMixer", "vb-shell app close audioMixer imageViewer"]
      }),
    gateway("app.toggle", ["toggle", arg("ID", "enum", { values: ["audioMixer", "imageViewer"] })],
      "", {
        labelSummary: "Toggle an app window",
        arguments: [],
        output: { kind: "none", summary: "" },
        notes: [],
        examples: ["vb-shell app toggle audioMixer"]
      }),
    gateway("app.call.list", ["call", "list", arg("ID", "enum", { values: ["audioMixer", "imageViewer"] })],
      "List supported commands for ID", {
        parentHidden: true,
        output: { kind: "help", summary: "" },
        notes: [],
        examples: ["vb-shell app call list audioMixer", "vb-shell app call list imageViewer"]
      }),
    // One placeholder at the parent level; the concrete verbs stay below it.
    gateway("app.call", ["call", opt([arg("ID", "ref")])],
      "Run an app's own IPC commands", {
        helpOnly: true,
        notes: [],
        examples: ["vb-shell app call list audioMixer", "vb-shell app call audioMixer help"]
      }),
    gateway("app.call.imageViewer.openPath",
      ["call", "imageViewer", "openPath", arg("PATH", "ref")],
      "Open one absolute path or local file: URL in the image viewer", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        notes: [],
        examples: ["vb-shell app call imageViewer openPath /home/user/Pictures/one.png"]
      }),
    gateway("app.call.audioMixer.openTab",
      ["call", "audioMixer", "openTab", arg("TAB", "enum", {
        values: ["apps", "devices", "recording", "configuration", "graph"]
      })],
      "Open the mixer on a named tab", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        notes: [],
        examples: ["vb-shell app call audioMixer openTab configuration"]
      }),
    gateway("app.call.audioMixer.selectTab",
      ["call", "audioMixer", "selectTab", arg("TAB", "enum", {
        values: ["apps", "devices", "recording", "configuration", "graph"]
      })],
      "Select a tab in the already open mixer", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        notes: [],
        examples: ["vb-shell app call audioMixer selectTab devices"]
      }),
    gateway("app.call.audioMixer.status", ["call", "audioMixer", "status"],
      "Show the audio mixer's status, including its tab", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        notes: [],
        examples: ["vb-shell app call audioMixer status"]
      }),
    gateway("app.call.imageViewer.status", ["call", "imageViewer", "status"],
      "Show the image viewer's status", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        notes: [],
        examples: ["vb-shell app call imageViewer status"]
      })
  ], {
    call: {
      usage: "vb-shell app call <ID>",
      summary: "Explicit per-app commands",
      notes: ["Use 'vb-shell app list' to see available apps"],
      examples: ["vb-shell app call list audioMixer", "vb-shell app call audioMixer help"],
      commands: ["app.call.list"]
    },
    "call.audioMixer": {
      summary: "Audio mixer commands",
      examples: ["vb-shell app call audioMixer openTab apps", "vb-shell app call audioMixer status"]
    },
    "call.imageViewer": {
      summary: "Image viewer commands",
      examples: ["vb-shell app call imageViewer openPath /tmp/one.png"]
    }
  }, {
    notes: ["Use 'vb-shell app call help' to see available per-app calls"]
  }),

  target("audio", "Audio", "Control volume and microphone levels", [
    gateway("audio.volume.up", ["volume", "up", opt(["step", arg("N", "int", { min: 1, max: 200 })])],
      "Raise the default output volume", {
        parentHidden: true,
        arguments: [{ name: "N", type: "int", optional: true, label: "step <N>",
          summary: "Increase by N percentage points (1-200)" }],
        options: [],
        output: { kind: "record", summary: "Accepted state" },
        examples: ["vb-shell audio volume up", "vb-shell audio volume up step 10"]
      }),
    gateway("audio.volume.down", ["volume", "down", opt(["step", arg("N", "int", { min: 1, max: 200 })])],
      "Lower the default output volume", {
        parentHidden: true,
        arguments: [{ name: "N", type: "int", optional: true, label: "step <N>",
          summary: "Decrease by N percentage points (1-200)" }],
        options: [],
        output: { kind: "record", summary: "Accepted state" },
        examples: ["vb-shell audio volume down", "vb-shell audio volume down step 10"]
      }),
    gateway("audio.volume.toggle", ["volume", "toggle"],
      "Mute or unmute the default output", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting percent and mute" },
        examples: ["vb-shell audio volume toggle"]
      }),
    gateway("audio.volume.get", ["volume", "get"],
      "Get current default output level", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        examples: ["vb-shell audio volume get"]
      }),
    gateway("audio.volume.set", ["volume", "set", arg("N", "int", { min: 0, max: 200 })],
      "Set the output level, 0-200 percent", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting percent and mute" },
        examples: ["vb-shell audio volume set 80"]
      }),
    gateway("audio.microphone.up", ["microphone", "up", opt(["step", arg("N", "int", { min: 1, max: 200 })])],
      "Raise the default microphone volume", {
        parentHidden: true,
        arguments: [{ name: "N", type: "int", optional: true, label: "step <N>",
          summary: "Increase by N percentage points (1-200)" }],
        options: [],
        output: { kind: "record", summary: "Accepted state" },
        examples: ["vb-shell audio microphone up", "vb-shell audio microphone up step 10"]
      }),
    gateway("audio.microphone.down", ["microphone", "down", opt(["step", arg("N", "int", { min: 1, max: 200 })])],
      "Lower the default microphone volume", {
        parentHidden: true,
        arguments: [{ name: "N", type: "int", optional: true, label: "step <N>",
          summary: "Decrease by N percentage points (1-200)" }],
        options: [],
        output: { kind: "record", summary: "Accepted state" },
        examples: ["vb-shell audio microphone down", "vb-shell audio microphone down step 10"]
      }),
    gateway("audio.microphone.toggle", ["microphone", "toggle"],
      "Mute or unmute the default microphone", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting percent and mute" },
        examples: ["vb-shell audio microphone toggle"]
      }),
    gateway("audio.microphone.get", ["microphone", "get"],
      "Get current default input level", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        examples: ["vb-shell audio microphone get"]
      }),
    gateway("audio.microphone.set", ["microphone", "set", arg("N", "int", { min: 0, max: 200 })],
      "Set the microphone level, 0-200 percent", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting percent and mute" },
        examples: ["vb-shell audio microphone set 60"]
      }),
    gateway("audio.sink.list", ["sink", "list"], "Live output devices from the shared PipeWire graph", {
      parentHidden: true,
      output: { kind: "table", summary: "Output devices", columns: [
        { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
        { key: "direction", heading: "Direction" }, { key: "virtual", heading: "Virtual" },
        { key: "monitor", heading: "Monitor" }, { key: "default", heading: "Default" },
        { key: "configuredDefault", heading: "Configured" },
        { key: "percent", heading: "Percent" }, { key: "muted", heading: "Muted" }
      ] },
      examples: ["vb-shell audio sink list"]
    }),
    gateway("audio.sink.set", ["sink", "set", arg("ID", "ref")],
      "Make an output device the configured default", {
        parentHidden: true,
        output: { kind: "record", summary: "Accepted or unchanged state and the ref" },
        examples: ["vb-shell audio sink set n1.2"]
      }),
    gateway("audio.source.list", ["source", "list"], "Live input devices from the shared PipeWire graph", {
      parentHidden: true,
      output: { kind: "table", summary: "Input devices", columns: [
        { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
        { key: "direction", heading: "Direction" }, { key: "virtual", heading: "Virtual" },
        { key: "monitor", heading: "Monitor" }, { key: "default", heading: "Default" },
        { key: "configuredDefault", heading: "Configured" },
        { key: "percent", heading: "Percent" }, { key: "muted", heading: "Muted" }
      ] },
      notes: ["Virtual sources, including Audio/Source/Virtual, are listed"],
      examples: ["vb-shell audio source list"]
    }),
    gateway("audio.source.set", ["source", "set", arg("ID", "ref")],
      "Make an input device the configured default", {
        parentHidden: true,
        output: { kind: "record", summary: "Accepted or unchanged state and the ref" },
        examples: ["vb-shell audio source set n1.3"]
      }),
    gateway("audio.stream.list", ["stream", "list"], "Live application playback and capture streams", {
      parentHidden: true,
      output: { kind: "table", summary: "Application streams", columns: [
        { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
        { key: "app", heading: "App" }, { key: "direction", heading: "Direction" },
        { key: "percent", heading: "Percent" }, { key: "muted", heading: "Muted" }
      ] },
      examples: ["vb-shell audio stream list"]
    }),
    gateway("audio.stream.set", ["stream", arg("ID", "ref"),
      "set", arg("N", "int", { min: 0, max: 150 })],
      "Set an application stream's level, 0-150 percent", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting id, percent and mute" },
        notes: ["A positive level unmutes; a zero keeps an explicit mute",
          "No default-device OSD is shown for a stream write"],
        examples: ["vb-shell audio stream n1.2 set 75"]
      }),
    gateway("audio.stream.mute", ["stream", arg("ID", "ref"),
      "mute", arg("BOOL", "bool")],
      "Set an application stream's explicit mute", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting id, percent and mute" },
        notes: ["The value is exactly true or false"],
        examples: ["vb-shell audio stream n1.2 mute true"]
      }),
    gateway("audio.stream.route", ["stream", arg("ID", "ref"),
      "route", arg("DEVICE", "ref"), opt(["verbose"])],
      "Move an application stream to a matching device", {
        parentHidden: true,
        output: { kind: "record", summary: "Accepted state and request id" },
        notes: ["Playback moves to a sink, capture to a source; monitors are refused",
          "One request may be pending at a time. Observe it with 'route-status'",
          "'verbose' prints the request id; without it the order is silent"],
        examples: ["vb-shell audio stream n1.2 route n1.4",
          "vb-shell audio stream n1.2 route n1.4 verbose"]
      }),
    gateway("audio.stream.route-status", ["stream", "route-status", arg("REQUEST", "ref")],
      "Read the state of one stream route request", {
        parentHidden: true,
        output: { kind: "record", summary: "Pending, done, or failed with a code" },
        notes: ["The last eight terminal requests are kept for 60 seconds"],
        examples: ["vb-shell audio stream route-status r1.1"]
      }),
    gateway("audio.volume", ["volume", opt([arg("ACTION", "ref")])],
      "Control the default output volume", {
        helpOnly: true,
        examples: ["vb-shell audio volume up step 10", "vb-shell audio volume get",
          "vb-shell audio volume set 80"]
      }),
    gateway("audio.microphone", ["microphone", opt([arg("ACTION", "ref")])],
      "Control the default microphone", {
        helpOnly: true,
        examples: ["vb-shell audio microphone up", "vb-shell audio microphone get",
          "vb-shell audio microphone set 60"]
      }),
    gateway("audio.sink", ["sink", opt([arg("ACTION", "ref")])],
      "List or choose output devices", {
        helpOnly: true,
        examples: ["vb-shell audio sink list", "vb-shell audio sink set n1.2"]
      }),
    gateway("audio.source", ["source", opt([arg("ACTION", "ref")])],
      "List or choose input devices", {
        helpOnly: true,
        examples: ["vb-shell audio source list", "vb-shell audio source set n1.3"]
      }),
    gateway("audio.stream", ["stream", opt([arg("ACTION", "ref")])],
      "List and control application streams", {
        helpOnly: true,
        notes: ["Stream IDs come from 'vb-shell audio stream list'",
          "Device refs come from 'audio sink list' or 'audio source list'"],
        examples: ["vb-shell audio stream list", "vb-shell audio stream n1.2 set 75",
          "vb-shell audio stream route-status r1.1"]
      })
  ], {
    volume: {
      summary: "Control output level and mute",
      examples: ["vb-shell audio volume up step 10", "vb-shell audio volume set 80"],
      commands: ["audio.volume.up", "audio.volume.down", "audio.volume.toggle",
        "audio.volume.get", "audio.volume.set"]
    },
    microphone: {
      summary: "Control microphone level and mute",
      examples: ["vb-shell audio microphone up", "vb-shell audio microphone set 60"],
      commands: ["audio.microphone.up", "audio.microphone.down", "audio.microphone.toggle",
        "audio.microphone.get", "audio.microphone.set"]
    },
    sink: {
      summary: "List output devices and choose the default",
      examples: ["vb-shell audio sink list", "vb-shell audio sink set n1.2"],
      commands: ["audio.sink.list", "audio.sink.set"]
    },
    source: {
      summary: "List input devices and choose the default",
      examples: ["vb-shell audio source list", "vb-shell audio source set n1.3"],
      commands: ["audio.source.list", "audio.source.set"]
    },
    stream: {
      usage: "vb-shell audio stream <ID> [<ACTION>]",
      summary: "List and control application streams",
      notes: ["Stream IDs come from 'vb-shell audio stream list'",
        "Device refs come from 'audio sink list' or 'audio source list'"],
      examples: ["vb-shell audio stream list", "vb-shell audio stream n1.2 set 50",
        "vb-shell audio stream route-status r1.1"],
      commands: ["audio.stream.list", "audio.stream.set", "audio.stream.mute",
        "audio.stream.route", "audio.stream.route-status"]
    },
    "stream.ID": {
      summary: "Control one application's level, mute and routing",
      notes: ["The ref comes from 'vb-shell audio stream list'; device refs from 'sink list' or 'source list'"],
      examples: ["vb-shell audio stream n1.2 set 50", "vb-shell audio stream n1.2 route n1.4"],
      commands: ["audio.stream.set", "audio.stream.mute", "audio.stream.route"]
    }
  }),

  target("hyprlandSettings", "Hyprland settings", "View and edit live Hyprland settings", [
    gateway("hyprlandSettings.get", ["get", arg("KEY", "ref")],
      "Read one managed setting", {
        output: { kind: "value", summary: "Managed value" },
        examples: ["vb-shell hyprlandSettings get hypr.animations.enabled"]
      }),
    gateway("hyprlandSettings.set.value", ["set", arg("KEY", "ref"),
      arg("JSON", "json", { summary: "One typed JSON value accepted by the option, e.g. `false`. Pass as one quoted argv token" }),
      opt(["verbose"])],
      "Write one managed option from a typed JSON value", {
      parentHidden: true,
      output: { kind: "record", summary: "The key and accepted value" },
        notes: ["An unchanged typed value is a silent success; 'verbose' prints the key and value"],
        examples: ["vb-shell hyprlandSettings set hypr.animations.enabled 'false'",
          "vb-shell hyprlandSettings set hypr.animations.enabled false",
          "vb-shell hyprlandSettings set hypr.animations.enabled true verbose"]
      }),
    gateway("hyprlandSettings.set.toggle", ["set", arg("KEY", "ref"), "--toggle", opt(["verbose"])],
      "Flip a known managed boolean option", {
      parentHidden: true,
      output: { kind: "record", summary: "The key and resulting value" },
        notes: ["'verbose' prints the key and resulting value"],
        examples: ["vb-shell hyprlandSettings set hypr.animations.enabled --toggle",
          "vb-shell hyprlandSettings set hypr.animations.enabled --toggle verbose"]
      }),
    gateway("hyprlandSettings.dump", ["dump"], "Show all managed options", {
      output: { kind: "value", summary: "Managed values record" },
      examples: ["vb-shell hyprlandSettings dump"]
    }),
    gateway("hyprlandSettings.reload", ["reload"], "Reload the live Hyprland config"),
    gateway("hyprlandSettings.set", ["set", arg("KEY", "ref"), opt([arg("VALUE", "ref")])],
      "Edit options live", {
        helpOnly: true,
        examples: ["vb-shell hyprlandSettings set hypr.animations.enabled 'false'",
          "vb-shell hyprlandSettings set hypr.animations.enabled --toggle"]
      })
  ], {
    set: {
      usage: "vb-shell hyprlandSettings set <KEY>",
      summary: "Write one managed option",
      examples: ["vb-shell hyprlandSettings set hypr.animations.enabled --toggle",
        "vb-shell hyprlandSettings set hypr.animations.enabled 'false'"],
      commands: ["hyprlandSettings.set.value", "hyprlandSettings.set.toggle"]
    }
  }, { noExamples: true }),

  target("inhibitor", "Inhibitor", "Keep the system awake for a set time", [
    gateway("inhibitor.remaining", ["remaining"], "Show the remaining seconds on the active inhibitor", {
      output: { kind: "value", summary: "Null when off, 0 when infinite, else seconds" },
      notes: ["Off is JSON null; an active infinite lock is 0; a finite lock is at least one second",
        "The value follows the owner's expiry edge, not a stale cycle index"],
      examples: ["vb-shell inhibitor remaining"]
    }),
    gateway("inhibitor.start", ["start", arg("SECONDS", "int", { min: 0, max: 2147483647 })],
      "Start an inhibitor; 0 keeps it on until stopped", {
        output: { kind: "record", summary: "Accepted state, target and infinite flag" },
        notes: ["Backend startup stays asynchronous; observe 'held' through 'status'",
          "Starting while active retargets the single owned job"],
        examples: ["vb-shell inhibitor start 600", "vb-shell inhibitor start 0"]
      }),
    gateway("inhibitor.stop", ["stop"], "Release the active inhibitor", {
      output: { kind: "none", summary: "" },
      notes: ["Never stops a foreign application's inhibitor"],
      examples: ["vb-shell inhibitor stop"]
    }),
    gateway("inhibitor.cycle.next", ["cycle", "next"], "Step forward through the named durations", {
      parentHidden: true,
      output: { kind: "record", summary: "Active flag, targetSec and infinite flag" },
      examples: ["vb-shell inhibitor cycle next"]
    }),
    gateway("inhibitor.cycle.back", ["cycle", "back"], "Step backward through the named durations", {
      parentHidden: true,
      output: { kind: "record", summary: "Active flag, targetSec and infinite flag" },
      examples: ["vb-shell inhibitor cycle back"]
    }),
    gateway("inhibitor.cycle", ["cycle"], "Step through the named inhibit durations", {
      helpOnly: true,
      examples: ["vb-shell inhibitor cycle next", "vb-shell inhibitor cycle back"]
    })
  ], {
    cycle: {
      summary: "Step through the named inhibit durations",
      commands: ["inhibitor.cycle.next", "inhibitor.cycle.back"],
      noExamples: true
    }
  }, {
    status: {
      summary: "Show whether the inhibitor is active",
      output: { kind: "record", summary: "{active,held,infinite,targetSec,remaining} and health" },
      examples: ["vb-shell inhibitor status"]
    }
  }),

  target("idle", "Idle", "Manage idle timers and actions", [
    gateway("idle.enable", ["enable"], "Enable the idle daemon", {
      examples: ["vb-shell idle enable"]
    }),
    gateway("idle.disable", ["disable"], "Disable the idle daemon", {
      examples: ["vb-shell idle disable"]
    }),
    gateway("idle.reload", ["reload"], "Reload the idle daemon", {
      examples: ["vb-shell idle reload"]
    }),
    gateway("idle.list", ["list"], "List known and active timers", {
      output: { kind: "table", summary: "Timer rows", columns: [
        { key: "id", heading: "ID" }, { key: "seconds", heading: "Seconds" },
        { key: "action", heading: "Action" }, { key: "command", heading: "Command" },
        { key: "commandClass", heading: "Class" }
      ] },
      examples: ["vb-shell idle list"]
    }),
    gateway("idle.add", ["add", arg("SECONDS", "int", { min: 1, max: 604800 }), arg("COMMAND", "ref")],
      "Add a new timer", {
        examples: ["vb-shell idle add 600 'systemctl suspend'"]
      }),
    gateway("idle.remove", ["remove", arg("ID", "int")], "Remove a timer", {
      examples: ["vb-shell idle remove 0"]
    }),
    gateway("idle.class", ["class", arg("ID", "int"),
      arg("CLASS", "enum", { values: ["lock", "suspend", "none"] })],
      "Declare what a command timer does to the session", {
        examples: ["vb-shell idle class 0 suspend"]
      })
  ], {}, {
    noExamples: true,
    status: {
      summary: "Show the idle daemon's status",
      output: { kind: "record", summary: "{enabled,epoch,capability,degraded,timers}" },
      examples: ["vb-shell idle status"]
    }
  }),

  target("appLauncher", "App launcher", "Search and launch applications", [
    gateway("appLauncher.open", ["open"], "Show the launcher panel", {
      output: { kind: "none", summary: "" },
      notes: ["An open or pending panel is already open; success is silent",
        "A refused demand is unavailable, or busy while loading"],
      examples: ["vb-shell appLauncher open"]
    }),
    gateway("appLauncher.close", ["close"], "Hide the launcher panel", {
      output: { kind: "none", summary: "" },
      examples: ["vb-shell appLauncher close"]
    }),
    gateway("appLauncher.toggle", ["toggle"], "Toggle the launcher panel", {
      output: { kind: "none", summary: "" },
      examples: ["vb-shell appLauncher toggle"]
    }),
    gateway("appLauncher.history.is-empty", ["history", "is-empty"],
      "Show whether usage history is empty", {
        parentHidden: true,
        output: { kind: "bool", summary: "" },
        notes: ["Unavailable until the controller has read usage; an unknown history is never an empty one"],
        examples: ["vb-shell appLauncher history is-empty"]
      }),
    gateway("appLauncher.history.show", ["history", "show"],
      "Show usage counts, most used first", {
        parentHidden: true,
        output: { kind: "table", summary: "Usage rows", columns: [
          { key: "id", heading: "ID" }, { key: "count", heading: "Count" }
        ] },
        notes: ["Ties are ordered by id"],
        examples: ["vb-shell appLauncher history show"]
      }),
    gateway("appLauncher.history.clear", ["history", "clear"],
      "Clear usage history", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        notes: ["A known empty history is a silent no-op; an unknown one is unavailable"],
        examples: ["vb-shell appLauncher history clear"]
      }),
    gateway("appLauncher.history", ["history"],
      "Inspect or clear usage history", {
        helpOnly: true,
        examples: ["vb-shell appLauncher history show", "vb-shell appLauncher history clear"]
      }),
    gateway("appLauncher.plugin.list", ["plugin", "list"], "List all known plugins", {
      parentHidden: true,
      output: { kind: "table", summary: "Plugin rows", columns: [
        { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
        { key: "description", heading: "Description" }, { key: "type", heading: "Type" },
        { key: "keyword", heading: "Keyword" }, { key: "enabled", heading: "Enabled" }
      ] },
      notes: ["Unavailable until discovery has published a registry; no plugin code is loaded"],
      examples: ["vb-shell appLauncher plugin list"]
    }),
    gateway("appLauncher.plugin.status", ["plugin", arg("ID", "ref"), "status"],
      "Show one plugin's status", {
      parentHidden: true,
      output: { kind: "record", summary: "Need-to-know fields plus loaded, broken, grants and generation" },
        notes: ["'loaded' means init succeeded, not merely that an implementation was assigned"],
        examples: ["vb-shell appLauncher plugin calc status"]
      }),
    gateway("appLauncher.plugin.enable", ["plugin", arg("ID", "ref"), "enable"],
      "Enable a plugin", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        notes: ["A resolved plugin already in the requested state writes nothing"],
        examples: ["vb-shell appLauncher plugin calc enable"]
      }),
    gateway("appLauncher.plugin.disable", ["plugin", arg("ID", "ref"), "disable"],
      "Disable a plugin", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        examples: ["vb-shell appLauncher plugin calc disable"]
      }),
    gateway("appLauncher.plugin.toggle", ["plugin", arg("ID", "ref"), "toggle"],
      "Toggle a plugin", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        examples: ["vb-shell appLauncher plugin calc toggle"]
      }),
    gateway("appLauncher.plugin.reload", ["plugin", "reload"],
      "Reload all enabled plugins", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        notes: ["Registered implementations only; no directory discovery and no other plugin identities are replaced",
          "Success and unchanged no-ops print nothing; errors keep their diagnostics"],
        examples: ["vb-shell appLauncher plugin reload"]
      }),
    gateway("appLauncher.plugin.id.reload", ["plugin", arg("ID", "ref"), "reload"],
      "Reload one plugin", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        notes: ["A known disabled plugin is a silent, unchanged no-op with no code load"],
        examples: ["vb-shell appLauncher plugin calc reload"]
      }),
    // One branch row replaces all seven lifecycle spellings at the parent.
    gateway("appLauncher.plugin", ["plugin"], "List and manage launcher plugins", {
        helpOnly: true,
        notes: ["Use 'vb-shell appLauncher plugin list' to see plugin ids",
          "Manage one plugin with 'vb-shell appLauncher plugin <ID> <VERB>'"],
        examples: ["vb-shell appLauncher plugin list", "vb-shell appLauncher plugin calc status",
          "vb-shell appLauncher plugin reload"]
      }),
    // Help-only signature: the generic branch, not an executable call. It
    // keeps the parent pages short while every fixed verb stays dispatchable.
    gateway("appLauncher.plugin.command", ["plugin", "command"],
      "Query and manage commands from plugins", {
        helpOnly: true,
        notes: ["Use 'vb-shell appLauncher plugin list' to see plugin ids",
          "Describe one plugin with 'vb-shell appLauncher plugin command <PLUGIN> help'"],
        examples: ["vb-shell appLauncher plugin list",
          "vb-shell appLauncher plugin command calc help"]
      }),
    gateway("appLauncher.plugin.command.calc.eval", ["plugin", "command", "calc", "eval", arg("EXPR", "ref")],
      "Evaluate an arithmetic expression without copying it", {
      parentHidden: true,
      output: { kind: "record", summary: "Expression, numeric value and formatted result" },
        notes: ["'EXPR' is one arithmetic expression passed as a quoted argv word"],
        examples: ["vb-shell appLauncher plugin command calc eval '5+5'"]
      }),
    gateway("appLauncher.plugin.command.unit.convert", ["plugin", "command", "unit", "convert", arg("QUERY", "ref")],
      "Convert units; keep successful readings in order", {
      parentHidden: true,
      output: { kind: "table", summary: "Conversions", columns: [
          { key: "label", heading: "Label" }, { key: "value", heading: "Value" }
        ] },
        notes: ["'QUERY' is one quantity query, e.g. '1 light years'"],
        examples: ["vb-shell appLauncher plugin command unit convert '1 light years'"]
      }),
    gateway("appLauncher.plugin.command.constants.lookup", ["plugin", "command", "constants", "lookup", arg("QUERY", "ref")],
      "Read named constants without copying a result", {
      parentHidden: true,
      output: { kind: "table", summary: "Readings", columns: [
          { key: "label", heading: "Label" }, { key: "value", heading: "Value" }
        ] },
        notes: ["'QUERY' is a constant name or keyword"],
        examples: ["vb-shell appLauncher plugin command constants lookup 'speed of light'"]
      }),
    gateway("appLauncher.plugin.command.color.parse", ["plugin", "command", "color", "parse", arg("COLOR", "ref")],
      "Parse a color into its known formats", {
      parentHidden: true,
      output: { kind: "record", summary: "Hex, alpha, edge and formats" },
        notes: ["'COLOR' is one color expression, e.g. '#ff8800'"],
        examples: ["vb-shell appLauncher plugin command color parse '#ff8800'"]
      }),
    gateway("appLauncher.plugin.command.time.lookup", ["plugin", "command", "time", "lookup", arg("ZONE_OR_CITY", "ref")],
      "Read the time in a city or zone", {
      parentHidden: true,
      output: { kind: "record", summary: "City, timezone, time, date and code, or accepted state" },
        notes: ["'ZONE_OR_CITY' is one city or zone name, e.g. 'Berlin'",
          "A cache miss is accepted; repeat the read to observe the landed clock"],
        examples: ["vb-shell appLauncher plugin command time lookup 'Berlin'"]
      }),
    gateway("appLauncher.plugin.command.time.convert", ["plugin", "command", "time", "convert", arg("QUERY", "ref")],
      "Convert a typed time between zones", {
      parentHidden: true,
      output: { kind: "record", summary: "Source and local time, date and offset" },
        notes: ["'QUERY' is one typed time, e.g. '7:55pm cst'"],
        examples: ["vb-shell appLauncher plugin command time convert '7:55pm cst'"]
      }),
    gateway("appLauncher.plugin.command.fx.convert", ["plugin", "command", "fx", "convert", arg("QUERY", "ref")],
      "Convert an amount between currencies", {
      parentHidden: true,
      output: { kind: "value", summary: "Accepted state or conversion rows" },
        notes: ["'QUERY' is one currency amount, e.g. '1 USD to EUR'",
          "A pending provider fetch is accepted; repeat the read after it settles",
          "No pick is recorded by a query"],
        examples: ["vb-shell appLauncher plugin command fx convert '1 USD to EUR'"]
      }),
    gateway("appLauncher.plugin.command.websearch.url", ["plugin", "command", "websearch", "url", arg("QUERY", "ref")],
      "Build the configured search URL for a query", {
      parentHidden: true,
      output: { kind: "text", summary: "Absolute URL" },
        notes: ["'QUERY' is one search phrase; the command returns the engine URL only",
          "The command does not open a browser"],
        examples: ["vb-shell appLauncher plugin command websearch url 'shell ipc'"]
      })
  ], {
    history: {
      summary: "View and manage usage history",
      examples: ["vb-shell appLauncher history is-empty", "vb-shell appLauncher history show"],
      commands: ["appLauncher.history.is-empty", "appLauncher.history.show",
        "appLauncher.history.clear"]
    },
    plugin: {
      summary: "List and manage plugins",
      notes: [],
      examples: ["vb-shell appLauncher plugin list", "vb-shell appLauncher plugin calc status",
        "vb-shell appLauncher plugin reload"],
      commands: ["appLauncher.plugin.list", "appLauncher.plugin.reload",
        "appLauncher.plugin.status", "appLauncher.plugin.enable",
        "appLauncher.plugin.disable", "appLauncher.plugin.toggle",
        "appLauncher.plugin.id.reload", "appLauncher.plugin.command"]
    },
    "plugin.command": {
      summary: "Query and manage commands from plugins",
      notes: ["Use 'vb-shell appLauncher plugin list' to see plugin ids",
        "Describe one plugin with 'vb-shell appLauncher plugin command <PLUGIN> help'",
        "A disabled or broken plugin is discoverable but cannot run"],
      examples: ["vb-shell appLauncher plugin list",
        "vb-shell appLauncher plugin command calc help",
        "vb-shell appLauncher plugin command websearch help"],
      commands: ["appLauncher.plugin.command.calc.eval", "appLauncher.plugin.command.unit.convert",
        "appLauncher.plugin.command.constants.lookup", "appLauncher.plugin.command.color.parse",
        "appLauncher.plugin.command.time.lookup", "appLauncher.plugin.command.time.convert",
        "appLauncher.plugin.command.fx.convert", "appLauncher.plugin.command.websearch.url"]
    }
  }),

  // --- batch E: menu model automation -------------------------------------
  // Every row is a gateway command registered by the resident Menu singleton.
  // Reads project the same safe row record the UI sees; writes use the shared
  // row actions, never a synthesized key or caller-supplied shell source.
  target("menu", "Menu", "Open and control menu bundles", [
    gateway("menu.open.inline", ["open", "inline",
      arg("JSON", "json", { summary: "One inline JSON/JSONC bundle object with `entry` and `pages`, e.g. `{\"entry\":\"main\",\"pages\":[]}`. Pass as one quoted argv token" })],
      "Open one inline JSON/JSONC bundle", {
        parentHidden: true,
        output: { kind: "record", summary: "Open flag and entry page" },
        notes: ["The submitted text is the inline identity; the same text again is a no-op",
          "A page fragment selects the entry; an unknown fragment is not silenced"],
        examples: ["vb-shell menu open inline '{\"entry\":\"main\",\"pages\":[{\"id\":\"main\",\"items\":[]}]}'"]
      }),
    gateway("menu.open.file", ["open", "file", arg("PATH", "ref")],
      "Open a bundle file or an existing path#page entry", {
        parentHidden: true,
        output: { kind: "record", summary: "Open flag and entry page" },
        notes: ["A relative path resolves in the caller's working directory",
          "Opening the same source and entry again is a no-op"],
        examples: ["vb-shell menu open file /home/user/.config/vibranium/menu.jsonc#main"]
      }),
    gateway("menu.open", ["open"], "Open a menu bundle", {
      helpOnly: true,
      examples: ["vb-shell menu open inline '{\"entry\":\"main\",\"pages\":[]}'",
        "vb-shell menu open file /home/user/.config/vibranium/menu.jsonc#main"]
    }),
    gateway("menu.toggle.inline", ["toggle", "inline",
      arg("JSON", "json", { summary: "One inline JSON/JSONC bundle object with `entry` and `pages`, e.g. `{\"entry\":\"main\",\"pages\":[]}`. Pass as one quoted argv token" })],
      "Switch bundles, or close when the same inline bundle is already open", {
        parentHidden: true,
        output: { kind: "record", summary: "Open flag and current page" },
        examples: ["vb-shell menu toggle inline '{\"entry\":\"main\",\"pages\":[]}'"]
      }),
    gateway("menu.toggle.file", ["toggle", "file", arg("PATH", "ref")],
      "Close the same file+entry or open a different one", {
        parentHidden: true,
        output: { kind: "record", summary: "Open flag and current page" },
        examples: ["vb-shell menu toggle file /home/user/.config/vibranium/menu.jsonc#main"]
      }),
    gateway("menu.toggle", ["toggle"], "Toggle a menu bundle", {
      helpOnly: true,
      examples: ["vb-shell menu toggle inline '{\"entry\":\"main\",\"pages\":[]}'",
        "vb-shell menu toggle file /home/user/.config/vibranium/menu.jsonc#main"]
    }),
    gateway("menu.close", ["close"], "Close a menu", {
      output: { kind: "record", summary: "Closed state" },
      examples: ["vb-shell menu close"]
    }),
    gateway("menu.pages", ["pages"], "Show the entry, stack and reachable pages", {
      output: { kind: "table", summary: "Page rows", columns: [
        { key: "id", heading: "ID" }, { key: "title", heading: "Title" },
        { key: "layout", heading: "Layout" }, { key: "reachable", heading: "Reachable" }
      ] },
      notes: ["A guarded link is never a path; protected pages stay out of public reads"],
      examples: ["vb-shell menu pages"]
    }),
    gateway("menu.go", ["go", arg("PAGE", "ref")],
      "Go to a page by its shortest allowed path, or back to an existing page", {
        output: { kind: "record", summary: "Resulting page and depth" },
        notes: ["On the current page this is a no-op; an unlinked dynamic page is refused"],
        examples: ["vb-shell menu go settings"]
      }),
    gateway("menu.back", ["back"], "Go back one page; closes at the root", {
      output: { kind: "record", summary: "Open flag and current page" },
      examples: ["vb-shell menu back"]
    }),
    gateway("menu.list", ["list", opt([arg("PAGE", "ref")])],
      "List the current rows or a page's tree without navigating", {
        output: { kind: "table", summary: "Row records", columns: [
          { key: "ref", heading: "Ref" }, { key: "uid", heading: "UID" },
          { key: "type", heading: "Type" }, { key: "label", heading: "Label" },
          { key: "available", heading: "Available" }, { key: "depth", heading: "Depth" }
        ] },
        notes: ["With no argument the current rendered projection is returned"],
        examples: ["vb-shell menu list", "vb-shell menu list settings"]
      }),
    gateway("menu.current", ["current"], "Show the current page, scope, revision and selected row", {
      output: { kind: "record", summary: "Safe current snapshot" },
      notes: ["Closed is a successful snapshot with open:false and a current revision"],
      examples: ["vb-shell menu current"]
    }),
    gateway("menu.select", ["select", arg("ROW", "ref")],
      "Select a row without activating it", {
        output: { kind: "none", summary: "" },
        notes: ["Nested refs expand the verified ancestor chain first",
          "A visual-only seat needs a visible panel"],
        examples: ["vb-shell menu select r1.1.1.2"]
      }),
    gateway("menu.search.global", ["search", "global", arg("QUERY", "string")],
      "Search the whole current bundle scope", {
        parentHidden: true,
        output: { kind: "record", summary: "Scope and pending flag" },
        notes: ["A dynamic page without global search is unsupported, not silently scoped",
          "Activation while pending is busy"],
        examples: ["vb-shell menu search global 'wallpaper'"]
      }),
    gateway("menu.search.scoped", ["search", "scoped", arg("QUERY", "string")],
      "Filter the current page with the scoped '/'-filter pipeline", {
        parentHidden: true,
        output: { kind: "record", summary: "Scope and pending flag" },
        examples: ["vb-shell menu search scoped 'theme'"]
      }),
    gateway("menu.search.clear", ["search", "clear"],
      "Clear global and scoped queries together", {
        parentHidden: true,
        output: { kind: "record", summary: "Scope none and pending flag" },
        examples: ["vb-shell menu search clear"]
      }),
    gateway("menu.item.ROW.get", ["item", arg("ROW", "ref"), "get"],
      "Read safe row metadata, value, options and flow/confirm state", {
        parentHidden: true,
        output: { kind: "record", summary: "Safe item projection" },
        notes: ["Protected rows redact value and drafted data",
          "No command template, provider object or environment value is published"],
        examples: ["vb-shell menu item r1.1.1.2 get"]
      }),
    gateway("menu.item.ROW.activate", ["item", arg("ROW", "ref"), "activate"],
      "Apply the row's own activation action", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        examples: ["vb-shell menu item r1.1.1.2 activate"]
      }),
    gateway("menu.item.ROW.open", ["item", arg("ROW", "ref"), "open"],
      "Open an editor, dropdown or submenu; idempotent when already open", {
        parentHidden: true,
        output: { kind: "record", summary: "Open flag and page" },
        examples: ["vb-shell menu item r1.1.1.2 open"]
      }),
    gateway("menu.item.ROW.close", ["item", arg("ROW", "ref"), "close"],
      "Cancel an editor or fold a dropdown; idempotent", {
        parentHidden: true,
        output: { kind: "record", summary: "Open flag and page" },
        examples: ["vb-shell menu item r1.1.1.2 close"]
      }),
    gateway("menu.item.ROW.toggle", ["item", arg("ROW", "ref"), "toggle"],
      "Invert a toggle row", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting boolean value" },
        examples: ["vb-shell menu item r1.1.1.2 toggle"]
      }),
    gateway("menu.item.ROW.set", ["item", arg("ROW", "ref"), "set",
      arg("JSON", "json", { summary: "One typed JSON scalar, e.g. `true` or `\"text\"`. Pass as one quoted argv token" })],
      "Set a typed bool, number or string on the row", {
        parentHidden: true,
        output: { kind: "record", summary: "Committed value or accepted draft" },
        notes: ["A select accepts a string only while its edit prompt is open",
          "On a flow row this fills the current step's draft"],
        examples: ["vb-shell menu item r1.1.1.2 set '\"text\"'",
          "vb-shell menu item r1.1.1.2 set true"]
      }),
    gateway("menu.item.ROW.step.up", ["item", arg("ROW", "ref"), "step", "up"],
      "Step a number/range row up by its configured increment", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting value" },
        examples: ["vb-shell menu item r1.1.1.2 step up"]
      }),
    gateway("menu.item.ROW.step.down", ["item", arg("ROW", "ref"), "step", "down"],
      "Step a number/range row down by its configured increment", {
        parentHidden: true,
        output: { kind: "record", summary: "Resulting value" },
        examples: ["vb-shell menu item r1.1.1.2 step down"]
      }),
    gateway("menu.item.ROW.options", ["item", arg("ROW", "ref"), "options"],
      "List selectable options by their exact IDs", {
        parentHidden: true,
        output: { kind: "table", summary: "Option rows", columns: [
          { key: "id", heading: "ID" }, { key: "label", heading: "Label" },
          { key: "value", heading: "Value" }, { key: "enabled", heading: "Enabled" },
          { key: "selected", heading: "Selected" }
        ] },
        examples: ["vb-shell menu item r1.1.1.2 options"]
      }),
    gateway("menu.item.ROW.choose", ["item", arg("ROW", "ref"), "choose", arg("OPTION", "ref")],
      "Choose one option by its exact ID; a disabled option is refused", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        examples: ["vb-shell menu item r1.1.1.2 choose o2"]
      }),
    gateway("menu.item.ROW.info.open", ["item", arg("ROW", "ref"), "info", "open"],
      "Open the row's description", {
        parentHidden: true,
        output: { kind: "record", summary: "Info open flag" },
        examples: ["vb-shell menu item r1.1.1.2 info open"]
      }),
    gateway("menu.item.ROW.info.close", ["item", arg("ROW", "ref"), "info", "close"],
      "Close the row's description slot", {
        parentHidden: true,
        output: { kind: "record", summary: "Info open flag" },
        examples: ["vb-shell menu item r1.1.1.2 info close"]
      }),
    gateway("menu.item.ROW.confirm.status", ["item", arg("ROW", "ref"), "confirm", "status"],
      "Read the confirmation kind and stage", {
        parentHidden: true,
        output: { kind: "record", summary: "kind, stage and total" },
        examples: ["vb-shell menu item r1.1.1.2 confirm status"]
      }),
    gateway("menu.item.ROW.confirm.next", ["item", arg("ROW", "ref"), "confirm", "next"],
      "Arm or advance one confirmation stage; run only after the final stage", {
        parentHidden: true,
        output: { kind: "record", summary: "kind, stage and total" },
        examples: ["vb-shell menu item r1.1.1.2 confirm next"]
      }),
    gateway("menu.item.ROW.confirm.cancel", ["item", arg("ROW", "ref"), "confirm", "cancel"],
      "Reset the confirmation and collapse the row", {
        parentHidden: true,
        output: { kind: "record", summary: "Idle confirmation" },
        examples: ["vb-shell menu item r1.1.1.2 confirm cancel"]
      }),
    gateway("menu.item.ROW.flow.status", ["item", arg("ROW", "ref"), "flow", "status"],
      "Read the staged flow cursor, kind and committed values", {
        parentHidden: true,
        output: { kind: "record", summary: "active, step, kind, ready and values" },
        examples: ["vb-shell menu item r1.1.1.2 flow status"]
      }),
    gateway("menu.item.ROW.flow.next", ["item", arg("ROW", "ref"), "flow", "next"],
      "Record the current draft and advance, skipping unmatched stages", {
        parentHidden: true,
        output: { kind: "record", summary: "Flow status after the step" },
        examples: ["vb-shell menu item r1.1.1.2 flow next"]
      }),
    gateway("menu.item.ROW.flow.back", ["item", arg("ROW", "ref"), "flow", "back"],
      "Return to the previous visited step, dropping later values", {
        parentHidden: true,
        output: { kind: "record", summary: "Flow status after the step" },
        examples: ["vb-shell menu item r1.1.1.2 flow back"]
      }),
    gateway("menu.item.ROW.flow.commit", ["item", arg("ROW", "ref"), "flow", "commit"],
      "Commit a ready flow", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        examples: ["vb-shell menu item r1.1.1.2 flow commit"]
      }),
    gateway("menu.item.ROW.flow.cancel", ["item", arg("ROW", "ref"), "flow", "cancel"],
      "Collapse the flow and drop its draft without persisting", {
        parentHidden: true,
        output: { kind: "record", summary: "Inactive flow status" },
        examples: ["vb-shell menu item r1.1.1.2 flow cancel"]
      }),
    gateway("menu.item.ROW.flow.set", ["item", arg("ROW", "ref"), "flow", "set",
      arg("STEP", "int", { min: 0 }),
      arg("JSON", "json", { summary: "One typed JSON value for the step's draft, e.g. `15`. Pass as one quoted argv token" })],
      "Fill only the current zero-based step's draft", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        notes: ["A protected, skipped or undisplayed step refuses the value",
          "'STEP' is a decimal integer; the value is one quoted JSON token"],
        examples: ["vb-shell menu item r1.1.1.2 flow set 0 '15'"]
      }),
    gateway("menu.item.ROW.delete", ["item", arg("ROW", "ref"), "delete"],
      "Arm or advance staged deletion; run exactly one configured action", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        examples: ["vb-shell menu item r1.1.1.2 delete"]
      }),
    // Branch placeholders: a row ref or a search scope never enumerates the
    // whole current menu in a parent page.
    gateway("menu.search", ["search", opt([arg("ACTION", "ref")]),
      opt([arg("QUERY", "ref")])], "Search the current menu", {
        helpOnly: true,
        notes: ["Actions are 'global <QUERY>', 'scoped <QUERY>' and 'clear'"],
        examples: ["vb-shell menu search global 'theme'", "vb-shell menu search clear"]
      }),
    gateway("menu.item", ["item", opt([arg("ROW", "ref")])],
      "Inspect and operate one row by reference", {
        helpOnly: true,
        notes: ["Refs come from 'list' or 'current' and retire on close, page replacement or row rebuild",
          "Describe one ref with 'vb-shell menu item <ROW> help'"],
        examples: ["vb-shell menu item r1.1.1.2 get", "vb-shell menu item r1.1.1.2 activate"]
      }),
    gateway("menu.item.ROW.info", ["info", opt([arg("ACTION", "ref")])],
      "Open or close the row's description", {
        helpOnly: true,
        parent: "item.ROW",
        notes: ["Actions are 'open' and 'close'"],
        examples: ["vb-shell menu item r1.1.1.2 info open"]
      }),
    gateway("menu.item.ROW.confirm", ["confirm", opt([arg("ACTION", "ref")])],
      "Read or advance the row's confirmation", {
        helpOnly: true,
        parent: "item.ROW",
        notes: ["Actions are 'status', 'next' and 'cancel'; run 'next' only after the final stage"],
        examples: ["vb-shell menu item r1.1.1.2 confirm status",
          "vb-shell menu item r1.1.1.2 confirm next"]
      }),
    gateway("menu.item.ROW.flow", ["flow", opt([arg("ACTION", "ref")])],
      "Inspect or advance a staged flow on this row", {
        helpOnly: true,
        parent: "item.ROW",
        notes: ["Actions are 'status', 'next', 'back', 'commit', 'cancel' and 'set <STEP> <JSON>'"],
        examples: ["vb-shell menu item r1.1.1.2 flow status",
          "vb-shell menu item r1.1.1.2 flow set 0 '15'"]
      }),
    gateway("menu.item.ROW.step", ["step", opt([arg("DIRECTION", "ref")])],
      "Step a number or range row up or down", {
        helpOnly: true,
        parent: "item.ROW",
        notes: ["Directions are 'up' and 'down'"],
        examples: ["vb-shell menu item r1.1.1.2 step up"]
      })
  ], {
    open: {
      summary: "Open a menu bundle",
      examples: ["vb-shell menu open inline '{\"entry\":\"main\",\"pages\":[]}'",
        "vb-shell menu open file /home/user/.config/vibranium/menu.jsonc#main"],
      commands: ["menu.open.inline", "menu.open.file"]
    },
    toggle: {
      summary: "Toggle a menu bundle",
      examples: ["vb-shell menu toggle inline '{\"entry\":\"main\",\"pages\":[]}'",
        "vb-shell menu toggle file /home/user/.config/vibranium/menu.jsonc#main"],
      commands: ["menu.toggle.inline", "menu.toggle.file"]
    },
    search: {
      summary: "Query the current menu scope",
      notes: ["Global search is a whole-bundle ranking, scoped search is the in-page filter"],
      examples: ["vb-shell menu search global 'theme'", "vb-shell menu search scoped 'dark'",
        "vb-shell menu search clear"],
      commands: ["menu.search.global", "menu.search.scoped", "menu.search.clear"]
    },
    item: {
      summary: "Inspect and operate one row by reference",
      notes: ["Refs come from 'list' or 'current' and retire on close, page replacement or row rebuild",
        "A ref read on another page cannot write behind that page"],
      examples: ["vb-shell menu item r1.1.1.2 get", "vb-shell menu item r1.1.1.2 activate",
        "vb-shell menu item r1.1.1.2 flow status"],
      commands: ["menu.item.ROW.get", "menu.item.ROW.activate", "menu.item.ROW.open",
        "menu.item.ROW.close", "menu.item.ROW.toggle", "menu.item.ROW.set",
        "menu.item.ROW.step", "menu.item.ROW.options", "menu.item.ROW.choose",
        "menu.item.ROW.info", "menu.item.ROW.confirm", "menu.item.ROW.flow",
        "menu.item.ROW.delete"]
    },
    "item.ROW": {
      summary: "Inspect and operate one menu row",
      notes: ["A ref read on another page cannot write behind that page"],
      examples: ["vb-shell menu item r1.1.1.2 get", "vb-shell menu item r1.1.1.2 activate"],
      commands: ["menu.item.ROW.get", "menu.item.ROW.activate", "menu.item.ROW.open",
        "menu.item.ROW.close", "menu.item.ROW.toggle", "menu.item.ROW.set",
        "menu.item.ROW.step", "menu.item.ROW.options", "menu.item.ROW.choose",
        "menu.item.ROW.info", "menu.item.ROW.confirm", "menu.item.ROW.flow",
        "menu.item.ROW.delete"]
    },
    "item.ROW.info": {
      summary: "Open or close the row's description",
      examples: ["vb-shell menu item r1.1.1.2 info open", "vb-shell menu item r1.1.1.2 info close"],
      commands: ["menu.item.ROW.info.open", "menu.item.ROW.info.close"]
    },
    "item.ROW.confirm": {
      summary: "Read or advance the row's confirmation",
      notes: ["'next' advances a stage; run it once more only after the final stage"],
      examples: ["vb-shell menu item r1.1.1.2 confirm status",
        "vb-shell menu item r1.1.1.2 confirm cancel"],
      commands: ["menu.item.ROW.confirm.status", "menu.item.ROW.confirm.next",
        "menu.item.ROW.confirm.cancel"]
    },
    "item.ROW.flow": {
      summary: "Inspect or advance the row's staged flow",
      notes: ["'set' fills only the current zero-based step's draft"],
      examples: ["vb-shell menu item r1.1.1.2 flow status",
        "vb-shell menu item r1.1.1.2 flow set 0 '15'"],
      commands: ["menu.item.ROW.flow.status", "menu.item.ROW.flow.next",
        "menu.item.ROW.flow.back", "menu.item.ROW.flow.commit",
        "menu.item.ROW.flow.cancel", "menu.item.ROW.flow.set"]
    },
    "item.ROW.step": {
      summary: "Increment or decrement a number or range row",
      examples: ["vb-shell menu item r1.1.1.2 step up", "vb-shell menu item r1.1.1.2 step down"],
      commands: ["menu.item.ROW.step.up", "menu.item.ROW.step.down"]
    }
  }),

  // --- batch C: bar, clipboard and emoji picker -----------------------------
  // Owner commands registered by the resident bar, clipboard and picker
  // singletons. Like batches B/D/E, every row is an explicit closure in the
  // owner's IpcRouter.register block; no QML member is selected from argv.
  target("bar", "Bar", "Inspect and control the status bar", [
    gateway("bar.enable", ["enable"], "Enable the status bar", {
      output: { kind: "record", summary: "Resulting `enabled`" },
      notes: ["Does not clear a transient hide override"],
      examples: ["vb-shell bar enable"]
    }),
    gateway("bar.disable", ["disable"], "Disable the status bar", {
      output: { kind: "record", summary: "Resulting `enabled`" },
      examples: ["vb-shell bar disable"]
    }),
    gateway("bar.toggle", ["toggle"], "Toggle the status bar", {
      output: { kind: "record", summary: "Resulting `enabled`" },
      notes: ["This is the persistent enable switch, not the transient hide"],
      examples: ["vb-shell bar toggle"]
    }),
    gateway("bar.show", ["show"], "Show the status bar again", {
      output: { kind: "record", summary: "Hide override and effective enablement" },
      notes: ["A persistent disable is not overridden"],
      examples: ["vb-shell bar show"]
    }),
    gateway("bar.hide", ["hide"], "Hide the status bar", {
      output: { kind: "record", summary: "Hide override and effective enablement" },
      notes: ["Resets on the next shell start"],
      examples: ["vb-shell bar hide"]
    }),
    gateway("bar.showToggle", ["showToggle"], "Temporarily show or hide the status bar", {
      output: { kind: "record", summary: "Hide override and effective enablement" },
      examples: ["vb-shell bar showToggle"]
    }),
    gateway("bar.position.get", ["position", "get"], "Get current position", {
      parentHidden: true,
      output: { kind: "text", summary: "`top` or `bottom`" },
      examples: ["vb-shell bar position get"]
    }),
    gateway("bar.position.set", ["position", "set",
      arg("POSITION", "enum", { values: ["top", "bottom", "toggle"] })], "Set statusbar position", {
      usageOnly: true,
      parentHidden: true,
      output: { kind: "text", summary: "`top` or `bottom` or `toggle`" },
        notes: ["Bare `position set` prints its one-line usage"],
        examples: ["vb-shell bar position set bottom", "vb-shell bar position set toggle"]
      }),
    gateway("bar.layout.get", ["layout", "get"], "Get current layout", {
      parentHidden: true,
      output: { kind: "record", summary: "{left,center,right,disabled}" },
      examples: ["vb-shell bar layout get"]
    }),
    gateway("bar.layout.set", ["layout", "set",
      arg("LAYOUT", "json", { summary: "One JSON object with `left`, `center`, `right` and `disabled` arrays. Pass as one quoted argv token" })],
      "Update layout", {
      parentHidden: true,
      output: { kind: "record", summary: "The canonical stored layout" },
        notes: ["All four arrays are required; duplicate, unknown, group-member and fixed-slot moves are refused",
          "The submitted arrays are never mutated"],
        examples: ["vb-shell bar layout set '{\"left\":[],\"center\":[\"clock\"],\"right\":[],\"disabled\":[]}'"]
      }),
    gateway("bar.module.list", ["module", "list",
      opt([arg("FILTER", "enum", { values: ["all", "enabled", "disabled", "hidden", "visible"] })])],
      "Show all known status bar modules", {
      parentHidden: true,
      usage: "module list [all|enabled|disabled|hidden|visible]",
      output: { kind: "table", summary: "Module rows", columns: [
          { key: "id", heading: "ID" }, { key: "prettyName", heading: "Name" },
          { key: "description", heading: "Description" }, { key: "enabled", heading: "Enabled" },
          { key: "visible", heading: "Visible" }
        ] },
        notes: ["FILTER defaults to 'all'; 'hidden' is enabled but not visible",
          "'visible' is physical projection on a live screen, not layout membership",
          "A hidden bar has no visible modules"],
        examples: ["vb-shell bar module list", "vb-shell bar module list visible"]
      }),
    gateway("bar.module.ID.status", ["module", arg("MODULE", "ref"), "status"],
      "Show MODULE status", {
      parentHidden: true,
      output: { kind: "record", summary: "Module status" },
        examples: ["vb-shell bar module volume status"]
      }),
    gateway("bar.module.ID.enable", ["module", arg("MODULE", "ref"), "enable"],
      "Enable [a] MODULE", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        notes: ["An already-enabled standalone is an unchanged success; owned and member ids are unsupported"],
        examples: ["vb-shell bar module volume enable"]
      }),
    gateway("bar.module.ID.disable", ["module", arg("MODULE", "ref"), "disable"],
      "Disable [a] MODULE", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        examples: ["vb-shell bar module volume disable"]
      }),
    gateway("bar.module.ID.toggle", ["module", arg("MODULE", "ref"), "toggle"],
      "Toggle [a] MODULE", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
        examples: ["vb-shell bar module volume toggle"]
      }),
    gateway("bar.module.ID.island.open", ["module", arg("MODULE", "ref"), "island", "open",
      opt(["screen", arg("OUTPUT", "ref")])], "Open one module's island", {
        parentHidden: true,
        output: { kind: "record", summary: "{isOpen}" },
        notes: ["An already open anchor is a no-op; another anchor is replaced by the host"],
        examples: ["vb-shell bar module clock island open", "vb-shell bar module clock island open screen HDMI-A-1"]
      }),
    gateway("bar.module.ID.island.close", ["module", arg("MODULE", "ref"), "island", "close",
      opt(["screen", arg("OUTPUT", "ref")])], "Close one module's island", {
      parentHidden: true,
      output: { kind: "record", summary: "{isOpen}" },
        notes: ["A different island is never closed"],
        examples: ["vb-shell bar module clock island close"]
      }),
    gateway("bar.module.ID.island.toggle", ["module", arg("MODULE", "ref"), "island", "toggle",
      opt(["screen", arg("OUTPUT", "ref")])], "Toggle one module's island", {
      parentHidden: true,
      output: { kind: "record", summary: "{isOpen}" },
        examples: ["vb-shell bar module clock island toggle"]
      }),
    gateway("bar.module.ID.island.is-open", ["module", arg("MODULE", "ref"), "island", "is-open",
      opt(["screen", arg("OUTPUT", "ref")])], "Whether this module's island is the open one", {
      parentHidden: true,
      output: { kind: "bool", summary: "`true` or `false`" },
        examples: ["vb-shell bar module clock island is-open"]
      }),
    gateway("bar.module.ID.opt.list", ["module", arg("MODULE", "ref"), "opt", "list"],
      "List the persisted options that belong to this module", {
        parentHidden: true,
        output: { kind: "table", summary: "Option rows", columns: [
          { key: "key", heading: "Key" }, { key: "type", heading: "Type" },
          { key: "value", heading: "Value" }, { key: "default", heading: "Default" }
        ] },
        notes: ["Keys are the case-sensitive suffixes shown here, not arbitrary QML properties"],
        examples: ["vb-shell bar module weather opt list"]
      }),
    gateway("bar.module.ID.opt.KEY.get", ["module", arg("MODULE", "ref"), "opt",
      arg("KEY", "enum", { values: IPC_OPTION_KEYS })],
      "Read one persisted module option", {
      parentHidden: true,
      output: { kind: "record", summary: "{key,value}" },
        notes: ["A key not in this module's table is 'unsupported'; the fixed 'list' branch never matches a key"],
        examples: ["vb-shell bar module weather opt ShowTemp"]
      }),
    gateway("bar.module.ID.opt.KEY.set", ["module", arg("MODULE", "ref"), "opt",
      arg("KEY", "enum", { values: IPC_OPTION_KEYS }),
      arg("JSON", "json", { summary: "One typed JSON value for the option, e.g. `true`. Pass as one quoted argv token" })],
      "Write one persisted module option", {
        parentHidden: true,
        output: { kind: "record", summary: "{key,value}" },
        notes: ["An unchanged typed value writes nothing",
          "The value is one parsed JSON token; quote a JSON string inside the argv quotes"],
        examples: ["vb-shell bar module weather opt ShowTemp 'true'",
          "vb-shell bar module weather opt ShowTemp true"]
      }),
    gateway("bar.module.ID.trigger", ["module", arg("MODULE", "ref"), "trigger",
      arg("NAME", "enum", { values: ["flashTrack", "flashTemperature", "flashConnection",
        "flashDevice", "flashCharge"] }), opt(["screen", arg("OUTPUT", "ref")])],
      "Run an explicit module announcement", {
      parentHidden: true,
      output: { kind: "record", summary: "{state,reason}" },
        notes: ["Only the named module/name pairs are supported; any other pair is 'unsupported'",
          "A fullscreen defer may queue the announcement without requiring final visible width"],
        examples: ["vb-shell bar module weather trigger flashTemperature",
          "vb-shell bar module network trigger flashConnection"]
      }),
    // Branch placeholders keep parent pages flat as modules and options grow.
    gateway("bar.position", ["position"],
      "Set & query statusbar position", {
        helpOnly: true,
        notes: ["POSITION is one of: top, bottom, toggle"],
        examples: ["vb-shell bar position get", "vb-shell bar position set bottom"]
      }),
    gateway("bar.layout", ["layout"],
      "Query and edit layout", {
        helpOnly: true,
        notes: ["Actions are 'get' and 'set <JSON>'; all four slot arrays are required"],
        examples: ["vb-shell bar layout get", "vb-shell bar layout set '{\"left\":[],\"center\":[],\"right\":[],\"disabled\":[]}'"]
      }),
    gateway("bar.module", ["module"],
      "Inspect and operate configured bar modules", {
        helpOnly: true,
        notes: ["Discover ids with 'vb-shell bar module list'",
          "One module owns status, enablement, an island and persisted options"],
        examples: ["vb-shell bar module list", "vb-shell bar module volume status",
          "vb-shell bar module volume help"]
      }),
    gateway("bar.module.ID.island", ["island", opt([arg("ACTION", "ref")])],
      "Open, close, toggle or query this module's island", {
        helpOnly: true,
        parent: "module.ID",
        notes: ["Actions are 'open', 'close', 'toggle' and 'is-open'; each takes an optional 'screen <OUTPUT>'"],
        examples: ["vb-shell bar module clock island open", "vb-shell bar module clock island is-open"]
      }),
    gateway("bar.module.ID.opt", ["opt", opt([arg("KEY", "ref")])],
      "Read and write this module's options", {
        helpOnly: true,
        parent: "module.ID",
        notes: ["Use 'opt list' for exact, case-sensitive keys"],
        examples: ["vb-shell bar module weather opt list", "vb-shell bar module weather opt ShowTemp"]
      }),
    gateway("bar.module.ID.triggerBranch", ["trigger", opt([arg("NAME", "ref")])],
      "Run explicit module announcements", {
        helpOnly: true,
        parent: "module.ID",
        notes: ["Valid names are listed by 'vb-shell bar module <MODULE> trigger help'"],
        examples: ["vb-shell bar module nowPlaying trigger flashTrack"]
      }),
  ], {
    position: {
      summary: "Set & query statusbar position",
      notes: ["POSITION is one of: top, bottom, toggle"],
      examples: ["vb-shell bar position get", "vb-shell bar position set top"],
      commands: ["bar.position.get", "bar.position.set"]
    },
    layout: {
      summary: "Query and edit layout",
      notes: ["Zones hold every known slot; 'disabled' is the off list"],
      examples: ["vb-shell bar layout get", "vb-shell bar layout set '{\"left\":[],\"center\":[\"clock\"],\"right\":[],\"disabled\":[]}'"],
      commands: ["bar.layout.get", "bar.layout.set"]
    },
    module: {
      summary: "Inspect and operate configured bar modules and their options",
      notes: ["Use 'module list' for all available MODULEs"],
      examples: ["vb-shell bar module list", "vb-shell bar module volume status",
        "vb-shell bar module volume island open"],
      commands: ["bar.module.list", "bar.module.ID.status", "bar.module.ID.enable",
        "bar.module.ID.disable", "bar.module.ID.toggle", "bar.module.ID.island",
        "bar.module.ID.opt", "bar.module.ID.triggerBranch"]
    },
    "module.ID": {
      summary: "Inspect and control one bar module",
      notes: ["Ids come from 'bar module list'; a disabled instance stays discoverable"],
      examples: ["vb-shell bar module clock island is-open", "vb-shell bar module clock opt list"],
      commands: ["bar.module.ID.status", "bar.module.ID.enable", "bar.module.ID.disable",
        "bar.module.ID.toggle", "bar.module.ID.island", "bar.module.ID.opt",
        "bar.module.ID.triggerBranch"]
    },
    "module.ID.island": {
      summary: "Open, close, toggle or query this module's island",
      notes: ["An explicit output must exactly match a live screen name"],
      examples: ["vb-shell bar module clock island open", "vb-shell bar module clock island is-open"],
      commands: ["bar.module.ID.island.open", "bar.module.ID.island.close",
        "bar.module.ID.island.toggle", "bar.module.ID.island.is-open"]
    },
    "module.ID.opt": {
      summary: "Read and write this module's options",
      notes: ["Only the suffixes listed by 'module <ID> status' are accepted"],
      examples: ["vb-shell bar module weather opt list", "vb-shell bar module weather opt ShowTemp 'true'"],
      commands: ["bar.module.ID.opt.list", "bar.module.ID.opt.KEY.get", "bar.module.ID.opt.KEY.set"]
    },
    "module.ID.trigger": {
      summary: "Run explicit module announcements",
      examples: ["vb-shell bar module nowPlaying trigger flashTrack"],
      commands: ["bar.module.ID.trigger"]
    },

  }),

  // Thin top-level alias for the bar-owned picker. The closures are the same
  // Bar owner methods as `bar.colorPicker.*`; there is no second seat and no
  // duplicate state. The bar keeps its own module-view branch hint.
  target("colorPicker", "Color picker", "Pick a color from the screen", [
    gateway("colorPicker.pick", ["pick"], "Pick a color from the screen", {
      output: { kind: "none", summary: "" },
      notes: ["Uses the loaded bar module or the headless fallback; a duplicate pick while active is unchanged",
        "A retired callback cannot write a clipboard value"],
      examples: ["vb-shell colorPicker pick"]
    }),
    gateway("colorPicker.close", ["close"], "Cancel the active color picker, if any", {
      output: { kind: "none", summary: "" },
      examples: ["vb-shell colorPicker close"]
    })
  ], {}, {
    // The injected `status` row carries the owner's readiness projection; the
    // metadata stays here even though the row is not listed in help.
    status: {
      summary: "Show the color picker's status",
      output: { kind: "record", summary: "{available,picking,screen}" },
      notes: ["'status', 'ping' and 'help' are available on every target"],
      examples: ["vb-shell colorPicker status"]
    }
  }),

  target("clipboard", "Clipboard", "Browse clipboard history and selections", [
    gateway("clipboard.window.open", ["window", "open", opt(["pinned"])],
      "Show the clipboard panel", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        notes: ["The optional 'pinned' literal opens the pinned view; it has no argument label"],
        examples: ["vb-shell clipboard window open", "vb-shell clipboard window open pinned"]
      }),
    gateway("clipboard.window.close", ["window", "close"], "Hide the clipboard panel", {
        parentHidden: true,
      output: { kind: "record", summary: "" },
      examples: ["vb-shell clipboard window close"]
    }),
    gateway("clipboard.window.toggle", ["window", "toggle", opt(["pinned"])],
      "Show or hide the clipboard panel", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        notes: ["The optional 'pinned' literal opens the pinned view when showing; it has no argument label"],
        examples: ["vb-shell clipboard window toggle", "vb-shell clipboard window toggle pinned"]
      }),
    gateway("clipboard.window", ["window"], "Open, close or toggle the clipboard panel", {
      helpOnly: true,
      notes: ["'open pinned' and 'toggle pinned' open the pinned view; 'close' needs no argument"],
      examples: ["vb-shell clipboard window open", "vb-shell clipboard window open pinned",
        "vb-shell clipboard window toggle pinned"]
    }),
    gateway("clipboard.list.regular", ["list"],
      "List regular clipboard items with safe previews", {
        parentHidden: true,
        output: { kind: "table", summary: "", columns: [
          { key: "index", heading: "Index" }, { key: "content", heading: "Content" }
        ] },
        notes: ["Only '{index,content}' is published; paths, MIME and metadata never leave the owner"],
        examples: ["vb-shell clipboard list"]
      }),
    gateway("clipboard.list.pinned", ["list", "pinned"],
      "List pinned clipboard items with safe previews", {
        parentHidden: true,
        output: { kind: "table", summary: "", columns: [
          { key: "index", heading: "Index" }, { key: "content", heading: "Content" }
        ] },
        examples: ["vb-shell clipboard list pinned"]
      }),
    gateway("clipboard.list.current", ["list", "current"],
      "List the open panel's current filtered view", {
        parentHidden: true,
        output: { kind: "table", summary: "", columns: [
          { key: "index", heading: "Index" }, { key: "content", heading: "Content" }
        ] },
        notes: ["Requires an open panel; a closed one is 'unavailable'"],
        examples: ["vb-shell clipboard list current"]
      }),
    gateway("clipboard.list", ["list"], "Show regular or pinned clipboard", {
      helpOnly: true,
      notes: ["'list' shows the regular bucket, 'list pinned' the pinned bucket,",
        "'list current' the open panel's filtered view"],
      examples: ["vb-shell clipboard list", "vb-shell clipboard list pinned"]
    }),
    gateway("clipboard.pin", ["pin", arg("INDEX", "string")], "Pin one regular clipboard item", {
      output: { kind: "none", summary: "" },
      notes: ["A protected or out-of-range row is 'invalid-index'"],
      examples: ["vb-shell clipboard pin 0"]
    }),
    gateway("clipboard.unpin", ["unpin", arg("INDEX", "string")], "Unpin one pinned clipboard item", {
      output: { kind: "none", summary: "" },
      notes: ["Unpin is not a delete"],
      examples: ["vb-shell clipboard unpin 0"]
    }),
    gateway("clipboard.purge.regular", ["purge", arg("INDEX", "string")],
      "Delete one regular clipboard item", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        examples: ["vb-shell clipboard purge 0"]
      }),
    gateway("clipboard.purge.pinned", ["purge", "pinned", arg("INDEX", "string")],
      "Delete one pinned clipboard item", {
        parentHidden: true,
        output: { kind: "record", summary: "" },
        examples: ["vb-shell clipboard purge pinned 0"]
      }),
    gateway("clipboard.purge", ["purge", opt([arg("INDEX", "string")])],
      "Delete one clipboard item by list", {
        helpOnly: true,
        notes: ["'purge <ID>' targets the regular bucket, 'purge pinned <ID>' the pinned one"],
        examples: ["vb-shell clipboard purge 0", "vb-shell clipboard purge pinned 0"]
      }),
    gateway("clipboard.clear.regular", ["clear"], "Clear the regular clipboard list", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
      notes: ["Pinned rows and their retained paths are untouched"],
      examples: ["vb-shell clipboard clear"]
    }),
    gateway("clipboard.clear.pinned", ["clear", "pinned"], "Clear the pinned clipboard list", {
      parentHidden: true,
      output: { kind: "none", summary: "" },
      notes: ["Normal rows and their retained paths are untouched"],
      examples: ["vb-shell clipboard clear pinned"]
    }),
    gateway("clipboard.clear", ["clear"], "Clear the regular or pinned clipboard list", {
      helpOnly: true,
      notes: ["'clear' empties the regular bucket, 'clear pinned' the pinned one"],
      examples: ["vb-shell clipboard clear", "vb-shell clipboard clear pinned"]
    }),
    gateway("clipboard.select", ["select", arg("INDEX", "string")],
      "Select one row of the open panel's current filter", {
        output: { kind: "record", summary: "" },
        notes: ["Indices come from 'vb-shell clipboard list current'; a pending renderer is 'busy'"],
        examples: ["vb-shell clipboard select 2"]
      }),
    gateway("clipboard.copy.entry", ["copy", "entry",
      arg("BUCKET", "enum", { values: ["regular", "pinned"] }), arg("INDEX", "string")],
      "Put one history item back on the system clipboard", {
        parentHidden: true,
        usage: "copy entry regular|pinned <INDEX>",
        output: { kind: "record", summary: "" },
        notes: ["A missing file or a refused start never promotes the row"],
        examples: ["vb-shell clipboard copy entry regular 0", "vb-shell clipboard copy entry pinned 1"]
      }),
    // Client-owned: the Python client writes the selection with wl-copy after
    // confirming `clipboard ping`. The router never executes these rows.
    row("clipboard.copy.text", ["copy", "text", arg("TEXT", "string")],
      "Copy UTF-8 text from one literal word or stdin", {
        parentHidden: true,
        usage: "copy text <TEXT|->",
        output: { kind: "none", summary: "" },
        route: "clipboard-copy",
        notes: ["A lone '-' reads stdin as strict UTF-8, capped at 32 MiB; 'copy text -- -' is a literal '-'",
          "Payload never enters argv, an envelope, a temporary file, a log or the reply"],
        examples: ["vb-shell clipboard copy text 'hello world'", "printf 'hi' | vb-shell clipboard copy text -"]
      }),
    row("clipboard.copy.uri", ["copy", "uri", arg("URI", "string")],
      "Copy one absolute URI as text/uri-list", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        route: "clipboard-copy",
        notes: ["The scheme must be nonempty; CR, LF, NUL and unescaped spaces are refused"],
        examples: ["vb-shell clipboard copy uri 'https://example.org/a'"]
      }),
    row("clipboard.copy.file", ["copy", "file", arg("PATH", "string")],
      "Copy one file or directory URI, resolved from the caller's cwd", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        route: "clipboard-copy",
        notes: ["The path must exist; path segments are escaped as a file URI"],
        examples: ["vb-shell clipboard copy file ./notes.txt"]
      }),
    row("clipboard.copy.image", ["copy", "image",
      arg("MIME", "enum", { values: ["image/png", "image/jpeg", "image/gif", "image/webp",
        "image/bmp", "image/tiff"] }), "-"], "Copy image bytes from stdin", {
        parentHidden: true,
        output: { kind: "none", summary: "" },
        route: "clipboard-copy",
        notes: ["Magic bytes must match the declared MIME; input is capped at 32 MiB",
          "Bytes are written unchanged with the exact declared MIME"],
        examples: ["vb-shell clipboard copy image image/png - < shot.png"]
      }),
    row("clipboard.copy", ["copy", opt([arg("FORMAT", "ref")])],
      "Write new data to the system clipboard from the terminal", {
        helpOnly: true,
        notes: ["verbs are 'entry', 'text', 'uri', 'file' and 'image'; 'entry' restores a history row",
          "The four stream formats are client-owned; 'entry' is a gateway call",
          "No history entry is injected by a stream write and payload bytes never enter an envelope"],
        examples: ["vb-shell clipboard copy entry regular 0",
          "vb-shell clipboard copy text 'hello'",
          "vb-shell clipboard copy uri 'https://example.org/a'",
          "vb-shell clipboard copy file ./notes.txt",
          "vb-shell clipboard copy image image/png - < shot.png"]
      })
  ], {
    window: {
      summary: "Open, close or toggle the clipboard panel",
      examples: ["vb-shell clipboard window open", "vb-shell clipboard window toggle",
        "vb-shell clipboard window toggle pinned"],
      commands: ["clipboard.window.open", "clipboard.window.close", "clipboard.window.toggle"]
    },
    list: {
      summary: "Show regular or pinned clipboard",
      examples: ["vb-shell clipboard list", "vb-shell clipboard list pinned",
        "vb-shell clipboard list current"],
      commands: ["clipboard.list.regular", "clipboard.list.pinned", "clipboard.list.current"]
    },
    purge: {
      summary: "Delete one clipboard item from a list",
      examples: ["vb-shell clipboard purge 0", "vb-shell clipboard purge pinned 0"],
      commands: ["clipboard.purge.regular", "clipboard.purge.pinned"]
    },
    clear: {
      summary: "Empty a clipboard list",
      examples: ["vb-shell clipboard clear", "vb-shell clipboard clear pinned"],
      commands: ["clipboard.clear.regular", "clipboard.clear.pinned"]
    },
    copy: {
      summary: "Write new data to the system clipboard from the terminal",
      notes: ["verbs are 'entry', 'text', 'uri', 'file' and 'image'",
        "No history entry is injected by a stream write; the shell's watcher captures it",
        "The shell is confirmed with 'clipboard ping' before a stream write runs"],
      examples: ["vb-shell clipboard copy entry regular 0", "vb-shell clipboard copy text 'hello'",
        "vb-shell clipboard copy uri 'https://example.org/a'",
        "vb-shell clipboard copy file ./notes.txt",
        "vb-shell clipboard copy image image/png - < shot.png"],
      commands: ["clipboard.copy.entry", "clipboard.copy.text", "clipboard.copy.uri",
        "clipboard.copy.file", "clipboard.copy.image"]
    }
  }),

  target("emojiPicker", "Emoji picker", "Search for and copy emoji", [
    gateway("emojiPicker.open", ["open"], "Open the emoji picker window", {
      output: { kind: "none", summary: "" },
      notes: ["Opening the same bundle again leaves search and selection alone"],
      examples: ["vb-shell emojiPicker open"]
    }),
    gateway("emojiPicker.close", ["close"], "Close the emoji picker window", {
      output: { kind: "none", summary: "" },
      examples: ["vb-shell emojiPicker close"]
    }),
    gateway("emojiPicker.toggle", ["toggle"], "Toggle the emoji picker window", {
      output: { kind: "none", summary: "" },
      examples: ["vb-shell emojiPicker toggle"]
    }),
    gateway("emojiPicker.copy", ["copy", arg("ID", "ref")],
      "Copy one emoji by glyph, U+ code point, label or keyword", {
        output: { kind: "none", summary: "" },
        notes: ["Exact glyphs and U+ code points win over label/keyword search; ties use catalog source order",
          "The bundle's paste command is never run"],
        examples: ["vb-shell emojiPicker copy '😀'", "vb-shell emojiPicker copy U+1F600",
          "vb-shell emojiPicker copy 'grinning face'"]
      })
  ], {})
]

// Apply the injected verbs to every target once, at module evaluation time.
// The resulting records are ordinary objects, just like the declared rows.
var targetsById = Object.create(null)
var rowsById = Object.create(null)
for (var t = 0; t < targets.length; t++) {
  var targetEntry = targets[t]
  targetsById[targetEntry.id] = targetEntry
  var base = commonRows()
  for (var c = 0; c < base.length; c++) {
    var prefix = targets[t].id + "."
    var copy = {}
    var keys = Object.keys(base[c])
    for (var k = 0; k < keys.length; k++) copy[keys[k]] = base[c][keys[k]]
    copy.id = prefix + copy.id
    if (targets[t].id === "log" && copy.id !== "log.help") copy.route = "log-read"
    // Clipboard help pages never show an Output section, including the
    // injected help/status/ping rows.
    if (targets[t].id === "clipboard") {
      copy.output = { kind: copy.output.kind, summary: "" }
    }
    // Per-target status metadata customizes the injected row (summary, output,
    // notes, examples) without making it owner-dispatched; `visible` opts into
    // listing it on the target page and index.
    if (copy.id === prefix + "status" && targets[t].status
        && typeof targets[t].status === "object") {
      var sm = targets[t].status
      if (typeof sm.summary === "string") copy.summary = sm.summary
      if (sm.output && typeof sm.output === "object") copy.output = sm.output
      if (Array.isArray(sm.notes)) copy.notes = sm.notes
      if (Array.isArray(sm.examples)) copy.examples = sm.examples
      if (sm.visible === true) copy.visible = true
    }
    targets[t].rows.push(copy)
  }
  for (var r = 0; r < targetEntry.rows.length; r++) {
    var entry = targetEntry.rows[r]
    rowsById[entry.id] = entry
  }
}

// Confirmation-only orders. Each mutates state and every resulting value is
// available from a separate read verb (`status`, `get`, `list`, `is-open`).
// Publishing a fresh copy of that value would make the order look like a
// query, so their public output is none. `action()` rows already default to
// none; this list covers the gateway rows that still declared a projection.
var SILENT_ACTIONS = [
  "audio.volume.up", "audio.volume.down", "audio.volume.toggle", "audio.volume.set",
  "audio.microphone.up", "audio.microphone.down", "audio.microphone.toggle", "audio.microphone.set",
  "audio.sink.set", "audio.source.set", "audio.stream.set", "audio.stream.mute",
  "bar.enable", "bar.disable", "bar.toggle", "bar.show", "bar.hide", "bar.showToggle",
  "bar.position.set", "bar.layout.set", "bar.module.ID.island.open",
  "bar.module.ID.island.close", "bar.module.ID.island.toggle", "bar.module.ID.opt.KEY.set",
  "clipboard.window.open", "clipboard.window.close", "clipboard.window.toggle",
  "clipboard.purge.regular", "clipboard.purge.pinned", "clipboard.select",
  "clipboard.copy.entry",
  "colorPicker.pick", "colorPicker.close",
  "hyprlandSettings.reload",
  "inhibitor.start", "inhibitor.cycle.next", "inhibitor.cycle.back",
  // Menu navigation and row operations. The menu's read verbs (`current`,
  // `list`, `pages`, `item get`, `item options`, `confirm status`,
  // `flow status`, `search global|scoped`) remain the way to inspect state.
  "menu.open.inline", "menu.open.file", "menu.toggle.inline", "menu.toggle.file",
  "menu.close", "menu.go", "menu.back", "menu.select", "menu.search.clear",
  "menu.item.ROW.activate", "menu.item.ROW.open", "menu.item.ROW.close",
  "menu.item.ROW.toggle", "menu.item.ROW.set", "menu.item.ROW.step.up",
  "menu.item.ROW.step.down", "menu.item.ROW.choose", "menu.item.ROW.info.open",
  "menu.item.ROW.info.close", "menu.item.ROW.confirm.next",
  "menu.item.ROW.confirm.cancel", "menu.item.ROW.flow.next",
  "menu.item.ROW.flow.back", "menu.item.ROW.flow.commit",
  "menu.item.ROW.flow.cancel", "menu.item.ROW.flow.set", "menu.item.ROW.delete"
]
for (var silent = 0; silent < SILENT_ACTIONS.length; silent++) {
  var actionRow = rowsById[SILENT_ACTIONS[silent]]
  if (actionRow) actionRow.output = { kind: "none", summary: "" }
}

var Manifest = {
  version: 1,
  common: commonRows(),
  targets: targets
}

// Public target ids in code-point order, for a deterministic index.
function targetIds() {
  var ids = []
  for (var i = 0; i < targets.length; i++) ids.push(targets[i].id)
  ids.sort()
  return ids
}

function findTarget(id) {
  return typeof id === "string" ? targetsById[id] || null : null
}

function findRow(id) {
  return typeof id === "string" ? rowsById[id] || null : null
}

// Top-level verb spellings for `Registry.offer` on a migrated owner. Row
// order is catalog order; the common suffix matches UnitIpc's table.
function topLevelVerbs(publicId) {
  var t = findTarget(publicId)
  if (!t) return []
  var verbs = []
  for (var i = 0; i < t.rows.length; i++) {
    // A help-only signature is presentation, not a published verb.
    if (t.rows[i].route === "injected" || t.rows[i].helpOnly === true) continue
    var w = t.rows[i].words[0]
    if (typeof w !== "string" || verbs.indexOf(w) >= 0) continue
    verbs.push(w)
  }
  var suffix = ["status", "help", "ping"]
  for (var s = 0; s < suffix.length; s++) {
    if (verbs.indexOf(suffix[s]) < 0) verbs.push(suffix[s])
  }
  return verbs
}

// Ids every handler is expected to register, derived from the table. The
// manifest tests compare this with the registered maps in the QML files.
function publicRowIds() {
  var ids = []
  for (var i = 0; i < targets.length; i++) {
    var rows = targets[i].rows
    for (var j = 0; j < rows.length; j++) {
      if (rows[j].route !== "gateway" && rows[j].route !== "compat") continue
      // A help-only row is presentation in the parent pages; no owner may
      // dispatch it and no registration is required for it.
      if (rows[j].helpOnly === true) continue
      ids.push(rows[j].id)
    }
  }
  return ids.sort()
}

// Every row that describes a real command, including help-only signatures
// that appear in parent help but cannot be invoked.
function allRowIds() {
  var ids = []
  for (var i = 0; i < targets.length; i++) {
    for (var j = 0; j < targets[i].rows.length; j++) ids.push(targets[i].rows[j].id)
  }
  return ids
}
