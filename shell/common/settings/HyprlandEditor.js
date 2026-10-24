// HyprlandEditor.js - text-based editor/reader for Hyprland's Lua config format.
// This is the only implementation of the Hyprland config editor: the Quickshell
// settings stores, the node CLI, and anything outside the shell all share it.
// Text-based editor/reader for Hyprland's Lua config format.
//
// Does NOT execute the config; treats it as text and parses/rewrites the shape:
//   hl.config({ general = { border_size = 2, ["col.active_border"] = "0xff89b4fa" } })
//   hl.monitor({ output = "HDMI-A-1", mode = "preferred" })
//
// Public API:
//   edit(content, path, value, opts) -> { ok, content, error }
//   get(content, path, opts) -> { ok, value, error }
//   editFile(file, path, value, opts) / getFile(...) for Node/QML with fs
//
// Path is array of strings (section names + option), value is bool/number/string or table for batch.
// Opts: { occurrence: int (1, -1 etc), scope: "config"|"monitor", output: string }
//
.pragma library

function ltrim(s) {
  const m = String(s).match(/^\s*(.*)$/)
  return m ? m[1] : ""
}

function trim(s) {
  const m = String(s).match(/^\s*(.*?)\s*$/)
  return m ? m[1] : ""
}

function leading_ws(s) {
  const m = String(s).match(/^(\s*)/)
  return m ? m[1] : ""
}

function unescape_lua_string(s) {
  s = String(s)
  let out = ""
  for (let i = 0; i < s.length; ) {
    const c = s[i]
    if (c === "\\" && i + 1 < s.length) {
      const nx = s[i + 1]
      if (nx === "\\" || nx === '"') {
        out += nx
        i += 2
      } else {
        out += c
        i += 1
      }
    } else {
      out += c
      i += 1
    }
  }
  return out
}

function escape_lua_string(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

function _get_env(name) {
  let v = ""
  try { v = (typeof Quickshell !== "undefined" ? Quickshell.env(name) : "") || "" } catch(e) {}
  if (!v && typeof process !== "undefined" && process.env) v = process.env[name] || ""
  return v
}
function _home_dir() {
  let h = _get_env("HOME")
  if (!h) {
    try { h = (typeof Quickshell !== "undefined" ? Quickshell.env("HOME") : "") || "" } catch(e) {}
  }
  return h
}
function expand_path(path) {
  let p = String(path)
  // ~ expansion with HOME fallback
  if (p[0] === "~") {
    const home = _home_dir()
    if (home) {
      if (p === "~") p = home
      else if (p.slice(0, 2) === "~/") p = home + p.slice(1)
    }
  }
  // ${VAR} first - with XDG fallbacks
  p = p.replace(/\${([A-Za-z_][A-Za-z0-9_]*)}/g, (m, name) => {
    let v = _get_env(name)
    if (!v) {
      const home = _home_dir()
      if (name === "XDG_CONFIG_HOME" && home) v = home + "/.config"
      else if (name === "XDG_STATE_HOME" && home) v = home + "/.local/state"
      else if (name === "XDG_CACHE_HOME" && home) v = home + "/.cache"
      else if (name === "XDG_DATA_HOME" && home) v = home + "/.local/share"
    }
    return v ? v : "${" + name + "}"
  })
  p = p.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (m, name) => {
    let v = _get_env(name)
    if (!v) {
      const home = _home_dir()
      if (name === "XDG_CONFIG_HOME" && home) v = home + "/.config"
      else if (name === "XDG_STATE_HOME" && home) v = home + "/.local/state"
      else if (name === "XDG_CACHE_HOME" && home) v = home + "/.cache"
      else if (name === "XDG_DATA_HOME" && home) v = home + "/.local/share"
    }
    return v ? v : "$" + name
  })
  return p
}

function read_lines_content(content) {
  if (content === "" || content == null) return []
  let c = String(content)
  // normalize: drop exactly one trailing newline before splitting
  if (c.endsWith("\n")) c = c.slice(0, -1)
  const lines = []
  // re-add newline to ensure last line captured
  const tmp = c + "\n"
  let start = 0
  for (let i = 0; i < tmp.length; i++) {
    if (tmp[i] === "\n") {
      lines.push(tmp.slice(start, i))
      start = i + 1
    }
  }
  return lines
}

function write_lines_content(lines) {
  if (lines.length === 0) return ""
  return lines.join("\n") + "\n"
}

function detect_indent_unit(lines) {
  let min_indent = null
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const stripped = ltrim(line)
    if (stripped === "" || stripped.slice(0, 2) === "--" || stripped === line) continue
    const lead = leading_ws(line)
    if (lead !== "" && (min_indent === null || lead.length < min_indent.length)) {
      min_indent = lead
    }
  }
  return min_indent !== null ? min_indent : "    "
}

function infer_child_indent(lines, sec_start, sec_end, unit) {
  let depth = 0
  for (let i = sec_start + 1; i < sec_end - 1; i++) {
    const line = lines[i]
    const stripped = ltrim(line)
    if (stripped === "" || stripped.slice(0, 2) === "--") {
    } else if (stripped[0] === "}") {
      depth -= 1
    } else {
      if (depth === 0) return leading_ws(line)
      if (stripped.indexOf("{") !== -1) depth += 1
    }
  }
  return leading_ws(lines[sec_start]) + unit
}

function lua_key_fmt(key) {
  key = String(key)
  if (key !== "" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) return key
  return '["' + escape_lua_string(key) + '"]'
}

function lua_number_str(n) {
  if (n === Math.floor(n)) return n.toFixed(0)
  return String(n)
}

function serialize_value(value) {
  const t = typeof value
  if (t === "boolean") return String(value)
  if (t === "number") return lua_number_str(value)
  if (t === "string") return '"' + escape_lua_string(value) + '"'
  return null
}

function parse_typed_value(raw) {
  let s = trim(raw)
  if (s.endsWith(",")) s = trim(s.slice(0, -1))
  if (s === "true") return true
  if (s === "false") return false
  if (s.length >= 2 && ((s[0] === '"' && s[s.length - 1] === '"') || (s[0] === "'" && s[s.length - 1] === "'"))) {
    return unescape_lua_string(s.slice(1, -1))
  }
  const n = Number(s)
  if (!isNaN(n) && s !== "" && /^-?[0-9]+(\.[0-9]+)?$/.test(s.trim().replace(",", "."))) {
    // use tonumber logic: if s is numeric string, return number
    // but need to handle cases like "2.0" -> 2
    const num = Number(s)
    if (!isNaN(num)) return num
  }
  // fallback: if tonumber succeeds
  const num2 = Number(s)
  if (!isNaN(num2) && s !== "" && s.trim() !== "") {
    // check if s is valid number representation (allow .?)
    if (/^-?\d+(\.\d+)?$/.test(s.trim())) return num2
  }
  return s
}

function parse_bracket_key(token) {
  let s = trim(token)
  if (s[0] !== "[") return null
  const endp = s.indexOf("]")
  if (endp === -1) return null
  const inner = trim(s.slice(1, endp))
  if (inner.length >= 2 && ((inner[0] === '"' && inner[inner.length - 1] === '"') || (inner[0] === "'" && inner[inner.length - 1] === "'"))) {
    return inner.slice(1, -1)
  }
  return null
}

function section_name(stripped) {
  stripped = String(stripped)
  if (stripped[0] === "[") {
    const bracket_end = stripped.indexOf("]")
    if (bracket_end === -1) return null
    const name = parse_bracket_key(stripped.slice(0, bracket_end + 1))
    if (!name) return null
    const rest = ltrim(stripped.slice(bracket_end + 1))
    if (rest[0] === "=") {
      const after_eq = ltrim(rest.slice(1))
      if (after_eq[0] === "{") return name
    }
    return null
  }
  const m = stripped.match(/^([\w_-]+)/)
  const name = m ? m[1] : null
  if (!name) return null
  const rest = ltrim(stripped.slice(name.length))
  if (rest[0] !== "=") return null
  const after = ltrim(rest.slice(1))
  if (after[0] === "{") return name
  return null
}

function option_key(stripped) {
  stripped = String(stripped)
  if (stripped[0] === "[") {
    const bracket_end = stripped.indexOf("]")
    if (bracket_end === -1) return null
    const name = parse_bracket_key(stripped.slice(0, bracket_end + 1))
    if (!name) return null
    const rest = ltrim(stripped.slice(bracket_end + 1))
    if (rest[0] === "=") {
      const after_eq = ltrim(rest.slice(1))
      if (after_eq[0] !== "{") return name
    }
    return null
  }
  const eq = stripped.indexOf("=")
  if (eq !== -1) {
    const key = trim(stripped.slice(0, eq))
    if (key !== "" && /^[\w_-]+$/.test(key)) {
      const after_eq = trim(stripped.slice(eq + 1))
      if (after_eq[0] !== "{") return key
    }
  }
  return null
}

function option_value_typed(stripped) {
  stripped = String(stripped)
  let raw
  if (stripped[0] === "[") {
    const bracket_end = stripped.indexOf("]")
    if (bracket_end === -1) return null
    const rest = ltrim(stripped.slice(bracket_end + 1))
    if (rest[0] !== "=") return null
    raw = rest.slice(1)
  } else {
    const eq = stripped.indexOf("=")
    if (eq === -1) return null
    raw = stripped.slice(eq + 1)
  }
  return parse_typed_value(raw)
}

function resolve_occurrence(list, occurrence) {
  const count = list.length
  if (count === 0) return null
  let idx
  if (occurrence > 0) idx = occurrence
  else idx = count + occurrence + 1
  if (idx < 1 || idx > count) return null
  return list[idx - 1]
}

function find_top_level_calls(lines, prefix) {
  const results = []
  let i = 0
  const n = lines.length
  while (i < n) {
    const stripped = ltrim(lines[i])
    if (stripped.slice(0, prefix.length) === prefix) {
      const start = i
      let brace_depth = 1
      let j = i + 1
      while (j < n && brace_depth > 0) {
        const s = ltrim(lines[j])
        if (s.slice(0, 2) !== "--") {
          const opens = (s.match(/{/g) || []).length
          const closes = (s.match(/}/g) || []).length
          brace_depth += opens - closes
        }
        j += 1
      }
      results.push({ start: start, end: j - 1 })
      i = j
    } else {
      i += 1
    }
  }
  return results
}

function path_equal(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function find_all_section_bounds(lines, path, start_line, end_line) {
  const results = []
  let current_path = []
  let i = start_line
  while (i <= end_line) {
    const stripped = ltrim(lines[i])
    if (stripped === "" || stripped.slice(0, 2) === "--") {
      i += 1
    } else if (stripped[0] === "}") {
      current_path.pop()
      i += 1
    } else {
      const name = section_name(stripped)
      if (name !== null) {
        current_path.push(name)
        if (path_equal(current_path, path)) {
          const depth = current_path.length - 1
          let brace_depth = 1
          let j = i + 1
          while (j <= end_line && brace_depth > 0) {
            const s = ltrim(lines[j])
            if (s.slice(0, 2) !== "--") {
              const opens = (s.match(/{/g) || []).length
              const closes = (s.match(/}/g) || []).length
              brace_depth += opens - closes
            }
            j += 1
          }
          results.push({ start: i, end: j - 1, depth: depth })
          current_path.pop()
          i = j
        } else {
          i += 1
        }
      } else {
        i += 1
      }
    }
  }
  return results
}

function find_section_bounds(lines, path, start_line, end_line, occurrence) {
  const all = find_all_section_bounds(lines, path, start_line, end_line)
  return resolve_occurrence(all, occurrence)
}

function find_option_in_section(lines, sec_start, sec_end, option_name) {
  let depth = 0
  for (let i = sec_start + 1; i < sec_end; i++) {
    const stripped = ltrim(lines[i])
    if (stripped === "" || stripped.slice(0, 2) === "--") continue
    if (stripped.indexOf("{") !== -1) {
      const opens = (stripped.match(/{/g) || []).length
      depth += opens
    } else if (stripped.indexOf("}") !== -1) {
      const closes = (stripped.match(/}/g) || []).length
      depth -= closes
    } else if (depth === 0) {
      const key = option_key(stripped)
      if (key === option_name) return i
    }
  }
  return null
}

function get_scope_root(lines, opts, occurrence, unit, create) {
  const scope = (opts && opts.scope) || "config"
  if (scope === "config") {
    const calls = find_top_level_calls(lines, "hl.config({")
    if (calls.length === 0) {
      if (!create) return { error: "not found" }
      const n = lines.length
      lines.push("hl.config({")
      lines.push("})")
      return { start: n, end: n + 1 }
    }
    const last = calls[calls.length - 1]
    return { start: last.start, end: last.end }
  }
  if (scope === "monitor") {
    const calls = find_top_level_calls(lines, "hl.monitor({")
    const matches = []
    for (let c = 0; c < calls.length; c++) {
      const call = calls[c]
      const ol = find_option_in_section(lines, call.start, call.end, "output")
      if (ol !== null) {
        const val = option_value_typed(ltrim(lines[ol]))
        if (val === opts.output) matches.push(call)
      }
    }
    if (matches.length === 0) {
      if (!create) return { error: "not found" }
      const n = lines.length
      lines.push("hl.monitor({")
      lines.push(unit + 'output = "' + escape_lua_string(opts.output) + '",')
      lines.push("})")
      return { start: n, end: n + 2 }
    }
    const picked = resolve_occurrence(matches, occurrence)
    if (!picked) return { error: "not found" }
    return { start: picked.start, end: picked.end }
  }
  return { error: "invalid scope" }
}

function navigate_section_readonly(lines, root, section_path, occurrence) {
  if (section_path.length === 0) return { start: root.start, end: root.end }
  let current_line = root.start
  let bounds = null
  for (let depth = 0; depth < section_path.length; depth++) {
    const sub = section_path.slice(0, depth + 1)
    const occ = depth < section_path.length - 1 ? 1 : occurrence
    bounds = find_section_bounds(lines, sub, current_line, root.end, occ)
    if (!bounds) return null
    current_line = bounds.start
  }
  return { start: bounds.start, end: bounds.end }
}

function resolve_section(lines, root, path, occurrence, unit) {
  if (path.length === 0) return { start: root.start, end: root.end }
  let current_line = root.start
  for (let depth = 0; depth < path.length; depth++) {
    const sub = path.slice(0, depth + 1)
    const occ = depth < path.length - 1 ? 1 : occurrence
    let bounds = find_section_bounds(lines, sub, current_line, root.end, occ)
    if (bounds) {
      current_line = bounds.start
      if (depth === path.length - 1) return { start: bounds.start, end: bounds.end }
    } else {
      let parent_start, parent_end
      if (depth === 0) {
        parent_start = root.start; parent_end = root.end
      } else {
        const parent_sub = path.slice(0, depth)
        const pb = find_section_bounds(lines, parent_sub, root.start, root.end, 1)
        parent_start = pb.start; parent_end = pb.end
      }
      const insert_pos = parent_end
      const base_indent = infer_child_indent(lines, parent_start, parent_end, unit)
      const to_insert = []
      if (insert_pos - 1 >= 0) {
        const prev = trim(lines[insert_pos - 1])
        if (prev === "}," || prev === "}") to_insert.push("")
      }
      for (let i = depth; i < path.length; i++) {
        const ind = base_indent + unit.repeat(i - depth)
        to_insert.push(ind + lua_key_fmt(path[i]) + " = {")
      }
      const levels = path.length - depth
      for (let i = levels - 1; i >= 0; i--) {
        const ind = base_indent + unit.repeat(i)
        to_insert.push(ind + "},")
      }
      const blank = to_insert[0] === "" ? 1 : 0
      const target_start = insert_pos + blank + (levels - 1)
      const target_end = target_start + 1
      for (let k = to_insert.length - 1; k >= 0; k--) lines.splice(insert_pos, 0, to_insert[k])
      root.end += to_insert.length
      return { start: target_start, end: target_end }
    }
  }
}

function write_scalar_option(lines, root, section_path, option_name, lua_val, occurrence, unit) {
  const opt_key = lua_key_fmt(option_name)
  if (section_path.length === 0) {
    for (let i = root.start + 1; i < root.end; i++) {
      const stripped = ltrim(lines[i])
      if (stripped === "" || stripped.slice(0, 2) === "--") continue
      const key = option_key(stripped)
      if (key === option_name) {
        lines[i] = leading_ws(lines[i]) + opt_key + " = " + lua_val + ","
        return
      }
    }
    const child_indent = infer_child_indent(lines, root.start, root.end, unit)
    lines.splice(root.start + 1, 0, child_indent + opt_key + " = " + lua_val + ",")
    root.end += 1
    return
  }
  let current_line = root.start
  for (let depth = 0; depth < section_path.length; depth++) {
    const sub = section_path.slice(0, depth + 1)
    const occ = depth < section_path.length - 1 ? 1 : occurrence
    let bounds = find_section_bounds(lines, sub, current_line, root.end, occ)
    if (bounds) {
      current_line = bounds.start
      if (depth === section_path.length - 1) {
        const sec_start = bounds.start, sec_end = bounds.end
        const opt_line = find_option_in_section(lines, sec_start, sec_end, option_name)
        if (opt_line !== null) {
          lines[opt_line] = leading_ws(lines[opt_line]) + opt_key + " = " + lua_val + ","
        } else {
          const opt_indent = infer_child_indent(lines, sec_start, sec_end, unit)
          lines.splice(sec_end, 0, opt_indent + opt_key + " = " + lua_val + ",")
          root.end += 1
        }
        return
      }
    } else {
      let parent_start, parent_end
      if (depth === 0) { parent_start = root.start; parent_end = root.end }
      else {
        const parent_sub = section_path.slice(0, depth)
        const pb = find_section_bounds(lines, parent_sub, root.start, root.end, 1)
        parent_start = pb.start; parent_end = pb.end
      }
      const insert_pos = parent_end
      const base_indent = infer_child_indent(lines, parent_start, parent_end, unit)
      const to_insert = []
      if (insert_pos - 1 >= 0) {
        const prev = trim(lines[insert_pos - 1])
        if (prev === "}," || prev === "}") to_insert.push("")
      }
      for (let i = depth; i < section_path.length; i++) {
        const ind = base_indent + unit.repeat(i - depth)
        to_insert.push(ind + lua_key_fmt(section_path[i]) + " = {")
      }
      const opt_ind = base_indent + unit.repeat(section_path.length - depth)
      to_insert.push(opt_ind + opt_key + " = " + lua_val + ",")
      const levels = section_path.length - depth + 1 - 1
      // close levels = section_path.length - depth
      const lvl = section_path.length - depth
      for (let i = lvl - 1; i >= 0; i--) {
        const ind = base_indent + unit.repeat(i)
        to_insert.push(ind + "},")
      }
      for (let k = to_insert.length - 1; k >= 0; k--) lines.splice(insert_pos, 0, to_insert[k])
      root.end += to_insert.length
      return
    }
  }
}

function normalize_path(path) {
  return path.slice()
}

// Public API working on content string (pure, testable)
function hyprGetContent(content, path, opts) {
  try {
    opts = opts || {}
    const scope = opts.scope || "config"
    if (scope !== "config" && scope !== "monitor") return { ok: false, error: "invalid scope" }
    if (scope === "monitor" && opts.output == null) return { ok: false, error: "opts.output is required when scope is 'monitor'" }
    const clean_path = normalize_path(path)
    const occurrence = opts.occurrence || 1
    if (clean_path.length === 0) return { ok: false, error: "path must include an option name" }
    const lines = read_lines_content(content || "")
    const unit = detect_indent_unit(lines)
    const root = get_scope_root(lines, opts, occurrence, unit, false)
    if (root.error) return { ok: false, error: root.error }
    const section_path = clean_path.slice(0, -1)
    const option_name = clean_path[clean_path.length - 1]
    const sec = navigate_section_readonly(lines, root, section_path, occurrence)
    if (!sec) return { ok: false, error: "not found" }
    const opt_line = find_option_in_section(lines, sec.start, sec.end, option_name)
    if (opt_line === null) return { ok: false, error: "not found" }
    const val = option_value_typed(ltrim(lines[opt_line]))
    if (val === null || val === undefined) return { ok: false, error: "not found" }
    return { ok: true, value: val }
  } catch (e) {
    return { ok: false, error: "internal error: " + String(e && e.message || e) }
  }
}

function hyprEditContent(content, path, value, opts) {
  try {
    opts = opts || {}
    const scope = opts.scope || "config"
    if (scope !== "config" && scope !== "monitor") return { ok: false, error: "invalid scope" }
    if (scope === "monitor" && opts.output == null) return { ok: false, error: "opts.output is required when scope is 'monitor'" }
    const clean_path = normalize_path(path)
    const occurrence = opts.occurrence || 1
    const vtype = typeof value
    // table batch handling
    const isBatch = value !== null && typeof value === "object" && !Array.isArray(value)
    if (isBatch) {
      for (const k in value) {
        const v = value[k]
        if (v !== null && typeof v === "object") return { ok: false, error: "nested table values not supported" }
        if (typeof v === "string" && v === "") return { ok: false, error: "empty value" }
        if (typeof v !== "boolean" && typeof v !== "number" && typeof v !== "string") return { ok: false, error: "unsupported value type" }
      }
    } else {
      if (vtype !== "boolean" && vtype !== "number" && vtype !== "string" && vtype !== "object") return { ok: false, error: "unsupported value type" }
      if (vtype === "string" && value === "") return { ok: false, error: "empty value" }
      if (vtype === "object") return { ok: false, error: "unsupported value type" }
    }
    const lines = read_lines_content(content || "")
    const unit = detect_indent_unit(lines)
    if (isBatch) {
      const root = get_scope_root(lines, opts, occurrence, unit, true)
      if (root.error) return { ok: false, error: root.error }
      const sec = resolve_section(lines, root, clean_path, occurrence, unit)
      if (!sec) return { ok: false, error: "section not found" }
      const is_root_target = clean_path.length === 0
      const sec_start = sec.start, sec_end = sec.end
      // update existing, collect to_insert
      const to_insert = []
      for (const k in value) {
        const serialized = serialize_value(value[k])
        const opt_line = find_option_in_section(lines, sec_start, sec_end, k)
        if (opt_line !== null) {
          lines[opt_line] = leading_ws(lines[opt_line]) + lua_key_fmt(k) + " = " + serialized + ","
        } else {
          to_insert.push({ key: k, val: serialized })
        }
      }
      if (to_insert.length > 0) {
        if (is_root_target) {
          const child_indent = infer_child_indent(lines, sec_start, sec_end, unit)
          for (let i = 0; i < to_insert.length; i++) {
            const item = to_insert[i]
            lines.splice(sec_start + 1, 0, child_indent + lua_key_fmt(item.key) + " = " + item.val + ",")
          }
        } else {
          const opt_indent = infer_child_indent(lines, sec_start, sec_end, unit)
          const batch_lines = []
          for (let i = 0; i < to_insert.length; i++) batch_lines.push(opt_indent + lua_key_fmt(to_insert[i].key) + " = " + to_insert[i].val + ",")
          for (let k = batch_lines.length - 1; k >= 0; k--) lines.splice(sec_end, 0, batch_lines[k])
        }
        root.end += to_insert.length
      }
      return { ok: true, content: write_lines_content(lines) }
    }
    // scalar
    if (clean_path.length === 0) return { ok: false, error: "path must include an option name" }
    const section_path = clean_path.slice(0, -1)
    const option_name = clean_path[clean_path.length - 1]
    const serialized = serialize_value(value)
    const root = get_scope_root(lines, opts, occurrence, unit, true)
    if (root.error) return { ok: false, error: root.error }
    write_scalar_option(lines, root, section_path, option_name, serialized, occurrence, unit)
    return { ok: true, content: write_lines_content(lines) }
  } catch (e) {
    return { ok: false, error: "internal error: " + String(e && e.message || e) }
  }
}

// Command-line argument helpers. HyprlandEditorCli.js calls these so a
// path, a type and an occurrence selector are split and typed the same way
// whether the caller is a process or the shell itself.
function splitPath(s) {
  const parts = []
  let start = 0
  for (let i = 0; i <= s.length; i++) {
    if (i === s.length || s[i] === ":") {
      parts.push(s.slice(start, i))
      start = i + 1
    }
  }
  return parts
}

function parseComponent(s) {
  const m = s.match(/^(.*)@(-?\d+)$/)
  if (m) return { name: m[1], occ: parseInt(m[2], 10) }
  return { name: s, occ: null }
}

function inferType(s) {
  if (s === "true") return true
  if (s === "false") return false
  if (s.length >= 2 && ((s[0] === '"' && s[s.length - 1] === '"') || (s[0] === "'" && s[s.length - 1] === "'"))) {
    return s.slice(1, -1)
  }
  const n = Number(s)
  if (!isNaN(n) && s.trim() !== "") return n
  return s
}

// File-based wrappers for Node / shell usage (optional)
function hyprGetFile(file, path, opts) {
  let content = ""
  try {
    const fs = require("fs")
    const p = expand_path(file)
    try { content = fs.readFileSync(p, "utf8") } catch(e) { content = "" }
  } catch(e) {}
  return hyprGetContent(content, path, opts)
}

function hyprEditFile(file, path, value, opts) {
  let content = ""
  let filePath = file
  try {
    const fs = require("fs")
    filePath = expand_path(file)
    try { content = fs.readFileSync(filePath, "utf8") } catch(e) { content = "" }
    const res = hyprEditContent(content, path, value, opts)
    if (!res.ok) return res
    fs.writeFileSync(filePath, res.content, "utf8")
    return { ok: true }
  } catch(e) {
    return { ok: false, error: String(e) }
  }
}
