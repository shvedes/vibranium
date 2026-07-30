-- editor.lua -- text-based editor/reader for Hyprland's Lua config format.
--
-- This does NOT execute or require a Lua interpreter to run the target
-- config; it treats it purely as text and parses/rewrites the specific
-- shape produced by:
--
--   hl.config({
--       general = { border_size = 2, ["col.active_border"] = "0xff89b4fa" },
--   })
--
--   hl.monitor({ output = "HDMI-A-1", mode = "preferred" })
--
-- Public API (globals):
--   ok, err     = hyprEdit(file, path, value, opts)
--   value, err  = hyprGet(file, path, opts)
--
-- Everything else in this file is declared `local` on purpose. `hl.*` is
-- reserved for Hyprland's own runtime, and since this file is dofile'd
-- into the caller's environment, any non-local name here would leak into
-- that environment too -- so only the two public entry points are global.

-- ============================================================================
-- string helpers
-- ============================================================================

-- Strip leading whitespace only, keep everything after it (including any
-- trailing whitespace). Used to get the "logical" start of a line for
-- pattern-matching (section headers, option lines, comments, closing
-- braces) without disturbing the rest of the line's content.
local function ltrim(s)
  return s:match("^%s*(.*)$")
end

-- Strip leading AND trailing whitespace. `(.-)` is a non-greedy capture,
-- so this doesn't accidentally eat whitespace that's part of the middle
-- of the string -- it just peels off the outer edges.
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Return just the leading whitespace of a line, verbatim. Used whenever we
-- rewrite a line in place and need to preserve whatever indentation it
-- already had, rather than recomputing indentation from nesting depth
-- (recomputing would fight the file's existing style on every edit).
local function leading_ws(s)
  return s:match("^(%s*)")
end

-- Inverse of Lua string-literal escaping: turns `\\` -> `\` and `\"` -> `"`
-- inside the *contents* of a quoted string token (quotes already stripped
-- by the caller). Implemented as an explicit character walk rather than a
-- couple of naive gsubs, because gsub-based unescaping is ambiguous on
-- inputs like `\\"` (backslash-escaped-backslash followed by a literal
-- quote, vs. backslash followed by an escaped quote) -- a linear scan that
-- consumes two characters at a time on a real escape pair is the only way
-- to get that right in general.
local function unescape_lua_string(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n then
      local nx = s:sub(i + 1, i + 1)
      if nx == "\\" or nx == '"' then
        -- Recognised two-character escape: emit the escaped char, skip both.
        out[#out + 1] = nx
        i = i + 2
      else
        -- Backslash followed by something we don't treat as an escape
        -- (shouldn't occur in output *we* produced, but be lenient on
        -- read since the file could have been hand-edited) -- keep the
        -- backslash literally and advance one.
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Escape a raw string for embedding inside a double-quoted Lua literal.
-- Order matters: backslashes must be doubled BEFORE quotes are escaped,
-- or a literal `"` would have its escaping backslash re-escaped.
local function escape_lua_string(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- ============================================================================
-- path expansion (~, $VAR, ${VAR})
-- ============================================================================
-- `file` is documented as "always an explicit absolute path", but callers
-- pass shell-flavored paths anyway (config authors write `~/...` out of
-- habit), so this does the same substitutions a POSIX shell would do
-- before ever opening the file -- both for reads and writes, so a given
-- logical path always resolves to the same file regardless of which
-- literal spelling was used to reach it.
--
-- Deliberately NOT supported: `~user` (would require a passwd lookup this
-- environment may not have) and unset environment variables. Both are
-- left untouched rather than guessed at or silently emptied -- an unset
-- `$VAR` staying literal `$VAR` means the resulting path almost certainly
-- won't exist, which surfaces as an honest "not found" instead of quietly
-- writing to the wrong place.

local function expand_path(path)
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME")
    if home and home ~= "" then
      if path == "~" then
        path = home
      elseif path:sub(1, 2) == "~/" then
        path = home .. path:sub(2)
      end
      -- Any other `~`-prefixed form (e.g. `~user`, `~foo/bar`) falls
      -- through unchanged -- see note above.
    end
  end

  -- `${VAR}` must be expanded before `$VAR`: the bare-`$VAR` pattern's
  -- name-char class would otherwise stop at the literal `{`, leaving
  -- `${HOME}` half-expanded into `${HOME}` -> lookup of a var literally
  -- named "" or garbage. Doing the braced form first consumes the whole
  -- `${...}` token before the unbraced pattern ever sees it.
  path = path:gsub("%${([%a_][%w_]*)}", function(name)
    local v = os.getenv(name)
    return v or ("${" .. name .. "}")
  end)
  path = path:gsub("%$([%a_][%w_]*)", function(name)
    local v = os.getenv(name)
    return v or ("$" .. name)
  end)

  return path
end

-- ============================================================================
-- file I/O
-- ============================================================================
-- Lines are stored WITHOUT their trailing newline; a uniform "\n" is
-- reintroduced once at write time via table.concat(lines, "\n"). This
-- means CRLF line endings in the source file are NOT round-tripped --
-- everything gets normalized to LF on write. A nonexistent file is not an
-- error at this layer: it reads back as an empty line list, and downstream
-- logic (scope resolution, section creation) treats "empty file" and
-- "file with no hl.config/hl.monitor yet" identically.

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  if content == "" then
    return {}
  end
  -- Drop exactly one trailing newline before splitting, so a file that
  -- ends "...})\n" doesn't produce a bogus empty final line. Appending
  -- "\n" back on before the gmatch below guarantees the last real line is
  -- still captured by the "(.-)\n" pattern even if it had no line ending
  -- of its own to begin with.
  content = content:gsub("\n$", "")
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function write_lines(path, lines)
  local f, err = io.open(path, "w")
  if not f then
    return nil, err
  end
  f:write(table.concat(lines, "\n"))
  if #lines > 0 then
    f:write("\n")
  end
  f:close()
  return true
end

-- ============================================================================
-- indent detection
-- ============================================================================

-- Scan the whole file for the shortest leading-whitespace run used on any
-- indented, non-blank, non-comment line, and treat that as the file's
-- "one indent level" unit for anything newly inserted. This is a global,
-- file-wide inference (not per-section), matching the idea that a config
-- file has one consistent indent style throughout. Falls back to 4 spaces
-- -- this format's convention -- when the file has no indentation to learn
-- from at all (e.g. a brand new or single-line file).
local function detect_indent_unit(lines)
  local min_indent = nil
  for _, line in ipairs(lines) do
    local stripped = ltrim(line)
    -- Skip blank lines, comment lines, and lines with zero leading
    -- whitespace (stripped == line means nothing was trimmed).
    if stripped ~= "" and stripped:sub(1, 2) ~= "--" and stripped ~= line then
      local lead = leading_ws(line)
      if lead ~= "" and (min_indent == nil or #lead < #min_indent) then
        min_indent = lead
      end
    end
  end
  return min_indent or "    "
end

-- Determine the indentation that DIRECT children of a section should use,
-- so a newly-inserted option/sub-section matches the file's existing
-- style rather than a mechanically-recomputed "depth * unit" indent
-- (which would drift from hand-formatted files, e.g. ones using tabs, or
-- ones that indent 2 spaces per level instead of 4).
--
-- `sec_start`/`sec_end` are the header line (`key = {`) and the matching
-- closing-brace line, both inclusive. We walk strictly between them,
-- tracking a local brace depth so that a nested sub-table's children
-- aren't mistaken for direct children of `sec_start`'s section.
--
-- Crucially, a line's own indentation is read off BEFORE deciding whether
-- it also opens a further nested table: `col = {` is itself a depth-0
-- child of its parent (we want its indent), even though after processing
-- it depth becomes 1 for everything that follows. Reversing that order
-- would skip straight past the one line we actually wanted to sample.
--
-- If the section has no existing children at all (freshly created, or
-- genuinely empty), fall back to "header's own indent + one more unit" --
-- there's nothing to copy from, so we derive a level from first
-- principles instead.
local function infer_child_indent(lines, sec_start, sec_end, unit)
  local depth = 0
  for i = sec_start + 1, sec_end - 1 do
    local line = lines[i]
    local stripped = ltrim(line)
    if stripped == "" or stripped:sub(1, 2) == "--" then
    -- Blank/comment lines carry no indentation signal; skip.
    elseif stripped:sub(1, 1) == "}" then
      depth = depth - 1
    else
      if depth == 0 then
        return leading_ws(line)
      end
      if stripped:find("{", 1, true) then
        depth = depth + 1
      end
    end
  end
  return leading_ws(lines[sec_start]) .. unit
end

-- ============================================================================
-- Lua key / value formatting (writing NEW literals into the file)
-- ============================================================================

-- Format a key for use as a NEW table key. Plain Lua identifiers (start
-- with a letter or underscore, then any run of word characters) are
-- written bare, e.g. `border_size`. Anything else -- dots, hyphens,
-- leading digits, empty string -- must use bracket-string form, e.g.
-- `["col.active_border"]`, since `col.active_border = x` would parse as
-- assigning into a field `active_border` of some table named `col`,
-- which is not what's intended.
local function lua_key_fmt(key)
  if key ~= "" and key:match("^[%a_][%w_]*$") then
    return key
  end
  return '["' .. escape_lua_string(key) .. '"]'
end

-- Format a Lua number the way Lua's own `tostring` would for an integer
-- value, avoiding a spurious ".0" suffix on whole numbers regardless of
-- whether the number arrived as an integer or float subtype (both exist
-- in Lua 5.3+, and `2` vs `2.0` stringify differently by default -- we
-- want `2` either way here since Hyprland's config format has no need to
-- distinguish the two on the page). Non-whole numbers fall through to the
-- default `tostring`, which is adequate for floats like `1.25`.
local function lua_number_str(n)
  if n == math.floor(n) then
    return string.format("%.0f", n)
  end
  return tostring(n)
end

-- Serialize a typed Lua value (boolean / number / string -- the only
-- types `hyprEdit` accepts) into the literal text that should appear on
-- the right-hand side of `key = <this>,`. Returns nil for any other type,
-- which callers are expected to have already rejected before reaching
-- here (kept simple/total rather than raising, per the "never throws"
-- API contract).
local function serialize_value(value)
  local t = type(value)
  if t == "boolean" then
    return tostring(value)
  elseif t == "number" then
    return lua_number_str(value)
  elseif t == "string" then
    return '"' .. escape_lua_string(value) .. '"'
  end
  return nil
end

-- ============================================================================
-- Lua key / value parsing (reading EXISTING literals out of the file)
-- ============================================================================

-- Parse a raw right-hand-side token -- everything after the `=` on an
-- option line, which may still carry a trailing comma and/or surrounding
-- whitespace -- into its typed Lua value. This is the read-side inverse
-- of `serialize_value` / `lua_number_str`, and it's what lets `hyprGet`
-- hand back a real boolean/number/string instead of always a string.
--
-- Order of checks matters: literal `true`/`false` tokens are recognised
-- before falling through to `tonumber`, since Lua's `tonumber("true")`
-- would (correctly) fail anyway, but checking booleans explicitly first
-- keeps the boolean/number/string cases cleanly separated rather than
-- relying on tonumber's failure mode.
local function parse_typed_value(raw)
  local s = trim(raw)
  if s:sub(-1) == "," then
    s = trim(s:sub(1, -2))
  end
  if s == "true" then
    return true
  end
  if s == "false" then
    return false
  end
  if #s >= 2 and ((s:sub(1, 1) == '"' and s:sub(-1) == '"') or (s:sub(1, 1) == "'" and s:sub(-1) == "'")) then
    return unescape_lua_string(s:sub(2, -2))
  end
  local n = tonumber(s)
  if n ~= nil then
    return n
  end
  -- Not a recognised literal shape (e.g. a bare unquoted word from a
  -- hand-edited file) -- return it verbatim as a string rather than
  -- failing outright; this mirrors how a lenient reader would behave and
  -- keeps `hyprGet` total over anything that looks even roughly like an
  -- RHS token.
  return s
end

-- Parse the key out of a bracket-notation token: `["key"]` or `['key']`
-- -> `key`. The input must start at `[` and contain a matching `]`; the
-- bracket's *contents* must themselves be a quoted string (Lua table
-- constructors technically allow arbitrary expressions inside `[...]`,
-- but this library only ever writes and expects to read plain quoted
-- string keys there, so anything else is treated as "not a key we
-- understand" and yields nil).
local function parse_bracket_key(token)
  local s = trim(token)
  if s:sub(1, 1) ~= "[" then
    return nil
  end
  local endp = s:find("]")
  if not endp then
    return nil
  end
  local inner = trim(s:sub(2, endp - 1))
  if
    #inner >= 2
    and ((inner:sub(1, 1) == '"' and inner:sub(-1) == '"') or (inner:sub(1, 1) == "'" and inner:sub(-1) == "'"))
  then
    return inner:sub(2, -2)
  end
  return nil
end

-- Recognise a section-opening line: `word = {` or `["word"] = {` at the
-- start of an already-left-trimmed line. Returns the section's name, or
-- nil if this line isn't a section header.
--
-- This deliberately does NOT match `hl.config({` or `hl.monitor({`: those
-- wrapper calls have a `{` directly after `(`, with no `=` in between, so
-- neither the bracket-form nor the plain-identifier branch below can
-- match them. That's intentional -- wrapper calls are found separately by
-- `find_top_level_calls`, and must never be pushed onto the section-name
-- stack that `find_all_section_bounds` tracks, or scope resolution and
-- generic section navigation would trip over each other.
local function section_name(stripped)
  if stripped:sub(1, 1) == "[" then
    local bracket_end = stripped:find("]")
    if not bracket_end then
      return nil
    end
    local name = parse_bracket_key(stripped:sub(1, bracket_end))
    if not name then
      return nil
    end
    local rest = ltrim(stripped:sub(bracket_end + 1))
    if rest:sub(1, 1) == "=" then
      local after_eq = ltrim(rest:sub(2))
      if after_eq:sub(1, 1) == "{" then
        return name
      end
    end
    return nil
  end

  -- Plain identifier form. The character class here (`%w_%-`) is
  -- deliberately permissive -- broader than what `lua_key_fmt` will ever
  -- WRITE for a bare key -- because this is the READ side: it has to
  -- recognise whatever a human already typed into the file (including
  -- hyphens, which Lua identifiers can't normally contain but which
  -- config authors sometimes use anyway in a loosely-parsed format like
  -- this one).
  local name = stripped:match("^([%w_%-]+)")
  if not name or name == "" then
    return nil
  end
  local rest = ltrim(stripped:sub(#name + 1))
  if rest:sub(1, 1) ~= "=" then
    return nil
  end
  rest = ltrim(rest:sub(2))
  if rest:sub(1, 1) == "{" then
    return name
  end
  return nil
end

-- Extract the key from an option line: `key = value,` or
-- `["key"] = value,`. Returns nil for section-header lines (RHS starts
-- with `{`, meaning this is a nested table, not a scalar option) and for
-- anything else that doesn't parse as either form -- callers use that nil
-- to mean "this line isn't a recognisable option" and skip it.
local function option_key(stripped)
  if stripped:sub(1, 1) == "[" then
    local bracket_end = stripped:find("]")
    if not bracket_end then
      return nil
    end
    local name = parse_bracket_key(stripped:sub(1, bracket_end))
    if not name then
      return nil
    end
    local rest = ltrim(stripped:sub(bracket_end + 1))
    if rest:sub(1, 1) == "=" then
      local after_eq = ltrim(rest:sub(2))
      if after_eq:sub(1, 1) ~= "{" then
        return name
      end
    end
    return nil
  end

  local eq = stripped:find("=")
  if eq then
    local key = trim(stripped:sub(1, eq - 1))
    -- Stricter identifier check than `section_name`'s on purpose: this is
    -- validating a key we're about to treat as a genuine option name, not
    -- just scanning past it, so we require the WHOLE pre-`=` text to be a
    -- clean identifier-like token (anchored `^...$`), not merely that it
    -- starts with one.
    if key ~= "" and key:match("^[%w%-_]+$") then
      local after_eq = trim(stripped:sub(eq + 1))
      if after_eq:sub(1, 1) ~= "{" then
        return key
      end
    end
  end
  return nil
end

-- Extract the typed value from an option line, by locating the `=` (or
-- bracket-key equivalent) and handing everything after it to
-- `parse_typed_value`.
local function option_value_typed(stripped)
  local raw
  if stripped:sub(1, 1) == "[" then
    local bracket_end = stripped:find("]")
    if not bracket_end then
      return nil
    end
    local rest = ltrim(stripped:sub(bracket_end + 1))
    if rest:sub(1, 1) ~= "=" then
      return nil
    end
    raw = rest:sub(2)
  else
    local eq = stripped:find("=")
    if not eq then
      return nil
    end
    raw = stripped:sub(eq + 1)
  end
  return parse_typed_value(raw)
end

-- ============================================================================
-- occurrence resolution
-- ============================================================================
-- Shared by two distinct ambiguity situations: multiple sections in the
-- file that share the same (cumulative) name path, and -- for
-- `scope = "monitor"` -- multiple `hl.monitor({...})` blocks that happen
-- to share the same `output` value. Both resolve the same way: collect
-- every match in file order into a list, then index into it.
--
-- `occurrence` is 1-indexed from the front for positive values (1 = first
-- match) and 1-indexed from the back for negative values (-1 = last,
-- -2 = second-to-last). This function must NEVER use a bare number like
-- `0` or `-1` as a sentinel for "not found" -- those are legitimate
-- occurrence values in Lua (see the truthiness note below), so "not
-- found" is always communicated as an actual `nil` return, and every
-- caller must check `result == nil`, not `if result then`.
--
-- Lua truthiness note: unlike C/JS/Python, the ONLY falsy values in Lua
-- are `nil` and `false` -- `0`, negative numbers, and `""` are all
-- truthy. That's what makes `x or default` a safe way to fill in a
-- missing `occurrence` elsewhere in this file (since "missing" is always
-- `nil`, never `0`), but it's also exactly why this function can't use
-- `0`/`-1` as an internal "miss" marker the way equivalent C code might:
-- a real match at index 0 or a request for occurrence -1 would be
-- silently swallowed by that kind of check.
local function resolve_occurrence(list, occurrence)
  local count = #list
  if count == 0 then
    return nil
  end
  local idx
  if occurrence > 0 then
    idx = occurrence
  else
    -- occurrence <= 0: treat as "from the end". -1 -> count (last),
    -- -2 -> count - 1, etc. occurrence == 0 falls into this branch too
    -- and simply resolves to `count + 1`, which is always out of range
    -- and therefore a clean miss -- there is no valid "0th" occurrence.
    idx = count + occurrence + 1
  end
  if idx < 1 or idx > count then
    return nil
  end
  return list[idx]
end

-- ============================================================================
-- top-level wrapper-call finding: hl.config({ ... }) / hl.monitor({ ... })
-- ============================================================================

-- Find every top-level occurrence of a wrapper call whose opening line
-- starts with `prefix` (e.g. "hl.config({"), returning their
-- {start, ["end"]} line-index bounds in file order. For each match, the
-- closing line is located by brace-counting forward from a depth of 1
-- (the call's own opening `{`) until it returns to 0 -- comment lines
-- (`--...`) are skipped entirely so that a stray `{`/`}` inside a comment
-- can't desynchronize the count.
--
-- This is intentionally a flat, non-nesting scan across the WHOLE file:
-- wrapper calls are top-level by construction (nothing nests an
-- `hl.config({...})` inside another table), so there's no need for the
-- section-stack machinery `find_all_section_bounds` uses below.
local function find_top_level_calls(lines, prefix)
  local results = {}
  local i, n = 1, #lines
  while i <= n do
    local stripped = ltrim(lines[i])
    if stripped:sub(1, #prefix) == prefix then
      local start = i
      local brace_depth = 1
      local j = i + 1
      while j <= n and brace_depth > 0 do
        local s = ltrim(lines[j])
        if s:sub(1, 2) ~= "--" then
          local _, opens = s:gsub("{", "")
          local _, closes = s:gsub("}", "")
          brace_depth = brace_depth + opens - closes
        end
        j = j + 1
      end
      results[#results + 1] = { start = start, ["end"] = j - 1 }
      i = j
    else
      i = i + 1
    end
  end
  return results
end

-- ============================================================================
-- section bounds finding
-- ============================================================================
-- Locate nested-table blocks (`key = { ... }`) by their full path of
-- names, e.g. {"general", "col"} for the `col` sub-table inside
-- `general`. Returns {start=, ["end"]=, depth=} entries in file order,
-- scanning only within [start_line, end_line] (both inclusive) -- that
-- bound is what keeps navigation confined to a single resolved
-- `hl.config`/`hl.monitor` root instead of leaking into a different
-- top-level block that happens to contain identically-named sections.

-- Structural (not just value) equality of two path arrays: same length,
-- same names in the same order.
local function path_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- Walk the file maintaining a stack of currently-open section names
-- (`current_path`), pushing on a section-opening match and popping on any
-- line that starts with `}` (covering both `},` mid-file and the file's
-- final `})`/`}`). Comment and blank lines are transparent -- they don't
-- affect the stack either way.
--
-- Whenever the live stack equals the target `path` exactly, that's a
-- match: its closing line is located by depth-1 brace counting (same
-- technique as `find_top_level_calls`), the (start, end, depth) triple is
-- recorded, and scanning resumes immediately AFTER that block's closing
-- line -- so sibling sections sharing the same path (duplicate
-- `animations` tables, say) are all discovered as separate entries in
-- file order, ready for `resolve_occurrence` to index into.
--
-- Note this pop-on-`}` behaviour is intentionally unconditional: even
-- when we're scanning for a nested path and cross a closing brace that
-- belongs to some OTHER, unrelated section the stack was never tracking
-- as part of the current match attempt, popping is still correct --
-- `current_path` mirrors the file's actual nesting at every point, not
-- just the portion relevant to `path`, so the stack and the file's real
-- brace structure never drift apart.
local function find_all_section_bounds(lines, path, start_line, end_line)
  local results = {}
  local current_path = {}
  local i = start_line
  while i <= end_line do
    local stripped = ltrim(lines[i])
    if stripped == "" or stripped:sub(1, 2) == "--" then
      i = i + 1
    elseif stripped:sub(1, 1) == "}" then
      current_path[#current_path] = nil
      i = i + 1
    else
      local name = section_name(stripped)
      if name then
        current_path[#current_path + 1] = name
        if path_equal(current_path, path) then
          local depth = #current_path - 1
          local brace_depth = 1
          local j = i + 1
          while j <= end_line and brace_depth > 0 do
            local s = ltrim(lines[j])
            if s:sub(1, 2) ~= "--" then
              local _, opens = s:gsub("{", "")
              local _, closes = s:gsub("}", "")
              brace_depth = brace_depth + opens - closes
            end
            j = j + 1
          end
          results[#results + 1] = { start = i, ["end"] = j - 1, depth = depth }
          -- Pop back off the name we just matched on, and resume scanning
          -- right after this block's close, so a sibling section with the
          -- same name (at the same nesting level) is found as a distinct,
          -- later match rather than being masked by this one.
          current_path[#current_path] = nil
          i = j
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end
  end
  return results
end

-- Convenience wrapper: find all matches, then resolve straight to one via
-- `occurrence`. Returns nil (not found) if either the path has no matches
-- at all, or `occurrence` resolves to an out-of-range index.
local function find_section_bounds(lines, path, start_line, end_line, occurrence)
  local all = find_all_section_bounds(lines, path, start_line, end_line)
  return resolve_occurrence(all, occurrence)
end

-- Find a direct-child (depth-0-within-this-section) option line by name,
-- strictly between `sec_start` and `sec_end` (both exclusive -- the
-- header and closer themselves are never option lines). A running local
-- brace depth is tracked so that options belonging to a NESTED sub-table
-- are skipped rather than mistaken for direct children of this section:
-- a line containing `{` is assumed to open a level (and is otherwise
-- ignored -- it can't simultaneously be a `key = value,` option line,
-- since option lines by definition don't have `{` on the RHS), a line
-- containing `}` closes one, and only lines seen while depth is exactly 0
-- are considered as candidate option lines at all.
local function find_option_in_section(lines, sec_start, sec_end, option_name)
  local depth = 0
  for i = sec_start + 1, sec_end - 1 do
    local stripped = ltrim(lines[i])
    if stripped == "" or stripped:sub(1, 2) == "--" then
    -- skip
    elseif stripped:find("{", 1, true) then
      local _, opens = stripped:gsub("{", "")
      depth = depth + opens
    elseif stripped:find("}", 1, true) then
      local _, closes = stripped:gsub("}", "")
      depth = depth - closes
    elseif depth == 0 then
      local key = option_key(stripped)
      if key == option_name then
        return i
      end
    end
  end
  return nil
end

-- ============================================================================
-- scope resolution: hl.config({...}) vs hl.monitor({ output = ..., ...})
-- ============================================================================
-- This determines the (start, end) bounds of the "root" table body that
-- `path` navigation happens inside -- everything downstream (section
-- lookup/creation, option read/write) is IDENTICAL regardless of which
-- scope produced these bounds; only the step that produces them differs.
--
-- `create`: when true, a missing root is synthesized by appending to the
-- end of `lines` (mutating it in place) instead of returning a miss. This
-- is always safe to do as a plain append, with no need to re-derive
-- indices for anything already in `lines`, because appending happens
-- strictly after every existing line -- nothing already-recorded shifts.

local function get_scope_root(lines, opts, occurrence, unit, create)
  local scope = opts.scope or "config"

  if scope == "config" then
    local calls = find_top_level_calls(lines, "hl.config({")
    if #calls == 0 then
      if not create then
        return nil, "not found"
      end
      -- No hl.config block anywhere in the file: synthesize an empty one
      -- at EOF. Its body is empty, so subsequent section/option insertion
      -- will fall back to infer_child_indent's "derive from header indent
      -- + one unit" path, which is exactly what we want for a fresh file.
      local n = #lines
      lines[n + 1] = "hl.config({"
      lines[n + 2] = "})"
      return { start = n + 1, ["end"] = n + 2 }
    end
    -- Multiple hl.config({...}) blocks are legal in principle (nothing
    -- stops a hand-edited file from having more than one); by spec, the
    -- LAST one in the file is always the authoritative root, no
    -- occurrence option involved -- config scope has exactly one root
    -- candidate rule, unlike monitor scope below.
    local last = calls[#calls]
    return { start = last.start, ["end"] = last["end"] }
  end

  if scope == "monitor" then
    local calls = find_top_level_calls(lines, "hl.monitor({")
    -- Each hl.monitor({...}) block is identified by its own `output`
    -- field (a direct, depth-0 child), NOT by its position in the file --
    -- so every call block found above has to be individually inspected to
    -- see whether its `output` matches what the caller asked for.
    local matches = {}
    for _, c in ipairs(calls) do
      local ol = find_option_in_section(lines, c.start, c["end"], "output")
      if ol then
        local val = option_value_typed(ltrim(lines[ol]))
        if val == opts.output then
          matches[#matches + 1] = c
        end
      end
    end
    if #matches == 0 then
      if not create then
        return nil, "not found"
      end
      -- No monitor block with this output exists yet: append a new one,
      -- seeded with `output = "<opts.output>"` as its first (and, for
      -- now, only) key -- this is the source of truth other calls will
      -- match against, so it MUST be present and correctly quoted from
      -- the moment the block is created.
      local n = #lines
      lines[n + 1] = "hl.monitor({"
      lines[n + 2] = unit .. 'output = "' .. escape_lua_string(opts.output) .. '",'
      lines[n + 3] = "})"
      return { start = n + 1, ["end"] = n + 3 }
    end
    -- One or more monitor blocks share this output (the "more than one"
    -- case is a malformed file -- two monitors claiming the same output
    -- -- but we don't refuse to operate on it; `occurrence` just picks
    -- which one, using the exact same resolver as section-name dupes).
    local picked = resolve_occurrence(matches, occurrence)
    if not picked then
      return nil, "not found"
    end
    return { start = picked.start, ["end"] = picked["end"] }
  end

  return nil, "invalid scope"
end

-- ============================================================================
-- read-only section navigation (hyprGet)
-- ============================================================================
-- Walks `section_path` one level at a time, rooted inside an already-
-- resolved scope root. At each depth, the CUMULATIVE path so far (e.g.
-- depth 1 = {"animations"}, depth 2 = {"animations","bezier"}) is looked
-- up with `find_section_bounds`; every depth except the last always uses
-- occurrence = 1 (ancestors are assumed unambiguous -- take the first
-- match), while the FINAL depth uses the caller's real `occurrence`. This
-- means `occurrence` disambiguates whichever level in the path actually
-- has duplicates in the file, since the cumulative-path lookup at the
-- final depth only succeeds along a stack trace that already includes
-- the correctly-resolved ancestors.
--
-- This mirrors `write_scalar_option`'s navigation exactly (read and write
-- must agree on which physical block "the 2nd animations table" refers
-- to, or `hyprEdit(..., {occurrence=2})` followed by
-- `hyprGet(..., {occurrence=2})` could silently talk past each other).
-- The one difference from the write path is that this function never
-- creates anything: a miss at any depth is an immediate `nil` return.
local function navigate_section_readonly(lines, root, section_path, occurrence)
  if #section_path == 0 then
    return root.start, root["end"]
  end
  local current_line = root.start
  local bounds
  for depth = 1, #section_path do
    local sub = {}
    for k = 1, depth do
      sub[k] = section_path[k]
    end
    local occ = (depth < #section_path) and 1 or occurrence
    bounds = find_section_bounds(lines, sub, current_line, root["end"], occ)
    if not bounds then
      return nil
    end
    -- Re-anchor the next depth's scan at the START of the section just
    -- found (not its end): find_all_section_bounds re-derives the whole
    -- nesting stack from wherever it starts scanning, so starting again
    -- from this section's own header line lets it correctly walk back
    -- into that same section to look for the next-level child, still
    -- bounded above by root["end"] so it can never wander into a
    -- different top-level block.
    current_line = bounds.start
  end
  return bounds.start, bounds["end"]
end

-- ============================================================================
-- section resolution + creation (batch write)
-- ============================================================================
-- Like `navigate_section_readonly` above, but allowed to CREATE missing
-- section levels rather than failing. Used by the batch-write path, where
-- `path` is entirely section names (no trailing option name -- the
-- table's own keys supply those).
--
-- On hitting the first missing depth, ALL remaining levels
-- (path[depth..#path]) are created in a single insertion, rather than
-- looping back through the outer `for depth = ...` again -- there's no
-- point re-searching for something we just established doesn't exist.
local function resolve_section(lines, root, path, occurrence, unit)
  if #path == 0 then
    return root.start, root["end"]
  end

  local current_line = root.start
  for depth = 1, #path do
    local sub = {}
    for k = 1, depth do
      sub[k] = path[k]
    end
    local occ = (depth < #path) and 1 or occurrence
    local bounds = find_section_bounds(lines, sub, current_line, root["end"], occ)

    if bounds then
      current_line = bounds.start
      if depth == #path then
        return bounds.start, bounds["end"]
      end
    else
      -- Everything from `depth` onward is missing. Find the nearest
      -- EXISTING ancestor to insert after -- either the section one
      -- level up (already resolved on a previous loop iteration's
      -- success, or freshly re-looked-up here for depth == 1's special
      -- case of "the ancestor IS the root"), or the root itself.
      local parent_start, parent_end
      if depth == 1 then
        parent_start, parent_end = root.start, root["end"]
      else
        local parent_sub = {}
        for k = 1, depth - 1 do
          parent_sub[k] = path[k]
        end
        -- Ancestor lookup always uses occurrence = 1 here, matching the
        -- per-depth loop above: by the time we reach a missing depth, all
        -- shallower levels already succeeded (with occurrence = 1, since
        -- only the deepest level in the ORIGINAL walk gets the real
        -- occurrence) so re-deriving the immediate parent this way is
        -- consistent with how we got here.
        local pb = find_section_bounds(lines, parent_sub, root.start, root["end"], 1)
        parent_start, parent_end = pb.start, pb["end"]
      end

      local insert_pos = parent_end
      local base_indent = infer_child_indent(lines, parent_start, parent_end, unit)

      local to_insert = {}
      -- A blank separator line is inserted before the new section(s) IFF
      -- the line immediately preceding the insertion point is itself a
      -- closing brace -- i.e. we're inserting right after some other
      -- section's `},`/`}`, and want a visual gap between unrelated
      -- blocks rather than jamming them together.
      if insert_pos - 1 >= 1 then
        local prev = trim(lines[insert_pos - 1])
        if prev == "}," or prev == "}" then
          to_insert[#to_insert + 1] = ""
        end
      end

      -- Open each missing level in turn, one unit deeper than the last,
      -- all indentation derived from `base_indent` (the nearest known
      -- ancestor's inferred child style) rather than a raw depth counter
      -- -- so this stays correct no matter how many levels already exist
      -- above the insertion point.
      for i = depth, #path do
        local ind = base_indent .. unit:rep(i - depth)
        to_insert[#to_insert + 1] = ind .. lua_key_fmt(path[i]) .. " = {"
      end
      -- Close them again in REVERSE order (innermost first), each one
      -- unit shallower than the last, mirroring the opens above.
      local levels = #path - depth + 1
      for i = levels - 1, 0, -1 do
        local ind = base_indent .. unit:rep(i)
        to_insert[#to_insert + 1] = ind .. "},"
      end

      -- Compute where the newly-created INNERMOST (target) section will
      -- end up once `to_insert` is spliced in, so we can hand its bounds
      -- straight back without a second re-scan of the file. Layout of
      -- `to_insert` is: [optional blank], open_1, open_2, ..., open_N
      -- (innermost/target), close_N (target's own closer), close_(N-1),
      -- ..., close_1. So the target header sits at
      -- `insert_pos + blank + (levels - 1)`, and its closer is the very
      -- next line after that.
      local blank = (to_insert[1] == "") and 1 or 0
      local target_start = insert_pos + blank + (levels - 1)
      local target_end = target_start + 1

      -- Insert in reverse so each `table.insert` at a fixed `insert_pos`
      -- pushes the previously-inserted lines down by one, landing the
      -- whole block in the same order it was built in.
      for k = #to_insert, 1, -1 do
        table.insert(lines, insert_pos, to_insert[k])
      end
      -- The root's own closing line has shifted down by however many
      -- lines we just spliced in above it; keep the caller's root table
      -- in sync so any further operations against the same root (e.g.
      -- subsequent batch-key insertion) use correct bounds.
      root["end"] = root["end"] + #to_insert

      return target_start, target_end
    end
  end
end

-- ============================================================================
-- scalar option write
-- ============================================================================
-- Mirrors the section-navigation-with-creation algorithm in
-- `resolve_section` above almost exactly, but the deepest thing being
-- resolved/created is a single OPTION line (`key = value,`), not a
-- section -- so the two aren't factored into one shared function: the
-- "found" branch needs to additionally locate-or-append the option
-- inside the final section, and the "missing" branch needs to fold the
-- option line into the same insertion batch as any newly-opened section
-- levels (one level deeper than the deepest new section), rather than
-- returning bounds for the caller to do that separately.
local function write_scalar_option(lines, root, section_path, option_name, lua_val, occurrence, unit)
  local opt_key = lua_key_fmt(option_name)

  if #section_path == 0 then
    -- Top-level option: no enclosing section, written directly into the
    -- root's own body (e.g. a monitor's `mode`/`scale`/etc, or a
    -- true top-level hl.config field).
    for i = root.start + 1, root["end"] - 1 do
      local stripped = ltrim(lines[i])
      if stripped ~= "" and stripped:sub(1, 2) ~= "--" then
        local key = option_key(stripped)
        if key == option_name then
          -- Update in place: preserve whatever leading whitespace this
          -- line already had rather than recomputing it, since an
          -- existing line's indentation is ground truth for the file's
          -- style at that exact position.
          lines[i] = leading_ws(lines[i]) .. opt_key .. " = " .. lua_val .. ","
          return
        end
      end
    end
    -- Not found anywhere in the root body: insert as the FIRST line
    -- inside the wrapper. This differs from the nested-section case
    -- below (which appends just before the closing brace) -- it's a
    -- distinct rule specifically for the root-level, no-enclosing-section
    -- case.
    local child_indent = infer_child_indent(lines, root.start, root["end"], unit)
    table.insert(lines, root.start + 1, child_indent .. opt_key .. " = " .. lua_val .. ",")
    root["end"] = root["end"] + 1
    return
  end

  local current_line = root.start
  for depth = 1, #section_path do
    local sub = {}
    for k = 1, depth do
      sub[k] = section_path[k]
    end
    local occ = (depth < #section_path) and 1 or occurrence
    local bounds = find_section_bounds(lines, sub, current_line, root["end"], occ)

    if bounds then
      current_line = bounds.start
      if depth == #section_path then
        -- Reached the innermost EXISTING section: handle the option
        -- itself, either updating an existing line in place or appending
        -- a new one just before this section's closing brace.
        local sec_start, sec_end = bounds.start, bounds["end"]
        local opt_line = find_option_in_section(lines, sec_start, sec_end, option_name)
        if opt_line then
          lines[opt_line] = leading_ws(lines[opt_line]) .. opt_key .. " = " .. lua_val .. ","
        else
          local opt_indent = infer_child_indent(lines, sec_start, sec_end, unit)
          table.insert(lines, sec_end, opt_indent .. opt_key .. " = " .. lua_val .. ",")
          root["end"] = root["end"] + 1
        end
        return
      end
    else
      -- One or more sections from `depth` onward are missing. Same
      -- ancestor-finding logic as `resolve_section`, but the insertion
      -- batch below additionally carries the option line itself, one
      -- level deeper than the deepest newly-opened section.
      local parent_start, parent_end
      if depth == 1 then
        parent_start, parent_end = root.start, root["end"]
      else
        local parent_sub = {}
        for k = 1, depth - 1 do
          parent_sub[k] = section_path[k]
        end
        local pb = find_section_bounds(lines, parent_sub, root.start, root["end"], 1)
        parent_start, parent_end = pb.start, pb["end"]
      end

      local insert_pos = parent_end
      local base_indent = infer_child_indent(lines, parent_start, parent_end, unit)

      local to_insert = {}
      if insert_pos - 1 >= 1 then
        local prev = trim(lines[insert_pos - 1])
        if prev == "}," or prev == "}" then
          to_insert[#to_insert + 1] = ""
        end
      end

      for i = depth, #section_path do
        local ind = base_indent .. unit:rep(i - depth)
        to_insert[#to_insert + 1] = ind .. lua_key_fmt(section_path[i]) .. " = {"
      end

      -- The option sits exactly one level deeper than the innermost
      -- newly-opened section.
      local opt_ind = base_indent .. unit:rep(#section_path - depth + 1)
      to_insert[#to_insert + 1] = opt_ind .. opt_key .. " = " .. lua_val .. ","

      local levels = #section_path - depth + 1
      for i = levels - 1, 0, -1 do
        local ind = base_indent .. unit:rep(i)
        to_insert[#to_insert + 1] = ind .. "},"
      end

      for k = #to_insert, 1, -1 do
        table.insert(lines, insert_pos, to_insert[k])
      end
      root["end"] = root["end"] + #to_insert
      return
    end
  end
end

-- ============================================================================
-- path normalization
-- ============================================================================
-- Historically this also stripped an inline "name@N" occurrence suffix
-- off path elements; that shorthand has been removed -- occurrence now
-- comes exclusively from `opts.occurrence`. All that's left here is a
-- defensive shallow copy, so nothing downstream can accidentally mutate
-- the caller's own `path` table.
local function normalize_path(path)
  local clean = {}
  for i, p in ipairs(path) do
    clean[i] = p
  end
  return clean
end

-- ============================================================================
-- public API
-- ============================================================================
-- Both entry points run their real body inside `pcall`, so a bug or an
-- unanticipated input shape turns into `nil, "internal error: ..."`
-- instead of propagating a raised error up through `dofile` into
-- Hyprland's own runtime -- the API contract is "never raises", full stop.

function hyprEdit(file, path, value, opts)
  local ok, result, err2 = pcall(function()
    file = expand_path(file)
    opts = opts or {}
    local scope = opts.scope or "config"
    if scope ~= "config" and scope ~= "monitor" then
      return nil, "invalid scope"
    end
    if scope == "monitor" and opts.output == nil then
      return nil, "opts.output is required when scope is 'monitor'"
    end

    local clean_path = normalize_path(path)
    -- `opts.occurrence or 1` is safe here specifically because "absent"
    -- is always represented as Lua `nil` (never `0`, which would be
    -- truthy and pass straight through unmodified anyway) -- see the
    -- Lua-truthiness note above `resolve_occurrence`.
    local occurrence = opts.occurrence or 1

    local vtype = type(value)
    if vtype ~= "table" and vtype ~= "boolean" and vtype ~= "number" and vtype ~= "string" then
      return nil, "unsupported value type"
    end

    if vtype == "table" then
      -- Batch write: validate the ENTIRE value table up front, before
      -- touching the file at all, so a single bad entry anywhere in the
      -- batch means NOTHING gets written (no partial writes). A nested
      -- table as any value is explicitly out of scope for v1; empty
      -- strings are rejected the same as they are for scalar writes.
      for k, v in pairs(value) do
        if type(v) == "table" then
          return nil, "nested table values not supported"
        end
        if type(v) == "string" and v == "" then
          return nil, "empty value"
        end
        if type(v) ~= "boolean" and type(v) ~= "number" and type(v) ~= "string" then
          return nil, "unsupported value type"
        end
      end
    elseif vtype == "string" and value == "" then
      -- Scalar empty-string rejection. Note this checks specifically for
      -- string "" -- `false` and numeric `0`/`-1` are legitimate,
      -- distinct, non-empty values and must NOT be caught by this branch
      -- (they aren't, since `vtype == "string"` already excludes them).
      return nil, "empty value"
    end

    local lines = read_lines(file)
    local unit = detect_indent_unit(lines)

    if vtype == "table" then
      local root, rerr = get_scope_root(lines, opts, occurrence, unit, true)
      if not root then
        return nil, rerr
      end

      -- For batch writes, `clean_path` is entirely section names (no
      -- trailing option-name element -- the table's own keys supply
      -- those), so it's handed to `resolve_section` as-is.
      local sec_start, sec_end = resolve_section(lines, root, clean_path, occurrence, unit)
      if not sec_start then
        return nil, "section not found"
      end
      local is_root_target = (#clean_path == 0)

      -- Single read -> mutate-lines -> write pass: first update every key
      -- that already exists IN PLACE (no line-count change, so indices
      -- for everything else stay valid), then batch-insert whatever
      -- didn't already exist in one shot at the end, rather than
      -- inserting one-at-a-time (which would require re-deriving
      -- insertion points after every single insert).
      local to_insert = {}
      for k, v in pairs(value) do
        local serialized = serialize_value(v)
        local opt_line = find_option_in_section(lines, sec_start, sec_end, k)
        if opt_line then
          lines[opt_line] = leading_ws(lines[opt_line]) .. lua_key_fmt(k) .. " = " .. serialized .. ","
        else
          to_insert[#to_insert + 1] = { key = k, val = serialized }
        end
      end

      if #to_insert > 0 then
        if is_root_target then
          -- Writing directly into the root body (path == {}): same rule
          -- as the scalar top-level case -- brand new keys go FIRST, not
          -- appended before the closing brace.
          local child_indent = infer_child_indent(lines, sec_start, sec_end, unit)
          for _, item in ipairs(to_insert) do
            table.insert(lines, sec_start + 1, child_indent .. lua_key_fmt(item.key) .. " = " .. item.val .. ",")
          end
        else
          -- Writing into a genuine nested section: append missing keys
          -- just before the section's closing brace, in one batch
          -- insertion so the closing-brace index only needs to be valid
          -- once (at the moment of insertion), not re-derived per key.
          local opt_indent = infer_child_indent(lines, sec_start, sec_end, unit)
          local batch_lines = {}
          for _, item in ipairs(to_insert) do
            batch_lines[#batch_lines + 1] = opt_indent .. lua_key_fmt(item.key) .. " = " .. item.val .. ","
          end
          for k = #batch_lines, 1, -1 do
            table.insert(lines, sec_end, batch_lines[k])
          end
        end
        root["end"] = root["end"] + #to_insert
      end

      local wok, werr = write_lines(file, lines)
      if not wok then
        return nil, werr
      end
      return true
    end

    -- Scalar write: the last path element is the option name, everything
    -- before it is the section path.
    if #clean_path == 0 then
      return nil, "path must include an option name"
    end
    local section_path = {}
    for i = 1, #clean_path - 1 do
      section_path[i] = clean_path[i]
    end
    local option_name = clean_path[#clean_path]
    local serialized = serialize_value(value)

    local root, rerr = get_scope_root(lines, opts, occurrence, unit, true)
    if not root then
      return nil, rerr
    end

    write_scalar_option(lines, root, section_path, option_name, serialized, occurrence, unit)

    local wok, werr = write_lines(file, lines)
    if not wok then
      return nil, werr
    end
    return true
  end)

  if not ok then
    -- `pcall` caught a raised Lua error (a bug, most likely) rather than
    -- one of our own `return nil, "..."` misses -- report it the same
    -- shape as every other failure so callers only ever need to check
    -- for a non-true first return value.
    return nil, "internal error: " .. tostring(result)
  end
  return result, err2
end

function hyprGet(file, path, opts)
  local ok, result, err2 = pcall(function()
    file = expand_path(file)
    opts = opts or {}
    local scope = opts.scope or "config"
    if scope ~= "config" and scope ~= "monitor" then
      return nil, "invalid scope"
    end
    if scope == "monitor" and opts.output == nil then
      return nil, "opts.output is required when scope is 'monitor'"
    end

    local clean_path = normalize_path(path)
    local occurrence = opts.occurrence or 1
    if #clean_path == 0 then
      return nil, "path must include an option name"
    end

    local lines = read_lines(file)
    local unit = detect_indent_unit(lines)

    -- `create = false`: a read never synthesizes a missing
    -- hl.config/hl.monitor block -- a missing root is simply a miss.
    local root, rerr = get_scope_root(lines, opts, occurrence, unit, false)
    if not root then
      return nil, rerr
    end

    local section_path = {}
    for i = 1, #clean_path - 1 do
      section_path[i] = clean_path[i]
    end
    local option_name = clean_path[#clean_path]

    local sec_start, sec_end = navigate_section_readonly(lines, root, section_path, occurrence)
    if not sec_start then
      return nil, "not found"
    end

    local opt_line = find_option_in_section(lines, sec_start, sec_end, option_name)
    if not opt_line then
      return nil, "not found"
    end

    local val = option_value_typed(ltrim(lines[opt_line]))
    if val == nil then
      -- Genuinely unparseable RHS (shouldn't normally occur for a line
      -- `find_option_in_section` already accepted as an option, but stay
      -- defensive) -- surfaced as a plain miss, matching the "never
      -- distinguishable from not-found except by a stored `false`" rule:
      -- a stored `false` is returned as the boolean `false`, not `nil`,
      -- by `parse_typed_value`, so this branch is only reached when
      -- nothing usable could be parsed at all.
      return nil, "not found"
    end
    return val
  end)

  if not ok then
    return nil, "internal error: " .. tostring(result)
  end
  return result, err2
end
