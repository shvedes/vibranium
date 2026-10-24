// Neutral command contract: data reaches a process as an argv element or as
// an environment value, never as shell source. Every function is pure and
// returns a stable result object; nothing here spawns, signals, or resolves
// anything, so a caller that ignores a rejected result still cannot run a
// partially built command.
//
// `argv` is the default form. `trustedShell` is a compatibility form for fixed
// source that genuinely needs shell features (pipes, redirection, globbing);
// its source is a literal in the caller, and anything dynamic must travel as a
// positional argument or an environment entry.
//
// `templateShell` builds the reference form
// `/bin/sh -c template sh arg1...`, so the interpreter's `$0` is fixed and
// data occupies `$1` and up. A template may only name a command and pass it
// data: every word is inert literal text or a double quoted reference, so the
// form cannot carry a pipeline, a redirection, or a command substitution, and
// data is never split into fields or globbed. Data is never inserted into
// source, so metacharacters stay data in every form.
.pragma library

const ARGV = "argv"
const TEMPLATE = "template"
const TRUSTED_SHELL = "trusted_shell"
const TRUSTED_ENV = "trusted_env"
const INTERPOLATION = "interpolation"
const POSIX_SHELL = "/bin/sh"
const SHELL_ARGV0 = "sh"

// A bare template word is inert only when it carries no shell syntax. The
// set excludes separators, operators, substitutions, quoting characters,
// globbing, and every expansion sigil.
const INERT_WORD = /^[A-Za-z0-9._:/@%+=,-]+$/

function argv(command) {
  if (!Array.isArray(command)) return invalid("invalid_argv")
  if (command.length === 0) return invalid("invalid_argv")
  for (let i = 0; i < command.length; i++) {
    if (!isData(command[i])) return invalid("invalid_argv")
  }
  return result(ARGV, { argv: command.slice() })
}

function trustedShell(script, options) {
  if (typeof script !== "string" || script.trim() === "") return invalid("invalid_script")
  if (!isObject(options)) return invalid("invalid_options")
  if (options.trusted !== true) return invalid("untrusted_shell")
  if (options.trusted_env === true && !validEnv(options.env)) return invalid("invalid_env")
  if (options.trusted_interpolation === true && !validHoles(options.holes)) {
    return invalid("invalid_hole")
  }

  const source = {}
  if (options.shell !== undefined) {
    if (!isData(options.shell)) return invalid("invalid_shell")
    source.shell = options.shell
  }
  if (options.argv0 !== undefined) {
    if (!isData(options.argv0)) return invalid("invalid_argv0")
    source.argv0 = options.argv0
  }

  const env = options.trusted_env === true ? normalizeEnv(options.env) : []
  return result(TRUSTED_SHELL, {
    argv: shellArgv(script, source),
    env: env,
    interpolation: options.trusted_interpolation === true ? INTERPOLATION : "none"
  })
}

function templateShell(template, args) {
  if (typeof template !== "string" || template.trim() === "") return invalid("invalid_template")
  if (!Array.isArray(args)) return invalid("invalid_args")

  const source = template
  if (source.indexOf("\0") >= 0) return invalid("invalid_template")
  if (!positionalOnly(source)) return invalid("unexpanded_reference")

  const form = templateForm(source)
  if (form === null) return invalid("unrecognised_hole")
  if (form.maxRef > args.length) return invalid("arg_count_mismatch")

  return result(TEMPLATE, {
    argv: [POSIX_SHELL, "-c", source, SHELL_ARGV0].concat(args.slice()),
    env: [],
    interpolation: "none"
  })
}

function isData(value) {
  return typeof value === "string" && value !== "" && value.indexOf("\0") < 0
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function invalid(code) {
  return { ok: false, code: code }
}

function result(mode, extra) {
  return Object.assign({ ok: true, code: "ok", mode: mode }, extra)
}

function shellArgv(script, source) {
  const shell = source.shell !== undefined ? source.shell : POSIX_SHELL
  const name = source.argv0 !== undefined ? source.argv0 : SHELL_ARGV0
  return [shell, "-c", script, name]
}

function validEnv(env) {
  if (env === undefined) return true
  if (!isObject(env)) return false
  const names = Object.keys(env)
  for (let i = 0; i < names.length; i++) {
    if (!isIdentifier(names[i])) return false
    if (typeof env[names[i]] !== "string" || env[names[i]].indexOf("\0") >= 0) return false
  }
  return true
}

function isIdentifier(name) {
  return typeof name === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name)
}

// A hole list names the dynamic values a trusted source interpolates, so the
// claim stays a manifest of identifiers rather than a channel for the data
// itself. A claim with no holes changes nothing and is refused.
function validHoles(holes) {
  if (holes === undefined) return true
  if (!Array.isArray(holes) || holes.length === 0) return false
  for (let i = 0; i < holes.length; i++) {
    if (!isIdentifier(holes[i])) return false
  }
  return true
}

function normalizeEnv(env) {
  if (env === undefined) return []
  const names = Object.keys(env)
  names.sort()
  const entries = []
  for (let i = 0; i < names.length; i++) entries.push(names[i] + "=" + env[names[i]])
  return entries
}

// A template is an inert word list. A word carrying an operator, a
// redirection, or any other shell syntax is source rather than a name, and
// belongs to the trusted form with its own explicit trust decision. The
// reference scan has already proved that no `$` opens anything but a positional
// reference, so this check only has to prove that no word carries shell
// syntax.
function templateForm(source) {
  const words = source.trim().split(/\s+/)
  let maxRef = 0
  for (let i = 0; i < words.length; i++) {
    const kind = templateWord(words[i])
    if (kind === null) return null
    if (kind === "literal") continue
    // The interpreter's $0 is fixed by the builder, so it is not a data hole.
    if (hasZeroReference(words[i])) return null
    const index = holeIndex(words[i])
    if (index > maxRef) maxRef = index
  }
  return { maxRef: maxRef }
}

// Every `$` in a template must open a positional reference. A variable, a
// command substitution, an arithmetic expansion, or a special parameter has
// no place in a form whose only dynamic content is data.
function positionalOnly(source) {
  let index = source.indexOf("$")
  while (index >= 0) {
    if (!/^\$(?:\{[0-9]+\}|[0-9]+)/.test(source.slice(index))) return false
    index = source.indexOf("$", index + 1)
  }
  return true
}

function hasZeroReference(word) {
  return /\$\{?0\}?(?![0-9])/.test(word)
}

// Highest positional number a word refers to, or 0 when it refers to none.
function holeIndex(word) {
  let max = 0
  const pattern = /\$(?:\{)?([0-9]+)(?:\})?/g
  let match = pattern.exec(word)
  while (match !== null) {
    const index = parseInt(match[1], 10)
    if (index > max) max = index
    match = pattern.exec(word)
  }
  return max
}

// Classifies one template word as inert literal text or as a quoted reference.
// A reference must be quoted, because an unquoted expansion is split into
// fields and globbed by the interpreter, which would let data change the word
// list or reach the filesystem as a pattern.
function templateWord(word) {
  if (word === "") return null
  const quote = word.charAt(0)
  // A quote character inside a quoted word would close it early and hand the
  // rest of the word back to the interpreter.
  if (quote === "'") {
    if (word.length < 2 || word.charAt(word.length - 1) !== "'") return null
    return word.indexOf("'", 1) === word.length - 1 ? "literal" : null
  }
  if (quote === '"') {
    if (word.length < 2 || word.charAt(word.length - 1) !== '"') return null
    const inner = word.slice(1, -1)
    // Inside double quotes a backtick still substitutes and a backslash still
    // escapes, so both would end the literal.
    if (inner.indexOf("`") >= 0 || inner.indexOf("\\") >= 0 || inner.indexOf('"') >= 0) return null
    let index = inner.indexOf("$")
    while (index >= 0) {
      if (!/^\$(?:\{[0-9]+\}|[0-9]+)/.test(inner.slice(index))) return null
      index = inner.indexOf("$", index + 1)
    }
    return "reference"
  }
  return INERT_WORD.test(word) ? "literal" : null
}

// --- argv allowlist for the Exec prefix helpers ---
//
// The fixed argv[0] vocabulary a helper-built command may carry: the
// setsid/timeout wrapper pair, the file verbs the rm/cp/mkdir helpers
// emit, the magick convert pipeline the capture paths drive, the sh
// probe tails, and the realpath/stat identity probes. Everything else
// resolves through an explicit absolute path at the call site or not at
// all, so a helper can never be steered onto an arbitrary binary.
const ALLOWED_ARGV0 = ["setsid", "timeout", "rm", "cp", "mkdir", "magick", "sh", "realpath", "stat"]

function isAllowedArgv0(name) {
  return ALLOWED_ARGV0.indexOf(String(name)) >= 0
}

// Validate a helper-built prefixed argv: [setsid, timeout, <secs>s,
// ...tail] with a non-empty tail of data strings whose head names an
// allowlisted binary. Returns a result object; never throws, so a
// caller that ignores a rejection still cannot run a partially built
// command.
function prefixedArgv(command) {
  if (!Array.isArray(command) || command.length < 4) return invalid("invalid_argv")
  for (let i = 0; i < command.length; i++) {
    if (!isData(command[i])) return invalid("invalid_argv")
  }
  if (command[0] !== "setsid" || command[1] !== "timeout") return invalid("invalid_prefix")
  if (!/^[0-9]+s$/.test(command[2])) return invalid("invalid_timeout")
  if (!isAllowedArgv0(command[3])) return invalid("disallowed_argv0")
  return result(ARGV, { argv: command.slice() })
}
