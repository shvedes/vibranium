// Loader for QML `.pragma library` scripts, so they can be unit-tested from
// node.
//
// A `.pragma library` file is not a node module: it has no exports, and its
// `.import "x.js" as Y` lines are QML syntax. This loader reproduces the two
// rules that matter:
//
//   1. A `.pragma library` exposes its *top-level declarations* as members of
//      the namespace. That is why `SU.shellQuote(...)` works in QML without
//      anything being exported.
//   2. `.import "path" as Alias` binds the resolved library's namespace
//      object to `Alias` in the importing file's scope.
//
// Each library gets its own vm context. That matches the QJSEngine behaviour
// the libs are written for, and it means a `var` of the same name in two
// libraries cannot collide, which a single shared context would allow.
//
// Nothing in the tree needs a host global except `Quickshell.env`, which
// HyprlandEditor.js already guards with a `typeof` check. The shim below
// supplies it from process.env so the environment-reading helpers are testable
// rather than dead in this harness.

import vm from 'node:vm'
import fs from 'node:fs'
import path from 'node:path'

// `Quickshell.env(name)` is the QML-side environment read. Scripts may also
// poke `Quickshell.envPath`/`Quickshell.dataPath`; a probe file that wants
// them should set them through setQuickshellEnv rather than relying on this
// default.
const envShim = {
  env: (k) => process.env[k] || '',
  envPath: (name) => path.join(process.env.HOME || '/tmp', '.local', 'state', name),
  dataPath: (name) => path.join(process.env.HOME || '/tmp', '.local', 'share', name),
  cachePath: (name) => path.join(process.env.HOME || '/tmp', '.cache', name),
  configDir: () => path.join(process.env.HOME || '/tmp', '.config'),
  stateDir: () => path.join(process.env.HOME || '/tmp', '.local', 'state'),
  dataDir: () => path.join(process.env.HOME || '/tmp', '.local', 'share'),
  cacheDir: () => path.join(process.env.HOME || '/tmp', '.cache'),
  statePath: (n) => path.join(process.env.HOME || '/tmp', '.local', 'state', n),
  dataPath_: (n) => path.join(process.env.HOME || '/tmp', '.local', 'share', n),
}

const cache = new Map()

// Top-level declarations are the module's public surface under .pragma
// library. `const`/`let` at the top level of a .pragma library file is
// meaningless in QML, so these files use var/function; both are matched.
const DECL = /^(?:function\s+([A-Za-z_$][\w$]*)|(?:var|let|const)\s+([A-Za-z_$][\w$]*))/gm

const IMPORT_RE = /^[ \t]*\.import\s+["']([^"']+)["']\s+as\s+([A-Za-z_$][\w$]*)\s*;?\s*$/gm

// loadLib evaluates a .pragma library and returns its namespace object.
//
// Throws with the file and message on any evaluation error, so a test that
// merely requires a library still fails loudly rather than silently seeing an
// empty namespace.
export function loadLib(file) {
  const abs = path.resolve(file)
  if (cache.has(abs)) return cache.get(abs)

  let src = fs.readFileSync(abs, 'utf8')
  src = src.replace(/^[ \t]*\.pragma\s+library\s*;?\s*$/gm, '')

  // Bind each .import to the resolved namespace, then drop the line.
  const holder = { console, Quickshell: envShim }
  src = src.replace(IMPORT_RE, (_m, spec, alias) => {
    holder[alias] = loadLib(path.resolve(path.dirname(abs), spec))
    return ''
  })

  const ctx = vm.createContext(holder)
  try {
    vm.runInContext(src, ctx, { filename: abs })
  } catch (e) {
    throw new Error(`${path.basename(abs)}: ${e.message}`)
  }

  // Some libs (CalendarLib) also publish a CommonJS `module.exports`; honour
  // it, because that list is a curated public surface worth using when it
  // exists, and fall back to the declarations otherwise.
  const out = {}
  if (holder.module && holder.module.exports && typeof holder.module.exports === 'object') {
    Object.assign(out, holder.module.exports)
  }
  for (const m of src.matchAll(DECL)) {
    const name = m[1] || m[2]
    if (name && name in ctx) out[name] = ctx[name]
  }
  // `.import` aliases are part of the file's own scope, not its exports, so
  // they are deliberately not re-exported.
  cache.set(abs, out)
  return out
}

// setEnv installs an environment value visible to Quickshell.env(name).
// Scripts read the environment lazily inside a function body, so a test can
// set this after loading and still affect behaviour.
export function setEnv(key, value) {
  process.env[key] = value
}

export function clearCache() {
  cache.clear()
}

// Raw source of a library with the QML-only syntax removed. Tests that need
// to assert on the *text* of a library (an export list, a doc comment, a
// declared contract) use this rather than re-reading the file.
export function libSource(file) {
  return fs
    .readFileSync(path.resolve(file), 'utf8')
    .replace(/^[ \t]*\.pragma\s+library\s*;?\s*$/gm, '')
    .replace(IMPORT_RE, '')
}

// export the shim so a suite can assert what the harness gives a library.
export const hostGlobals = { Quickshell: envShim }

// loadPlugin evaluates a plugin's main.js the way PluginInstance.qml does.
//
// A plugin is not a .pragma library: PluginInstance.qml wraps the source in
// its own function scope, so the plugin gets a private engine, and the
// contract is that evaluating the source assigns a global `VibraniumPlugin`
// carrying at least `items` and `activate` functions. That wrapper also
// means the file's own top-level declarations are *not* exported - they are
// locals of the wrapper - so a plugin's public surface is exactly the
// VibraniumPlugin object.
//
// The three rejection paths from PluginInstance.qml are reproduced as thrown
// errors with the same message text, so a suite can assert both the accept
// and the reject contract rather than only the happy path.
//
// `api` is the context object handed to `VibraniumPlugin.init(context)`,
// which is where a plugin reads shell services from.
export function loadPlugin(file, api = {}) {
  const abs = path.resolve(file)
  const source = fs.readFileSync(abs, 'utf8')

  // Reproduce the host's two steps exactly: declare `VibraniumPlugin` as
  // null, then eval the source. A plugin that never assigns it must stay
  // distinguishable from one that assigns undefined, and both must be
  // distinguishable from one that throws during evaluation.
  const ctx = vm.createContext({ console, Quickshell: envShim, __source: source })
  const wrapper = `(function(){ var VibraniumPlugin = null; eval(__source); return VibraniumPlugin; })()`
  let impl
  try {
    impl = vm.runInContext(wrapper, ctx, { filename: abs })
  } catch (e) {
    throw new Error(`${path.basename(abs)}: did not assign VibraniumPlugin (${e.message})`)
  }

  if (impl === null || impl === undefined) {
    throw new Error(`${path.basename(abs)}: did not assign VibraniumPlugin`)
  }
  if (typeof impl.items !== 'function' || typeof impl.activate !== 'function') {
    throw new Error(`${path.basename(abs)}: items/activate must be functions`)
  }
  if (typeof impl.init === 'function') impl.init(api)
  return impl
}

// pluginManifest reads a plugin's plugin.json, which is the metadata
// PluginPolicy.js validates before a plugin is ever evaluated.
export function pluginManifest(dir) {
  return JSON.parse(fs.readFileSync(path.resolve(dir, 'plugin.json'), 'utf8'))
}

// listPlugins returns every plugin directory under the launcher's plugins/
// root, sorted. A suite iterates this rather than hardcoding a list, so a
// dropped-in plugin is covered without editing the suite.
export function listPlugins(root) {
  const base = path.resolve(root)
  if (!fs.existsSync(base)) return []
  return fs
    .readdirSync(base, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => path.join(base, d.name))
    .filter((d) => fs.existsSync(path.join(d, 'main.js')))
    .sort()
}
