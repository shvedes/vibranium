#!/usr/bin/awk

# This is the engine underneath vb-theme-set-templates. The bash side has
# already done the boring parts by the time we get here: it merged
# colors.toml and colors-extended.toml into one flat key/value table and
# figured out which template files need rendering and where their output
# should land. All this file does is the actual substitution: read every
# template line, find {{ ... }} tokens, resolve each one, write the result.
#
# The part worth understanding before touching anything below is that a
# placeholder like {{ color4 }} is not just a string lookup. The suffix on
# the key name (_rgb, _hsl, _r, and so on) selects a color format, and an
# optional pipe chain after the key (|lightness=0.8|alpha=0.5) lets a
# template ask for a color it does not literally have, by computing it from
# one it does. Hex, RGB, and HSL each describe the same color differently,
# and "make this lighter" or "rotate the hue" only makes sense once you are
# looking at the color through the HSL lens. rgb_to_hsl and hsl_to_rgb exist
# purely so the rest of the code can hop between those lenses on demand.
#
# Two global conventions worth flagging up front:
#   - Functions communicate intermediate color state through the globals
#     _r, _g, _b, _h, _s, _l, _w, _bk rather than return values, since most
#     of resolve_token() is a sequence of operations that all need to see
#     and modify the same color in place.
#   - A placeholder the engine cannot resolve, an unknown key, a pipe
#     operation on a key missing from the table, is left in the output
#     untouched rather than replaced with an empty string. A literal
#     {{ typo_key }} sitting in a generated config file is something a
#     person will actually notice; a silently blank value is not.

# Two lookup tables that pay for themselves many times over during template
# rendering. _hv[] maps any hex digit character (both cases) directly to
# its integer value, so hex_char_val no longer needs a tolower() call and
# an index() scan for every nibble it reads. _hex2[] maps every integer
# 0-255 directly to its two-character lowercase hex string, so int_to_hex2
# can return in one step rather than two substr() calls.
BEGIN {
  _hv["0"]=0; _hv["1"]=1; _hv["2"]=2; _hv["3"]=3; _hv["4"]=4
  _hv["5"]=5; _hv["6"]=6; _hv["7"]=7; _hv["8"]=8; _hv["9"]=9
  _hv["a"]=10; _hv["b"]=11; _hv["c"]=12; _hv["d"]=13; _hv["e"]=14; _hv["f"]=15
  _hv["A"]=10; _hv["B"]=11; _hv["C"]=12; _hv["D"]=13; _hv["E"]=14; _hv["F"]=15

  _d = "0123456789abcdef"
  for (_i = 0; _i <= 255; _i++)
    _hex2[_i] = substr(_d, int(_i / 16) + 1, 1) substr(_d, (_i % 16) + 1, 1)
}

# Restrict v to the closed range [lo, hi]. Nearly every operation below ends
# with a clamp, since channel math has a way of drifting just outside its
# valid range from rounding alone.
function clamp(v, lo, hi) {
  return v < lo ? lo : (v > hi ? hi : v)
}

# Splits a "#rrggbb" string into the _r, _g, _b globals. Assumes the value
# has already been confirmed to start with # and to be well-formed; callers
# are responsible for that check before reaching here.
function parse_hex(hex) {
  hex = substr(hex, 2)
  _r = _hv[substr(hex, 1, 1)] * 16 + _hv[substr(hex, 2, 1)]
  _g = _hv[substr(hex, 3, 1)] * 16 + _hv[substr(hex, 4, 1)]
  _b = _hv[substr(hex, 5, 1)] * 16 + _hv[substr(hex, 6, 1)]
}

# Converts integer RGB (0-255 each) into HSL, plus the HWB whiteness and
# blackness that fall out of the same math almost for free. Sets the
# globals _h (0-360), _s (0-100), _l (0-100), _w, _bk.
function rgb_to_hsl(r, g, b,    rn, gn, bn, cmax, cmin, delta, lv, abs2l1, max_ch) {
  rn = r / 255.0
  gn = g / 255.0
  bn = b / 255.0

  if (rn >= gn && rn >= bn) { cmax = rn; max_ch = "r" }
  else if (gn >= bn)        { cmax = gn; max_ch = "g" }
  else                      { cmax = bn; max_ch = "b" }

  cmin = (rn <= gn && rn <= bn) ? rn : (gn <= bn ? gn : bn)
  delta = cmax - cmin
  lv = (cmax + cmin) / 2.0

  _w = cmin * 100.0
  _bk = (1.0 - cmax) * 100.0

  if (delta < 0.000001) {
    _h = 0; _s = 0; _l = lv * 100.0
    return
  }

  abs2l1 = 2.0 * lv - 1.0
  if (abs2l1 < 0) abs2l1 = -abs2l1
  _s = (delta / (1.0 - abs2l1)) * 100.0

  if      (max_ch == "r") _h = 60.0 * (((gn - bn) / delta) % 6)
  else if (max_ch == "g") _h = 60.0 * ((bn - rn) / delta + 2.0)
  else                    _h = 60.0 * ((rn - gn) / delta + 4.0)

  if (_h < 0) _h += 360.0
  _l = lv * 100.0
}

# The other direction of the same bridge: HSL (h 0-360, s/l 0-100) back into
# integer RGB. Used both to serve a direct {{ key_hsl }} style request and
# to rebuild RGB after a lightness operation has changed _l.
function hsl_to_rgb(h, s, l,    sn, ln, C, Hp, X, m, r1, g1, b1, hmod2, abshm1, abs2l1) {
  sn = s / 100.0
  ln = l / 100.0

  h = ((h % 360.0) + 360.0) % 360.0

  abs2l1 = 2.0 * ln - 1.0
  if (abs2l1 < 0) abs2l1 = -abs2l1
  C = (1.0 - abs2l1) * sn

  Hp = h / 60.0
  hmod2 = Hp % 2.0
  abshm1 = hmod2 - 1.0
  if (abshm1 < 0) abshm1 = -abshm1
  X = C * (1.0 - abshm1)

  if      (Hp < 1) { r1=C; g1=X; b1=0 }
  else if (Hp < 2) { r1=X; g1=C; b1=0 }
  else if (Hp < 3) { r1=0; g1=C; b1=X }
  else if (Hp < 4) { r1=0; g1=X; b1=C }
  else if (Hp < 5) { r1=X; g1=0; b1=C }
  else             { r1=C; g1=0; b1=X }

  m = ln - C / 2.0
  _r = int((r1 + m) * 255.0 + 0.5)
  _g = int((g1 + m) * 255.0 + 0.5)
  _b = int((b1 + m) * 255.0 + 0.5)
}

# Called once before the first template line is processed, after both
# subs[] and outmap[] are fully loaded. It walks every entry in subs[] and
# pre-computes all the format variants a template might ask for, storing the
# results in resolved[]. The payoff is in resolve_token(): a no-pipeline
# placeholder becomes a single array lookup here rather than a parse_hex()
# call, an rgb_to_hsl() call, and a chain of suffix comparisons per token.
#
# In addition to resolved[], this also populates _pr/_pg/_pb/_ph/_ps/_pl/
# _pw/_pbk cache arrays. resolve_token() reads these cached channels for
# pipeline tokens instead of calling parse_hex() and rgb_to_hsl() again.
#
# Non-hex values (font names and the like) get the four string-only
# variants; hex colors get the full set of channel and format
# representations. The second loop re-stamps every literal subs[] key
# directly into resolved[], so if a key name happens to collide with a
# derived variant name the explicit value always wins.
function _precompute(    key, val, stripped, ph, ps, pl, pw, pbk) {
  for (key in subs) {
    val = subs[key]

    if (val !~ /^#/) {
      resolved[key]          = val
      resolved[key "_strip"] = val
      resolved[key "_upper"] = toupper(val)
      resolved[key "_lower"] = tolower(val)
      continue
    }

    stripped = substr(val, 2)
    resolved[key]          = val
    resolved[key "_strip"] = stripped
    resolved[key "_upper"] = "#" toupper(stripped)
    resolved[key "_lower"] = "#" tolower(stripped)
    resolved[key "_0x"]    = "0x" stripped

    parse_hex(val)
    _pr[key] = _r; _pg[key] = _g; _pb[key] = _b
    resolved[key "_r"]   = _r
    resolved[key "_g"]   = _g
    resolved[key "_b"]   = _b
    resolved[key "_rgb"] = _r "," _g "," _b

    rgb_to_hsl(_r, _g, _b)
    _ph[key] = _h; _ps[key] = _s; _pl[key] = _l; _pw[key] = _w; _pbk[key] = _bk
    ph = int(_h + 0.5); ps = int(_s + 0.5); pl = int(_l + 0.5)
    pw = int(_w + 0.5); pbk = int(_bk + 0.5)
    resolved[key "_h"]   = ph
    resolved[key "_s"]   = ps
    resolved[key "_l"]   = pl
    resolved[key "_hsl"] = ph "," ps "," pl
    resolved[key "_w"]   = pw
    resolved[key "_hwb"] = ph "," pw "%," pbk "%"
  }

  for (key in subs) { resolved[key] = subs[key] }
}

# Takes whatever sat between {{ and }} (for example "color4|lightness=0.8")
# and turns it into the final string a template should see. This is the
# one function that knows about every output format and every pipe
# operation, so it is long, but each branch below stands on its own.
#
# Memoization: results are cached in _memo[] indexed by the exact
# inner_expr string. Repeated occurrences of the same placeholder
# (e.g. "background|lightness=+0.10" appearing 40 times in vscode.json)
# skip all computation after the first hit.
function resolve_token(inner_expr,    pipe_pos, base_part, ops_str, base_key, fmt, hex_variant, scalar_ch, raw_val, has_alpha, alpha_str, n_ops, ops, i, op, eq_pos, op_name, op_val_str, op_val, hex_modified, rebuilt, scalar_val, scalar_lo, scalar_hi) {
  if (inner_expr in _memo) return _memo[inner_expr]

  pipe_pos = index(inner_expr, "|")
  if (pipe_pos == 0) {
    if (inner_expr in resolved) {
      _memo[inner_expr] = resolved[inner_expr]
      return resolved[inner_expr]
    }
    return ""
  }

  base_part = substr(inner_expr, 1, pipe_pos - 1)
  ops_str   = substr(inner_expr, pipe_pos + 1)

  fmt = "hex"
  hex_variant = "plain"
  scalar_ch = ""
  base_key = base_part

  if (base_key in subs) {
  } else if (sub(/_strip$/, "", base_key)) { hex_variant = "strip" }
  else if (sub(/_upper$/, "", base_key))   { hex_variant = "upper" }
  else if (sub(/_lower$/, "", base_key))   { hex_variant = "lower" }
  else if (sub(/_0x$/, "", base_key))      { hex_variant = "0x" }
  else if (sub(/_rgb$/, "", base_key))     { fmt = "rgb" }
  else if (sub(/_hsl$/, "", base_key))     { fmt = "hsl" }
  else if (sub(/_hwb$/, "", base_key))     { fmt = "hwb" }
  else if (sub(/_r$/, "", base_key))       { fmt = "scalar"; scalar_ch = "r" }
  else if (sub(/_g$/, "", base_key))       { fmt = "scalar"; scalar_ch = "g" }
  else if (sub(/_b$/, "", base_key))       { fmt = "scalar"; scalar_ch = "b" }
  else if (sub(/_h$/, "", base_key))       { fmt = "scalar"; scalar_ch = "h" }
  else if (sub(/_s$/, "", base_key))       { fmt = "scalar"; scalar_ch = "s" }
  else if (sub(/_l$/, "", base_key))       { fmt = "scalar"; scalar_ch = "l" }
  else if (sub(/_w$/, "", base_key))       { fmt = "scalar"; scalar_ch = "w" }
  else return ""

  if (!(base_key in subs)) return ""
  raw_val = subs[base_key]

  if (raw_val !~ /^#/) {
    if (ops_str != "" || fmt != "hex") return ""
    if (hex_variant == "upper") { _memo[inner_expr] = toupper(raw_val); return toupper(raw_val) }
    if (hex_variant == "lower") { _memo[inner_expr] = tolower(raw_val); return tolower(raw_val) }
    if (hex_variant == "strip") { sub(/^#/, "", raw_val); _memo[inner_expr] = raw_val; return raw_val }
    _memo[inner_expr] = raw_val; return raw_val
  }

  # Use cached channel values from _precompute() instead of calling
  # parse_hex() again. The _ph[] entries are only populated for hex
  # colors (raw_val starts with #), so the existence of _pr[key]
  # indicates the cache is warm.
  _r = _pr[base_key]; _g = _pg[base_key]; _b = _pb[base_key]
  _hsl_done = 0

  if (fmt == "hsl" || fmt == "hwb") {
    _h = _ph[base_key]; _s = _ps[base_key]; _l = _pl[base_key]
    _w = _pw[base_key]; _bk = _pbk[base_key]
    _hsl_done = 1
  }

  if (fmt == "scalar") {
    if (scalar_ch == "r")      scalar_val = _r
    else if (scalar_ch == "g") scalar_val = _g
    else if (scalar_ch == "b") scalar_val = _b
    else {
      _h = _ph[base_key]; _s = _ps[base_key]; _l = _pl[base_key]
      _w = _pw[base_key]; _bk = _pbk[base_key]
      _hsl_done = 1
      if      (scalar_ch == "h") scalar_val = _h
      else if (scalar_ch == "s") scalar_val = _s
      else if (scalar_ch == "l") scalar_val = _l
      else if (scalar_ch == "w") scalar_val = _w
    }
  }

  has_alpha = 0
  alpha_str = ""
  hex_modified = 0

  if (ops_str != "") {
    n_ops = split(ops_str, ops, "|")
    for (i = 1; i <= n_ops; i++) {
      op = ops[i]
      sub(/^[[:space:]]+/, "", op)
      sub(/[[:space:]]+$/, "", op)
      eq_pos = index(op, "=")
      if (eq_pos == 0) continue

      op_name = substr(op, 1, eq_pos - 1)
      op_val_str = substr(op, eq_pos + 1)

      op_val = op_val_str + 0

      if (fmt == "hex") {
        if (op_name == "alpha") {
          alpha_str = _hex2[int(clamp(op_val, 0.0, 1.0) * 255.0 + 0.5)]
          has_alpha = 1
        } else if (op_name == "lightness") {
          if (!_hsl_done) {
            _h = _ph[base_key]; _s = _ps[base_key]; _l = _pl[base_key]
            _w = _pw[base_key]; _bk = _pbk[base_key]
            _hsl_done = 1
          }
          if (substr(op_val_str, 1, 1) == "+" || substr(op_val_str, 1, 1) == "-")
            _l = clamp(_l + op_val * 100.0, 0, 100)
          else
            _l = clamp(op_val * 100.0, 0, 100)
          hsl_to_rgb(_h, _s, _l)
          hex_modified = 1
        }
      } else if (fmt == "rgb") {
        if (op_name == "alpha") {
          alpha_str = op_val_str
          has_alpha = 1
        } else if (op_name == "red") {
          _r = int(clamp(_r + op_val, 0, 255))
          _hsl_done = 0
        } else if (op_name == "green") {
          _g = int(clamp(_g + op_val, 0, 255))
          _hsl_done = 0
        } else if (op_name == "blue") {
          _b = int(clamp(_b + op_val, 0, 255))
          _hsl_done = 0
        } else if (op_name == "lightness") {
          if (!_hsl_done) {
            _h = _ph[base_key]; _s = _ps[base_key]; _l = _pl[base_key]
            _w = _pw[base_key]; _bk = _pbk[base_key]
            _hsl_done = 1
          }
          if (substr(op_val_str, 1, 1) == "+" || substr(op_val_str, 1, 1) == "-")
            _l = clamp(_l + op_val * 100.0, 0, 100)
          else
            _l = clamp(op_val * 100.0, 0, 100)
          hsl_to_rgb(_h, _s, _l)
        }
      } else if (fmt == "hsl") {
        if      (op_name == "lighten")    _l = clamp(_l + op_val, 0, 100)
        else if (op_name == "darken")     _l = clamp(_l - op_val, 0, 100)
        else if (op_name == "saturate")   _s = clamp(_s + op_val, 0, 100)
        else if (op_name == "desaturate") _s = clamp(_s - op_val, 0, 100)
        else if (op_name == "hue")        _h = ((_h + op_val) % 360.0 + 360.0) % 360.0
      } else if (fmt == "hwb") {
        if      (op_name == "whiten")  _w = clamp(_w + op_val, 0, 100)
        else if (op_name == "blacken") _bk = clamp(_bk + op_val, 0, 100)
        else if (op_name == "hue")     _h = ((_h + op_val) % 360.0 + 360.0) % 360.0
      } else if (fmt == "scalar" && op_name == "lightness") {
        if (scalar_ch == "r" || scalar_ch == "g" || scalar_ch == "b") {
          scalar_lo = 0; scalar_hi = 255
        } else {
          scalar_lo = 0; scalar_hi = 100
        }

        if (substr(op_val_str, 1, 1) == "+" || substr(op_val_str, 1, 1) == "-") {
          if (scalar_ch == "h")
            scalar_val = ((scalar_val + op_val * 360.0) % 360.0 + 360.0) % 360.0
          else
            scalar_val = clamp(scalar_val + op_val * (scalar_hi - scalar_lo), scalar_lo, scalar_hi)
        } else {
          if (scalar_ch == "h")
            scalar_val = ((op_val * 360.0) % 360.0 + 360.0) % 360.0
          else
            scalar_val = clamp(op_val * (scalar_hi - scalar_lo), scalar_lo, scalar_hi)
        }
      }
    }
  }

  if (fmt == "hex") {
    if (hex_modified) {
      # Channels are already clamped to [0,255] by hsl_to_rgb, so _hex2[]
      # lookup is safe without an additional clamp call.
      rebuilt = _hex2[_r] _hex2[_g] _hex2[_b]
    } else {
      rebuilt = substr(raw_val, 2)
      if (has_alpha && length(rebuilt) == 8) rebuilt = substr(rebuilt, 1, 6)
    }
    if (has_alpha) rebuilt = rebuilt alpha_str

    if (hex_variant == "strip")      { _memo[inner_expr] = rebuilt; return rebuilt }
    if (hex_variant == "upper")      { _memo[inner_expr] = "#" toupper(rebuilt); return "#" toupper(rebuilt) }
    if (hex_variant == "lower")      { _memo[inner_expr] = "#" tolower(rebuilt); return "#" tolower(rebuilt) }
    if (hex_variant == "0x")         { _memo[inner_expr] = "0x" rebuilt; return "0x" rebuilt }
    _memo[inner_expr] = "#" rebuilt; return "#" rebuilt
  }

  if (fmt == "rgb") {
    if (has_alpha) { _memo[inner_expr] = _r "," _g "," _b "," alpha_str; return _r "," _g "," _b "," alpha_str }
    _memo[inner_expr] = _r "," _g "," _b; return _r "," _g "," _b
  }

  if (fmt == "hsl")    { _memo[inner_expr] = int(_h + 0.5) "," int(_s + 0.5) "," int(_l + 0.5); return int(_h + 0.5) "," int(_s + 0.5) "," int(_l + 0.5) }
  if (fmt == "hwb")    { _memo[inner_expr] = int(_h + 0.5) "," int(_w + 0.5) "%," int(_bk + 0.5) "%"; return int(_h + 0.5) "," int(_w + 0.5) "%," int(_bk + 0.5) "%" }
  if (fmt == "scalar") { _memo[inner_expr] = int(scalar_val + 0.5); return int(scalar_val + 0.5) }

  return ""
}

# Scans one line left to right for {{ ... }} tokens, replacing each one in
# turn. The inner expression is trimmed once here rather than in
# resolve_token(), eliminating two sub() calls per token. Anything that
# resolve_token() could not resolve comes back as an empty string, which we
# treat as "leave the original token in place" rather than "delete it", so
# a broken placeholder stays visible in the rendered file instead of
# vanishing.
function process_line(line,    result, rest, open_pos, close_pos, inner, resolved) {
  result = ""
  rest   = line

  while (1) {
    open_pos = index(rest, "{{")
    if (open_pos == 0) { result = result rest; break }

    result = result substr(rest, 1, open_pos - 1)
    rest   = substr(rest, open_pos)

    close_pos = index(rest, "}}")
    if (close_pos == 0) { result = result rest; break }

    inner = substr(rest, 3, close_pos - 3)
    sub(/^[[:space:]]+/, "", inner)
    sub(/[[:space:]]+$/, "", inner)

    resolved = resolve_token(inner)
    if (resolved != "") {
      result = result resolved
    } else {
      result = result substr(rest, 1, close_pos + 1)
    }

    rest = substr(rest, close_pos + 2)
  }

  return result
}

# AWK is handed three kinds of input on its command line, in order: the
# substitution table file, the template-to-output map file, then every
# actual template file to render. These two rules catch the first two and
# load them into the subs[] and outmap[] arrays; everything else falls
# through to the rendering rule at the bottom.

# ARGV[1]: one "key\x01value" pair per line, the merged colors table.
FILENAME == ARGV[1] {
  sep = index($0, "\x01")
  subs[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

# ARGV[2]: one "template_path\x01output_path" pair per line.
FILENAME == ARGV[2] {
  sep = index($0, "\x01")
  outmap[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

# The first line of each remaining input file tells us which output path
# it was assigned in the map above; every subsequent line of that file
# writes to the same place. _precompute() runs on the first template seen,
# after subs[] and outmap[] are both fully loaded.
FNR == 1 {
  if (!_precomputed) { _precompute(); _precomputed = 1 }
  outfile = outmap[FILENAME]
}

{
  print process_line($0) > outfile
}
