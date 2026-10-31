// Capability policy for launcher plugins.
//
// A launcher plugin is TRUSTED CODE, not sandboxed code. Its main.js is
// evaluated by PluginInstance.evaluate() inside this shell's own JS engine,
// with the engine's whole authority, and it can reach that authority
// without asking: anything the host object exposes, anything the engine
// itself exposes, anything it finds on the value it was handed. No verdict
// in this file confines that, and nothing here should ever be described as
// a sandbox, a jail, a VM or an isolation boundary - it is not one, and a
// plugin is expected to be as trusted as the code shipped in this
// repository.
//
// What the policy does bound is the API the launcher PUBLISHES. A plugin
// gets no ambient access to the filesystem, a process, the network, the
// clipboard or a secret: each of those is a named operation, and the
// object a plugin receives carries only the operations the launcher
// granted it. A denied operation is absent from that object rather than
// present and refusing, so a plugin cannot probe for one either.
//
// Two directions, deliberately: the vocabulary is closed and a name
// outside it is denied instead of being read as a nearby capability (a
// "readFiles" spelling must not fall through to a read), and the launcher
// owns every grant (see AppLauncher._grantsFor). A plugin manifest can
// only ask, so nothing a plugin carries can widen its own reach.
//
// Errors crossing this boundary are reported by shape and never by
// message: a thrown message can carry a path, a token or a fragment of
// user data, and there is no reliable way to tell which.
//
// Pure JS, `.pragma library`, no Qt imports: unit-drivable and readable
// on its own.
.pragma library

// Operations a plugin may hold. Every entry is a key on the object the
// launcher hands over; `outside` marks the ones that leave this process,
// which is exactly the set the launcher has to name deliberately.
//
//   id              the plugin's own directory name
//   configDir       XDG config root, for a plugin that keeps its own files
//   pluginDir       the plugin's own directory
//   setting         read a settings option
//   shellQuote      quote a string for a shell the plugin builds itself
//   stripJsonc      drop // comments and trailing commas from JSONC
//   requestTime     ask for one timezone clock reading
//   cachedTime      read the last reading for a timezone
//   requestBinaries ask the shell to rescan PATH          (outside)
//   cachedBinaries  read the last PATH scan
//   cachedNet       read the last body fetched for a URL
//   cachedOnline    read the last online verdict
//   cachedSection   read a namespaced section of the shell cache
//   log             the silent no-op the plugin API contract keeps
//   readFile        read an arbitrary file                   (outside)
//   execDetached    run a detached command from shell source (outside)
//   requestNet      ask the shell to fetch a URL             (outside)
//   setCacheSection write a namespaced section of the shell cache (outside)
//   network         open a remote URL                        (outside)
//   clipboard       write the clipboard                      (outside)
//   secret          read a stored secret                     (outside)
//
// The fetch is split in two on purpose, and only one half is `outside`.
// `requestNet` is: it makes the shell open a socket, so it is a capability
// the launcher has to name deliberately and it can never be a default grant.
// `cachedNet` is not: it reads a string the shell already holds, exactly like
// `cachedTime` reads a clock reading, and it is useless without the request
// half beside it. A plugin holding the pair gets a URL in and a body out and
// never sees a socket, a response object or a callback; the raw `network`
// operation stays declared-but-unbound, because nothing shipped needs a
// response stream and a narrower pair is the one worth granting.
//
// The PATH pair is the same shape a third time. `requestBinaries` is
// `outside` because it starts a process and walks every directory on the
// user's PATH - a read the launcher has to name deliberately - and
// `cachedBinaries` is a plain in-process read like the other cached half.
// Naming the executable SET rather than the directories that hold it is the
// narrower grant: a plugin holding this pair can ask what is runnable and
// nothing about where it lives, and it is the one pair a shipped plugin needs
// that no engine does.
//
// The cache pair splits on the same line, and the line is READ versus WRITE
// rather than read versus ask. `cachedSection` reads a namespaced section of
// $VIBRANIUM_CACHE/shell.json - a document the shell has already loaded and
// holds in memory - so it is an in-process read like `cachedTime` and belongs
// with the defaults. `setCacheSection` reaches the disk, so it is `outside`
// and can never be a default grant: a cache the whole shell shares is exactly
// the kind of document an unprivileged plugin must not be able to rewrite.
// The launcher also confines a writer to sections that begin with the plugin's
// own id, so a granted writer cannot reach the audio level or the update
// mirror sitting in the same file.
const OPERATIONS = {
  id: false,
  configDir: false,
  pluginDir: false,
  setting: false,
  shellQuote: false,
  stripJsonc: false,
  requestTime: false,
  cachedTime: false,
  requestBinaries: true,
  cachedBinaries: false,
  cachedNet: false,
  cachedOnline: false,
  cachedSection: false,
  log: false,
  readFile: true,
  execDetached: true,
  requestNet: true,
  network: true,
  clipboard: true,
  secret: true,
  setCacheSection: true
}

// What a plugin holds with no grant named at all. Every entry stays inside
// this process and reads nothing the user did not already see on screen;
// none of them starts a process, opens a socket or touches a secret.
//
// `cachedNet` is here and `requestNet` is not, which is the whole shape of
// the fetch pair: reading a body the shell already fetched is a read, and
// asking for one is a socket. A plugin can hold the read half and never fill
// it, which costs nothing and is why the two are separate names.
// `cachedBinaries` sits here beside `cachedTime` for the same reason: the
// scan is the expensive half and the launcher owns it, so reading its result
// is a read the whole shell already made. `cachedSection` is here for the
// same reason again and is the only cache half that is: reading a section of
// the shell cache touches a document this process already holds, and its write
// half is deliberately not.
const DEFAULT_GRANTS = [
  "id",
  "configDir",
  "pluginDir",
  "setting",
  "shellQuote",
  "stripJsonc",
  "requestTime",
  "cachedTime",
  "cachedBinaries",
  "cachedNet",
  "cachedOnline",
  "cachedSection",
  "log"
]

const DENIED_CODE = "capability_denied"
const UNBOUND_CODE = "capability_unbound"
const REDACTED = "plugin operation failed"

// Exact membership against the closed vocabulary. A name that is not in it
// is denied; it is never repaired into a name that is.
function isOperation(name) {
  return typeof name === "string" && Object.prototype.hasOwnProperty.call(OPERATIONS, name)
}

// The operations a launcher must name deliberately. Reading this instead of
// keeping a second list here means a new privileged operation cannot be
// added to the vocabulary while staying off the launcher's grant table.
// The names a grant asked for that this policy will not honour: either
// outside the vocabulary, or already the default. Deduplicated so a caller
// can report a grant table once instead of per row.
function normalize(grants) {
  const out = []
  const seen = {}
  const list = Array.isArray(grants) ? grants : []
  for (let i = 0; i < list.length; i++) {
    const name = list[i]
    if (!isOperation(name) || seen[name] === true) continue
    seen[name] = true
    out.push(name)
  }
  return out
}

// Narrow one grant set with another: what the launcher decided to allow,
// minus anything the manifest did not name. A request that is not an array
// is no request at all, so the launcher's set stands; a request that is an
// array narrows, and one naming nothing in the vocabulary narrows to
// nothing - a plugin cannot answer a misspelling with its own grant.
function intersect(granted, requested) {
  const allowed = normalize(granted)
  if (!Array.isArray(requested)) return allowed
  const asked = normalize(requested)
  const out = []
  for (let i = 0; i < asked.length; i++) {
    if (allowed.indexOf(asked[i]) >= 0) out.push(asked[i])
  }
  return out
}

// True when `dir` is a plugin directory under `root`. The two are always
// parent and child, never siblings, so the containment test runs from the
// directory outward: the root is what has to prefix it. Asking the root to
// contain its own child can never be true, and a builtin plugin then reads as
// a user one - which costs it every operation the shipped table holds, so its
// activate() throws and the launcher degrades the plugin for good.
function underRoot(dir, root) {
  const d = String(dir === null || dir === undefined ? "" : dir)
  const r = String(root === null || root === undefined ? "" : root)
  if (d === "" || r === "") return false
  return d.indexOf(r + "/") === 0
}

// The grant set for one discovered plugin: the table its discovery root owns,
// narrowed by whatever the manifest asked for. The launcher owns both tables
// and the root they are chosen by; this only applies them, so the choice
// itself is drivable from here rather than only from QML.
//
// `extrasById` is an optional { pluginId: [operation] } map folded into the
// BUILT-IN table only. It exists so one shipped plugin can hold a capability
// its siblings do not: widening the whole shipped root would hand every
// engine in this repository a socket or a clipboard, which is a larger
// decision than the one any single plugin needs. A user root is never
// reached by it - a plugin id is a directory name, and a directory dropped
// into a user root matching a shipped one resolves in favour of the shipped
// root anyway, so the map cannot become a way to name your way into a
// privilege. A map entry naming something outside the vocabulary, or
// something the table already holds, is dropped by normalize() like any
// other grant.
function grantsForRoot(root, dir, builtinGrants, userGrants, requested, extrasById, id) {
  if (!underRoot(dir, root)) return intersect(userGrants, requested)
  const extra = extrasById === null || extrasById === undefined
    ? null : extrasById[String(id)]
  const table = extra === undefined || extra === null
    ? builtinGrants : builtinGrants.concat(extra)
  return intersect(table, requested)
}

// An error crossing the boundary, reduced to its shape. The kind is a
// fixed platform vocabulary (TypeError, RangeError, ...) and is the only
// part of a thrown value that can be reported without risking what the
// message carried; a bare string or a non-standard name reports nothing.
function redact(error) {
  const kind = errorKind(error)
  return kind === "" ? REDACTED : REDACTED + " (" + kind + ")"
}

function errorKind(error) {
  if (error === null || error === undefined || typeof error === "string") return ""
  const name = typeof error.name === "string" ? error.name : ""
  return /^[A-Za-z][A-Za-z0-9]*$/.test(name) ? name : ""
}

// A refusal is a redacted Error carrying a machine-readable code, so the
// shell can branch on the code while neither side ever sees a message that
// could carry a path, a token or user data.
function refusal(code, name) {
  const err = new Error(REDACTED + " (" + code + ":" + name + ")")
  err.code = code
  err.operation = name
  return err
}

// What the launcher binds per plugin. A missing member leaves its
// operation unbound rather than absent, so a misconfigured grant is
// visible as an unbound capability instead of silently doing nothing.
function denyAllHost() {
  return null
}

// The policy instance. `host` supplies the implementation behind each
// granted operation; every exposed member is a trampoline that redacts
// whatever the implementation throws, so a plugin and the shell's own log
// see the shape of a failure and never its text.
//
// With no arguments this is the default posture: the operations inside the
// process, none of the ones that leave it. The members exist because the
// launcher binds a host; until then each one refuses, which is a
// capability that has not been granted an implementation yet, not a
// capability that reached something.
function createPolicy(grants, host) {
  const allowed = normalize(DEFAULT_GRANTS.concat(normalize(grants)))
  const impl = host === null || host === undefined ? denyAllHost() : host
  const granted = []
  const denied = []
  for (const name of Object.keys(OPERATIONS)) {
    if (allowed.indexOf(name) >= 0) granted.push(name)
    else denied.push(name)
  }

  const policy = {
    // The predicate the launcher and the settings surface ask. Exact
    // membership: a name outside the vocabulary is denied, and so is every
    // operation the grant did not name.
    allows: function allows(name) {
      return isOperation(name) && allowed.indexOf(name) >= 0
    },

    // What the launcher granted, in vocabulary order, and what it did not.
    // Reported so a status read or a settings row can show the posture
    // instead of leaving it implicit in a missing property.
    grantedOperations: function grantedOperations() {
      return granted.slice()
    },
    deniedOperations: function deniedOperations() {
      return denied.slice()
    }
  }

  for (const name of granted) {
    policy[name] = function operation() {
      const fn = impl !== null && typeof impl === "object" && typeof impl[name] === "function"
        ? impl[name]
        : null
      if (fn === null) throw refusal(UNBOUND_CODE, name)
      const args = Array.prototype.slice.call(arguments)
      try {
        return fn.apply(impl, args)
      } catch (error) {
        throw new Error(redact(error))
      }
    }
  }
  return policy
}

// The default posture, named for callers that want it without spelling the
// argument out.