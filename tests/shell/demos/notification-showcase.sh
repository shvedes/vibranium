#!/bin/bash

# One card per notification feature the Vibranium shell reads, posted at the
# running notification daemon.
#
# The daemon is Quickshell's NotificationServer, configured by
# shell/features/notifications/Notifications.qml, so everything here goes over
# the org.freedesktop.Notifications session bus and lands in the notification
# pile as a card.
#
# What each case exercises, and where the shell reads it:
#
#   app name, summary, body   the Notify call itself
#   actions                    a flat id/label array. Two or more draw buttons;
#                              one draws no button and is reached by the body
#                              click instead (NotificationCard.qml)
#   app icon                   the app_icon field, resolved by AppIcons: the
#                              shell's own glyph set first, then the platform
#                              icon theme
#   icon tone                  x-vb-icon-color, a palette KEY and not a hex, so
#                              the glyph is recolored against the live palette
#   image                      the image field, drawn as artwork beside the body
#   image-data                 a raw pixmap tuple, and the only way to ship a
#                              real bitmap: an image path is looked up as an
#                              icon NAME and never read as a file
#   progress                   the value/progress hint, a fraction or a percent
#   volume lane                x-vb-vol and x-vb-vol-muted
#   urgency                    0 low, 1 normal, 2 critical. Critical is red and
#                              never expires
#   lifetime                   expire_timeout in MILLISECONDS, 0 never expires
#   transient, resident        the standard lifetime hints
#   desktop-entry              the .desktop basename, used to focus the sender
#   hide-meta                  x-vb-hide-meta, an OSD-style card
#   replace tag                x-vb-tag, x-dunst-stack-tag and
#                              x-canonical-private-synchronous, three names
#                              for one slot
#   replace id                 the replaces_id field
#
# Two transports, because notify-send cannot express everything: the action
# cards go over busctl because notify-send's --action implies --wait and would
# block until the card closed, and the raw pixmap goes over busctl because it
# is a struct on the wire.
#
# Usage:
#   tests/shell/demos/notification-showcase.sh            # dry run
#   tests/shell/demos/notification-showcase.sh --send     # post the cards
#   tests/shell/demos/notification-showcase.sh --send --only progress
#
# The dry run is the default because the cards appear on the user's desktop and
# a critical card is, by design, persistent.

_VB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../bin" && pwd)"
source "$_VB_BIN/vb-lib-cli"

VIBRANIUM="$(dirname "$_VB_BIN")"
SHELL_DIR="$VIBRANIUM/shell"

VERBOSE=${VERBOSE:-false}
SELF="${0##*/}"

SEND=false
LIST=false
KEEP=false
ONLY=""
DELAY=1.0
DWELL=4.0

# Counters, reported at the end of the run.
PLANNED=0
CARDS=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
SEND_ERRORS=0

# The id of the last card posted, which the replace-by-id case reuses, and
# every id posted, which the wave dismissal walks.
LAST_ID=""
POSTED_IDS=()

# The stderr of the last send, kept out of the stdout the id is read from.
ERR_FILE=""

if [[ -t 1 && -z "${NO_COLOR+x}" ]]; then
  BOLD=$'\e[1m'
  DIM=$'\e[90m'
  GREEN=$'\e[32m'
  RED=$'\e[31m'
  YELLOW=$'\e[33m'
  RESET=$'\e[0m'
else
  BOLD=""
  DIM=""
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

usage() {
  shcat << EOF
Usage: $SELF [OPTIONS]

Posts one notification per feature the Vibranium shell reads, at the running
notification daemon (org.freedesktop.Notifications on the session bus).

Options:
      --send            Post the cards. Without it, only the calls that would
                        be made are printed.
      --only PATTERN    Run only the cases whose name matches PATTERN (glob).
      --delay SECONDS   Pause between two cases (default 1.0).
      --dwell SECONDS   How long a wave stays up before it is dismissed
                        (default 4.0). The pile holds eight cards, so a wave
                        is cleared before the next one starts.
      --keep            Do not dismiss the waves; leave every card up.
      --list            Print the case catalogue and exit.
  -v, --verbose           Enable verbose output
  -h, --help              Show this help message and exit
EOF
}

while (($# > 0)); do
  case "$1" in
    --send)
      SEND=true
      shift
      ;;
    --keep)
      KEEP=true
      shift
      ;;
    --list)
      LIST=true
      shift
      ;;
    --only)
      if [[ $# -lt 2 ]]; then
        log Error "--only needs a pattern"
        usage
        exit 1
      fi
      ONLY="$2"
      shift 2
      ;;
    --delay)
      if [[ $# -lt 2 ]]; then
        log Error "--delay needs a number of seconds"
        usage
        exit 1
      fi
      DELAY="$2"
      shift 2
      ;;
    --dwell)
      if [[ $# -lt 2 ]]; then
        log Error "--dwell needs a number of seconds"
        usage
        exit 1
      fi
      DWELL="$2"
      shift 2
      ;;
    -v | --verbose)
      export VERBOSE=true
      shift
      ;;
    -h | --help | "")
      usage
      exit 0
      ;;
    *)
      log Error "unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# --- transports ------------------------------------------------------------

# The argv a busctl Notify call is built into, so a case can hand it to post()
# the same way a notify-send case hands over its own argv.
BUSCTL_ARGV=()

# The action list of a card that offers none. busctl_notify reads the list
# through a nameref, so it needs a name to point at.
# shellcheck disable=SC2034
NO_ACTIONS=()

# busctl_notify <app_icon> <summary> <body> <timeout> <hint_count> <actions> <hints>
#
# The interface fixes the argument order (susssasa{sv}i): app name, replaces
# id, app icon, summary, body, actions, hints, timeout. The actions and the
# hints arrive through namerefs: an action is an id/label pair and a hint is a
# key/type/value triple, which is the shape busctl's own parser expects.
#
# busctl wants the length of every array and dictionary spelled out before its
# elements, so the action count is the length of the action list and the hint
# count is passed in: a hint's own value can be a whole struct, so the length
# of the hint list is not the number of entries in it.
busctl_notify() {
  local app_icon="$1" summary="$2" body="$3" timeout="$4" hint_count="$5"
  local -n _actions="$6"
  local -n _hints="$7"
  BUSCTL_ARGV=(
    busctl --user call org.freedesktop.Notifications
    /org/freedesktop/Notifications org.freedesktop.Notifications Notify
    "susssasa{sv}i" "Vibranium Showcase" 0 "$app_icon" "$summary" "$body"
    "${#_actions[@]}" "${_actions[@]}"
    "$hint_count" "${_hints[@]}"
    "$timeout"
  )
}

# The raw RGBA pixels of a small gradient, as the count-prefixed byte array
# busctl wants for an "ay" field.
#
# The tuple the daemon reads is (width, height, rowstride, has_alpha,
# bits_per_sample, channels, data), and the data is the pixels in RGBA order.
# Eight by eight keeps the argv short: a busctl "ay" is one argv element per
# byte, so a card-sized image would be four thousand of them.
_pixmap_bytes() {
  local size=8
  local -a pixels=()
  local x y
  for ((y = 0; y < size; y++)); do
    for ((x = 0; x < size; x++)); do
      pixels+=("$((x * 32))" "$((y * 32))" "180" "255")
    done
  done
  printf '%s\n' "$((size * size * 4))" "${pixels[@]}"
}

# --- the shell's side ------------------------------------------------------

# The history the daemon keeps, as JSON.
#
# The reply is retried and then validated rather than trusted: the IPC
# channel answers "Not ready to accept queries yet." while the shell is busy
# - resolving an icon, for one - and that is a hiccup in the check, not a
# broken feature.
#
# The retries are spent once. A shell that answered "not ready" to eight
# queries is not answering, and every later check would spend the same two
# seconds finding out.
HISTORY_DOWN=false

_history_json() {
  local attempt=0
  local json
  if [[ "$HISTORY_DOWN" == true ]]; then
    return 1
  fi
  while ((attempt < 8)); do
    attempt=$((attempt + 1))
    json="$(qs -p "$SHELL_DIR" ipc call notifications history 2>/dev/null)" || json=""
    if [[ "$json" == "["* ]]; then
      printf '%s' "$json"
      return 0
    fi
    sleep 0.25
  done
  HISTORY_DOWN=true
  return 1
}

# check <id> <jq-expression>
#
# The expression is evaluated against the history row of that server id and
# must answer true. A missing jq or a shell that is not answering skips the
# check rather than failing it: an absent tool is not a broken feature.
check() {
  local id="$1" expression="$2"
  local json value
  if [[ "$SEND" != true ]]; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    log Info "skipped check for id $id: jq is not on PATH"
    return 0
  fi
  if ! json="$(_history_json)"; then
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    log Info "skipped check for id $id: the shell is not answering"
    return 0
  fi
  # The row is looked up by id and the expression is run against it, so a
  # false answer is a failure and not a missing row.
  if ! value="$(jq -r --argjson id "$id" \
    'map(select(.id == $id)) | .[0] | if . == null then "no row" else ('"$expression"') end' \
    <<<"$json" 2>"$ERR_FILE")"; then
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    log Info "skipped check for id $id: $(<"$ERR_FILE")"
    return 0
  fi
  if [[ "$value" == "true" ]]; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    return 0
  fi
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  printf '    %sFAILED%s id %s: %s answered %s\n' \
    "$RED" "$RESET" "$id" "$expression" "${value:-nothing}" >&2
  return 1
}

# check_all <jq-expression>
#
# An assertion about the whole history rather than about one row: one tag
# keeping one row is a property of the list, not of a single snapshot.
check_all() {
  local expression="$1"
  local json value
  if [[ "$SEND" != true ]]; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    log Info "skipped a history check: jq is not on PATH"
    return 0
  fi
  if ! json="$(_history_json)"; then
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    log Info "skipped a history check: the shell is not answering"
    return 0
  fi
  if ! value="$(jq -r '('"$expression"')' <<<"$json" 2>"$ERR_FILE")"; then
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    log Info "skipped a history check: $(<"$ERR_FILE")"
    return 0
  fi
  if [[ "$value" == "true" ]]; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    return 0
  fi
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  printf '    %sFAILED%s %s answered %s\n' \
    "$RED" "$RESET" "$expression" "${value:-nothing}" >&2
  return 1
}

# The argv as a copy-pasteable command line.
#
# A long argv is elided in the middle rather than at the end: the pixmap case
# carries a thousand argv elements, and the interesting ones - the program, the
# signature, the app name, the summary, the timeout - are at the two ends.
_print_cmd() {
  local -a argv=("$@")
  local count=${#argv[@]}
  local -a shown=()
  local i
  if ((count > 24)); then
    for ((i = 0; i < 12; i++)); do
      shown+=("${argv[$i]}")
    done
    shown+=("...")
    for ((i = count - 12; i < count; i++)); do
      shown+=("${argv[$i]}")
    done
  else
    shown=("${argv[@]}")
  fi

  local arg out=""
  for arg in "${shown[@]}"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      out+="${out:+ }$arg"
    else
      out+="${out:+ }'${arg//\'/\'\\\'\'}'"
    fi
  done
  printf '%s' "$out"
}

# post <label> <expectation> <argv...>
#
# The expectation is a jq expression over the history row of the card that was
# posted, and is empty when the snapshot has nothing to say about the case. An
# empty expectation is not a skipped check: it is a fact about what the
# daemon records, not about the daemon.
post() {
  local label="$1" expectation="$2"
  shift 2
  local output="" errors="" rc=0 id=""

  PLANNED=$((PLANNED + 1))
  printf '    %s%s%s\n' "$DIM" "$(_print_cmd "$@")" "$RESET"

  if [[ "$SEND" != true ]]; then
    return 0
  fi

  # stderr is kept apart: the server id is read off stdout, and a warning on
  # stderr must not be mistaken for one.
  : >"$ERR_FILE"
  output="$("$@" 2>"$ERR_FILE")"
  rc=$?
  errors="$(<"$ERR_FILE")"
  if ((rc != 0)); then
    SEND_ERRORS=$((SEND_ERRORS + 1))
    printf '    %sFAILED%s %s %s\n' "$RED" "$RESET" "$label" "$errors" >&2
    return 1
  fi
  if [[ -n "$errors" ]]; then
    log Info "$label: $errors"
  fi

  # The server id is the last field of the output: notify-send -p prints it
  # bare, busctl prints "u 15".
  id="${output##*[[:space:]]}"
  id="${id//[^0-9]/}"
  if [[ -z "$id" ]]; then
    SEND_ERRORS=$((SEND_ERRORS + 1))
    printf '    %sFAILED%s %s: no server id in %s\n' \
      "$RED" "$RESET" "$label" "$output" >&2
    return 1
  fi

  LAST_ID="$id"
  POSTED_IDS+=("$id")
  CARDS=$((CARDS + 1))
  printf '    %s->%s id %s\n' "$GREEN" "$RESET" "$id"

  if [[ -n "$expectation" ]]; then
    check "$id" "$expectation"
  fi
  return 0
}

# --- the cases -------------------------------------------------------------
#
# One function per case. The name is the case name with the dashes turned
# into underscores, and the catalogue below lists them in the order they run.

case_plain() {
  post "plain" '.appName == "Vibranium Showcase" and .summary == "Plain notification"' \
    notify-send -p -a "Vibranium Showcase" "Plain notification" \
    "A card with nothing on it but a title and a body."
}

case_summary_only() {
  post "summary-only" '.body == ""' \
    notify-send -p -a "Vibranium Showcase" "Summary only" ""
}

case_rich_body() {
  post "rich-body" '.body | contains("<b>bold</b>")' \
    notify-send -p -a "Vibranium Showcase" "Rich body" \
    "Body with <b>bold</b>, <i>italic</i> and a <a href=\"https://example.com\">hyperlink</a>."
}

case_long_body() {
  post "long-body" '.body | contains("\n")' \
    notify-send -p -a "Vibranium Showcase" "Long body" \
    "line one
line two
line three
line four
line five
line six
line seven
line eight
line nine
line ten"
}

case_app_icon_theme() {
  post "app-icon-theme" '.appIcon == "firefox"' \
    notify-send -p -a "Firefox" -n "firefox" "App icon from the icon theme" \
    "The app_icon field, looked up in the user's icon theme."
}

case_app_icon_shipped() {
  post "app-icon-shipped" '.appIcon == "update"' \
    notify-send -p -a "Vibranium" -n "update" "App icon from the shell's glyphs" \
    "The shell's own SVG set is tried before the platform theme."
}

case_app_icon_tone() {
  post "app-icon-tone" '.appIcon == "update" and .iconColor == "orange"' \
    notify-send -p -a "Vibranium" -n "update" \
    -h string:x-vb-icon-color:orange "Tinted app icon" \
    "The tone is a palette key, so the glyph follows a theme switch."
}

case_desktop_entry() {
  post "desktop-entry" '.desktopEntry == "org.gnome.Terminal.desktop"' \
    notify-send -p -a "Terminal" -h string:desktop-entry:org.gnome.Terminal.desktop \
    "Desktop entry" "A body click matches this against the open windows."
}

case_image_icon_name() {
  post "image-icon-name" '.image | startswith("image://icon/")' \
    notify-send -p -a "Vibranium Showcase" -i "firefox" "Provided image" \
    "The image field is an icon NAME; an absolute path is not read as a file."
}

case_image_pixmap() {
  local -a hints=("image-data" "(iiibiiay)" "8" "8" "32" "1" "8" "4")
  mapfile -t pixels < <(_pixmap_bytes)
  hints+=("${pixels[@]}")
  busctl_notify "" "Raw pixmap" "The only way to ship a real bitmap." 2000 1 \
    NO_ACTIONS hints
  post "image-pixmap" '.image | startswith("image://qsimage/")' \
    "${BUSCTL_ARGV[@]}"
}

case_action_two() {
  local -a actions=("reply" "Reply" "archive" "Archive")
  local -a hints=()
  busctl_notify "" "Two action buttons" \
    "Two or more actions draw a button row." 0 0 actions hints
  post "action-two" \
    '(.actions | length) == 2 and .actions[0].identifier == "reply"' \
    "${BUSCTL_ARGV[@]}"
}

case_action_single() {
  local -a actions=("open" "Open")
  local -a hints=()
  busctl_notify "" "One action, no button" \
    "A single action draws no button; the body click is the activation." 0 0 \
    actions hints
  post "action-single" '(.actions | length) == 1' "${BUSCTL_ARGV[@]}"
}

case_action_default() {
  # The list is read through a nameref, which shellcheck cannot see through.
  # shellcheck disable=SC2034
  local -a actions=("default" "Default action" "cancel" "Cancel")
  local -a hints=()
  busctl_notify "" "The default action" \
    "'default' is an ordinary identifier here, not a special one." 0 0 \
    actions hints
  post "action-default" '.actions[0].identifier == "default"' \
    "${BUSCTL_ARGV[@]}"
}

case_progress_fraction() {
  post "progress-fraction" '.progress == 0.42' \
    notify-send -p -a "Vibranium Showcase" -h double:value:0.42 \
    "Progress, fraction" "The value hint is a fraction by contract."
}

case_progress_percent() {
  post "progress-percent" '.progress == 0.42' \
    notify-send -p -a "Vibranium Showcase" -h int:value:42 \
    "Progress, percent" "A value above 1 is read as a percent and scaled down."
}

case_progress_zero() {
  post "progress-zero" '.progress == 0' \
    notify-send -p -a "Vibranium Showcase" -h double:value:0 \
    "Progress, empty" "Zero is a real bar; -1 is no bar at all."
}

case_progress_full() {
  post "progress-full" '.progress == 1' \
    notify-send -p -a "Vibranium Showcase" -h double:value:1 \
    "Progress, full" "The bar clamps at a full width."
}

case_volume() {
  post "volume" '.vol == 73 and .volMuted == false' \
    notify-send -p -a "Vibranium Showcase" -h int:x-vb-vol:73 \
    "Volume" "The lane replaces the generic bar and carries its own icon."
}

case_volume_muted() {
  post "volume-muted" '.vol == 40 and .volMuted == true' \
    notify-send -p -a "Vibranium Showcase" -h int:x-vb-vol:40 \
    -h boolean:x-vb-vol-muted:true "Volume, muted" \
    "A muted lane keeps filling and takes the red accent."
}

case_urgency_low() {
  post "urgency-low" '.urgency == 0' \
    notify-send -p -a "Vibranium Showcase" -u low "Low urgency" \
    "Low and normal draw the same face; only critical is styled."
}

case_urgency_normal() {
  post "urgency-normal" '.urgency == 1' \
    notify-send -p -a "Vibranium Showcase" -u normal "Normal urgency" \
    "The default urgency."
}

case_urgency_critical() {
  post "urgency-critical" '.urgency == 2' \
    notify-send -p -a "Vibranium Showcase" -u critical "Critical urgency" \
    "A critical card never expires, whatever timeout it asked for."
}

case_timeout_zero() {
  post "timeout-zero" '.expireTimeout == 0' \
    notify-send -p -a "Vibranium Showcase" -t 0 "Never expires" \
    "Zero means no deadline at all."
}

case_timeout_short() {
  post "timeout-short" '.expireTimeout == 2000' \
    notify-send -p -a "Vibranium Showcase" -t 2000 "Two seconds" \
    "The timeout is milliseconds, not seconds."
}

case_transient() {
  post "transient" "" \
    notify-send -p -a "Vibranium Showcase" -e "Transient" \
    "The daemon does not act on it, but the hint is on the wire."
}

case_resident() {
  post "resident" "" \
    notify-send -p -a "Vibranium Showcase" -h boolean:resident:true "Resident" \
    "A resident card survives an action invocation."
}

case_hide_meta() {
  post "hide-meta" '.hideMeta == true' \
    notify-send -p -a "Vibranium Showcase" -h boolean:x-vb-hide-meta:true \
    "No clock, no sender" "The meta line is hidden for this card alone."
}

case_replace_tag() {
  local -a hints=("x-vb-tag" "s" "showcase-tag")
  busctl_notify "" "Replace tag, first" \
    "A second card with the same tag replaces this one." 0 1 NO_ACTIONS hints
  post "replace-tag" '.replaceTag == "showcase-tag"' "${BUSCTL_ARGV[@]}"

  busctl_notify "" "Replace tag, second" \
    "The same card, new content: one card and one history row." 0 1 NO_ACTIONS hints
  post "replace-tag again" '.replaceTag == "showcase-tag"' "${BUSCTL_ARGV[@]}"

  # The tag is the notification's identity, so the replacement is one row and
  # not two.
  check_all '[.[] | select(.replaceTag == "showcase-tag")] | length == 1'
}

case_replace_dunst_tag() {
  local -a hints=("x-dunst-stack-tag" "s" "showcase-dunst-tag")
  busctl_notify "" "Dunst stack tag" \
    "The conventional name for the same slot." 0 1 NO_ACTIONS hints
  post "replace-dunst-tag" '.replaceTag == "showcase-dunst-tag"' \
    "${BUSCTL_ARGV[@]}"
}

case_replace_canonical_tag() {
  local -a hints=("x-canonical-private-synchronous" "s" "showcase-mako-tag")
  busctl_notify "" "Canonical private synchronous" \
    "The mako/notify-osd alias for the same slot." 0 1 NO_ACTIONS hints
  post "replace-canonical-tag" '.replaceTag == "showcase-mako-tag"' \
    "${BUSCTL_ARGV[@]}"
}

case_replace_id() {
  post "replace-id" "" \
    notify-send -p -a "Vibranium Showcase" "Replace id" \
    "The card before this one, replaced in place."
  if [[ -z "$LAST_ID" ]]; then
    return 0
  fi
  post "replace-id again" '.revisions >= 1' \
    notify-send -p -r "$LAST_ID" -a "Vibranium Showcase" "Replace id, again" \
    "The same card, new content."
}

# The catalogue, in the order the cases run. Each entry is "name|note", and
# a "---" entry ends a wave.
CATALOGUE=(
  "plain|app name, summary, body, the daemon's default timeout"
  "summary-only|a title with no body at all"
  "rich-body|markup and a hyperlink in the body"
  "long-body|a body past the card's six-line cap"
  "---"
  "app-icon-theme|app_icon resolved from the platform icon theme"
  "app-icon-shipped|app_icon resolved from the shell's own glyph set"
  "app-icon-tone|the same glyph, tinted through x-vb-icon-color"
  "desktop-entry|the .desktop basename, for focusing the sender"
  "image-icon-name|the image field, drawn beside the body"
  "image-pixmap|a raw pixmap tuple, sent as image-data"
  "---"
  "action-two|two actions, drawn as buttons"
  "action-single|one action, reached by the body click"
  "action-default|the 'default' action identifier"
  "---"
  "progress-fraction|a progress bar from a fraction"
  "progress-percent|the same bar from a percent-scale value"
  "progress-zero|a bar at 0%, which is not the same as no bar"
  "progress-full|a bar at 100%"
  "volume|the volume lane, in place of the progress bar"
  "volume-muted|the volume lane, muted"
  "---"
  "urgency-low|urgency 0"
  "urgency-normal|urgency 1"
  "urgency-critical|urgency 2, red and persistent"
  "timeout-zero|expire_timeout 0, never expires"
  "timeout-short|expire_timeout in milliseconds"
  "transient|the transient hint"
  "resident|the resident hint"
  "---"
  "hide-meta|an OSD-style card with no meta line"
  "replace-tag|x-vb-tag, the shell's own name for the slot"
  "replace-dunst-tag|x-dunst-stack-tag, the conventional name"
  "replace-canonical-tag|x-canonical-private-synchronous, the alias"
  "replace-id|the replaces_id field"
)

# The hints the daemon ignores. Printed at the end of the run, because a
# sender that sets one of these gets no card change and no warning.
IGNORED_HINTS=(
  "sound, sound-name, suppress-sound: the daemon plays no sound"
  "category: carried by notify-send, read by nobody"
  "action-icons: the card draws no action icons"
  "x-kde-url, x-kde-icon-name: not read"
  "activation-token: the daemon does not offer one"
)

# --- the run ---------------------------------------------------------------

_selected() {
  local name="$1"
  [[ -z "$ONLY" ]] && return 0
  # The pattern is meant to glob, so it is deliberately unquoted on the right
  # hand side of the comparison.
  # shellcheck disable=SC2053
  [[ "$name" == $ONLY ]]
}

if [[ "$LIST" == true ]]; then
  printf '%snotification showcase - the case catalogue%s\n\n' "$BOLD" "$RESET"
  for entry in "${CATALOGUE[@]}"; do
    if [[ "$entry" == "---" ]]; then
      printf '\n'
      continue
    fi
    printf '  %-24s %s\n' "${entry%%|*}" "$DIM${entry#*|}$RESET"
  done
  printf '\n'
  exit 0
fi

if [[ "$SEND" == true ]]; then
  if ! busctl --user introspect org.freedesktop.Notifications \
    /org/freedesktop/Notifications >/dev/null 2>&1; then
    log Error "the notification daemon is not answering on the session bus"
    exit 1
  fi
  ERR_FILE="$(mktemp)"
  trap 'rm -f "$ERR_FILE"' EXIT
fi

printf '%snotification showcase%s %s\n' "$BOLD" "$RESET" \
  "$DIM$([[ "$SEND" == true ]] && echo "posting" || echo "dry run - pass --send to post")$RESET"
printf '%sthe daemon holds eight cards, so a wave is dismissed before the next one starts%s\n' \
  "$DIM" "$RESET"
printf '\n'

WAVE=1
WAVE_START=0

_dismiss_wave() {
  local id
  local i
  ((${#POSTED_IDS[@]} == WAVE_START)) && return 0
  if [[ "$SEND" != true ]]; then
    WAVE_START=${#POSTED_IDS[@]}
    return 0
  fi
  printf '  %swave %d dismissed%s\n' "$DIM" "$WAVE" "$RESET"
  for ((i = WAVE_START; i < ${#POSTED_IDS[@]}; i++)); do
    id="${POSTED_IDS[$i]}"
    qs -p "$SHELL_DIR" ipc call notifications dismiss "$id" >/dev/null 2>&1
  done
  WAVE_START=${#POSTED_IDS[@]}
}

for entry in "${CATALOGUE[@]}"; do
  if [[ "$entry" == "---" ]]; then
    if [[ "$KEEP" != true && "$SEND" == true ]]; then
      sleep "$DWELL"
      _dismiss_wave
    fi
    WAVE=$((WAVE + 1))
    continue
  fi

  name="${entry%%|*}"
  note="${entry#*|}"
  _selected "$name" || continue

  fn="case_${name//-/_}"
  if ! declare -F "$fn" >/dev/null; then
    log Error "no such case: $name"
    continue
  fi

  printf '  %s%-24s%s %s\n' "$BOLD" "$name" "$RESET" "$DIM$note$RESET"
  "$fn"

  if [[ "$SEND" == true && "$DELAY" != "0" ]]; then
    sleep "$DELAY"
  fi
done

if [[ "$KEEP" != true && "$SEND" == true ]]; then
  sleep "$DWELL"
  _dismiss_wave
fi

printf '\n'
if [[ "$SEND" == true ]]; then
  printf '%s%d card(s) posted%s' "$BOLD" "$CARDS" "$RESET"
  ((SEND_ERRORS > 0)) && printf ', %s%d refused%s' "$RED" "$SEND_ERRORS" "$RESET"
  printf ', %s%d check(s) passed%s' "$GREEN" "$CHECKS_PASSED" "$RESET"
  ((CHECKS_FAILED > 0)) && printf ', %s%d check(s) failed%s' "$RED" "$CHECKS_FAILED" "$RESET"
  ((CHECKS_SKIPPED > 0)) && printf ', %s%d check(s) skipped%s' "$YELLOW" "$CHECKS_SKIPPED" "$RESET"
  printf '\n'
else
  printf '%s%d call(s) would be posted%s\n' "$BOLD" "$PLANNED" "$RESET"
fi

printf '%sthe daemon ignores these hints, so setting them changes nothing:%s\n' "$DIM" "$RESET"
for hint in "${IGNORED_HINTS[@]}"; do
  printf '  %s\n' "$hint"
done
printf '\n'

if ((CHECKS_FAILED > 0 || SEND_ERRORS > 0)); then
  exit 1
fi
