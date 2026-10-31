pragma Singleton
pragma ComponentBehavior: Bound
// qmllint disable unqualified

import QtQml
import Quickshell
import "PathPolicy.js" as PP

// QML facade over the lexical helper.
//
// The helper judges strings only, so this facade never claims a filesystem
// guarantee. Canonical resolution, a recursive delete or copy, and atomic
// private creation need a trusted filesystem helper that owns the open with
// no-follow semantics. That helper is not part of the shell module, so a
// request for one of them answers `containment_unavailable` here: the
// operation must not be performed, and a lexical allow must not be read as
// containment. Every allow reports `containment: "unverified"` plus the
// `unverified` list of what no lexical check can prove.
//
// The facade imports no feature, service, or process type on purpose: a path
// decision must not be able to reach a shell.
//
// Operation names are a closed vocabulary read from the helper and matched for
// exact equality, as `mode` is. A name outside it is refused with
// `invalid_operation` instead of being judged as a request that reaches nothing
// more than one path, so a near-miss spelling cannot walk past the gates the
// helper puts on its recursive and private names.
Singleton {
  id: root

  readonly property string containmentUnavailable: "containment_unavailable"
  readonly property string lexicalMode: "lexical"

  // Judgment of one candidate against a root, lexical only. An allow carries
  // root, path, relative, depth, existing, and the unavailable and unverified
  // lists; a refusal carries root, path, and the same lists.
  function check(rootPath, candidate, options) {
    const refused = root._refuse(options)
    if (refused !== null) return refused
    return root._project(PP.lexical(rootPath, candidate, options), false)
  }

  // Judgment of a batch against one root, lexical only. The batch is
  // all-or-nothing: `ok` is false when any candidate is refused, and
  // `failedIndex` names the first refusal. The result carries the per-candidate
  // paths and their existing decisions in the same order. A request the helper
  // refuses before it examines a candidate keeps that shape with the helper's
  // own code and an empty per-candidate list.
  function authorize(rootPath, options) {
    const refused = root._refuse(options)
    if (refused !== null) return refused
    return root._project(PP.authorize(rootPath, options), true)
  }

  // A request without a usable options object cannot be judged, so a
  // malformed call never reads as a permissive default. An operation outside
  // the helper's vocabulary is refused here, before the lexical pass: the
  // gates there key on the exact name, so a spelling they do not recognise
  // would arrive as a request that reaches nothing more than one path.
  function _refuse(options) {
    if (options === null || typeof options !== "object" || Array.isArray(options)) return root._invalidOptions()
    if (options.operation !== undefined && !PP.isOperation(options.operation)) return root._invalidOperation(options)
    if (options.candidates !== undefined && !Array.isArray(options.candidates)) return root._invalidOptions()
    const blocked = root._blockedBy(options)
    if (blocked !== "") return root._unavailable(blocked, options)
    return null
  }

  // A verified canonical root, a recursive traversal, and the atomic private
  // open are the helper's domain. The operation names come from the helper
  // itself: a second list here could name an operation the lexical pass does
  // not recognise, and the pass would then allow it.
  function _blockedBy(options) {
    if (options.requireCanonical === true) return root.containmentUnavailable
    if (PP.helperOwned(options.operation)) return root.containmentUnavailable
    if (options.atomic === true) return root.containmentUnavailable
    return ""
  }

  function _unavailable(code, options) {
    return {
      ok: false,
      code: code,
      mode: root.lexicalMode,
      operation: typeof options.operation === "string" ? options.operation : "",
      canonicalRoot: options.canonicalRoot === true,
      containment: "unverified",
      unavailable: [code],
      unverified: PP.unverifiedList(options)
    }
  }

  // The helper already refuses every operation this facade blocks, so a
  // refusal reaching here is a path defect with a usable code and path.
  function _project(result, batch) {
    if (batch) return root._projectBatch(result)
    if (result.ok !== true) {
      return {
        ok: false,
        code: result.code,
        mode: root.lexicalMode,
        operation: result.operation,
        root: result.root,
        path: result.path,
        containment: "unverified",
        unavailable: result.unavailable,
        unverified: result.unverified
      }
    }
    return {
      ok: true,
      code: "ok",
      mode: root.lexicalMode,
      operation: result.operation,
      root: result.root,
      path: result.path,
      relative: result.relative,
      depth: result.depth,
      canonicalRoot: result.canonicalRoot === true,
      containment: "unverified",
      atomic: result.atomic === true,
      secret: result.secret === true,
      existing: result.existing,
      unavailable: result.unavailable,
      unverified: result.unverified
    }
  }

  // The helper judges no candidate when it refuses the request itself, and
  // such a refusal carries a code but no `results` array, so reading one throws
  // where a refusal is required. The array is checked instead: the code the
  // helper chose is the refusal, and the batch names no candidate, no index,
  // and no claim about what a lexical pass could not examine.
  function _projectBatch(result) {
    const candidates = []
    const existing = []
    const judged = Array.isArray(result.results) ? result.results : []
    for (let i = 0; i < judged.length; i++) {
      candidates.push(judged[i].ok === true ? judged[i].path : "")
      existing.push(judged[i].ok === true ? judged[i].existing : "refused")
    }
    return {
      ok: result.ok === true,
      code: result.code,
      mode: root.lexicalMode,
      operation: typeof result.operation === "string" ? result.operation : "",
      root: typeof result.root === "string" ? result.root : "",
      rootExists: result.rootExists === true,
      count: judged.length,
      failedIndex: typeof result.failedIndex === "number" ? result.failedIndex : -1,
      candidates: candidates,
      existing: existing,
      canonicalRoot: result.canonicalRoot === true,
      containment: "unverified",
      atomic: result.atomic === true,
      secret: result.secret === true,
      recursive: result.recursive === true,
      unavailable: Array.isArray(result.unavailable) ? result.unavailable : [],
      unverified: Array.isArray(result.unverified) ? result.unverified : []
    }
  }

  // A rejected operation is echoed so the caller can see which name the
  // vocabulary refused. No containment is claimed: the request never reached
  // a path decision.
  function _invalidOperation(options) {
    return {
      ok: false,
      code: "invalid_operation",
      mode: root.lexicalMode,
      operation: typeof options.operation === "string" ? options.operation : ""
    }
  }

  function _invalidOptions() {
    return {
      ok: false,
      code: "invalid_options",
      mode: root.lexicalMode
    }
  }
}
