#!/usr/bin/awk

# Literal string replacement: replace every occurrence of 'from' in 'str'
# with 'to', treating all characters as plain literals (no regex).
function lit_replace(str, from, to,    result, pos) {
  result = ""
  while ((pos = index(str, from)) > 0) {
    result = result substr(str, 1, pos - 1) to
    str    = substr(str, pos + length(from))
  }
  return result str
}

# Clamp value v to the closed interval [lo, hi].
function clamp(v, lo, hi) {
  return v < lo ? lo : (v > hi ? hi : v)
}

# Return the decimal value (0-15) of a single hex digit character.
function hex_char_val(c,    lc) {
  lc = tolower(c)
  if (lc >= "0" && lc <= "9") return lc + 0
  if (lc == "a") return 10
  if (lc == "b") return 11
  if (lc == "c") return 12
  if (lc == "d") return 13
  if (lc == "e") return 14
  if (lc == "f") return 15
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
  hex = substr(hex, 2)  # drop the leading '#'
  _r = hex_char_val(substr(hex, 1, 1)) * 16 + hex_char_val(substr(hex, 2, 1))
  _g = hex_char_val(substr(hex, 3, 1)) * 16 + hex_char_val(substr(hex, 4, 1))
  _b = hex_char_val(substr(hex, 5, 1)) * 16 + hex_char_val(substr(hex, 6, 1))
}

# Convert integer RGB (0-255 each) to HSL.
# Assumes: r, g, b are the only arguments; all other names are locals.
# Sets globals: _h (0-360), _s (0-100), _l (0-100).
function rgb_to_hsl(r, g, b,    rn, gn, bn, cmax, cmin, delta, lv, abs2l1, max_ch) {
  rn = r / 255.0
  gn = g / 255.0
  bn = b / 255.0

  # Track which channel is dominant so hue can be computed without
  # floating-point equality comparisons on derived values.
  if (rn >= gn && rn >= bn) { cmax = rn; max_ch = "r" }
  else if (gn >= bn)         { cmax = gn; max_ch = "g" }
  else                       { cmax = bn; max_ch = "b" }

  cmin  = (rn <= gn && rn <= bn) ? rn : (gn <= bn ? gn : bn)
  delta = cmax - cmin
  lv    = (cmax + cmin) / 2.0

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

  Hp     = h / 60.0
  hmod2  = Hp % 2.0
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

  m  = ln - C / 2.0
  _r = int((r1 + m) * 255.0 + 0.5)
  _g = int((g1 + m) * 255.0 + 0.5)
  _b = int((b1 + m) * 255.0 + 0.5)

  _r = clamp(_r, 0, 255)
  _g = clamp(_g, 0, 255)
  _b = clamp(_b, 0, 255)
}

# Evaluate one pipe expression and return the final color string.
#
# 'expr' is the stripped content between {{ and }}, already confirmed to
# contain at least one '|', e.g. "background_0_hsl|lighten=+15" or
# "red_rgb|alpha=0.8|blue=-26".
#
# The base key (the part before the first '|') is looked up in the subs
# table exactly as bash would have emitted it. The format (hex/rgb/hsl) is
# inferred from the key suffix.
#
# Returns the computed string, or "" if the base key is unknown or the
# format cannot be parsed.
#
# Supported operations per format:
#   hex  : alpha=<0.0-1.0>     -- appends two-digit hex alpha byte
#   rgb  : alpha=<0.0-1.0>     -- appends literal float as fourth channel
#          red=<+/-N>          -- offset red channel, clamped to 0-255
#          green=<+/-N>        -- offset green channel, clamped to 0-255
#          blue=<+/-N>         -- offset blue channel, clamped to 0-255
#          lightness=<0.0-1.0> -- set HSL L absolutely, rebuild RGB
#   hsl  : lighten=<N>         -- increase L by N percentage points
#          darken=<N>          -- decrease L by N percentage points
#          saturate=<N>        -- increase S by N percentage points
#          desaturate=<N>      -- decrease S by N percentage points
#          hue=<+/-N>          -- rotate H by N degrees
#   hwb  : hue=<+/-N>          -- rotate H by N degrees
#          whiten=<N>          -- increase W by N percentage points
#          blacken=<N>         -- increase B by N percentage points
#   cmyk : cyan=<+/-N>         -- offset C by N percentage points
#          magenta=<+/-N>      -- offset M by N percentage points
#          yellow=<+/-N>       -- offset Y by N percentage points
#          key=<+/-N>          -- offset K by N percentage points
#
# Assumes bash emits RGB as "r,g,b", HSL as "h,s,l", HWB as "h,w,b", and
# CMYK as "c,m,y,k" (comma-separated; HSL/HWB/CMYK channels carry a literal
# "%" suffix that AWK's numeric-string coercion (+0) ignores).
#
function resolve_pipe_expr(expr,    pipe_pos, base_part, base_key, ops_str, fmt, color_val, n_ops, ops, i, op, eq_pos, op_name, op_val_str, op_val, alpha_str, has_alpha, parts, hex_variant, hex_modified, norm_val, rebuilt) {
  pipe_pos = index(expr, "|")
  if (pipe_pos == 0) return ""

  base_part = substr(expr, 1, pipe_pos - 1)
  ops_str   = substr(expr, pipe_pos + 1)

  # Trim trailing whitespace from the base key part so "key | op" also works.
  sub(/[[:space:]]+$/, "", base_part)

  # Reconstruct the full substitution key with the standard {{ }} delimiters.
  base_key = "{{ " base_part " }}"

  if (!(base_key in subs)) return ""
  color_val = subs[base_key]

  # Detect color format from the suffix of the key string.
  if      (index(base_key, "_rgb }}") > 0)  fmt = "rgb"
  else if (index(base_key, "_hsl }}") > 0)  fmt = "hsl"
  else if (index(base_key, "_hwb }}") > 0)  fmt = "hwb"
  else if (index(base_key, "_cmyk }}") > 0) fmt = "cmyk"
  else                                       fmt = "hex"

  # For hex format, also detect which variant bash emitted so we can parse
  # the value correctly (each variant has a different prefix) and emit the
  # result in the matching format.
  #   plain / lower  ->  #rrggbb   (parse_hex handles both; tolower inside)
  #   upper          ->  #RRGGBB   (same, tolower inside parse_hex)
  #   strip          ->   rrggbb   (no '#'; parse_hex would drop first digit)
  #   0x             ->  0xrrggbb  (parse_hex would drop '0', leaving xrrggbb)
  if (fmt == "hex") {
    if      (index(base_key, "_strip }}") > 0) hex_variant = "strip"
    else if (index(base_key, "_upper }}") > 0) hex_variant = "upper"
    else if (index(base_key, "_0x }}")   > 0) hex_variant = "0x"
    else                                        hex_variant = "plain"
  }

  # Parse the stored color value into working globals.
  if (fmt == "rgb") {
    split(color_val, parts, ",")
    _r = int(parts[1] + 0)
    _g = int(parts[2] + 0)
    _b = int(parts[3] + 0)
  } else if (fmt == "hsl") {
    split(color_val, parts, ",")
    _h = parts[1] + 0
    _s = parts[2] + 0
    _l = parts[3] + 0
  } else if (fmt == "hwb") {
    # "%" suffixes on parts[2]/parts[3] are dropped by AWK's +0 coercion.
    split(color_val, parts, ",")
    _h  = parts[1] + 0
    _w  = parts[2] + 0
    _bk = parts[3] + 0
  } else if (fmt == "cmyk") {
    split(color_val, parts, ",")
    _c = parts[1] + 0
    _m = parts[2] + 0
    _y = parts[3] + 0
    _k = parts[4] + 0
  } else {
    # Normalize the stored value to #rrggbb before handing it to parse_hex,
    # which always expects a leading '#'.  Each variant needs different handling:
    #   strip -> bare hex digits, prepend '#'
    #   0x    -> "0x" prefix, replace with '#'
    #   plain/upper/lower -> already start with '#', pass through
    if      (hex_variant == "strip") norm_val = "#" color_val
    else if (hex_variant == "0x")    norm_val = "#" substr(color_val, 3)
    else                             norm_val = color_val

    if (length(norm_val) < 7 || substr(norm_val, 1, 1) != "#") return ""
    parse_hex(norm_val)
  }

  alpha_str = ""
  has_alpha  = 0

  n_ops = split(ops_str, ops, "|")

  for (i = 1; i <= n_ops; i++) {
    op = ops[i]
    sub(/^[[:space:]]+/, "", op)
    sub(/[[:space:]]+$/, "", op)

    eq_pos = index(op, "=")
    if (eq_pos == 0) continue

    op_name    = substr(op, 1, eq_pos - 1)
    op_val_str = substr(op, eq_pos + 1)

    # AWK converts "+15" and "-26" correctly via arithmetic context.
    op_val = op_val_str + 0

    if (fmt == "hex") {

      if (op_name == "alpha") {
        # Convert the 0.0-1.0 float to a two-digit hex byte and
        # store it for appending to the #rrggbb value.
        alpha_str = int_to_hex2(int(clamp(op_val, 0.0, 1.0) * 255.0 + 0.5))
        has_alpha = 1
      } else if (op_name == "lightness") {
        # Round-trip through HSL exactly like the RGB path.
        # A leading sign means relative adjustment (offset from current L);
        # no sign means absolute target in the 0.0-1.0 range.
        rgb_to_hsl(_r, _g, _b)
        if (substr(op_val_str, 1, 1) == "+" || substr(op_val_str, 1, 1) == "-")
          _l = clamp(_l + op_val * 100.0, 0, 100)
        else
          _l = clamp(op_val * 100.0, 0, 100)
        hsl_to_rgb(_h, _s, _l)
        # Signal that _r/_g/_b now differ from color_val and must be
        # re-encoded rather than returning the original hex string.
        hex_modified = 1
      }

    } else if (fmt == "rgb") {

      if (op_name == "alpha") {
        # Preserve the original string literal so "0.60" stays "0.60",
        # which is important for consumers that treat the field as text.
        alpha_str = op_val_str
        has_alpha = 1
      } else if (op_name == "red") {
        _r = int(clamp(_r + op_val, 0, 255))
      } else if (op_name == "green") {
        _g = int(clamp(_g + op_val, 0, 255))
      } else if (op_name == "blue") {
        _b = int(clamp(_b + op_val, 0, 255))
      } else if (op_name == "lightness") {
        # Always round-trip through HSL so the current L is available
        # regardless of whether the adjustment is relative or absolute.
        rgb_to_hsl(_r, _g, _b)

        # A leading '+' or '-' in the raw string means relative adjustment:
        # op_val is treated as a signed offset in 0.0-1.0 units added to
        # the current lightness. Without a sign prefix, it is an absolute
        # target (0.0 = black, 0.5 = mid, 1.0 = white).
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
      else if (op_name == "hue") {
        # Double modulo to handle negative rotations cleanly.
        _h = ((_h + op_val) % 360.0 + 360.0) % 360.0
      }

    } else if (fmt == "hwb") {

      if      (op_name == "whiten")  _w  = clamp(_w + op_val, 0, 100)
      else if (op_name == "blacken") _bk = clamp(_bk + op_val, 0, 100)
      else if (op_name == "hue") {
        _h = ((_h + op_val) % 360.0 + 360.0) % 360.0
      }

    } else if (fmt == "cmyk") {

      if      (op_name == "cyan")    _c = clamp(_c + op_val, 0, 100)
      else if (op_name == "magenta") _m = clamp(_m + op_val, 0, 100)
      else if (op_name == "yellow")  _y = clamp(_y + op_val, 0, 100)
      else if (op_name == "key")     _k = clamp(_k + op_val, 0, 100)

    }
  }

  # Emit the result in the same format as the base key.
  if (fmt == "hex") {
    if (hex_modified) {
      # Re-encode the modified channels and apply the same prefix/casing
      # that the original variant used, so the output stays a drop-in
      # replacement for what the plain (no-pipe) key would have produced.
      rebuilt = int_to_hex2(_r) int_to_hex2(_g) int_to_hex2(_b) (has_alpha ? alpha_str : "")
      if      (hex_variant == "strip") return rebuilt
      else if (hex_variant == "upper") return "#" toupper(rebuilt)
      else if (hex_variant == "0x")    return "0x" rebuilt
      else                             return "#" rebuilt
    }
    return color_val (has_alpha ? alpha_str : "")
  }

  if (fmt == "rgb") {
    if (has_alpha) return _r "," _g "," _b "," alpha_str
    return _r "," _g "," _b
  }

  if (fmt == "hsl") {
    # Round to integers to match the format bash emits.
    return int(_h + 0.5) "," int(_s + 0.5) "," int(_l + 0.5)
  }

  if (fmt == "hwb") {
    return int(_h + 0.5) "," int(_w + 0.5) "%," int(_bk + 0.5) "%"
  }

  if (fmt == "cmyk") {
    return int(_c + 0.5) "%," int(_m + 0.5) "%," int(_y + 0.5) "%," int(_k + 0.5) "%"
  }

  return ""
}

# Scan 'line' for any {{ ... | ... }} tokens that survived the literal
# substitution pass (meaning they are computed expressions, not plain keys)
# and resolve them one by one, left to right.
#
# Tokens without '|' that are still unresolved are left verbatim so that
# unknown keys remain visible rather than silently disappearing.
#
function resolve_pipe_exprs(line,    result, rest, open_pos, close_pos, full_tok, inner, resolved) {
  result = ""
  rest   = line

  while (1) {
    open_pos = index(rest, "{{")
    if (open_pos == 0) { result = result rest; break }

    result = result substr(rest, 1, open_pos - 1)
    rest   = substr(rest, open_pos)

    close_pos = index(rest, "}}")
    if (close_pos == 0) { result = result rest; break }

    # Capture the full token including its delimiters.
    full_tok = substr(rest, 1, close_pos + 1)

    # Isolate the inner content: skip the leading "{{" (2 chars), read up
    # to but not including "}}"; the length is therefore close_pos - 3.
    inner = substr(rest, 3, close_pos - 3)
    sub(/^[[:space:]]+/, "", inner)
    sub(/[[:space:]]+$/, "", inner)

    if (index(inner, "|") > 0) {
      resolved = resolve_pipe_expr(inner)
      # On failure, preserve the original token so the error stays visible.
      result = result (resolved != "" ? resolved : full_tok)
    } else {
      # No pipe operator: not a computed expression, leave it untouched.
      result = result full_tok
    }

    rest = substr(rest, close_pos + 2)
  }

  return result
}

FILENAME == ARGV[1] {
  sep = index($0, "\x01")
  subs[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

FILENAME == ARGV[2] {
  sep = index($0, "\x01")
  outmap[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

FNR == 1 { outfile = outmap[FILENAME] }

{
  line = $0
  # Pass 1: fast literal substitution from the pre-built subs table.
  for (k in subs) line = lit_replace(line, k, subs[k])
  # Pass 2: evaluate any remaining computed pipe expressions.
  line = resolve_pipe_exprs(line)
  print line > outfile
}
