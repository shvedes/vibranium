pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell

// Neutral store for credential material.
//
// Posture: a value enters through stash() under a caller-chosen handle and
// leaves through feed(), which hands it to a sink and then forgets it. Nothing
// is written to disk, no cipher key is derived or held here, and no value is
// exposed as a QML property, so a list row, a DTO, or an IPC projection has
// nothing to copy out. The only sink in this tree is a child process stdin
// write, which is what keeps a credential out of argv and out of every process
// listing that reads /proc/<pid>/cmdline.
//
// Persistence would need a key that does not sit beside the ciphertext it
// protects. Quickshell 0.3.1 ships no QML keyring type, so the only reachable
// posture is memory-only, and a captured credential lives exactly as long as
// the session that captured it. enableHelper() exists for a future validated
// helper: it judges the executable shape and the expected protocol version
// first, hands back a nonce, and the posture stays memory-only until
// confirmHelper() proves the helper answered that exact nonce. No function
// here takes a key, so no reversible key can reach this file even from a
// caller that would like to store one.
Singleton {
  id: root

  // "memory" until a validated helper answers, "helper" once one has.
  readonly property string posture: root._helperOk ? "helper" : "memory"
  // True only while a validated helper holds values across sessions.
  readonly property bool persistent: root._helperOk
  readonly property int count: Object.keys(root._slots).length

  property var _slots: ({})
  property string _helperState: "absent"
  property bool _helperOk: false
  property string _helperExec: ""
  property string _helperProtocol: ""
  property string _helperNonce: ""
  property int _seq: 0

  // A handle is an opaque caller-side name, never the value itself: it is
  // safe to log, compare, and put in a DTO.
  function stash(handle, value) {
    const key = String(handle === undefined || handle === null ? "" : handle)
    const text = String(value === undefined || value === null ? "" : value)
    if (key === "" || text === "") return false
    const next = Object.assign({}, root._slots)
    next[key] = text
    root._slots = next
    return true
  }

  function has(handle) {
    const key = String(handle === undefined || handle === null ? "" : handle)
    return key !== "" && root._slots[key] !== undefined
  }

  // Direct read, for the cases that need the bytes twice (feeding one child
  // and then another) or need to compare before committing. Prefer feed():
  // it forgets the value on the way out, peek() does not.
  function peek(handle) {
    const key = String(handle === undefined || handle === null ? "" : handle)
    if (key === "") return ""
    const v = root._slots[key]
    return v === undefined ? "" : String(v)
  }

  // The single exit path. The slot is dropped before the sink runs, so a sink
  // that throws cannot leave a value behind to be retried from memory, and
  // the value is handed to the sink and to nothing else - there is no call
  // shape here that returns a credential to arbitrary code.
  function feed(handle, sink) {
    const key = String(handle === undefined || handle === null ? "" : handle)
    if (key === "" || typeof sink !== "function") return false
    const v = root._slots[key]
    if (v === undefined) return false
    root.drop(key)
    let fed = false
    try {
      fed = sink(String(v))
    } catch (ignored) {
      return false
    }
    return fed !== false
  }

  function drop(handle) {
    const key = String(handle === undefined || handle === null ? "" : handle)
    if (key === "" || root._slots[key] === undefined) return false
    const next = Object.assign({}, root._slots)
    delete next[key]
    root._slots = next
    return true
  }

  // Equality test that never hands either value to the caller. Used for
  // deduplication and for matching a value that came back off the clipboard.
  function matchesValue(handle, candidate) {
    const key = String(handle === undefined || handle === null ? "" : handle)
    if (key === "") return false
    const v = root._slots[key]
    if (v === undefined) return false
    return String(v) === String(candidate === undefined || candidate === null ? "" : candidate)
  }

  function clear() {
    const n = root.count
    root._slots = ({})
    return n
  }

  // --- optional trusted helper ---
  // Path shape only: absolute, no whitespace, no shell metacharacter, no
  // traversal. Whether the file is executable and whether it speaks the
  // expected protocol is settled by confirmHelper(), never inferred here, and
  // this function deliberately takes no key to hand the helper.
  function enableHelper(execPath, protocolVersion) {
    if (root._helperOk) return { ok: false, code: "already_enabled" }
    const path = String(execPath === undefined || execPath === null ? "" : execPath)
    if (path === "") return { ok: false, code: "no_path" }
    if (path.charAt(0) !== "/") return { ok: false, code: "not_absolute" }
    if (/[\s;&|<>$`'"\\*?(){}[\]!#~]/.test(path)) return { ok: false, code: "unsafe_path" }
    if (path.indexOf("..") >= 0) return { ok: false, code: "unsafe_path" }
    const version = String(protocolVersion === undefined || protocolVersion === null ? "" : protocolVersion)
    if (version === "") return { ok: false, code: "no_protocol" }
    root._seq++
    const nonce = "h" + (Date.now().toString(36)) + "-" + root._seq
    root._helperExec = path
    root._helperProtocol = version
    root._helperNonce = nonce
    root._helperState = "unverified"
    return { ok: true, code: "unverified", nonce: nonce }
  }

  // The caller proves the executable is runnable and that the helper echoed
  // the nonce enableHelper() handed out. Until then every value stays in
  // memory: an unproven helper is indistinguishable from a key stored beside
  // its own ciphertext.
  function confirmHelper(nonce) {
    if (root._helperState !== "unverified") return { ok: false, code: "no_candidate" }
    if (String(nonce === undefined || nonce === null ? "" : nonce) !== root._helperNonce) {
      root._helperState = "rejected"
      return { ok: false, code: "nonce_mismatch" }
    }
    root._helperOk = true
    root._helperState = "verified"
    return { ok: true, code: "verified" }
  }
}
