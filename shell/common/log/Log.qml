pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "LogCore.js" as Core
import "LogSpec.js" as Spec
import "LogScope.js" as Scope

// Scoped logging for the whole shell, over Quickshell's handler.
//
// Nothing here owns a sink, a file, a format or a handler: a record goes to
// `console.info` / `warn` / `error` / `debug`, which is QML's own console
// object, which Qt routes to the message handler, which Quickshell installs.
// So the log lands in the terminal, in the journal, and in the `log.qslog`
// Quickshell already writes, at the severity the level asked for - which is
// what keeps `qs --log-rules` and a journal priority meaningful. Timestamps are
// absent because Quickshell omits them unless `--log-times` is passed; nothing
// here has to strip them.
//
// What the shell adds is the two things Qt cannot: the scope, derived from the
// call site, and the gate, so a suppressed record costs a comparison.
//
//   Log.info("cleared clipboard")      ->  INFO qml: clipboard: cleared clipboard
//   Log.debug("updated", count, list)  ->  DEBUG qml: clipboard: updated 3 [1, 2, 3]
//
// The level word is deliberately absent from the text: the handler has already
// printed it, and repeating it would put `INFO` in every line twice.
//
// This file is the tree's `Log` and it is a facade. It owns *when* the
// configuration is resolved - the environment, once, at construction - plus the
// boot readiness predicate and the IPC surface. `LogCore.js` owns what it
// resolves to, because a QML singleton is unreachable from a `.pragma library`
// and most of the code deep enough to want a DEBUG record is a script.
//
// It reads the environment and nothing else. There is no settings option and
// no per-scope map, which is why this file never names `Settings`: the boot
// catalog's first unit constructing the settings store early would be an
// ordering hazard in this layer, and a single synchronous source keeps it
// out. The spec grammar and the precedence rules the spec resolves against
// live in `LogSpec.js`.
Singleton {
  id: root

  readonly property string tag: "log"
  readonly property string envVar: Core.ENV_VAR

  // What the boot catalog's `ready` predicate reads. Set here rather than
  // read back from LogCore, because a `.pragma library` is a plain JS object
  // with no change notification: a binding over `Core.ready()` would be
  // evaluated once and cached, so it could never report the configuration
  // arriving. Nothing is awaited - a singleton is constructed by its first
  // reference, and the gate is installed in the same turn - so this is an
  // observation of work done rather than a literal `true`.
  property bool _gateInstalled: false
  readonly property bool ready: root._gateInstalled
  readonly property bool fromEnv: Core.fromEnv()

  // The frame of the call site in a trace captured inside LogCore.emit: 0 is
  // `emit`, 1 is this method, 2 is whoever called it. A caller that reaches
  // LogCore directly lands on the same index - LogCore's own shorthand occupies
  // the slot this method occupies - which is why the two constants agree
  // instead of differing. `JS_DEPTH` in LogCore carries the arithmetic for the
  // direct path; this one is named because it is the one this file uses.
  readonly property int callerDepth: 2

  function info(...parts) { return Core.emit("info", parts, "", root.callerDepth) }
  function warn(...parts) { return Core.emit("warn", parts, "", root.callerDepth) }
  function error(...parts) { return Core.emit("error", parts, "", root.callerDepth) }
  function debug(...parts) { return Core.emit("debug", parts, "", root.callerDepth) }
  function trace(...parts) { return Core.emit("trace", parts, "", root.callerDepth) }

  // at(scope) -> a logger that claims a scope instead of deriving one.
  //
  // `at()` with no argument is the DERIVED-scope logger: it emits and gates
  // under the caller's own scope, which is what makes the gate pattern correct
  // without restating a scope string at each call site.
  function at(scope) { return Core.at(scope) }

  // allows(level, scope) -> whether a record would be emitted. A caller
  // wrapping expensive work in a debug log asks this first, rather than
  // building a payload that is then thrown away.
  //
  // With no scope, this answers for the CALLER's scope, not for `log`'s. A
  // fallback to `root.tag` would mean a component asking whether it may log
  // a DEBUG line is told whether the LOGGER may - and since the two are
  // configured independently, the answer would be routinely false in a scope
  // that allows it. A guard that silently always says "no" is worse than no
  // guard, because the payload it skips is never built and the line never
  // appears.
  //
  // The capture here does not weaken the rule that a suppressed record costs
  // one map read and no stack: that rule is about `emit`, which is what every
  // record goes through. This is the explicit pre-flight call, and a trace
  // capture is far cheaper than the payload it exists to avoid building.
  // `Log.at(scope).allows(level)` is the free form when the caller already has
  // a scoped logger.
  function allows(level, scope) {
    if (typeof scope === "string" && scope !== "") return Core.allows(level, scope)
    return Core.allows(level, Scope.scopeFromStack(new Error().stack, 1))
  }

  // summarize(value) -> the bounded form of a value, for a line that has to
  // name what it saw without printing all of it.
  //
  // Exposed here so the 48-character bound stays ONE number in this tree
  // rather than a per-caller habit. `Settings` imports LogSpec directly and
  // could keep doing so; everything else goes through here, because a module
  // that wants the bound should not have to know which script defines it.
  //
  // This is not a privacy control. It decides how a value is PRINTED, not
  // which values a caller may hand it - a secret never reaches this function,
  // it is replaced before the line is built.
  function summarize(value) { return Spec.summarize(value) }

  Component.onCompleted: {
    Registry.offer("log", {
      title: "Logging",
      description: "the scoped shell log, its level gate and its scope rules",
      verbNames: [
        "status",
        "help",
      ]
    })
    Registry.register("log", root)

    // One source, read once, in this turn. `configure` resolves in the turn
    // it is called, so the gate and the configuration land together. The
    // environment is the whole configuration, and this file never names
    // `Settings`, so nothing constructs the settings store before `paths`
    // and `watch` have been drained.
    //
    // `_gateInstalled` is set AFTER the call, because the boot catalog's
    // readiness predicate reads it and it must not report ready before the
    // gate exists. `announce` inside `configure` prints through `console`
    // directly and is deliberately not gated.
    Core.configure(Quickshell.env(root.envVar))
    root._gateInstalled = true
  }
  Component.onDestruction: Registry.unregister("log")

  function status() {
    return JSON.stringify({
      envVar: root.envVar,
      spec: Core.specText(),
      fromEnv: Core.fromEnv(),
      baseLevel: Core.baseLevel(),
      levels: Core.levels(),
      overrides: Core.overrides(),
      silenced: Core.silenced(),
      warnings: Core.warnings()
    })
  }

  IpcHandler {
    target: "log"

    function status(): string {
      return root.status()
    }
    function help(): string {
      return root.help()
    }
  }

  function help() {
    return [
      "vibranium log",
      "",
      "a scope is derived from the file the call was written in:",
      "  features/clipboard/Clipboard.qml                 -> clipboard",
      "  features/bar/modules/ArchUpdates/ArchUpdates.qml  -> bar.archUpdates",
      "  features/ and common/ are stripped, and so are services/ and boot/.",
      "Log.at(name) claims a scope explicitly; a script imports LogCore.js",
      "and calls the same five names.",
      "",
      Spec.grammar(),
      "",
      root.envVar + " is the ONLY configuration: there is no settings",
      "option and no per-scope map. Unset means the built-in level,",
      "which is " + Spec.DEFAULT_LEVEL + ".",
      "",
      "example: " + root.envVar + "=debug,info,bar=warn,-bar.archUpdates",
      "  errors, warnings, info and debug everywhere except under bar, where",
      "  bar's own pin reduces it to warnings and errors"
    ].join("\n")
  }
}