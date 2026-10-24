// Pure rules behind the binary-launch fallback: what a query may name, how the
// executable set on PATH is indexed, and the two lines the row paints. No Qt
// import, no api, no PATH - every function here is a total function of its
// arguments, which is what makes the claim drivable from a suite with no
// engine, no policy view and no filesystem.
//
// The plugin that uses this carries a byte-identical copy of the block below,
// because its main.js is EVALUATED AS TEXT (see PluginInstance.qml) and cannot
// import a library the way a QML module can. This file and that one are one
// source with two homes; the launcher suite compares the two copies line for
// line, so an edit to either is a visible diff in the other.

// The one character that forces a binary claim past a desktop entry already
// matching the same name. It is stripped before the lookup, so "thunar" and
// "!thunar" resolve through the same index and the escape changes only
// whether the launcher asks, never what it finds.
var FORCE_PREFIX = "!"

// What one executable on PATH can be named. The claim is a whole-token
// equality test against the executable set rather than a search, so this is
// the whole of what can ever match: no path separator, no whitespace, and no
// shell metacharacter that would need quoting to survive a launch. A query
// carrying one is not a binary name and is refused here rather than looked up
// and missed.
var NAME_RE = /^[A-Za-z0-9._+-]+$/

// The executable name the live query asks for, or "" when it asks for none.
// A leading FORCE_PREFIX is one escape rather than a mode: the plugin answers
// the same row either way, and only the launcher's gate reads the difference.
function binaryQuery(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  if (raw.charAt(0) === FORCE_PREFIX) raw = raw.substring(1).trim()
  if (raw === "") return ""
  if (raw.charAt(0) === "-") return ""
  if (!NAME_RE.test(raw)) return ""
  return raw
}

// Lowercased name -> the on-disk spelling, so the query is matched the way the
// launcher searches (case-insensitively) while the launched argv keeps the
// real name. Object.create(null) because PATH can hold a binary called
// "constructor" or "toString", and an inherited property would answer for it
// as though the name were installed.
//
// First spelling wins on a duplicate: the scan prints in PATH order, and that
// is the directory a launch would resolve the name to. Case variants are NOT
// duplicates here - LS and ls are two different files on a case-sensitive
// filesystem, and the first one PATH reaches is the one a launch would run.
function binaryIndex(names) {
  var out = Object.create(null)
  var list = Array.isArray(names) ? names : []
  for (var i = 0; i < list.length; i++) {
    var n = String(list[i] === undefined || list[i] === null ? "" : list[i])
    if (n === "") continue
    var key = n.toLowerCase()
    if (out[key] === undefined) out[key] = n
  }
  return out
}

// The installed spelling of `name`, or "" when PATH holds no such binary.
function binaryMatch(index, name) {
  if (index === null || index === undefined) return ""
  var key = String(name === undefined || name === null ? "" : name).toLowerCase()
  var hit = index[key]
  return typeof hit === "string" ? hit : ""
}

// The two lines the row paints. The label names the command and the sub says
// what accepting it does, which is the one thing a bare binary name cannot say
// for itself: that this runs a program rather than opening a desktop entry.
function launchLabel(name) {
  return "Launch " + name
}

function launchSub(name) {
  return "Launch " + name + " binary"
}

// Binary-launch plugin for AppLauncher: offers a program on PATH when the
// query IS that program's name.
//
// Silent by construction. A plugin with a keyword can be entered as a mode;
// this one declares an empty one, so there is no prefix to type and no way to
// summon it directly. It is reached only by claiming - and what it claims is
// the fallback slot, the single synthetic row the launcher shows when nothing
// local matched. So the shape of the feature is: "qt6c" offers the web search,
// and the moment the query becomes "qt6ct" that same row reads "Launch qt6ct"
// instead. Nothing is added to the list; one row changes.
//
// A desktop entry always wins that slot, because a matching entry keeps the
// app pool non-empty and the fallback is only consulted when the pool is empty
// - "thunar" stays "File Manager", "spotify" stays "Spotify". The "!" prefix
// is the way past it: "!thunar" forces the claim the entry would otherwise take
// away, and the row goes to the top of the list so Enter reaches it directly.
//
// The executable set comes from the launcher, never from this file: PATH
// changes with every package install, and a shipped list would be wrong the day
// after it was written. The pair of capabilities that carries it is
// requestBinaries/cachedBinaries (see PluginPolicy.js) - ask for a rescan, read
// what landed - and a plugin denied the request half simply reads the cache
// the launcher already filled, which is why cachedBinaries is a default grant
// and only the request is a privilege.

(function() {
  let api = null

  // The last cache record the index was built from, held by identity. The
  // controller replaces the record wholesale when a scan settles, so an
  // unchanged reference is a scan that has not moved, and rebuilding would
  // re-fold a few thousand names for no reason. items() runs on every
  // recompute, which is every keystroke, so this is the difference between one
  // map lookup per keypress and a full reindex.
  let indexSource = null
  let index = null

  // Adopt-lib: delegates to api.shellQuote (StringUtils.shellQuote
  // semantics); the inline fallback below mirrors it for hosts without the api.
  // The name came out of a PATH scan rather than from the user, so it is not a
  // shell metacharacter by construction - but it still reaches a shell word,
  // and the quoting is what makes that safe to change.
  function shellQuote(s) {
    return api.shellQuote(s)
  }

  // Ask for a rescan if the capability is held, then read what landed. The ask
  // is TTL-guarded and in-flight-guarded on the launcher side, so this can be
  // unconditional on every recompute: the guard belongs where the process is,
  // not in a plugin that cannot see one.
  function executables() {
    if (api === null) return null
    if (typeof api.requestBinaries === "function") api.requestBinaries()
    // The read half is a default grant on every policy, so it is normally
    // present - but a denied operation is ABSENT from the object rather than
    // present and refusing, so a host that withheld it leaves a hole here
    // rather than a value. Asking is the same question as the request, so both
    // halves are feature-detected and a host that grants neither simply cannot
    // answer, which is the correct verdict for a plugin with no executable set.
    if (typeof api.cachedBinaries !== "function") return null
    const cache = api.cachedBinaries()
    if (cache === null || cache === undefined) {
      indexSource = null
      index = null
      return null
    }
    if (cache !== indexSource) {
      indexSource = cache
      index = binaryIndex(cache.names)
    }
    return index
  }

  VibraniumPlugin = {
    init: function(context) {
      api = context
    },

    // One row, and only when the query IS an installed program. Anything else -
    // a partial name, a name nothing provides, a path, an option, a blank
    // field - answers with no rows at all, which is what hands the fallback
    // slot on to the web search below it in the chain.
    items: function(query) {
      const name = binaryQuery(query)
      if (name === "") return []
      const match = binaryMatch(executables(), name)
      if (match === "") return []
      return [{
        label: launchLabel(match),
        sub: launchSub(match),
        desc: "",
        icon: "application-x-executable",
        // The resolved spelling travels as the payload so activate() runs the
        // name this row was built from, and so a row whose match changed is
        // not the same row to the change-aware comparison above it.
        data: { exec: match }
      }]
    },

    // The one exit from this process, and the same one every app row takes:
    // vb-launch-cmd focuses a window whose class already matches the command
    // and otherwise starts it through app2unit. Routing here rather than
    // exec-ing the binary directly is what makes a second invocation focus the
    // running instance instead of stacking another one.
    activate: function(item, query) {
      const carried = item && item.data ? String(item.data.exec ?? "") : ""
      const name = carried !== "" ? carried : binaryMatch(executables(), binaryQuery(query))
      if (name === "") return
      api.execDetached("vb-launch-cmd -- " + shellQuote(name) + "\n")
    }
  }
})()
