// Pure checkupdates / yay -Qua output parsing for the Arch updates
// service (qs.services). One line per package: `pkgname oldver ->
// newver` (checkupdates and yay -Qua share the shape; the bare 4-field
// pacman -Qu form is handled too). Canonical home of the parser that
// lived inline in ArchUpdates.qml; the service delegates to it. Pure JS,
// pragma library, no Qt imports - unit-tested in
// tests/shell/suites/js/arch-updates.test.mjs.
.pragma library

// Parse one fetcher's stdout into package records
// { name, current, candidate, repository, size, source }. Malformed
// lines are skipped, never painted; overlong fields are capped.
function parseUpdates(text, source) {
  const lines = String(text || "").split("\n")
  const pkgs = []
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim()
    if (line === "") continue
    if (line.length > 512) continue
    let name = ""
    let current = ""
    let candidate = ""
    const arrow = line.indexOf("->")
    if (arrow >= 0) {
      const left = line.substring(0, arrow).trim()
      const right = line.substring(arrow + 2).trim()
      const parts = left.split(/\s+/)
      name = parts[0] || ""
      current = parts[1] || ""
      const rparts = right.split(/\s+/)
      candidate = rparts[0] || ""
    } else {
      const parts = line.split(/\s+/)
      if (parts.length >= 4) {
        name = parts[0]
        current = parts[1]
        candidate = parts[3]
      } else if (parts.length >= 3) {
        name = parts[0]
        current = parts[1]
        candidate = parts[2]
      }
    }
    if (name === "") continue
    if (name.length > 128) name = name.substring(0, 128)
    if (current.length > 128) current = current.substring(0, 128)
    if (candidate.length > 128) candidate = candidate.substring(0, 128)
    pkgs.push({
      name: name,
      current: current,
      candidate: candidate,
      repository: "",
      size: "",
      source: source
    })
  }
  return pkgs
}

if (typeof module !== "undefined") {
  module.exports = {
    parseUpdates: parseUpdates
  }
}
