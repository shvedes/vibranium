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

# Restrict v to the closed range [lo, hi]. Nearly every operation below ends
# with a clamp, since channel math has a way of drifting just outside its
# valid range from rounding alone.
function clamp(v, lo, hi) {
  return v < lo ? lo : (v > hi ? hi : v)
}

# Value of a single hex digit, case-insensitively. The building block for
# pulling a "#rrggbb" string apart one nibble at a time.
function hex_char_val(c,    lc) {
  lc = tolower(c)
  if (lc >= "0" && lc <= "9") return lc + 0
  if (lc >= "a" && lc <= "f") return 10 + index("abcdef", lc) - 1
  return 0
}

# The reverse of hex_char_val: an integer channel value (0-255) back into a
# two-character lowercase hex pair. Used whenever a computed channel needs
# to be written back out as hex.
function int_to_hex2(n,    iv, digits) {
  digits = "0123456789abcdef"
  iv = int(clamp(n, 0, 255))
  return substr(digits, int(iv / 16) + 1, 1) substr(digits, (iv % 16) + 1, 1)
}

# Splits a "#rrggbb" string into the _r, _g, _b globals. Assumes the value
# has already been confirmed to start with # and to be well-formed; callers
# are responsible for that check before reaching here.
function parse_hex(hex) {
  hex = substr(hex, 2) # drop the leading #
  _r = hex_char_val(substr(hex, 1, 1)) * 16 + hex_char_val(substr(hex, 2, 1))
  _g = hex_char_val(substr(hex, 3, 1)) * 16 + hex_char_val(substr(hex, 4, 1))
  _b = hex_char_val(substr(hex, 5, 1)) * 16 + hex_char_val(substr(hex, 6, 1))
}

# Converts integer RGB (0-255 each) into HSL, plus the HWB whiteness and
# blackness that fall out of the same math almost for free. Sets the
# globals _h (0-360), _s (0-100), _l (0-100), _w, _bk.
function rgb_to_hsl(r, g, b,    rn, gn, bn, cmax, cmin, delta, lv, abs2l1, max_ch) {
  rn = r / 255.0
  gn = g / 255.0
  bn = b / 255.0

  # We only need to know which channel is largest, not its exact value, so
  # this is decided with plain comparisons rather than a max() call.
  if (rn >= gn && rn >= bn) { cmax = rn; max_ch = "r" }
  else if (gn >= bn)        { cmax = gn; max_ch = "g" }
  else                      { cmax = bn; max_ch = "b" }

  cmin = (rn <= gn && rn <= bn) ? rn : (gn <= bn ? gn : bn)
  delta = cmax - cmin
  lv = (cmax + cmin) / 2.0

  _w = cmin * 100.0
  _bk = (1.0 - cmax) * 100.0

  # A gray has no real hue or saturation to speak of (all three channels
  # are equal, so delta is zero); treat it as hue 0, saturation 0 rather
  # than dividing by zero a few lines down.
  if (delta < 0.000001) {
    _h = 0; _s = 0; _l = lv * 100.0
    return
  }

  abs2l1 = 2.0 * lv - 1.0
  if (abs2l1 < 0) abs2l1 = -abs2l1
  _s = (delta / (1.0 - abs2l1)) * 100.0

  # Standard HSL hue formula, one branch per dominant channel.
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

  # Normalize hue into [0, 360) up front so the sextant lookup below cannot
  # see a negative or over-large value.
  h = ((h % 360.0) + 360.0) % 360.0

  abs2l1 = 2.0 * ln - 1.0
  if (abs2l1 < 0) abs2l1 = -abs2l1
  C = (1.0 - abs2l1) * sn

  Hp = h / 60.0
  hmod2 = Hp % 2.0
  abshm1 = hmod2 - 1.0
  if (abshm1 < 0) abshm1 = -abshm1
  X = C * (1.0 - abshm1)

  # The colorwheel is split into six 60-degree sextants; which one we are
  # in decides which two channels carry C and X and which sits at zero.
  if      (Hp < 1) { r1=C; g1=X; b1=0 }
  else if (Hp < 2) { r1=X; g1=C; b1=0 }
  else if (Hp < 3) { r1=0; g1=C; b1=X }
  else if (Hp < 4) { r1=0; g1=X; b1=C }
  else if (Hp < 5) { r1=X; g1=0; b1=C }
  else             { r1=C; g1=0; b1=X }

  m = ln - C / 2.0
  _r = clamp(int((r1 + m) * 255.0 + 0.5), 0, 255)
  _g = clamp(int((g1 + m) * 255.0 + 0.5), 0, 255)
  _b = clamp(int((b1 + m) * 255.0 + 0.5), 0, 255)
}

# Takes whatever sat between {{ and }} (for example "color4|lightness=0.8")
# and turns it into the final string a template should see. This is the
# one function that knows about every output format and every pipe
# operation, so it is long, but each branch below stands on its own.
function resolve_token(inner_expr,    pipe_pos, base_part, ops_str, base_key, fmt, hex_variant, scalar_ch, raw_val, has_alpha, alpha_str, n_ops, ops, i, op, eq_pos, op_name, op_val_str, op_val, hex_modified, rebuilt, scalar_val, scalar_lo, scalar_hi) {
  # Split off the pipe chain, if there is one, from the base key.
  pipe_pos = index(inner_expr, "|")
  if (pipe_pos > 0) {
    base_part = substr(inner_expr, 1, pipe_pos - 1)
    ops_str   = substr(inner_expr, pipe_pos + 1)
  } else {
    base_part = inner_expr
    ops_str   = ""
  }

  # Templates are free to write "{{ key | op=val }}" with extra spaces
  # around the key for readability, so trim before doing anything else.
  sub(/^[[:space:]]+/, "", base_part)
  sub(/[[:space:]]+$/, "", base_part)

  fmt = "hex"
  hex_variant = "plain"
  scalar_ch = ""
  base_key = base_part

  # The key suffix is what tells us which format and variant the template
  # is asking for. A key with no recognized suffix that also is not a
  # literal entry in the substitution table is not one of ours, so it
  # falls through to the final "return \"\"" and is left alone by the
  # caller.
  if (base_key in subs) {
    # No suffix to strip: the key matches the table exactly, plain hex.
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

  # The suffix matched a known pattern, but the key underneath it still has
  # to exist in the substitution table. A pipe expression whose base key
  # was never defined is left as-is for the same reason an unknown key is.
  if (!(base_key in subs)) return ""
  raw_val = subs[base_key]

  # Not every value in colors.toml is a color. Font names and other plain
  # strings pass through case/strip variants on the literal text but cannot
  # be sent through any color math, since there is no color to compute.
  if (raw_val !~ /^#/) {
    if (ops_str != "" || fmt != "hex") return ""
    if (hex_variant == "upper") return toupper(raw_val)
    if (hex_variant == "lower") return tolower(raw_val)
    if (hex_variant == "strip") { sub(/^#/, "", raw_val); return raw_val }
    return raw_val
  }

  # From here on we know we are dealing with an actual color, so populate
  # the RGB globals, and HSL too unless the request is a plain unmodified
  # hex value that does not need it.
  parse_hex(raw_val)
  if (fmt != "hex" || ops_str != "") {
    rgb_to_hsl(_r, _g, _b)
  }

  # A scalar request (_r, _h, _w, and so on) wants exactly one channel out
  # of everything we just computed. Pull it into scalar_val now so the
  # lightness operation below has a single value to work against.
  if (fmt == "scalar") {
    if (scalar_ch == "r")      scalar_val = _r
    else if (scalar_ch == "g") scalar_val = _g
    else if (scalar_ch == "b") scalar_val = _b
    else if (scalar_ch == "h") scalar_val = _h
    else if (scalar_ch == "s") scalar_val = _s
    else if (scalar_ch == "l") scalar_val = _l
    else if (scalar_ch == "w") scalar_val = _w
  }

  has_alpha = 0
  alpha_str = ""
  hex_modified = 0

  # Run the pipe chain left to right. Each segment is "name=value"; a
  # segment with no "=" is silently skipped rather than treated as an
  # error, since a malformed op is not worth aborting the whole render for.
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

      # AWK turns a leading "+" or "-" into the expected signed number on
      # its own; what we still need the original string for is checking
      # whether a sign was present at all, since that is what decides
      # absolute versus relative mode for lightness below.
      op_val = op_val_str + 0

      if (fmt == "hex") {
        if (op_name == "alpha") {
          # alpha is given as 0.0-1.0 and stored as a hex byte appended
          # to the color, the same convention CSS uses for #rrggbbaa.
          alpha_str = int_to_hex2(int(clamp(op_val, 0.0, 1.0) * 255.0 + 0.5))
          has_alpha = 1
        } else if (op_name == "lightness") {
          # A leading sign means "shift the current lightness by this
          # much"; no sign means "set lightness to exactly this value".
          if (substr(op_val_str, 1, 1) == "+" || substr(op_val_str, 1, 1) == "-")
            _l = clamp(_l + op_val * 100.0, 0, 100)
          else
            _l = clamp(op_val * 100.0, 0, 100)
          hsl_to_rgb(_h, _s, _l)
          hex_modified = 1
        }
      } else if (fmt == "rgb") {
        if (op_name == "alpha") {
          # RGB output keeps alpha as a literal fourth number rather than
          # encoding it into hex, since the destination format here is a
          # comma list, not a hex string.
          alpha_str = op_val_str
          has_alpha = 1
        } else if (op_name == "red") {
          _r = int(clamp(_r + op_val, 0, 255))
          rgb_to_hsl(_r, _g, _b)
        } else if (op_name == "green") {
          _g = int(clamp(_g + op_val, 0, 255))
          rgb_to_hsl(_r, _g, _b)
        } else if (op_name == "blue") {
          _b = int(clamp(_b + op_val, 0, 255))
          rgb_to_hsl(_r, _g, _b)
        } else if (op_name == "lightness") {
          # Same absolute-vs-relative rule as the hex branch above, just
          # rebuilt into RGB instead of a hex string at the end.
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
        # The op is still called "lightness" here for syntax consistency
        # with the hex/rgb branches above, even though for a scalar key it
        # just means "shift or set this one channel". The valid range
        # depends on which channel it is: 0-255 for r/g/b, 0-100 for
        # everything else.
        if (scalar_ch == "r" || scalar_ch == "g" || scalar_ch == "b") {
          scalar_lo = 0; scalar_hi = 255
        } else {
          scalar_lo = 0; scalar_hi = 100
        }

        # Hue wraps around 360 instead of clamping, since hue is a
        # position on a circle, not a bounded quantity.
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

  # Everything above only ever touched the working globals. This is where
  # we finally turn them into the string the template actually gets.
  if (fmt == "hex") {
    if (hex_modified) {
      # A lightness operation ran, so rebuild from the (possibly changed)
      # RGB globals rather than reusing the original hex text.
      rebuilt = int_to_hex2(_r) int_to_hex2(_g) int_to_hex2(_b)
    } else {
      # No color math happened, only variant formatting, so the original
      # six hex digits are reused as-is; an existing alpha byte from an
      # 8-digit source value is dropped here and reattached just below if
      # a new alpha operation supplied one, so the two never stack.
      rebuilt = substr(raw_val, 2)
      if (has_alpha && length(rebuilt) == 8) rebuilt = substr(rebuilt, 1, 6)
    }
    if (has_alpha) rebuilt = rebuilt alpha_str

    if (hex_variant == "strip") return rebuilt
    if (hex_variant == "upper") return "#" toupper(rebuilt)
    if (hex_variant == "lower") return "#" tolower(rebuilt)
    if (hex_variant == "0x")    return "0x" rebuilt
    return "#" rebuilt
  }

  if (fmt == "rgb") {
    if (has_alpha) return _r "," _g "," _b "," alpha_str
    return _r "," _g "," _b
  }

  # HSL, HWB, and scalar outputs are always rounded to whole numbers; a
  # template asking for hue or lightness wants a clean integer, not eleven
  # digits of floating-point residue.
  if (fmt == "hsl")    return int(_h + 0.5) "," int(_s + 0.5) "," int(_l + 0.5)
  if (fmt == "hwb")    return int(_h + 0.5) "," int(_w + 0.5) "%," int(_bk + 0.5) "%"
  if (fmt == "scalar") return int(scalar_val + 0.5)

  return ""
}

# Scans one line left to right for {{ ... }} tokens, replacing each one in
# turn. Anything that resolve_token() could not resolve comes back as an
# empty string, which we treat as "leave the original token in place"
# rather than "delete it", so a broken placeholder stays visible in the
# rendered file instead of vanishing.
function process_line(line,    result, rest, open_pos, close_pos, full_tok, inner, resolved) {
  result = ""
  rest   = line

  while (1) {
    open_pos = index(rest, "{{")
    if (open_pos == 0) { result = result rest; break }

    result = result substr(rest, 1, open_pos - 1)
    rest   = substr(rest, open_pos)

    close_pos = index(rest, "}}")
    if (close_pos == 0) { result = result rest; break }

    full_tok = substr(rest, 1, close_pos + 1)
    inner = substr(rest, 3, close_pos - 3)

    resolved = resolve_token(inner)

    if (resolved != "") {
      result = result resolved
    } else {
      result = result full_tok
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
# writes to the same place.
FNR == 1 { outfile = outmap[FILENAME] }

{
  print process_line($0) > outfile
}
