pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import qs.common

// ShellState - one general JSON state file owned by the whole shell:
// $VIBRANIUM_STATE/shell.jsonc, namespaced by section
// ({"cursor": {"theme": "Adwaita", "size": 24}, "weather": {...}, ...}).
//
// Thin synchronous facade over AppState's "state"-scoped "shell" slot,
// which owns the debounced atomic writes, echo suppression and watching -
// consumers here never touch files or spawn processes. Sections are
// plain objects created on first write; unknown sections read as null.
//
// wallpaper.json stays standalone (per-theme memory outside the theme
// payload with its own hot write path) and theme.name / theme/qs.json
// stay owned by vb-theme-set (read-only for the shell).
Singleton {
  id: root

  readonly property string tag: "shellState"

  // AppState slot (and section map) backing this state.
  readonly property string slotKey: "shell"

  // Ensure the backing slot exists (idempotent - first call creates
  // and loads shell.jsonc, later calls are a map hit).
  function _ensure() {
    AppState.slot(root.slotKey, {}, "state", "shell.jsonc")
  }

  // Reactive section read: captures AppState.rev so bindings follow
  // writes. Returns the section object, or null when absent.
  function section(name) {
    root._ensure()
    return AppState.section(root.slotKey, name)
  }

  // Replace a section wholesale and schedule a debounced flush.
  // Returns false when the name is unusable. AppState owns the argument
  // guards, so the facade does not restate them.
  function setSection(name, obj) {
    root._ensure()
    return AppState.setSection(root.slotKey, name, obj)
  }

  // Shallow-merge `patch` into a section (created when absent).
  function updateSection(name, patch) {
    root._ensure()
    return AppState.updateSection(root.slotKey, name, patch)
  }

  // Numeric field read with fallback: validated finite number or
  // `fallback` otherwise.
  function number(sectionName, field, fallback) {
    root._ensure()
    return AppState.sectionNumber(root.slotKey, sectionName, field, fallback)
  }

  // String field read with fallback: trimmed string or `fallback`.
  function string(sectionName, field, fallback) {
    const s = root.section(sectionName)
    const v = s ? String(s[String(field)] ?? "") : ""
    const fb = typeof fallback === "string" ? fallback : ""
    return v !== "" ? v : fb
  }
}
