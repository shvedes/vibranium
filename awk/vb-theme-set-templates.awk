#!/usr/bin/awk

# ==============================================================================
# VIBRANIUM TEMPLATE REPLAY ENGINE (AWK IMPLEMENTATION)
# ==============================================================================
# Reads a pre-processed substitution table and an output file mapping, then
# tokenizes and evaluates theme template files in a single fast execution pass.
#
# TEMPLATE SYNTAX
#   {{ key }}            value as-is (e.g. #1e1e2e)
#   {{ key_strip }}      value with leading # removed (e.g. 1e1e2e)
#   {{ key_upper }}      value uppercased (e.g. #1E1E2E)
#   {{ key_lower }}      value lowercased (e.g. #1e1e2e)
#
#   Hex color keys only (values starting with #):
#   {{ key_0x }}         0x-prefixed hex; alpha byte passed through if present
#                          background = "#1e1e2e"    ->  0x1e1e2e
#                          shadow     = "#1e1e2ecc"  ->  0x1e1e2ecc
#   {{ key_r }}          red channel as decimal (e.g. 30)
#   {{ key_g }}          green channel as decimal (e.g. 30)
#   {{ key_b }}          blue channel as decimal (e.g. 46)
#   {{ key_rgb }}        decimal channels (e.g. 30,30,46)
#   {{ key_h }}          hue as integer degrees 0-359 (e.g. 240)
#   {{ key_s }}          saturation as integer percentage 0-100 (e.g. 21)
#   {{ key_l }}          lightness as integer percentage 0-100 (e.g. 15)
#   {{ key_hsl }}        H,S,L shorthand (e.g. 240,21,15)
#   {{ key_w }}          HWB whiteness as integer percentage 0-100 (e.g. 12)
#   {{ key_hwb }}        H,W,Bk shorthand (e.g. 240,12%,85%)
#
#   Alpha channels: use 8-char hex (rrggbbaa CSS order) in the TOML value to
#   include alpha. {{ key }}, {{ key_strip }}, and {{ key_0x }} pass it through
#   as-is. All channel variants (_r, _g, _b, _rgb, _h, _s, _l, _hsl, _w, _hwb)
#   decode only the first 6 digits and ignore alpha.
#
# INLINE COLOR CALCULATIONS
#   Any key can be extended with one or more pipe-separated operations that are
#   evaluated at substitution time and replaced with a final computed value.
#   The base key before the first | must be a key that exists in the subs table
#   (format suffix included). Operations are applied left to right.
#
#   Syntax: {{ base_key|op=val|op=val }}
#
#   HEX keys ({{ key }}, {{ key_strip }}, {{ key_upper }}, {{ key_0x }}):
#     alpha=<0.0-1.0>       appends a two-digit hex alpha byte
#                             {{ color4|alpha=0.5 }}    ->  #1e1e2eff -> #1e1e2e80
#     lightness=<value>     round-trips through HSL to set or shift L;
#                           output is re-encoded in the same variant format
#                           (strip stays strip, upper stays upper, etc.)
#
#   RGB keys ({{ key_rgb }}):
#     alpha=<0.0-1.0>       appends alpha as a literal float fourth channel
#                             {{ color4_rgb|alpha=0.6 }}   ->  30,30,46,0.6
#     red=<+/-N>            offsets the red channel by N, clamped to 0-255
#     green=<+/-N>          offsets the green channel by N, clamped to 0-255
#     blue=<+/-N>           offsets the blue channel by N, clamped to 0-255
#     lightness=<value>     round-trips through HSL to set or shift L,
#                           then rebuilds RGB; hue and saturation are preserved
#
#   HSL keys ({{ key_hsl }}):
#     lighten=<N>           increases L by N percentage points, clamped to 100
#     darken=<N>            decreases L by N percentage points, clamped to 0
#     saturate=<N>          increases S by N percentage points, clamped to 100
#     desaturate=<N>        decreases S by N percentage points, clamped to 0
#     hue=<+/-N>            rotates H by N degrees, wraps around 360
#
#   Single-channel scalar keys ({{ key_r }}, {{ key_g }}, {{ key_b }},
#   {{ key_h }}, {{ key_s }}, {{ key_l }}, {{ key_w }}):
#     lightness=<value>     shifts or sets the channel's own value directly;
#                           the op name is reused from the HEX/RGB lightness
#                           operation for syntax consistency, it is not
#                           limited to lightness-related channels
#                             {{ color1_r|lightness=-0.05 }}   shifts R down
#                             {{ color1_h|lightness=-0.05 }}   shifts H down
#                             {{ color1_w|lightness=0.3 }}     sets W to 30%
#     Absolute and relative modes work the same as the HEX/RGB lightness
#     operation below. R/G/B normalize against 0-255; H/S/L/W normalize
#     against 0-100, except H wraps modulo 360 instead of clamping.
#
#   The lightness operation (HEX and RGB only):
#     Absolute: lightness=0.75   sets L to exactly 75% (0.0 = black, 1.0 = white)
#     Relative: lightness=+0.15  shifts current L up by 15 percentage points
#               lightness=-0.10  shifts current L down by 10 percentage points
#     The presence of a leading + or - determines the mode.
#
#   Number format:
#     Both 0.20 and .20 are accepted. Integer values like alpha=1 are treated
#     as 1.0. The sign is part of the value string, not a separate token.
#
#   Order of operations:
#     Applied strictly left to right. Order matters when two operations affect
#     the same channel. In particular, channel offsets (red/green/blue) applied
#     before lightness will be overwritten during the HSL rebuild -- apply them
#     after lightness if both are needed.
#       {{ color4_rgb|lightness=0.8|blue=-30 }}   correct: offset survives
#       {{ color4_rgb|blue=-30|lightness=0.8 }}   wrong: offset is discarded
#
# WARNINGS
#   - Unknown {{ key }} placeholders with no pipe operator are left as-is in
#     the output. Pipe expressions whose base key is not found in the subs
#     table are also left verbatim, making resolution failures visible rather
#     than silently producing empty or broken values.
#   - Operations that are not defined for a given format (e.g. alpha on an
#     HSL key) are silently ignored; the color is still substituted.
#   - The alpha operation on HEX keys produces an 8-character #rrggbbaa string.
#     Configs that do not accept 8-character hex will break.
#   - Hue rotation and saturation on achromatic colors (pure greys, S=0)
#     have no visible effect since both H and S are zero for those colors.
# ==============================================================================

# Clamp value v to the closed interval [lo, hi].
function clamp(v, lo, hi) {
  return v < lo ? lo : (v > hi ? hi : v)
}

# Return the decimal value (0-15) of a single hex digit character.
function hex_char_val(c,    lc) {
  lc = tolower(c)
  if (lc >= "0" && lc <= "9") return lc + 0
  if (lc >= "a" && lc <= "f") return 10 + index("abcdef", lc) - 1
  return 0
}

# Convert an integer (0-255) to a two-character lowercase hex string.
function int_to_hex2(n,    iv, digits) {
  digits = "0123456789abcdef"
  iv = int(clamp(n, 0, 255))
  return substr(digits, int(iv / 16) + 1, 1) substr(digits, (iv % 16) + 1, 1)
}

# Parse a "#rrggbb" string into globals _r, _g, _b (integers 0-255).
function parse_hex(hex) {
  hex = substr(hex, 2) # drop the leading '#'
  _r = hex_char_val(substr(hex, 1, 1)) * 16 + hex_char_val(substr(hex, 2, 1))
  _g = hex_char_val(substr(hex, 3, 1)) * 16 + hex_char_val(substr(hex, 4, 1))
  _b = hex_char_val(substr(hex, 5, 1)) * 16 + hex_char_val(substr(hex, 6, 1))
}

# Convert integer RGB (0-255 each) to HSL.
# Assumes: r, g, b are the only arguments; all other names are locals.
# Sets globals: _h (0-360), _s (0-100), _l (0-100), and provisions HWB parameters.
function rgb_to_hsl(r, g, b,    rn, gn, bn, cmax, cmin, delta, lv, abs2l1, max_ch) {
  rn = r / 255.0
  gn = g / 255.0
  bn = b / 255.0

  # Track which channel is dominant so hue can be computed without
  # floating-point equality comparisons on derived values.
  if (rn >= gn && rn >= bn) { cmax = rn; max_ch = "r" }
  else if (gn >= bn)        { cmax = gn; max_ch = "g" }
  else                      { cmax = bn; max_ch = "b" }

  cmin = (rn <= gn && rn <= bn) ? rn : (gn <= bn ? gn : bn)
  delta = cmax - cmin
  lv = (cmax + cmin) / 2.0

  # Setup HWB parameters globally
  _w = cmin * 100.0
  _bk = (1.0 - cmax) * 100.0

  # Achromatic colors (greys) have no meaningful hue or saturation.
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

# Convert HSL back to integer RGB.
# Inputs: h (0-360), s (0-100), l (0-100).
# Sets globals: _r, _g, _b (integers 0-255).
function hsl_to_rgb(h, s, l,    sn, ln, C, Hp, X, m, r1, g1, b1, hmod2, abshm1, abs2l1) {
  sn = s / 100.0
  ln = l / 100.0

  # Normalize hue into [0, 360) before computing the sextant index.
  h = ((h % 360.0) + 360.0) % 360.0

  abs2l1 = 2.0 * ln - 1.0
  if (abs2l1 < 0) abs2l1 = -abs2l1
  C = (1.0 - abs2l1) * sn

  Hp = h / 60.0
  hmod2 = Hp % 2.0
  abshm1 = hmod2 - 1.0
  if (abshm1 < 0) abshm1 = -abshm1
  X = C * (1.0 - abshm1)

  # Assign initial RGB based on which 60-degree sextant H falls in.
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

# Computes and resolves a token inner expression explicitly requested by the scanner.
# e.g., "color1_hsl | lighten=10" or a plain key token like "background".
# Supports format detection, hex variations, single-channel scalars, and full pipeline processing.
function resolve_token(inner_expr,    pipe_pos, base_part, ops_str, base_key, fmt, hex_variant, scalar_ch, raw_val, has_alpha, alpha_str, n_ops, ops, i, op, eq_pos, op_name, op_val_str, op_val, hex_modified, rebuilt, scalar_val, scalar_lo, scalar_hi) {
  pipe_pos = index(inner_expr, "|")
  if (pipe_pos > 0) {
    base_part = substr(inner_expr, 1, pipe_pos - 1)
    ops_str   = substr(inner_expr, pipe_pos + 1)
  } else {
    base_part = inner_expr
    ops_str   = ""
  }

  # Trim leading/trailing whitespace from the base key part so "key | op" works smoothly.
  sub(/^[[:space:]]+/, "", base_part)
  sub(/[[:space:]]+$/, "", base_part)

  # Lazy format evaluation structure
  fmt = "hex"
  hex_variant = "plain"
  scalar_ch = ""
  base_key = base_part

  # Detect the expected color format from the key suffix.
  # Single-channel scalar keys are evaluated before bare hex fallback mappings.
  if (base_key in subs) {
    # Exact base dictionary match verified
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

  # If the resolved base component is absent from our substitutions database, drop execution.
  if (!(base_key in subs)) return ""
  raw_val = subs[base_key]

  # Guard check for non-hex values (e.g. font string options or raw literals)
  if (raw_val !~ /^#/) {
    if (ops_str != "" || fmt != "hex") return ""
    if (hex_variant == "upper") return toupper(raw_val)
    if (hex_variant == "lower") return tolower(raw_val)
    if (hex_variant == "strip") { sub(/^#/, "", raw_val); return raw_val }
    return raw_val
  }

  # Populate standard working globals
  parse_hex(raw_val)
  if (fmt != "hex" || ops_str != "") {
    rgb_to_hsl(_r, _g, _b)
  }

  # Synchronize specific current scalar dimension targeting
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

  # Evaluate pipeline operational modifications sequentially from left to right
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

      # Coerce string tokens cleanly into arithmetic context representations
      op_val = op_val_str + 0

      if (fmt == "hex") {
        if (op_name == "alpha") {
          # Transmute relative 0.0-1.0 floating point alpha metrics to hex pairs
          alpha_str = int_to_hex2(int(clamp(op_val, 0.0, 1.0) * 255.0 + 0.5))
          has_alpha = 1
        } else if (op_name == "lightness") {
          # Check for relative offset operation modifications (+/-) vs absolute target values
          if (substr(op_val_str, 1, 1) == "+" || substr(op_val_str, 1, 1) == "-")
            _l = clamp(_l + op_val * 100.0, 0, 100)
          else
            _l = clamp(op_val * 100.0, 0, 100)
          hsl_to_rgb(_h, _s, _l)
          hex_modified = 1
        }
      } else if (fmt == "rgb") {
        if (op_name == "alpha") {
          # Maintain precise matching literal float format strings for text processors
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
        # Standard native scaling boundaries lookup selection logic setup
        if (scalar_ch == "r" || scalar_ch == "g" || scalar_ch == "b") {
          scalar_lo = 0; scalar_hi = 255
        } else {
          scalar_lo = 0; scalar_hi = 100
        }

        # Scalar channel computations. Hue rotates/wraps, all other options clamp.
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

  # Build out and emit formatting representations matching request specifications
  if (fmt == "hex") {
    if (hex_modified) {
      rebuilt = int_to_hex2(_r) int_to_hex2(_g) int_to_hex2(_b)
    } else {
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

  if (fmt == "hsl")    return int(_h + 0.5) "," int(_s + 0.5) "," int(_l + 0.5)
  if (fmt == "hwb")    return int(_h + 0.5) "," int(_w + 0.5) "%," int(_bk + 0.5) "%"
  if (fmt == "scalar") return int(scalar_val + 0.5)

  return ""
}

# The single-pass tokenization loop scanning lines left to right
# Unresolved keys stay unmodified inside the templates so that visibility constraints remain clear.
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

    # If successfully evaluated append value; otherwise preserve the original token as-is
    if (resolved != "") {
      result = result resolved
    } else {
      result = result full_tok
    }

    rest = substr(rest, close_pos + 2)
  }

  return result
}

# ARGV[1]: Substitution variables map database entries file
FILENAME == ARGV[1] {
  sep = index($0, "\x01")
  subs[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

# ARGV[2]: Output file execution routing directories mapping file
FILENAME == ARGV[2] {
  sep = index($0, "\x01")
  outmap[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

# Route current stream context onto target file pointers
FNR == 1 { outfile = outmap[FILENAME] }

{
  print process_line($0) > outfile
}
