// Guard emission for menu bundles: the one bash script that answers every
// `when:` / `checked:` / `disabled:` / `requires:` expression in a page set.
//
// WHY IT IS ITS OWN MODULE. This is the only place the menu concatenates
// config-authored shell source, and the emitted text is a contract: a guard
// batch is read back line by line as `<uid>:<w|c|d>:<0|1>`. Keeping the
// emission (and its quoting rules) beside the parser that reads it would mean
// two files owning one format; keeping all of it here means the format is
// stated once, in the functions that write it. MenuLib re-exports the five
// entry points so every existing caller keeps its import.
.pragma library

.import "../../common/text/StringUtils.js" as SU

// One bash script for every when:/checked:/disabled: expression in the
// bundle, reporting `<uid>:<w|c|d>:<0|1>` per line. The menu opens on the
// previous evaluation's answers, so however long this takes is how long a
// row can contradict the state it describes.
function buildGuardScript(pages) {
  let script = ""
  for (let p = 0; p < pages.length; p++) {
    const items = pages[p].items
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      // `when` and `requires` are INDEPENDENT conditions on one row, so they
      // answer as one verdict, and they are emitted as ONE `w` line for the
      // same uid: the reader collapses a repeated uid last-one-wins, so a
      // second line would let an OR stand in for an AND, and an extension
      // that added a `requires` to a row whose own `when` said false would
      // make the row show. A refused `requires` shape is an unconditional
      // hide, which is not an expression and so cannot be ANDed; it wins
      // outright.
      const rq = requiresExpr(item.requires)
      const when = typeof item.when === "string" ? item.when.trim() : ""
      // A `when` that is not a string is a config error, and the two ways of
      // answering it were a silent drop and a hard hide - the same mistake met
      // two different fates depending on which field carried it. The drop was
      // the worse of the two: the row then rendered with no verdict at all,
      // and a missing verdict reads as VISIBLE, so a typo in a guard unhid the
      // row it was meant to hide. Same fail-open the reader had on a nonzero
      // exit, one level down. Refuse it the way a refused `requires` is
      // refused, and the two fields finally agree.
      if (rq === null || (item.when !== "" && typeof item.when !== "string"))
        script += hideLine(item.uid)
      else if (rq === undefined) script += guardLine(item.uid, "w", when)
      else script += guardLine(item.uid, "w", when === "" ? rq : when + " && " + rq)
      script += guardLine(item.uid, "c", item.checked)
      script += guardLine(item.uid, "d", item.disabled)
    }
  }
  return script
}

// The shell expression a structured `requires` compiles to.
//
// Three answers, and the middle one is the reason this is not a boolean:
// `undefined` means the row declared no requirement at all, `null` means it
// declared one this evaluator refuses, and a string is the expression. An
// absent requirement and a refused one must not collapse - the first is a row
// free to show, the second is a row that cannot prove itself, and treating the
// refused shape as "no constraint" would show a row the author gated.
function requiresExpr(requires) {
  if (requires === undefined || requires === null) return undefined
  // A non-object reaches the property probes below and reads as "declared
  // nothing", which is the one answer that must not be inferred from a shape
  // that is not a requirement at all.
  if (typeof requires !== "object" || Array.isArray(requires)) return null
  const exprs = []
  if (requires.binary !== undefined) {
    // Upper case is a program name too (Hyprland, Xwayland), and the name
    // must be lower case, so a row gated on one is hidden on every machine.
    // The first character may not be a hyphen: it would reach `type` as an
    // option.
    if (typeof requires.binary !== "string"
      || !/^[a-z0-9._-]+$/.test(requires.binary))
      return null
    // `type -P`, not `command -v`. The latter answers for shell builtins,
    // keywords and functions as well as PATH programs, so `{"binary":"cd"}`
    // or `{"binary":"true"}` passed on every machine and showed a row that was
    // gated on a program being installed. `type -P` reports PATH files only.
    exprs.push("type -P " + requires.binary + " >/dev/null")
  }
  if (requires.chassis !== undefined) {
    // Quoted on every arm. Inside [[ ]] there is no word splitting so the
    // answers coincide either way, but the right-hand side is a glob pattern
    // and the shipped bundles already spell one of the three arms this way -
    // an unquoted expansion here was the odd one out.
    if (requires.chassis === "laptop") exprs.push("[[ \"$CHASSIS_TYPE\" == laptop ]]")
    else if (requires.chassis === "vm") exprs.push("[[ \"$CHASSIS_TYPE\" == vm ]]")
    else if (requires.chassis === "!vm") exprs.push("[[ \"$CHASSIS_TYPE\" != vm ]]")
    else return null
  }
  if (exprs.length === 0) return null
  return exprs.join(" && ")
}

// Structured requires ({chassis} and/or {binary}) emitted as a `w` guard
// in the same batch shape. An unknown shape refuses the row (it renders
// muted, never usable).
//
// It does not LOG one, and the previous version of this comment said it did.
// A pure library has no logger, and a row silently deleted by a typo in a
// config file is the worst kind of surprise, so the honest options are to give
// the library a channel or to stop claiming one: the refusal is visible in the
// emitted script as an unconditional `echo <uid>:w:0`, which is at least
// checkable, and Menu's own log reports the batch that carried it.
function requiresGuard(uid, requires) {
  const expr = requiresExpr(requires)
  if (expr === undefined) return ""
  if (expr === null) return hideLine(uid)
  return guardLine(uid, "w", expr)
}

// A page id and an item id both reach the reader through the echo
// argument, and neither is sanitized the way a `when` expression is, so
// the verdict token is assembled as data and quoted in one piece. An
// apostrophe in a page or item id then stays inside the argument instead
// of ending it and running whatever follows.
function hideLine(uid) {
  return "echo " + SU.shellQuote(uid + ":w:0") + "\n"
}

function guardLine(uid, tag, expression) {
  if (typeof expression !== "string" || expression.trim() === "") return ""
  // `expression` is config-authored shell source by design and stays that
  // way: when/checked/disabled are a trusted local-config compatibility
  // surface evaluated by one batched bash run, not a data-only API, and
  // this is the only place the menu concatenates it. Extension or remote
  // configuration that must not be able to run source has to arrive as a
  // structured action descriptor (argv plus a call target), never as text
  // on this path. Only the verdict token is data, and it is quoted.
  // A trailing semicolon in the expression is stripped rather than doubled,
  // so the emitted braces stay well-formed bash.
  const expr = expression.trim().replace(/;+$/, "")
  if (expr === "") return ""
  return "if { " + expr + "; } >/dev/null 2>&1"
    + "; then echo " + SU.shellQuote(uid + ":" + tag + ":1")
    + "; else echo " + SU.shellQuote(uid + ":" + tag + ":0") + "; fi\n"
}

