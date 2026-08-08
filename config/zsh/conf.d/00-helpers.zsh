
# Colors
BLK=$'\e[30m' # black
RED=$'\e[31m' # red
GRN=$'\e[32m' # green
YEL=$'\e[33m' # yellow
BLU=$'\e[34m' # blue
MAG=$'\e[35m' # magenta
CYN=$'\e[36m' # cyan
WHT=$'\e[37m' # white

# Bright colors
GRY=$'\e[90m' # bright black (grey)
BRD=$'\e[91m' # bright red
BGR=$'\e[92m' # bright green
BYL=$'\e[93m' # bright yellow
BBL=$'\e[94m' # bright blue
BMG=$'\e[95m' # bright magenta
BCY=$'\e[96m' # bright cyan
BWH=$'\e[97m' # bright white

# Styles
BLD=$'\e[1m' # bold
DIM=$'\e[2m' # dim
ITL=$'\e[3m' # italic
UND=$'\e[4m' # underline
BLN=$'\e[5m' # blink
REV=$'\e[7m' # reverse
HID=$'\e[8m' # hidden
STR=$'\e[9m' # strikethrough

# Resets
RST=$'\e[0m'   # all
RBLD=$'\e[22m' # bold/dim off
RITL=$'\e[23m' # italic off
RUND=$'\e[24m' # underline off
RBLN=$'\e[25m' # blink off
RREV=$'\e[27m' # reverse off
RHID=$'\e[28m' # hidden off
RSTR=$'\e[29m' # strikethrough off

# Replaces `cat`
function print() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done
}
