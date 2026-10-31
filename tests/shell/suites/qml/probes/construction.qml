// Probe: every QML type the tree's qmldir files declare, constructed headlessly.
//
// The claim under test is narrow: **a declared type must construct under the
// offscreen platform without a QML error.** Not "renders correctly" - there is
// no render loop here - but the failures that actually happen in practice: a
// qmldir entry that names a file which no longer declares the type, a binding
// that throws while the object is being built, a circular component
// dependency, a JS type error in a Component.onCompleted.
//
// Why the case list is generated: QML resolves `Alias.Type` at compile time, so
// a probe that named 200 types by hand would be a hand-maintained copy of the
// 48 qmldir files, and a type added to a qmldir without being added here would
// go uncovered. The driver generates the list; because Quickshell's config
// directory has no implicit same-directory import, the probe reaches it
// through a Loader rather than through a bare identifier.
//
// Why each case is a string handed to Qt.createQmlObject, and not a
// `Component { Alias.Type {} }` block in that generated file: a block is
// resolved when the file loads, so one type whose file needs a PanelWindow
// makes the whole document unresolvable and takes the other 200 with it. That
// is not hypothetical - it is what the first version of this probe did, and it
// reported three observations instead of 200. Qt.createQmlObject compiles one
// small document at a time, so a document that fails to compile fails alone,
// and the diagnostic it throws carries the whole chain ("Type X unavailable"
// down to the frame that actually said no) - which is where a
// needs-environment reason comes from.
//
// A singleton cannot be instantiated at all - `Alias.Paths { }` is refused with
// "Composite Singleton Type Paths is not creatable" - so a singleton case is a
// one-property object whose binding names the singleton. QQmlEngine creates a
// singleton the first time anything names it, so the binding is the
// construction.
//
// A type that declares `required property` cannot be built bare, and the
// refusal is correct code rather than a defect: the engine names the property
// it wanted, the case supplies null for it, and the case asks again. Reading
// the names out of the source instead would mean guessing which
// `required property` lines belong to the type rather than to a delegate
// nested in it, and a wrong guess is its own false failure.
//
// Nothing here is expected to be clean. Under QT_QPA_PLATFORM=offscreen
// Quickshell loads no PanelWindow backend, so every type whose file reaches a
// window cannot be built at all. That is an environment fact and not a defect,
// and it is what the bucket split is for: `declared-but-uncreatable` for a type
// whose own root object is a Quickshell C++ type, `needs-environment` for a
// type that builds once a real windowing backend exists, and `broken` - which
// must be empty - for a genuine construction error.

import QtQuick
import Quickshell

Item {
  id: probe
  width: 1
  height: 1

  // The roots this process actually built against, read back out rather than
  // assumed. The driver hands the probe a private XDG/VIBRANIUM environment so
  // that constructing the shell's own Paths, Settings, FilePresence and Watch
  // singletons cannot read or write the session's configuration; these four are
  // how the driver checks that the isolation was really in force.
  readonly property var isolation: [
    "XDG_CONFIG_HOME=" + String(Quickshell.env("XDG_CONFIG_HOME")),
    "XDG_STATE_HOME=" + String(Quickshell.env("XDG_STATE_HOME")),
    "XDG_CACHE_HOME=" + String(Quickshell.env("XDG_CACHE_HOME")),
    "VIBRANIUM_RUNTIME=" + String(Quickshell.env("VIBRANIUM_RUNTIME"))
  ]

  // The generated case list: the driver writes ConstructionWorklist.qml into
  // the harness's mirror of the shell tree, beside this probe. Each row is
  // [module, name, kind, bucket, reason].
  Loader { id: worklist; source: "ConstructionWorklist.qml" }

  // A value containing a newline is escaped so one KV stays one line and the
  // parser never sees a split record.
  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // The environment refusals a shell type is allowed to make. Each is a phrase
  // Quickshell itself puts in the diagnostic, so "this type needs a real
  // display" is read off the error rather than guessed from the type's name.
  //
  // A refusal that is NOT in this table is a genuine construction error and
  // lands in `broken`, so a type that starts needing something new is a broken
  // type until somebody says which environment it needs. The driver pins both
  // the table and the type list.
  readonly property var environmentRefusals: [
    { needle: "No PanelWindow backend loaded", why: "No PanelWindow backend loaded" }
  ]

  // Bounded so a case cannot loop: a type with an unbounded chain of required
  // properties, or a pathological one, has to end as a reported failure rather
  // than as a run that never prints the sentinel. The tree's deepest is far
  // below this.
  readonly property int maxSupplies: 12

  property var tallies: ({})

  // One self-contained QML document. A singleton case binds a property to the
  // singleton's name, which is what makes the engine build it.
  function sourceFor(module, name, kind, args) {
    if (kind === "singleton") {
      return "import QtQml\nimport " + module + " as A\nQtObject { property var touch: typeof A." + name + " }"
    }
    return "import " + module + " as A\nA." + name + " { " + args + " }"
  }

  // The deepest frame of a failed construction with the "file:line:col: "
  // prefix removed: the last thing the type itself said, rather than the
  // cascade of "Type X unavailable" frames above it. The whole message when the
  // chain is a single line.
  function reasonOf(message) {
    const lines = String(message).split("\n").filter(l => l.trim() !== "")
    if (lines.length === 0) return String(message)
    return lines[lines.length - 1].trim().replace(/^[^\s]*:\d+:\d+:\s*/, "")
  }

  // A refusal the table names is an environment the type needs; anything else
  // is a construction error, and keeps the whole diagnostic because a truncated
  // one is not a report.
  function bucketFor(message) {
    const deepest = reasonOf(message)
    for (const refusal of probe.environmentRefusals) {
      if (deepest.indexOf(refusal.needle) >= 0) {
        return { bucket: "needs-environment", why: refusal.why }
      }
    }
    return { bucket: "broken", why: message }
  }

  // The observation prefix every type's verdict is filed under, and the prefix
  // the driver looks its keys up by. Named so the two cannot drift.
  readonly property string typePrefix: "type."

  // Record one case's verdict, and count it.
  function verdict(key, errKey, bucket, why, supplied) {
    kv(key, bucket)
    if (bucket !== "clean") kv(errKey, why)
    if (supplied !== "") kv("supplied." + key.substring(probe.typePrefix.length), supplied)
    probe.tallies[bucket] = (probe.tallies[bucket] || 0) + 1
    return bucket
  }

  // One case, built at most maxSupplies times: once bare, and once more for
  // each `required property` the engine names.
  function runCase(entry) {
    const module = entry[0]
    const name = entry[1]
    const kind = entry[2]
    const key = probe.typePrefix + module + "." + name
    const errKey = "err." + module + "." + name

    if (entry[3] !== "construct") {
      // The driver already knows this one cannot be built here and why, and
      // hands the reason over rather than the probe re-deriving it.
      return verdict(key, errKey, entry[3], entry[4], "")
    }

    let args = ""
    for (let attempt = 0; attempt <= probe.maxSupplies; attempt++) {
      let made
      try {
        made = Qt.createQmlObject(sourceFor(module, name, kind, args), probe,
          "/vb-construction-case.qml")
      } catch (e) {
        const message = String(e && e.message ? e.message : e)
        const wanted = /Required property ([A-Za-z_][A-Za-z0-9_]*) was not initialized/.exec(message)
        // Only supply a property this case has not already supplied, or a
        // second refusal for the same one would loop to the bound.
        if (wanted !== null && args.indexOf(wanted[1] + ":") < 0) {
          args = args === "" ? wanted[1] + ": null" : args + ", " + wanted[1] + ": null"
          continue
        }
        const answer = probe.bucketFor(message)
        return verdict(key, errKey, answer.bucket, answer.why, args)
      }
      if (made === null) {
        return verdict(key, errKey, "broken",
          "Qt.createQmlObject returned null for a document it had already compiled", args)
      }
      made.destroy()
      return verdict(key, errKey, "clean", "", args)
    }
    return verdict(key, errKey, "broken",
      "still demanding a required property after " + (probe.maxSupplies + 1) + " attempts: " + args, args)
  }

  Component.onCompleted: {
    if (worklist.item === null) {
      // The generated list did not load, so nothing was covered. A run that
      // cannot report is not a run that passed. Loader.status is reported
      // rather than errorString because this Loader has no errorString: 3 is
      // Loader.Error, and the transcript qp_run captured is where the
      // diagnostic is.
      kv("probe.error", "the generated case list did not load, Loader.status " + worklist.status)
      kv("probe.cases", "0")
      kv("probe.complete", "false")
      console.log("##DONE##")
      return
    }

    // qmllint disable missing-property
    // The case list is a property of a file this probe has never seen: the
    // driver generates it into the harness mirror, so its type is not
    // statically knowable here and is not knowable to qmllint either.
    const cases = worklist.item.cases
    kv("probe.isolation", probe.isolation.join(" "))
    kv("probe.listed", cases.length)
    for (let i = 0; i < cases.length; i++) {
      // The list ends with a bare "" so the array literal has no dangling
      // comma. It is not a case.
      if (cases[i] === "") continue
      try {
        runCase(cases[i])
      } catch (e) {
        // A throw outside a case's own try/catch is a defect in the probe, not
        // in the type. Recorded with its index so it is attributable, and the
        // run continues.
        kv("probe.case.error", "[" + i + "] " + String(e && e.message ? e.message : e))
      }
    }

    let reported = 0
    for (const b in probe.tallies) reported += probe.tallies[b]
    kv("probe.cases", reported)
    kv("probe.complete", reported + 1 === cases.length)
    console.log("##DONE##")
  }
}
