// Pure helpers for the pass password manager: listing, validation, paths.
// No Qt imports - deterministic and unit-drivable, like Network Model.js.
// Entry shape: { path, dir, name } where path is the pass-relative name
// without .gpg (e.g. "email/gmail"), dir the parent folder ("" at root).
// The list projection is that shape and nothing else: a row names an entry,
// it never carries its value, so the vault listing, the panel model, and the
// status counters cannot leak a credential. Decrypted values live in
// SecretStore and are reached by handle.

// Approximate `sort -V`: numeric chunks compare by value, the rest by
// code point. Close enough for stable entry ordering in the panel.
function versionCompare(a, b) {
  var ra = String(a || "").split(/([0-9]+)/);
  var rb = String(b || "").split(/([0-9]+)/);
  var n = Math.max(ra.length, rb.length);
  for (var i = 0; i < n; i++) {
    var x = ra[i] === undefined ? "" : ra[i];
    var y = rb[i] === undefined ? "" : rb[i];
    if (x === y) continue;
    var xn = /^[0-9]+$/.test(x);
    var yn = /^[0-9]+$/.test(y);
    if (xn && yn) {
      var xs = x.replace(/^0+/, "");
      var ys = y.replace(/^0+/, "");
      if (xs.length !== ys.length) return xs.length < ys.length ? -1 : 1;
      if (xs !== ys) return xs < ys ? -1 : 1;
      continue;
    }
    return x < y ? -1 : 1;
  }
  return 0;
}

function stripGpg(p) {
  var s = String(p || "");
  if (s.length > 4 && s.substring(s.length - 4) === ".gpg")
    return s.substring(0, s.length - 4);
  return s;
}

function splitEntry(path) {
  var p = String(path || "");
  var slash = p.lastIndexOf("/");
  if (slash === -1) return { path: p, dir: "", name: p };
  return { path: p, dir: p.substring(0, slash), name: p.substring(slash + 1) };
}

// Combined `find` output -> { files, dirs }. The probe prints one line
// per hit prefixed with its kind: "f <rel>" for entries, "d <rel>" for
// folders (the store root itself prints an empty rel and is dropped).
// .git bookkeeping never surfaces on either side.
function parseFindOutput(storeDir, lines) {
  var dir = String(storeDir || "");
  if (dir.length > 1 && dir.charAt(dir.length - 1) === "/")
    dir = dir.substring(0, dir.length - 1);
  var files = [];
  var dirs = [];
  var seen = {};
  var arr = Array.isArray(lines) ? lines : String(lines || "").split("\n");
  for (var i = 0; i < arr.length; i++) {
    var line = String(arr[i] === undefined || arr[i] === null ? "" : arr[i]);
    if (line.length > 0 && line.charAt(line.length - 1) === "\r")
      line = line.substring(0, line.length - 1);
    if (line.length < 3 || line.charAt(1) !== " ") continue;
    var kind = line.charAt(0);
    var f = line.substring(2);
    if (f === "") continue;
    if (dir !== "") {
      if (f === dir) continue;
      if (f.indexOf(dir + "/") === 0) f = f.substring(dir.length + 1);
    }
    if (f === ".git" || f.indexOf(".git/") === 0 || f.indexOf("/.git/") !== -1)
      continue;
    if (kind === "f") {
      if (f.length > 4 && f.substring(f.length - 4) === ".gpg") files.push(f);
    } else if (kind === "d") {
      if (f !== "" && !seen[f]) { seen[f] = true; dirs.push(f); }
    }
  }
  dirs.sort(versionCompare);
  return { files: files, dirs: dirs };
}

// Flat find output -> sorted entries. Called as listEntries(files) or
// listEntries(storeDir, files); with a store dir, absolute paths are
// relativized first. .git bookkeeping never surfaces as entries.
function listEntries(a, b) {
  var dir = "";
  var files = [];
  if (Array.isArray(a)) {
    files = a;
  } else {
    dir = String(a || "");
    if (Array.isArray(b)) files = b;
  }
  if (dir.length > 1 && dir.charAt(dir.length - 1) === "/")
    dir = dir.substring(0, dir.length - 1);
  var out = [];
  for (var i = 0; i < files.length; i++) {
    var f = String(files[i] === undefined || files[i] === null ? "" : files[i]);
    if (f.length > 0 && f.charAt(f.length - 1) === "\r")
      f = f.substring(0, f.length - 1);
    if (f === "") continue;
    if (dir !== "") {
      if (f === dir) continue;
      if (f.indexOf(dir + "/") === 0) f = f.substring(dir.length + 1);
    }
    if (f === ".git" || f.indexOf(".git/") === 0 || f.indexOf("/.git/") !== -1)
      continue;
    if (f.length <= 4 || f.substring(f.length - 4) !== ".gpg") continue;
    var logical = f.substring(0, f.length - 4);
    if (logical === "") continue;
    out.push(splitEntry(logical));
  }
  out.sort(function (x, y) { return versionCompare(x.path, y.path); });
  return out;
}

// Mirrors prompt_valid_name: non-empty after trim, no leading dot, no ..
// anywhere, allowlist [a-zA-Z0-9._ @-] only (no slashes or meta chars).
function isValidName(name) {
  if (typeof name !== "string") return false;
  var s = name.replace(/^\s+/, "").replace(/\s+$/, "");
  if (s === "") return false;
  if (s.charAt(0) === ".") return false;
  if (s.indexOf("..") !== -1) return false;
  if (/[^a-zA-Z0-9._ @-]/.test(s)) return false;
  return true;
}

// Mirrors pass resolution: caller-exported PASSWORD_STORE_DIR wins, then
// XDG_DATA_HOME, then ~/.local/share. Takes an env map so QML passes
// Quickshell.env values in and node tests pass a stub.
function storeDir(env) {
  var e = env;
  if (e === undefined || e === null) {
    if (typeof process !== "undefined" && process.env) e = process.env;
    else e = {};
  }
  var psd = e.PASSWORD_STORE_DIR;
  if (typeof psd === "string" && psd !== "") return psd;
  var xdg = e.XDG_DATA_HOME;
  if (typeof xdg === "string" && xdg !== "") return xdg + "/password-store";
  var home = e.HOME;
  if (typeof home === "string" && home !== "") return home + "/.local/share/password-store";
  return "~/.local/share/password-store";
}

// Password is line 1 only; printf %s semantics (no trailing newline out).
function firstLine(text) {
  var s = String(text === undefined || text === null ? "" : text);
  var idx = s.indexOf("\n");
  var line = idx === -1 ? s : s.substring(0, idx);
  if (line.length > 0 && line.charAt(line.length - 1) === "\r")
    line = line.substring(0, line.length - 1);
  return line;
}

// Immediate children of dir: subdir names plus entries living directly in
// it. Entries arrive sorted, so files need no re-sort; dirs sort -V.
// extraDirs folds in folders the entry scan cannot see (empty ones from
// the dirs probe) so they browse exactly like populated folders.
function childrenOf(entries, dir, extraDirs) {
  var d = String(dir || "");
  var dirs = [];
  var seen = {};
  var files = [];
  var extra = Array.isArray(extraDirs) ? extraDirs : [];
  var i, e, rest, head;
  var consider = function (dirPath) {
    if (dirPath === d) return;
    if (d === "") {
      if (dirPath === "" || dirPath.indexOf("/") !== -1) return;
      rest = dirPath;
    } else {
      if (dirPath.indexOf(d + "/") !== 0) return;
      rest = dirPath.substring(d.length + 1);
      head = rest.split("/")[0];
      if (head === "") return;
      rest = head;
    }
    if (rest !== "" && !seen[rest]) {
      seen[rest] = true;
      dirs.push(rest);
    }
  };
  for (i = 0; i < entries.length; i++) {
    e = entries[i];
    if (!e) continue;
    if (e.dir === d) {
      files.push(e);
      continue;
    }
    consider(e.dir);
  }
  for (i = 0; i < extra.length; i++) {
    var x = String(extra[i] || "");
    if (x === "") continue;
    consider(x);
    // An empty folder listed exactly at this level still counts when no
    // entry mentions it (consider skips dirPath === d, handled by files
    // being empty - nothing to add, the view shows its note row).
  }
  dirs.sort(versionCompare);
  return { dirs: dirs, files: files };
}

// Entries living anywhere under dir (the whole subtree, not just
// direct children). The trailing slash keeps sibling prefixes
// ("mail" vs "mail2") apart. dir "" counts the whole vault.
function countUnder(entries, dir) {
  var d = String(dir || "");
  if (d === "") return (Array.isArray(entries) ? entries : []).length;
  var n = 0;
  var arr = Array.isArray(entries) ? entries : [];
  for (var i = 0; i < arr.length; i++) {
    var e = arr[i];
    if (!e) continue;
    var ed = String(e.dir || "");
    if (ed === d || ed.indexOf(d + "/") === 0) n++;
  }
  return n;
}

// Flat case-insensitive substring filter over pass paths.
function filterEntries(entries, query) {
  var q = String(query || "").toLowerCase();
  if (q === "") return entries.slice();
  var out = [];
  for (var i = 0; i < entries.length; i++) {
    if (entries[i] && String(entries[i].path || "").toLowerCase().indexOf(q) !== -1)
      out.push(entries[i]);
  }
  return out;
}

// Vault-wide substring search: entries match on full path, dirs on
// their relative path. Both sides sort -V like the browser.
function searchVault(entries, allDirs, query) {
  var q = String(query || "").toLowerCase();
  if (q === "") return { entries: [], dirs: [] };
  var hits = [];
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i];
    if (e && String(e.path || "").toLowerCase().indexOf(q) !== -1) hits.push(e);
  }
  hits.sort(function (x, y) { return versionCompare(x.path, y.path); });
  var ds = [];
  var dirs = Array.isArray(allDirs) ? allDirs : [];
  for (var j = 0; j < dirs.length; j++) {
    var d = String(dirs[j] || "");
    if (d !== "" && d.toLowerCase().indexOf(q) !== -1) ds.push(d);
  }
  ds.sort(versionCompare);
  return { entries: hits, dirs: ds };
}

// GPG colon output -> secret-key fingerprints. For each "sec" record the
// next "fpr" line carries the fingerprint in field 10 (index 9).
function parseKeyFingerprints(text) {
  var lines = String(text || "").split("\n");
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var cols = lines[i].split(":");
    if (cols[0] !== "sec") continue;
    if (i + 1 >= lines.length) continue;
    var next = lines[i + 1].split(":");
    if (next[0] === "fpr" && next[9] !== undefined && next[9] !== "")
      out.push(next[9]);
  }
  return out;
}

// --- opaque store tokens --------------------------------------------------
//
// A line in the log may say which entry, folder or store it is about, but
// only through a TOKEN. In a password store the name IS the secret:
// "work-email/bank" says the bank before the password is even tried, so a
// name and a password are the same class of thing here and neither may
// reach a log at any level.
//
// The token is a COUNTER, and it must stay one. What it must never become is
// a hash or a truncated prefix of the name, and the reason is specific to
// this component rather than to taste: a password store has a small and
// entirely guessable vocabulary - github, work-email, bank, and a dozen
// service names - so anyone holding a log can confirm a guess against a
// digest, or enumerate a hundred candidates against a prefix, in one step.
// A hash is therefore not anonymisation, it is a lookup table with the
// answers still in it. A counter is not derived from the name at all: it is
// assigned in first-seen order, it is meaningful only inside the session
// that minted it, and two different names share neither its value nor the
// information of how long it took to mint.
//
// Two lines that name the same entry get the same token, which is the
// property that makes the log worth reading at all: entry#2 was read, then
// copied, then failed to decrypt, and a reader can follow that thread
// without being told what entry#2 is called.
//
// The map is null-prototype because its keys are user-chosen strings. A
// plain {} answers map["constructor"] and map["__proto__"] from the
// prototype, so an entry named "constructor" would read as already seen and
// log a prototype method's source instead of a token. The mapping is held
// for the session, never written to disk, and never logged - the token is
// the only half of the pair that exists anywhere at all.

// A fresh session's map. One per shell start, on the resident facade, so a
// token stays stable across a panel close and a controller rebuild while a
// new shell always restarts the numbering at #1.
function newTokenMap() {
  return Object.create(null)
}

// "entry#1" for the first distinct entry this session has seen, "entry#2"
// for the next, and that same entry#2 for every later line that names it.
// The counter is per kind, so entry#1 and folder#1 both exist and cannot be
// confused for one another. `raw` is the real name and is used only as a
// key: it is never returned, formatted or stored anywhere but here.
//
// DO NOT "improve" this into a hash, a digest, a length-prefix, a truncated
// prefix or any other name-derived value. It reads like anonymisation and is
// not: a password store's vocabulary is small and guessable, so a name-derived
// token lets whoever holds the log confirm a guess in one step, and the log is
// the one artefact of this component that outlives the session and leaves the
// machine. A counter has to be guessed in the sense that no function of the
// name produces it. The block comment above is the full argument; this line
// is here because this function is where the change would be made.
//
// Total by construction, because a logging call site has to have an answer
// whether or not the caller thought about it: an absent map, an unknown kind
// and an empty name each produce a line that reads as a token and matches
// nothing, which is the right failure for a redactor.
function token(map, kind, raw) {
  var m = map === null || map === undefined || typeof map !== "object" ? newTokenMap() : map
  var k = kind === null || kind === undefined ? "" : String(kind)
  var bucket = m[k]
  if (bucket === null || bucket === undefined || typeof bucket !== "object") {
    bucket = Object.create(null)
    m[k] = bucket
  }
  if (typeof bucket.n !== "number") bucket.n = 0
  if (bucket.seen === null || bucket.seen === undefined || typeof bucket.seen !== "object") {
    bucket.seen = Object.create(null)
  }
  var name = raw === null || raw === undefined ? "" : String(raw)
  var have = bucket.seen[name]
  if (typeof have === "string" && have.length > 0) return have
  bucket.n = bucket.n + 1
  var out = k + "#" + bucket.n
  bucket.seen[name] = out
  return out
}

// A word character for the boundary test, and deliberately a wider set than
// [A-Za-z0-9]: a store name is a file name, so dots, dashes, plus and at
// signs are part of one and must not be read as a boundary.
function _wordish(ch) {
  return ch !== "" && /[A-Za-z0-9._@+-]/.test(ch)
}

// One name -> its token, everywhere it occurs and nowhere it is part of a
// longer word. The boundary test is what keeps a three-character entry from
// garbling "high" into "hi" + token + "h": a hit flanked by a word
// character is not this name, it is a coincidence, and a garbled line is
// its own kind of wrong.
function _swap(text, name, tok) {
  if (name === "" || tok === undefined || tok === null || tok === "") return text
  var out = ""
  var i = 0
  for (;;) {
    var at = text.indexOf(name, i)
    if (at === -1) break
    var before = at > 0 ? text.charAt(at - 1) : ""
    var after = text.charAt(at + name.length)
    out = out + text.substring(i, at)
    if (_wordish(before) || _wordish(after)) {
      out = out + name
    } else {
      out = out + String(tok)
    }
    i = at + name.length
  }
  return out + text.substring(i)
}

// A child's stderr, with every name this session has tokenised replaced by
// its token. This is the second half of the token's job and the reason the
// map is kept at all: a child reports its own failures in its own words,
// and git in particular prints the absolute path of the store in almost
// every message it produces ("fatal: not a git repository: /home/.../
// password-store"). Those lines are worth having - they are the reason a
// pull failed - and they cannot be logged raw.
//
// Text is bounded and flattened first: the log is read by grep, which reads
// lines, so a message carrying a newline would forge a second line out of
// the first. Names are applied longest first, because "email/gmail" has to
// be replaced before "email" or the entry token would then be searched for
// in a string whose folder prefix has already become a folder token.
function redact(text, map, maxChars) {
  var s = String(text === null || text === undefined ? "" : text)
  var cap = typeof maxChars === "number" && maxChars > 0 ? Math.round(maxChars) : 160
  s = s.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim()
  if (s === "") return ""
  var pairs = []
  if (map !== null && map !== undefined && typeof map === "object") {
    for (var k in map) {
      var bucket = map[k]
      if (bucket === null || bucket === undefined || typeof bucket !== "object") continue
      var seen = bucket.seen
      if (seen === null || seen === undefined || typeof seen !== "object") continue
      for (var name in seen) {
        if (name === "") continue
        pairs.push([name, seen[name], k])
      }
    }
  }
  // Longest first, then by kind and name, and the tie-break is total. Two
  // kinds can hold the same name - an entry token and a folder token for the
  // same string, which happens whenever a name is both - and an unstable
  // comparison would let either of them win by accident, so the same log
  // would read differently on two runs of the same session.
  pairs.sort(function (a, b) {
    if (b[0].length !== a[0].length) return b[0].length - a[0].length
    if (a[2] !== b[2]) return a[2] < b[2] ? -1 : 1
    if (a[0] !== b[0]) return a[0] < b[0] ? -1 : 1
    return a[1] < b[1] ? -1 : 1
  })
  for (var i = 0; i < pairs.length; i++) s = _swap(s, pairs[i][0], pairs[i][1])
  if (s.length > cap) return s.substring(0, cap - 3) + "..."
  return s
}

// What a decrypted entry holds, as two counts. A pass entry is a first line
// (the password) and whatever follows it, and a line the user left blank is
// a field that is missing - a real and confusing state, because the panel
// shows the entry as present either way. The count answers "is one missing"
// without printing a field, and a field NAME is content here too: `password`
// and `totp` are harmless, but a custom field name is whatever the user
// typed and in some stores reveals the service.
//
// One trailing empty element is dropped first: it is the newline that ended
// the last line, not a blank field the user left behind.
function fieldCounts(text) {
  var s = String(text === null || text === undefined ? "" : text)
  var lines = s.split("\n")
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  var fields = 0
  var empty = 0
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length > 0 && line.charAt(line.length - 1) === "\r") line = line.substring(0, line.length - 1)
    if (line.replace(/^[ \t]+/, "").replace(/[ \t]+$/, "") === "") {
      // A blank before the first value is leading whitespace in the file,
      // not an empty field; a blank after one is a field with no value.
      if (fields > 0) empty++
      continue
    }
    fields++
  }
  return { fields: fields, empty: empty }
}

// What one scan found: entries, folders, and how deep the walk went. Depth
// is the segment count of the deepest name on either side, so
// "email/gmail.gpg" counts two and the folder holding it counts one. It is
// the number that separates a scan that found fewer entries than expected
// because the tree is shallower from one that walked the same tree and lost
// something - the difference between a small vault and a broken scan, which
// is otherwise the same two numbers.
function storeStats(files, dirs) {
  var farr = Array.isArray(files) ? files : []
  var darr = Array.isArray(dirs) ? dirs : []
  var depth = 0
  function depthOf(p) {
    var s = String(p === null || p === undefined ? "" : p)
    if (s === "") return 0
    var n = 1
    for (var i = 0; i < s.length; i++) if (s.charAt(i) === "/") n++
    return n
  }
  var i
  var d
  for (i = 0; i < farr.length; i++) { d = depthOf(farr[i]); if (d > depth) depth = d }
  for (i = 0; i < darr.length; i++) { d = depthOf(darr[i]); if (d > depth) depth = d }
  return { entries: farr.length, folders: darr.length, depth: depth }
}

// --- facade projections ---------------------------------------------------
//
// The resident facade over a demand-loaded controller: four pure derivations
// that answer an IPC caller or a panel while the controller is, may be, or
// is not there. They live here with the rest of the pass vocabulary because
// they are the same kind of thing - a value derived from state the facade
// only reads - and the facade is their only caller.
//
// The redaction contract they all keep: each returns a state name, a code, or
// a path, and none takes or returns a value. A decrypted credential lives in
// SecretStore under a handle and is reached only through the facade's
// transport; nothing in this file can read one, so a projection that landed
// here could not publish one either.

// The defined answer for a verb issued while no controller is there, so a
// caller learns why instead of getting a silent no-op. `error` is the
// controller's own code (a construction failure), never its lastError.
function unavailableVerb(state, error) {
  if (state === "failed") return "error:" + (error !== "" ? error : "controller");
  if (state === "loading") return "loading";
  return "unavailable";
}

// The status line's two sources: the controller's last error, else the
// transport's own. A code and a message, never a value.
function statusError(controllerError, copyError) {
  if (controllerError === "") return copyError;
  return controllerError;
}

// One peel step of the panel's navigation, as the fields to write: `mode`
// only where the step changes the page, `dir` only where it moves the folder,
// and `close` when the step is the terminal one. The facade applies them and
// nothing here mutates a panel. Menu dismissal is the terminal step - there
// are no Back rows anywhere.
function navigationBack(mode, dir) {
  if (mode === "action" || mode === "create") return { mode: "browse" };
  if (mode === "browse") {
    var d = String(dir || "");
    if (d === "") return { mode: "menu" };
    var slash = d.lastIndexOf("/");
    return { mode: "browse", dir: slash === -1 ? "" : d.substring(0, slash) };
  }
  return { close: true };
}

// The answer to a toggle: closing always reports ok, and opening reports ok
// only once the controller is ready and the panel is actually up. The
// refusal for a controller that is not there is unavailableVerb's.
function toggleReply(wasVisible, state, visible, error) {
  if (wasVisible) return "ok";
  if (state === "ready" && visible) return "ok";
  return unavailableVerb(state, error);
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    versionCompare: versionCompare,
    stripGpg: stripGpg,
    splitEntry: splitEntry,
    listEntries: listEntries,
    parseFindOutput: parseFindOutput,
    isValidName: isValidName,
    storeDir: storeDir,
    firstLine: firstLine,
    childrenOf: childrenOf,
    countUnder: countUnder,
    filterEntries: filterEntries,
    searchVault: searchVault,
    parseKeyFingerprints: parseKeyFingerprints,
    newTokenMap: newTokenMap,
    token: token,
    redact: redact,
    fieldCounts: fieldCounts,
    storeStats: storeStats,
    unavailableVerb: unavailableVerb,
    statusError: statusError,
    navigationBack: navigationBack,
    toggleReply: toggleReply
  };
}
