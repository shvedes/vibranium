#!/bin/bash
# Suite: byte-exact help pages for `app` and its branches. The fake transport
# supplies the descriptors the catalog/AppHost now publish; the client must
# render them exactly as the authoritative snapshots.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "app-help-golden" "four byte-exact app help pages and no Output sections"

CLIENT="$VIBRANIUM_DIR/bin/vb-shell"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-app-help.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export PATH="$TESTS_SHELL_DIR/suites/cli/fixtures:$PATH"
export VIBRANIUM="$VIBRANIUM_DIR"
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/opencode/vb-app-help-pycache"

export FAKE_QS_MODE=""

check_page() {
  local label="$1" mode="$2" golden="$3"
  FAKE_QS_MODE="$mode"
  python3 -B "$CLIENT" app >"$WORK/out" 2>"$WORK/err"
  t_status "$label exits 0" 0 python3 -B "$CLIENT" app
  t_eq "$label has no stderr" "" "$(cat "$WORK/err")"
  t_eq "$label matches the snapshot byte for byte" "0" "$(cmp -s "$WORK/out" "$golden"; echo $?)"
  t_eq "$label ends with one LF" "1" "$(python3 - "$WORK/out" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(1 if b.endswith(b'\n') and not b.endswith(b'\n\n') else 0)
PY
)"
  t_eq "$label has no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/out")"
  t_not_contains "$label has no Output section" "Output:" "$(cat "$WORK/out")"
  t_not_contains "$label has no Arguments section" "Arguments:" "$(cat "$WORK/out")"
}

cat >"$WORK/golden1" <<'EOF'
Usage: vb-shell app

Manage Vibranium's Quickshell apps

Commands:
  list    List all known apps
  open    Open ID
  close   Close ID
  toggle  Toggle ID window
  call    Manipulate ID with its IPC

Notes:
  Use 'vb-shell app call help' to see available per-app calls
EOF

cat >"$WORK/golden2" <<'EOF'
Usage: vb-shell app call <ID>

Explicit per-app commands

Commands:
  list <ID>  List supported commands for ID

Notes:
  Use 'vb-shell app list' to see available apps

Examples:
  vb-shell app call list audioMixer
  vb-shell app call audioMixer help
EOF

cat >"$WORK/golden3" <<'EOF'
Usage: vb-shell app call audioMixer

Audio mixer: native Pavucontrol replacement, with Pipewire node graph included

Commands:
  openTab   <TAB>  Open audioMixer with <TAB> focused
  selectTab <TAB>  Select a <TAB> in existing window
  status           audioMixer status

Notes:
  Valid tab ids are: apps, devices, recording, configuration, graph

Examples:
  vb-shell app call audioMixer openTab configuration
  vb-shell app call audioMixer selectTab devices
  vb-shell app call audioMixer status
EOF

cat >"$WORK/golden4" <<'EOF'
Usage: vb-shell app call imageViewer

A simple, Vibranium-native image viewer

Commands:
  openPath <PATH>  Open an image in <PATH>
  status           ImageViewer status

Examples:
  vb-shell app call imageViewer openPath /home/user/Pictures/my-image.png
  vb-shell app call imageViewer status
EOF

t_section "snapshot 1 - vb-shell app"
check_page "the app page" golden-app "$WORK/golden1"
t_not_contains "a target root never prints Examples" "Examples:" "$(cat "$WORK/out")"

t_section "snapshot 2 - vb-shell app call"
check_page "the call branch" golden-app-call "$WORK/golden2"

t_section "snapshot 3 - vb-shell app call audioMixer"
check_page "the audio mixer page" golden-app-mixer "$WORK/golden3"

t_section "snapshot 4 - vb-shell app call imageViewer"
check_page "the image viewer page" golden-app-viewer "$WORK/golden4"

t_section "audio volume options share one column (no placeholder on toggle/get)"
cat >"$WORK/golden-volume" <<'EOF'
Usage: vb-shell audio volume

Default output level and mute

Commands:
  up    [step <N>]  Raise the default output volume
  down  [step <N>]  Lower the default output volume
  toggle            Mute or unmute the default output
  get               Get current default output level
  set   <N>         Set the output level, 0-200 percent

Examples:
  vb-shell audio volume up step 10
EOF
check_page "the volume controller" golden-audio-volume "$WORK/golden-volume"
t_eq "up/down/set options share the toggle column" "1" \
  "$(python3 - "$WORK/out" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Commands:') + 1
block = lines[start:start + 5]
cols = set()
for line in block:
    places = [p for p in (line.find('<'), line.find('[')) if p >= 0]
    if places:
        cols.add(min(places))
bare = [len(line[:len(line) - len(line.lstrip()) + 6]) for line in block
        if '<' not in line and '[' not in line]
print(1 if len(cols) == 1 and all(c == next(iter(cols)) for c in bare) else 0)
PY
)"

t_section "root clipboard shows controllers only"
cat >"$WORK/golden-clip-root" <<'EOF'
Usage: vb-shell clipboard

clipboard history and system selection

Commands:
  window  Control the clipboard panel
  list    List clipboard rows by bucket
  pin     Pin one normal-bucket row
  unpin   Unpin one pinned-bucket row
  purge   Delete one row by bucket
  clear   Clear one bucket
  select  Seat one row of the open panel's current filter
  copy    Write new data to the system clipboard from the terminal
EOF
check_page "the clipboard root" golden-clipboard-root "$WORK/golden-clip-root"
t_eq "root clipboard has exactly one window row" "1" "$(grep -c '^  window ' "$WORK/out")"
t_eq "root clipboard has no window children" "0" \
  "$(grep -Ec '^  window (open|close|toggle)' "$WORK/out")"
t_eq "root clipboard has no placeholders" "0" "$(grep -c '[<[]' "$WORK/out")"

t_section "clipboard controller help pages"
cat >"$WORK/golden-clip-window" <<'EOF'
Usage: vb-shell clipboard window

Clipboard panel visibility

Commands:
  open   [pinned]  Show the clipboard panel
  close            Hide the clipboard panel
  toggle [pinned]  Show or hide the clipboard panel

Examples:
  vb-shell clipboard window open
  vb-shell clipboard window toggle
  vb-shell clipboard window toggle pinned
EOF
check_page "the clipboard window controller" golden-clipboard-window "$WORK/golden-clip-window"
t_not_contains "window page has no Output section" "Output:" "$(cat "$WORK/out")"

cat >"$WORK/golden-clip-list" <<'EOF'
Usage: vb-shell clipboard list

Clipboard buckets and the current filtered view

Commands:
  list          List the regular bucket with safe previews
  list pinned   List the pinned bucket with safe previews
  list current  List the open panel's current filtered projection

Examples:
  vb-shell clipboard list
  vb-shell clipboard list pinned
EOF
check_page "the clipboard list controller" golden-clipboard-list "$WORK/golden-clip-list"
t_not_contains "list page has no Output section" "Output:" "$(cat "$WORK/out")"

t_section "clipboard leaf and copy controller help"
cat >"$WORK/golden-clip-open" <<'EOF'
Usage: vb-shell clipboard window open [pinned]

Show the clipboard panel

Notes:
  The optional 'pinned' literal opens the pinned view; it has no argument label

Examples:
  vb-shell clipboard window open
  vb-shell clipboard window open pinned
EOF
check_page "the clipboard window open leaf" golden-clip-window-open "$WORK/golden-clip-open"
t_not_contains "no Options section on the leaf" "Options:" "$(cat "$WORK/out")"
t_not_contains "no PINNED label on the leaf" "PINNED" "$(cat "$WORK/out")"

cat >"$WORK/golden-clip-copy" <<'EOF'
Usage: vb-shell clipboard copy

Write new data to the system clipboard from the terminal

Commands:
  entry regular|pinned <INDEX>   Put one bucket row back on the system clipboard
  text                 <TEXT|->  Copy UTF-8 text from one literal word or stdin
  uri                  <URI>     Copy one absolute URI as text/uri-list
  file                 <PATH>    Copy one file or directory URI, resolved from the caller's cwd
  image                <MIME> -  Copy image bytes from stdin

Notes:
  verbs are 'entry', 'text', 'uri', 'file' and 'image'
  No history entry is injected by a stream write; the shell's watcher captures it
  The shell is confirmed with 'clipboard ping' before a stream write runs

Examples:
  vb-shell clipboard copy entry regular 0
  vb-shell clipboard copy text 'hello'
  vb-shell clipboard copy uri 'https://example.org/a'
  vb-shell clipboard copy file ./notes.txt
  vb-shell clipboard copy image image/png - < shot.png
EOF
check_page "the clipboard copy controller" golden-clipboard-copy "$WORK/golden-clip-copy"
t_contains "copy controller teaches entry" "entry regular|pinned <INDEX>" "$(cat "$WORK/out")"

t_section "root bar help lists bare branch nouns, no placeholders"
cat >"$WORK/golden-bar-root" <<'EOF'
Usage: vb-shell bar

Query and manipulate Vibranium's status bar

Commands:
  enable      Enable the statusbar
  disable     Disable the statusbar
  toggle      Toggle the statusbar
  show        Unhide the statusbar
  hide        Hide the statusbar
  showToggle  Show/Hide the statusbar temporarly
  position    Read or pin the bar edge
  layout      Read or validate the complete slot layout
  module      Inspect and operate configured bar modules
EOF
check_page "the bar root" golden-bar-root "$WORK/golden-bar-root"
t_eq "no angle-bracket placeholders in root bar help" "0" \
  "$(grep -c '[<[]' "$WORK/out")"

t_section "bare bar position set is a one-line usage"
FAKE_QS_MODE=bar-position-usage
python3 -B "$CLIENT" bar position set >"$WORK/out" 2>"$WORK/err"
t_eq "only the usage line is printed" "Usage: vb-shell bar position set top|bottom|toggle" \
  "$(cat "$WORK/out")"
t_eq "no second line is printed" "1" "$(wc -l < "$WORK/out")"
t_empty "stderr stays clean" "$(cat "$WORK/err")"

t_section "audio stream controller help"
cat >"$WORK/golden-stream" <<'EOF'
Usage: vb-shell audio stream <ID> [<ACTION>]

Per-application stream controls

Commands:
  list                    Live application playback and capture streams
  <ID> set <N>            Set an application stream's level, 0-150 percent
  <ID> mute <BOOL>        Set an application stream's explicit mute
  <ID> route <DEVICE>     Move an application stream to a matching device
  route-status <REQUEST>  Read the state of one stream route request

Notes:
  Stream IDs come from 'vb-shell audio stream list'
  Device refs come from 'audio sink list' or 'audio source list'

Examples:
  vb-shell audio stream list
  vb-shell audio stream n1.2 set 50
  vb-shell audio stream route-status r1.1
EOF
check_page "the stream controller" golden-audio-stream "$WORK/golden-stream"
t_not_contains "stream help has no Arguments section" "Arguments:" "$(cat "$WORK/out")"
t_contains "stream help quotes the list command" "'vb-shell audio stream list'" "$(cat "$WORK/out")"

t_section "a missing id teaches before showing a minimal help page"
for verb in open toggle; do
  FAKE_QS_MODE="app-${verb}-help"
  python3 -B "$CLIENT" app "$verb" >"$WORK/out" 2>"$WORK/err"
  t_status "app $verb with no id succeeds" 0 python3 -B "$CLIENT" app "$verb"
  t_eq "app $verb starts with the teaching line" \
    "Use 'app list' to see available apps" "$(head -1 "$WORK/out")"
  t_eq "app $verb has the blank line" "" "$(sed -n 2p "$WORK/out")"
  t_contains "app $verb help shows Usage" "Usage: vb-shell app $verb <ID>" "$(cat "$WORK/out")"
  t_contains "app $verb help shows Examples" "Examples:" "$(cat "$WORK/out")"
  t_contains "app $verb help has the concrete example" \
    "vb-shell app $verb audioMixer" "$(cat "$WORK/out")"
  t_not_contains "app $verb help has no summary or notes" "Notes:" "$(cat "$WORK/out")"
  t_not_contains "app $verb help has no Arguments" "Arguments:" "$(cat "$WORK/out")"
  t_not_contains "app $verb help has no Output" "Output:" "$(cat "$WORK/out")"
done

t_section "the removed sections on app open, close and toggle"
for mode in app-open app-close app-toggle; do
  FAKE_QS_MODE="$mode"
  python3 -B "$CLIENT" app open audioMixer >"$WORK/leaf" 2>"$WORK/err"
  t_not_contains "$mode has no Notes section" "Notes:" "$(cat "$WORK/leaf")"
  t_not_contains "$mode has no Arguments section" "Arguments:" "$(cat "$WORK/leaf")"
  t_not_contains "$mode has no Output section" "Output:" "$(cat "$WORK/leaf")"
done

t_section "a close with nothing open is a silent success"
FAKE_QS_MODE=app-close-noopen
python3 -B "$CLIENT" app close audioMixer >"$WORK/out" 2>"$WORK/err"
t_status "no open apps exits zero" 0 python3 -B "$CLIENT" app close audioMixer
t_empty "no open apps prints nothing on stdout" "$(cat "$WORK/out")"
t_empty "no open apps prints nothing on stderr" "$(cat "$WORK/err")"
FAKE_QS_MODE=app-close-unknown
python3 -B "$CLIENT" app close audioMixer >"$WORK/out" 2>"$WORK/err"
t_status "an unknown id still exits non-zero" 1 python3 -B "$CLIENT" app close audioMixer
t_contains "an unknown id still reports the diagnostic" "unknown app" "$(cat "$WORK/err")"

t_summary
