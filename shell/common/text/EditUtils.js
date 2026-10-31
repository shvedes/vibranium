// Shared editing helpers for panels that own a TextInput.
//
// Extracted from the duplicated wordBoundary* helpers historically
// copy-pasted between MenuPanel and LauncherPanel. Pure JS so both
// QML panels can import it as `EditUtils` and keep keyboard parity.
.pragma library

function boundaryBackward(text, from) {
  const t = String(text ?? "")
  let i = Math.min(Math.max(0, from), t.length)
  while (i > 0 && /\s/.test(t[i - 1])) i--
  while (i > 0 && !/\s/.test(t[i - 1])) i--
  return i
}

function boundaryForward(text, from) {
  const t = String(text ?? "")
  const n = t.length
  let i = Math.min(Math.max(0, from), n)
  while (i < n && !/\s/.test(t[i])) i++
  while (i < n && /\s/.test(t[i])) i++
  return i
}

function eraseWord(text, cursorPos) {
  const start = boundaryBackward(text, cursorPos)
  if (start === cursorPos) return { text: text, pos: cursorPos }
  return {
    text: String(text).substring(0, start) + String(text).substring(cursorPos),
    pos: start
  }
}
