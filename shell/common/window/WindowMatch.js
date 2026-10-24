.pragma library

// Pure app-identity matching behind common/window/WindowFocus.qml. Given
// what a notification sender says it is and what a compositor reports
// about each open window, decide which window the sender owns. No Qt,
// no Quickshell, no protocol objects here: rows arrive as plain records
// and the answer is an index or -1, so the whole policy is unit-drivable
// without a compositor.
//
// The policy mirrors the one bin/vb-launch-cmd already applies to the
// same problem from the other side (an executable name to a window
// class), so the shell and the launchers agree on which window "telegram"
// or "google-chrome" means.

// Recency 0 means "this shell never saw this window focused", which is
// both the default for a row carrying no recency and the floor a row has
// to clear to be considered at all.
const NO_RECENT = 0

// A name with its separators intact, lowercased: the form a window's
// appId also has, so the two can be compared for word boundaries. Spaces
// become dashes because that is what appIds use for the same thing -
// "Google Chrome" and google-chrome are the same app, and only a shared
// separator convention can say so.
function rawName(value) {
  return String(value ?? "").trim().toLowerCase().replace(/\s+/g, "-")
}

// A name with every separator removed: the form that makes a display
// string comparable to a machine id at all. "Telegram" and
// "org.telegram.desktop" are the same name written twice.
function flatten(value) {
  return rawName(value).replace(/[^a-z0-9]/g, "")
}

// A .desktop basename as senders report it in desktop_entry, reduced to
// the app name. The extension comes off, and a reverse-DNS id
// (org.telegram.desktop) keeps its last component, which is the name the
// window reports: org.gnome.nautilus -> nautilus, com.spotify.client ->
// spotify. The leading components are domain registration, not a name, and
// keeping them would give the key "org" and match every appId under a
// domain.
function fromDesktopEntry(value) {
  let s = rawName(value)
  if (s.endsWith(".desktop")) s = s.slice(0, -7)
  const parts = s.split(".").filter(p => p.length > 0)
  if (parts.length === 0) return ""
  return parts[parts.length - 1]
}

// True when one name is a separator-bounded prefix of the other: the
// character right after the shared prefix must end a word, or the two
// must be equal length. Symmetric, because both spellings occur - a key
// may be shorter than the appId (google-chrome -> google-chrome-stable)
// or longer (gnome-terminal against the component "gnome"). A bare
// startswith is not enough: "obs" would claim "obsidian".
function sepPrefix(a, b) {
  if (a === "" || b === "") return false
  if (a === b) return true
  if (b.length > a.length && b.startsWith(a)) {
    return "-._".indexOf(b.charAt(a.length)) !== -1
  }
  if (a.length > b.length && a.startsWith(b)) {
    return "-._".indexOf(a.charAt(b.length)) !== -1
  }
  return false
}

// A reverse-DNS appId (org.telegram.desktop) carries the app name in one
// component; a dotless class cannot be decomposed, so the dot is the
// guard. Plain startswith is not used on the component: short components
// like "org" or "com" would then match any key that merely begins with
// those letters.
function rdnsMatch(appId, key) {
  if (appId.indexOf(".") === -1 || key === "") return false
  const parts = appId.split(".").filter(p => p.length > 0)
  for (const part of parts) {
    if (part === key) return true
    if (sepPrefix(part, key)) return true
  }
  return false
}

// How closely one row's appId answers one key. Phases are ordered, not
// scored, and the caller runs them in turn.
//
// Both forms of the key are offered to every phase because each phase
// needs a different one: an exact hit compares the flattened forms (that
// is what lets a display string equal a machine id), while a prefix and a
// component need the separators intact (that is what makes a word
// boundary visible at all). A flattened key has no boundaries left, so
// asking it to match a prefix would only ever fail.
function phaseFor(appId, rawKey, flatKey) {
  if (appId === "" || rawKey === "") return -1
  if (appId === rawKey || flatten(appId) === flatKey) return 0
  if (sepPrefix(appId, rawKey)) return 1
  if (rdnsMatch(appId, rawKey) || rdnsMatch(appId, flatKey)) return 2
  return -1
}

// The keys a sender can be recognised by, strongest first, as {raw, flat}
// pairs. desktopEntry is the .desktop basename and the only field that is
// an app id by construction; appIcon is often the same string when a
// sender uses it as an app id rather than as an icon; appName is a
// display string and the last resort.
function candidateKeys(sender) {
  const keys = []
  const add = (value, component) => {
    const raw = component ? fromDesktopEntry(value) : rawName(value)
    const flat = flatten(raw)
    if (raw === "" || flat === "") return
    for (const existing of keys) {
      if (existing.flat === flat) return
    }
    keys.push({ raw: raw, flat: flat })
  }
  add(sender?.desktopEntry, true)
  const icon = rawName(sender?.appIcon)
  if (icon !== "" && !icon.startsWith("/") && !icon.startsWith("file:")) {
    // A filesystem path carries no app id: flattened it would be a long
    // alnum token no appId can equal, so the key could only ever miss.
    add(icon, false)
  }
  add(sender?.appName, false)
  return keys
}

// Index of the row a sender owns, or -1.
//
// The phases run across every row before the next key is tried. That
// ordering is the whole precedence rule: it makes the strongest identity
// decide which window, while recency decides only inside one identity. A
// desktop entry that matches one window exactly wins outright over a
// display name that reaches a more recently focused window only through
// the loosest phase. Scoring instead of ordering would invert that, since
// the loose phases are reached only by the weak keys and would
// accumulate enough to outrank a real hit.
//
// Recency is read from the row and never sorted here. The caller owns the
// ordering because it is the caller that knows how the compositor reports
// focus order, and a match that re-sorted its own input would silently
// disagree with whatever else ranks the same list.
function matchIndex(sender, rows) {
  if (!rows || rows.length === 0) return -1
  const keys = candidateKeys(sender)
  for (let phase = 0; phase < 3; phase++) {
    for (const key of keys) {
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i]
        if (!row) continue
        const recency = Number(row.recency ?? NO_RECENT)
        if (!Number.isFinite(recency) || recency < NO_RECENT) continue
        const appId = String(row.appId ?? "").toLowerCase()
        if (phaseFor(appId, key.raw, key.flat) === phase) return i
      }
    }
  }
  return -1
}
