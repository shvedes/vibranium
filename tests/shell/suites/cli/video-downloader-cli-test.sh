#!/bin/bash
# Suite: video-downloader-cli - bin/vb-util-yt-dlp end to end.
#
# The wrapper is the part of the downloader the shell cannot see: the island
# hands it a URL and reads exit statuses, stdout columns and the history file.
# Every case here runs the real script with a stubbed yt-dlp on PATH, so the
# argument shape, the normalisation, the retry/collision logic, the history
# owner and the clipboard URI are exercised without a network or a real
# downloader.
#
# Isolation: HOME, the XDG roots, VIBRANIUM_STATE/CACHE/RUNTIME and the
# download directory all point inside one mktemp root. PATH carries a private
# tools directory, so the host's own yt-dlp (present on some machines) can
# never decide a --probe case.
#
# shellcheck disable=SC2317  # fake binaries are written as heredocs

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "video-downloader-cli" "the yt-dlp wrapper's result, history and file contract"

CLI="$VIBRANIUM_DIR/bin/vb-util-yt-dlp"
t_file "the wrapper under test is in the tree" "$CLI"
t_true "the wrapper is executable" test -x "$CLI"

R="$(mktemp -d "${TMPDIR:-/tmp}/vb-ytdlp-cli.XXXXXX")"
trap 'rm -rf "$R"' EXIT

export HOME="$R/home"
export XDG_CONFIG_HOME="$R/config"
export XDG_STATE_HOME="$R/state"
export XDG_CACHE_HOME="$R/cache"
export XDG_DOWNLOAD_DIR="$R/downloads"
export VIBRANIUM_RUNTIME="$R/runtime"
export VIBRANIUM_STATE="$R/vibranium/state"
export VIBRANIUM_CACHE="$R/vibranium/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
  "$XDG_DOWNLOAD_DIR" "$VIBRANIUM_RUNTIME" "$VIBRANIUM_STATE" "$VIBRANIUM_CACHE"

HISTORY="$VIBRANIUM_STATE/vb-util-yt-dlp.history"
FOLDERS="$VIBRANIUM_STATE/vb-util-yt-dlp.folders"
ENTRIES="$VIBRANIUM_STATE/vb-util-yt-dlp.entries"
FAKE_LOG="$R/yt-dlp.log"
WL_LOG="$R/wl-copy.log"
WL_OUT="$R/wl-copy.stdin"
ATTEMPT_FILE="$R/attempts"

# A PATH without /usr/sbin: the host's yt-dlp is exactly what --probe must not
# find in the absent case. Every external command the wrapper reaches for is
# linked into the private tools directory.
TOOLS="$R/tools"
mkdir -p "$TOOLS"
for _tool in awk bash cat date dirname find grep mkdir mktemp mv od rm sed sleep timeout tr wc; do
  _path="$(command -v "$_tool")" || continue
  ln -s "$_path" "$TOOLS/$_tool"
done
BASE_PATH="$VIBRANIUM_DIR/bin:$TOOLS"
FAKE_BIN="$R/fake"
mkdir -p "$FAKE_BIN"
TOOL_PATH="$FAKE_BIN:$BASE_PATH"

# ---------------------------------------------------------------------------
# The stubs
# ---------------------------------------------------------------------------

cat >"$FAKE_BIN/yt-dlp" <<'FAKE'
#!/bin/bash
# Stub yt-dlp. The mode is read from the same argv the wrapper composes, so a
# missing flag in the wrapper changes what the stub does, not just a log line.
printf '%s\n' "$*" >>"${FAKE_LOG:?}"

args=("$@")
mode=download
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --list-formats) mode=formats ;;
    --flat-playlist) mode=playlist ;;
    --print)
      case "${args[i+1]:-}" in
        filename) mode=collision ;;
        '%(id)s') mode=preview ;;
      esac
      ;;
  esac
done

case "$mode" in
  formats)
    (( ${FAKE_LIST_RC:-0} == 0 )) || exit "${FAKE_LIST_RC}"
    cat "${FAKE_INFO_FILE:?}"
    exit 0
    ;;
  playlist)
    (( ${FAKE_PLAYLIST_RC:-0} == 0 )) || exit "${FAKE_PLAYLIST_RC}"
    cat "${FAKE_PLAYLIST_FILE:?}"
    exit 0
    ;;
  preview)
    (( ${FAKE_PREVIEW_RC:-0} == 0 )) || exit "${FAKE_PREVIEW_RC}"
    printf '%s\n%s\n' "${FAKE_VIDEO_ID:-dQw4w9WgXcQ}" \
      "${FAKE_PREVIEW_TITLE:-Preview Title}"
    exit 0
    ;;
  collision)
    printf '%s\n' "${FAKE_COLLISION_NAME:-}"
    exit 0
    ;;
esac

attempt=0
[[ -f ${FAKE_ATTEMPT_FILE:?} ]] && read -r attempt <"$FAKE_ATTEMPT_FILE"
attempt=$((attempt + 1))
printf '%s' "$attempt" >"$FAKE_ATTEMPT_FILE"

dir="${XDG_DOWNLOAD_DIR:?}"
template='%(title)s.%(ext)s'
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -P) dir="${args[i+1]}" ;;
    -o) template="${args[i+1]}" ;;
  esac
done
title="${FAKE_TITLE:-Downloaded Title}"
size="${FAKE_SIZE:-12345}"
name="${template//\%\(title\)s/$title}"
name="${name//\%\(ext\)s/mp4}"
[[ $name == /* ]] || name="$dir/$name"

if (( attempt <= ${FAKE_FAIL_TIMES:-0} )); then
  if [[ ${FAKE_PART:-1} == 1 ]]; then
    mkdir -p "$dir"
    : >"$name.part"
  fi
  printf 'ERROR: simulated failure on attempt %d\n' "$attempt" >&2
  exit 1
fi

if [[ ${FAKE_COLLISION_ERROR:-0} == 1 && $attempt == 1 ]]; then
  printf 'Postprocessing: Error opening input files\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$name")"
printf 'payload\n' >"$name"

for ((i = 0; i < ${#args[@]}; i++)); do
  [[ ${args[i]} == --print-to-file ]] || continue
  what="${args[i+1]}"
  dest="${args[i+2]}"
  case "$what" in
    after_move:filepath)
      [[ ${FAKE_NO_PATH:-0} == 1 ]] || printf '%s\n' "$name" >"$dest"
      ;;
    title) printf '%s\n' "$title" >"$dest" ;;
    filesize_approx) printf '%s\n' "$size" >"$dest" ;;
  esac
done
exit 0
FAKE

cat >"$FAKE_BIN/fzf" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_LOG:?}"
[[ -f ${FAKE_FZF_RC_FILE:-/nonexistent} ]] && exit 1
printf '%s\n' "${FAKE_FZF_LINE:-}"
FAKE

cat >"$FAKE_BIN/wl-copy" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"${WL_LOG:?}"
cat >"${WL_OUT:?}"
[[ ${WL_COPY_FAIL:-0} == 1 ]] && exit 1
exit 0
FAKE

chmod +x "$FAKE_BIN/yt-dlp" "$FAKE_BIN/fzf" "$FAKE_BIN/wl-copy"

# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

INFO_FILE="$R/info.txt"
PLAYLIST_FILE="$R/playlist.txt"

# Shapes copied from yt-dlp --list-formats: HLS rows leave FILESIZE blank,
# DASH rows say "audio only"/"video only", and one row carries both codecs.
cat >"$INFO_FILE" <<'EOF'
[youtube] Extracting URL: https://youtu.be/x
ID      EXT   RESOLUTION FPS CH |   FILESIZE    TBR PROTO | VCODEC           VBR ACODEC      ABR ASR MORE INFO
---------------------------------------------------------------------------------------------------------------------------
sb3     mhtml 48x27        0    |                   mhtml | images                                   storyboard
233     mp4   audio only        |                   m3u8  | audio only           unknown             Default, low
140     m4a   audio only      2 |    3.69MiB    49k https | audio only           mp4a.40.5   49k 22k low, m4a_dash
137     mp4   1920x1080    30    |   78.41MiB  1500k https | avc1.640028  1500k video only          1080p, mp4_dash
18      mp4   640x360      30    |    9.24MiB  1500k https | avc1.42001E  96k mp4a.40.2  96k 44k medium
EOF

printf '%s\n' \
  $'Krautrock\t1\tFirst video\t3:41\thttps://www.youtube.com/watch?v=a' \
  $'Krautrock\t2\tSecond tabbed title\t4:02\thttps://www.youtube.com/watch?v=b' \
  $'NA\t3\tUnknown length\tNA\thttps://www.youtube.com/watch?v=c' \
  >"$PLAYLIST_FILE"

export FAKE_LOG WL_LOG WL_OUT ATTEMPT_FILE INFO_FILE PLAYLIST_FILE
export FAKE_ATTEMPT_FILE="$ATTEMPT_FILE"
export FAKE_INFO_FILE="$INFO_FILE" FAKE_PLAYLIST_FILE="$PLAYLIST_FILE"

# The wrapper presents failures through operation::result, which waits for a
# keypress on /dev/tty when one exists. setsid -w drops the controlling terminal
# before the call, so every case stays non-interactive even when this suite is
# launched from a terminal; the PATH is set inside env so setsid itself still
# resolves from the suite's own PATH.
run_cli() {
  setsid -w env PATH="$TOOL_PATH" "$CLI" "$@" >"$R/out" 2>"$R/err"
  RC=$?
  OUT="$(cat "$R/out")"
  ERR="$(cat "$R/err")"
}

run_cli_without_ytdlp() {
  setsid -w env PATH="$BASE_PATH" "$CLI" "$@" >"$R/out" 2>"$R/err"
  RC=$?
  OUT="$(cat "$R/out")"
  ERR="$(cat "$R/err")"
}

reset_fake() {
  : >"$FAKE_LOG"
  : >"$WL_LOG"
  : >"$WL_OUT"
  rm -f "$ATTEMPT_FILE"
  unset FAKE_FAIL_TIMES FAKE_PART FAKE_NO_PATH FAKE_COLLISION_ERROR \
    FAKE_COLLISION_NAME FAKE_LIST_RC FAKE_PLAYLIST_RC FAKE_PREVIEW_RC \
    FAKE_FZF_LINE FAKE_FZF_RC_FILE WL_COPY_FAIL FAKE_VIDEO_ID \
    FAKE_PREVIEW_TITLE FAKE_TITLE FAKE_SIZE
}

write_history() {
  mkdir -p "${HISTORY%/*}"
  printf '%s\n' "$@" >"$HISTORY"
}

history_field() {
  # history_field <line-number> <field-number>
  awk -F'\t' -v n="$1" -v f="$2" 'NR == n { print $f }' "$HISTORY" 2>/dev/null
}

out_lines() { wc -l <"$R/out"; }
err_lines() { wc -l <"$R/err"; }
log_has() { grep -qF -- "$1" "$FAKE_LOG"; }
wl_log_has() { grep -qF -- "$1" "$WL_LOG"; }

# ---------------------------------------------------------------------------
# The CLI surface
# ---------------------------------------------------------------------------

t_section "option surface"

reset_fake
run_cli --help
t_eq "--help exits 0" 0 "$RC"
t_eq "--help leaves stderr empty" "" "$ERR"
t_contains "--help names the playlist listing" "--playlist-info" "$OUT"
t_contains "--help names the format listing" "--info" "$OUT"
t_contains "--help names the history owner" "--history-delete" "$OUT"
t_contains "--help names the history wipe" "--history-clear" "$OUT"
t_contains "--help names the missing-file probe" "--missing" "$OUT"
t_contains "--help names the tool probe" "--probe" "$OUT"
t_contains "--help names the folder option" "--subdir" "$OUT"
t_contains "--help names the folder tag" "--subdir-tag" "$OUT"
t_contains "--help names the preview" "--preview" "$OUT"
t_contains "--help names thumbnail embedding" "--embed-thumbnail" "$OUT"

reset_fake
run_cli --probe
t_eq "--probe is 0 with yt-dlp present" 0 "$RC"
t_empty "--probe prints nothing when present" "$OUT"
t_empty "--probe leaves stderr empty" "$ERR"

# An option that needs a value must report it instead of shifting past the
# end of argv, which leaves the parser on the same word forever.
for _opt in --format --subdir --subdir-tag --history-delete; do
  reset_fake
  run_cli "$_opt"
  t_eq "$_opt without a value exits 2" 2 "$RC"
  t_contains "$_opt without a value says so" "needs a value" "$ERR"
done

reset_fake
run_cli_without_ytdlp --probe
t_eq "--probe is 1 without yt-dlp" 1 "$RC"
t_empty "--probe prints nothing when absent" "$OUT"
t_empty "--probe writes no error when absent" "$ERR"

# ---------------------------------------------------------------------------
# --missing: the Recent table's existence check
# ---------------------------------------------------------------------------

t_section "missing-file probe"

reset_fake
: >"$R/still-here.mp4"
: >"$R/also here.mkv"
run_cli --missing "$R/still-here.mp4" "$R/gone one.mp4" "$R/also here.mkv" \
  "$R/never/was/there.mp4"
t_eq "--missing exits 0" 0 "$RC"
t_lines "--missing answers only with the gone paths" 2 "$(out_lines)"
t_eq "the gone path with a space is reported" \
  "$R/gone one.mp4" "$(sed -n '1p' "$R/out")"
t_eq "the missing parent is reported" \
  "$R/never/was/there.mp4" "$(sed -n '2p' "$R/out")"
t_not_contains "an existing file is not reported" "$R/still-here.mp4" "$OUT"
t_empty "--missing takes paths as arguments, not a script" "$ERR"

reset_fake
run_cli --missing
t_eq "--missing with no arguments exits 0" 0 "$RC"
t_empty "--missing with no arguments prints nothing" "$OUT"

# A path that begins with a dash is still a path to this probe: main's option
# loop stops at the first non-option and --missing consumes the rest as paths.
reset_fake
run_cli --missing "$R/-leading.mp4"
t_eq "a missing path that starts with a dash is reported" 0 "$RC"
t_eq "and printed verbatim" "$R/-leading.mp4" "$OUT"

# ---------------------------------------------------------------------------
# History: display, delete, clear
# ---------------------------------------------------------------------------

t_section "history display"

rm -f "$HISTORY"
reset_fake
run_cli --history
t_eq "--history without a file exits 0" 0 "$RC"
t_contains "--history says there is no history yet" "No download history yet" "$OUT"
t_empty "--history leaves stderr empty" "$ERR"

write_history \
  $'2026-11-16 21:30\tFirst Clip\t40943092\t/home/u/First Clip.mp4\thttps://youtu.be/a\t137' \
  $'2026-11-16 21:32\tSecond Clip\t879341\t/home/u/Second Clip.mp4\thttps://youtu.be/b\t18'
reset_fake
run_cli --history
t_eq "--history exits 0" 0 "$RC"
t_lines "one display line and one path line per entry" 4 "$(out_lines)"
t_contains "the first title is shown" "First Clip" "$OUT"
t_contains "the first path is shown" "/home/u/First Clip.mp4" "$OUT"
t_contains "the second title is shown" "Second Clip" "$OUT"
t_contains "the second path is shown" "/home/u/Second Clip.mp4" "$OUT"
t_not_contains "the stored selector is not part of the display" "137" "$OUT"

t_section "history delete"

write_history \
  $'2026-11-16 21:30\tFirst Clip\t40943092\t/home/u/First Clip.mp4\thttps://youtu.be/a\t137' \
  $'2026-11-16 21:32\tSecond Clip\t879341\t/home/u/Second Clip.mp4\thttps://youtu.be/b\t18' \
  $'2026-11-16 21:40\tThird Clip\t100\t/home/u/Third Clip.mp4\thttps://youtu.be/c\t22'
reset_fake
run_cli --history-delete 2
t_eq "--history-delete exits 0" 0 "$RC"
t_lines "one line is removed" 2 "$(wc -l <"$HISTORY")"
t_contains "the first entry stays" "First Clip" "$(cat "$HISTORY")"
t_not_contains "the deleted entry is gone" "Second Clip" "$(cat "$HISTORY")"
t_contains "the third entry stays" "Third Clip" "$(cat "$HISTORY")"

# Deleting the last line and the first line are the two off-by-one edges the
# island reaches (its newest row is the file's last line).
write_history \
  $'2026-11-16 21:30\tA\t1\t/p/a\thttps://youtu.be/a\t137' \
  $'2026-11-16 21:32\tB\t2\t/p/b\thttps://youtu.be/b\t18'
reset_fake
run_cli --history-delete 1
t_eq "deleting file line 1 exits 0" 0 "$RC"
t_eq "the remaining entry is the second" "B" "$(history_field 1 2)"

write_history \
  $'2026-11-16 21:30\tA\t1\t/p/a\thttps://youtu.be/a\t137' \
  $'2026-11-16 21:32\tB\t2\t/p/b\thttps://youtu.be/b\t18'
reset_fake
run_cli --history-delete 2
t_eq "deleting the last line exits 0" 0 "$RC"
t_eq "the first entry survives" "A" "$(history_field 1 2)"
t_lines "the file keeps one row" 1 "$(wc -l <"$HISTORY")"

write_history \
  $'2026-11-16 21:30\tA\t1\t/p/a\thttps://youtu.be/a\t137'
for bad in 0 -1 abc 1.5 ""; do
  reset_fake
  run_cli --history-delete "$bad"
  t_eq "an invalid entry '$bad' exits 1" 1 "$RC"
  t_contains "an invalid entry '$bad' is named" "Not a history entry" "$OUT"
  t_eq "an invalid entry '$bad' leaves the file alone" "A" "$(history_field 1 2)"
done

rm -f "$HISTORY"
reset_fake
run_cli --history-delete 1
t_eq "deleting from a missing history exits 1" 1 "$RC"
t_contains "and says there is no history" "No download history yet" "$OUT"

# The island numbers the rows it parsed, so a short malformed line must not
# shift the count: --history-delete 1 has to remove the first real row.
write_history \
  'short row' \
  $'2026-11-16 21:30\tAlpha\t1\t/p/a\thttps://youtu.be/a\t137' \
  $'2026-11-16 21:32\tBeta\t2\t/p/b\thttps://youtu.be/b\t18'
reset_fake
run_cli --history-delete 1
t_eq "a delete past a malformed line exits 0" 0 "$RC"
t_contains "the malformed line is left alone" "short row" "$(cat "$HISTORY")"
t_not_contains "the first valid row is removed" "Alpha" "$(cat "$HISTORY")"
t_contains "the second valid row stays" "Beta" "$(cat "$HISTORY")"

t_section "history clear"

write_history \
  $'2026-11-16 21:30\tA\t1\t/p/a\thttps://youtu.be/a\t137' \
  $'2026-11-16 21:32\tB\t2\t/p/b\thttps://youtu.be/b\t18'
reset_fake
run_cli --history-clear
t_eq "--history-clear exits 0" 0 "$RC"
t_file "the history file is kept" "$HISTORY"
t_eq "and is empty" 0 "$(wc -c <"$HISTORY")"
t_empty "--history-clear leaves stderr empty" "$ERR"

# The island calls this on a state directory that may not exist yet (a fresh
# account, or a state root that was just removed). A silent non-zero from the
# shell redirect would be reported as success while nothing was cleared.
rm -rf "$VIBRANIUM_STATE"
reset_fake
run_cli --history-clear
t_eq "clearing on a fresh state root exits 0" 0 "$RC"
t_empty "clearing on a fresh state root says nothing on stderr" "$ERR"
t_file "and creates the history file" "$HISTORY"
mkdir -p "$VIBRANIUM_STATE"

# ---------------------------------------------------------------------------
# --preview
# ---------------------------------------------------------------------------

t_section "preview"

reset_fake
export FAKE_VIDEO_ID="dQw4w9WgXcQ" FAKE_PREVIEW_TITLE="ONBOARD CAM! Starship 42 Catch"
run_cli --preview "https://youtu.be/dQw4w9WgXcQ"
t_eq "--preview exits 0" 0 "$RC"
t_eq "the title is the first line" "ONBOARD CAM! Starship 42 Catch" \
  "$(sed -n '1p' "$R/out")"
t_eq "the thumbnail is built from the id" \
  "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg" "$(sed -n '2p' "$R/out")"
t_lines "the preview is exactly two lines" 2 "$(out_lines)"
t_true "the extraction is simulated" grep -qF -- "--simulate" "$FAKE_LOG"
t_true "the fast visionOS client is requested" \
  grep -qF -- "youtube:player_client=visionos" "$FAKE_LOG"
t_true "the id and title are the prints" \
  grep -qF -- "--print %(id)s --print %(title)s" "$FAKE_LOG"
t_empty "--preview leaves stderr empty" "$ERR"

# A non-YouTube extractor has no i.ytimg.com thumbnail; the second line must
# still be a line, because the island reads positionally.
reset_fake
export FAKE_VIDEO_ID="vimeo-id" FAKE_PREVIEW_TITLE="A Vimeo Clip"
run_cli --preview "https://vimeo.com/123"
t_eq "a non-YouTube preview exits 0" 0 "$RC"
t_eq "the title is still first" "A Vimeo Clip" "$(sed -n '1p' "$R/out")"
t_eq "no invented thumbnail" "" "$(sed -n '2p' "$R/out")"
t_lines "the two-line shape holds without a thumbnail" 2 "$(out_lines)"

# A failed extraction answers on the result stream; the island reads stdout
# only when the exit status is 0, so what matters is that no title line can be
# mistaken for a preview.
reset_fake
export FAKE_PREVIEW_RC=1 FAKE_PREVIEW_TITLE="Should Not Appear"
run_cli --preview "https://youtu.be/x"
t_eq "a failed preview exits 1" 1 "$RC"
t_not_contains "a failed preview prints no title" "Should Not Appear" "$OUT"
t_contains "a failed preview reports it" "Could not load preview" "$OUT"
t_empty "a failed preview leaves stderr empty" "$ERR"

# ---------------------------------------------------------------------------
# --playlist-info
# ---------------------------------------------------------------------------

t_section "playlist listing"

reset_fake
run_cli --playlist-info "https://www.youtube.com/playlist?list=PL1"
t_eq "the listing exits 0" 0 "$RC"
t_eq "the listing is printed verbatim" "$(cat "$PLAYLIST_FILE")" "$OUT"
t_lines "one line per entry" 3 "$(out_lines)"
t_true "the flat listing is requested" grep -qF -- "--flat-playlist" "$FAKE_LOG"
t_true "the five columns are the print template" \
  grep -qF -- "%(playlist_title)s" "$FAKE_LOG"
t_contains "the template carries the title" "%(title)s" "$(cat "$FAKE_LOG")"
t_contains "the template carries the duration" "%(duration_string)s" "$(cat "$FAKE_LOG")"
t_contains "the template carries the url" "%(url)s" "$(cat "$FAKE_LOG")"
t_empty "the listing leaves stderr empty" "$ERR"

reset_fake
export FAKE_PLAYLIST_RC=1
run_cli --playlist-info "https://www.youtube.com/playlist?list=PL1"
t_eq "a failed listing exits 1" 1 "$RC"
t_not_contains "a failed listing prints no entries" "Krautrock" "$OUT"
t_contains "a failed listing is reported" "Could not list the playlist" "$OUT"
t_empty "a failed listing leaves stderr empty" "$ERR"

# ---------------------------------------------------------------------------
# --info
# ---------------------------------------------------------------------------

t_section "format listing"

reset_fake
run_cli --info "https://youtu.be/x"
t_eq "--info exits 0" 0 "$RC"
t_eq "the table is printed whole" "$(cat "$INFO_FILE")" "$OUT"
t_true "the format listing is requested" grep -qF -- "--list-formats" "$FAKE_LOG"
t_true "the extraction ignores the user config" grep -qF -- "--ignore-config" "$FAKE_LOG"
t_true "the visionOS client is requested" \
  grep -qF -- "youtube:player_client=visionos" "$FAKE_LOG"
t_no_file "the format cache file is not left behind" \
  "$VIBRANIUM_CACHE/vb-util-yt-dlp.formats"
t_empty "--info leaves stderr empty" "$ERR"

reset_fake
export FAKE_LIST_RC=1
run_cli --info "https://youtu.be/x"
t_eq "a failed listing exits 1" 1 "$RC"
t_not_contains "a failed listing prints no table" "RESOLUTION FPS" "$OUT"
t_contains "a failed listing is reported" "Could not list formats" "$OUT"
t_empty "a failed listing leaves stderr empty" "$ERR"
t_no_file "a failed listing removes its cache file" \
  "$VIBRANIUM_CACHE/vb-util-yt-dlp.formats"

# ---------------------------------------------------------------------------
# Download: the file, the history row, the clipboard
# ---------------------------------------------------------------------------

fresh_download() {
  rm -rf "$XDG_DOWNLOAD_DIR"
  mkdir -p "$XDG_DOWNLOAD_DIR"
  rm -f "$HISTORY" "$FOLDERS" "$ENTRIES"
  reset_fake
}

t_section "download"

fresh_download
export FAKE_TITLE="First Clip" FAKE_SIZE="40943092"
run_cli "https://youtu.be/abc12345678?si=tracking"
t_eq "a download exits 0" 0 "$RC"
t_file "the file lands in the download directory" "$XDG_DOWNLOAD_DIR/First Clip.mp4"
t_file "the history records it" "$HISTORY"
t_lines "exactly one history row" 1 "$(wc -l <"$HISTORY")"
t_eq "the history row has six tab-separated columns" 6 \
  "$(awk -F'\t' 'NR == 1 { print NF }' "$HISTORY")"
t_match "the timestamp leads the row" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$(history_field 1 1)"
t_eq "the title is stored" "First Clip" "$(history_field 1 2)"
t_eq "the raw size is stored" "40943092" "$(history_field 1 3)"
t_eq "the final path is stored" "$XDG_DOWNLOAD_DIR/First Clip.mp4" \
  "$(history_field 1 4)"
t_eq "the URL is normalized before it is stored" \
  "https://www.youtube.com/watch?v=abc12345678" "$(history_field 1 5)"
t_eq "the default selector is stored" \
  "bestvideo+bestaudio/best" "$(history_field 1 6)"
t_true "the default selector reaches yt-dlp" \
  grep -qF -- "-f bestvideo+bestaudio/best" "$FAKE_LOG"
t_true "yt-dlp is asked for an mp4 remux" grep -qF -- "--remux-video mp4" "$FAKE_LOG"
t_true "yt-dlp is told not to expand a playlist" grep -qF -- "--no-playlist" "$FAKE_LOG"
t_true "metadata is embedded" grep -qF -- "--embed-metadata" "$FAKE_LOG"
t_eq "thumbnail embedding is off by default" "" \
  "$(grep -o -- '--embed-thumbnail' "$FAKE_LOG" || true)"
t_true "subs are embedded" grep -qF -- "--embed-subs" "$FAKE_LOG"
t_true "live chat is not a subtitle" grep -qF -- "-live_chat" "$FAKE_LOG"
t_true "the destination is the download directory" \
  grep -qF -- "-P $XDG_DOWNLOAD_DIR" "$FAKE_LOG"
t_contains "the saved directory is reported" "Video has been saved to" "$OUT"
t_contains "the copied path is reported" "Copied to clipboard" "$OUT"
t_empty "a successful download leaves stderr empty" "$ERR"

t_file "the clipboard received the URI" "$WL_OUT"
t_match "the clipboard record is a file URI" '^file://' "$(cat "$WL_OUT")"
t_contains "the space is percent-encoded" "First%20Clip.mp4" "$(cat "$WL_OUT")"
t_eq "text/uri-list is the clipboard type" "text/uri-list" \
  "$(awk 'NR == 1 { print $2 }' "$WL_LOG")"
t_eq "the clipboard record ends CRLF" "0d 0a" \
  "$(tail -c2 "$WL_OUT" | od -An -tx1 | tr -s ' ' | sed 's/^ //;s/ $//')"

fresh_download
export FAKE_TITLE="Audio Clip" FAKE_SIZE="1"
run_cli --embed-thumbnail "https://youtu.be/audio"
t_eq "a thumbnail download exits 0" 0 "$RC"
t_true "the thumbnail flag reaches yt-dlp" grep -qF -- "--embed-thumbnail" "$FAKE_LOG"
t_true "the thumbnail is converted to jpg" \
  grep -qF -- "--convert-thumbnails jpg" "$FAKE_LOG"
t_true "metadata is still embedded with the cover art" \
  grep -qF -- "--embed-metadata" "$FAKE_LOG"

# A raw title that carries a tab cannot be represented by the six-column TSV:
# written raw it shifts size/path/url/selector by one and the island then reads
# another column as the path. The writer has to keep one record per download.
fresh_download
export FAKE_TITLE=$'Tabbed\tTitle' FAKE_SIZE="1"
run_cli "https://youtu.be/tabbedtitle"
t_eq "a tabbed title still downloads" 0 "$RC"
t_eq "a tabbed title cannot forge a seventh column" 6 \
  "$(awk -F'\t' 'NR == 1 { print NF }' "$HISTORY")"
t_eq "the path column is escaped, not split" \
  "$XDG_DOWNLOAD_DIR/Tabbed\\tTitle.mp4" "$(history_field 1 4)"
t_eq "the url column is still the url" "https://www.youtube.com/watch?v=tabbedtitle" \
  "$(history_field 1 5)"
t_eq "the selector column is still the selector" \
  "bestvideo+bestaudio/best" "$(history_field 1 6)"
reset_fake
run_cli --history
t_contains "the display restores the tab" \
  "$XDG_DOWNLOAD_DIR/Tabbed"$'\t'"Title.mp4" "$OUT"

fresh_download
export FAKE_TITLE='Back\slash' FAKE_SIZE="1"
run_cli "https://youtu.be/backslash"
t_eq "a backslash is escaped" "Back\\\\slash" "$(history_field 1 2)"
reset_fake
run_cli --history
t_contains "the display restores the backslash" 'Back\slash' "$OUT"

t_section "explicit format"

fresh_download
export FAKE_TITLE="Merged Clip" FAKE_SIZE="1000"
run_cli --format "137+bestaudio/137" "https://youtu.be/merged"
t_eq "an explicit format exits 0" 0 "$RC"
t_true "the selector reaches yt-dlp verbatim" \
  grep -qF -- "-f 137+bestaudio/137" "$FAKE_LOG"
t_eq "and is recorded as sent" "137+bestaudio/137" "$(history_field 1 6)"

# ---------------------------------------------------------------------------
# URL normalization, driven through the stored URL
# ---------------------------------------------------------------------------

t_section "URL normalization"

# Every case runs a real download, so the stored URL is the one yt-dlp saw,
# not a string the test normalized itself.
check_url() {
  local label="$1" input="$2" expected="$3"
  fresh_download
  export FAKE_TITLE="Normalized" FAKE_SIZE="1"
  run_cli "$input"
  t_eq "$label: exits 0" 0 "$RC"
  t_eq "$label: stored URL" "$expected" "$(history_field 1 5)"
}

check_url "short link" "https://youtu.be/abc" \
  "https://www.youtube.com/watch?v=abc"
check_url "short link with tracking" "https://youtu.be/abc?si=x" \
  "https://www.youtube.com/watch?v=abc"
check_url "shorts" "https://www.youtube.com/shorts/abc?t=4" \
  "https://www.youtube.com/watch?v=abc"
check_url "live" "https://www.youtube.com/live/abc?utm_source=x" \
  "https://www.youtube.com/watch?v=abc"
check_url "mobile host" "https://m.youtube.com/watch?v=abc&t=1" \
  "https://www.youtube.com/watch?v=abc"
check_url "music host" "https://music.youtube.com/watch?v=abc" \
  "https://www.youtube.com/watch?v=abc"
check_url "host without www" "https://youtube.com/watch?v=abc" \
  "https://www.youtube.com/watch?v=abc"
check_url "embed" "https://www.youtube.com/embed/abc" \
  "https://www.youtube.com/watch?v=abc"
check_url "nocookie embed" "https://www.youtube-nocookie.com/embed/abc" \
  "https://www.youtube.com/watch?v=abc"
check_url "a list survives the tracking strip" \
  "https://www.youtube.com/watch?v=abc&list=PL1&si=z" \
  "https://www.youtube.com/watch?v=abc&list=PL1"
check_url "a non-YouTube URL keeps its query" "https://vimeo.com/123?x=1" \
  "https://vimeo.com/123?x=1"
# scheme-less input is a URL the wrapper can normalize; the interactive loop
# accepts it after normalize rather than reprompting.
check_url "scheme-less short link" "youtu.be/abc" \
  "https://www.youtube.com/watch?v=abc"
check_url "scheme-less nocookie embed" "youtube-nocookie.com/embed/abc" \
  "https://www.youtube.com/watch?v=abc"

# ---------------------------------------------------------------------------
# Folders: --subdir and --subdir-tag
# ---------------------------------------------------------------------------

t_section "playlist folders"

fresh_download
export FAKE_TITLE="Entry" FAKE_SIZE="1"
run_cli --subdir "Krautrock" "https://youtu.be/e1"
t_eq "a subdir download exits 0" 0 "$RC"
t_file "the file lands in the named folder" "$XDG_DOWNLOAD_DIR/Krautrock/Entry.mp4"
t_eq "the stored path includes the folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock/Entry.mp4" "$(history_field 1 4)"

# The first run of a playlist keeps the bare folder; a later preset gets its
# own folder so two qualities are two copies, not a merge.
fresh_download
export FAKE_TITLE="Entry" FAKE_SIZE="1"
run_cli --subdir "Krautrock" --subdir-tag "Best" "https://youtu.be/e1"
t_eq "the first tagged run exits 0" 0 "$RC"
t_file "the first run keeps the bare folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock/Entry.mp4"
t_no_file "and does not create a tagged folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock (Best)/Entry.mp4"
t_no_file "and leaves no preset marker in the folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock/.vb-util-yt-dlp.preset"

run_cli --subdir "Krautrock" --subdir-tag "720p" "https://youtu.be/e2"
t_eq "a second preset exits 0" 0 "$RC"
t_file "and gets its own tagged folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock (720p)/Entry.mp4"
t_file "the first copy is untouched" "$XDG_DOWNLOAD_DIR/Krautrock/Entry.mp4"

# A rerun of the preset that created the bare folder is the same capture, so
# it reuses that folder rather than writing a duplicate under "(Best)".
run_cli --subdir "Krautrock" --subdir-tag "Best" "https://youtu.be/e1"
t_eq "a rerun of the first preset exits 0" 0 "$RC"
t_file "a rerun of the first preset reuses the bare folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock/Entry.mp4"
t_no_file "and does not create a duplicate tagged copy" \
  "$XDG_DOWNLOAD_DIR/Krautrock (Best)/Entry.mp4"
t_no_file "a rerun still leaves no preset marker" \
  "$XDG_DOWNLOAD_DIR/Krautrock/.vb-util-yt-dlp.preset"

# An old folder still carries the marker. Its tag must survive the move to
# state so a later rerun of that same preset still reuses the bare folder.
fresh_download
mkdir -p "$XDG_DOWNLOAD_DIR/Krautrock"
printf 'Best\n' >"$XDG_DOWNLOAD_DIR/Krautrock/.vb-util-yt-dlp.preset"
export FAKE_TITLE="Entry" FAKE_SIZE="1"
run_cli --subdir "Krautrock" --subdir-tag "720p" "https://youtu.be/e3"
t_file "a legacy folder's different preset gets its own copy" \
  "$XDG_DOWNLOAD_DIR/Krautrock (720p)/Entry.mp4"
t_no_file "the legacy marker is removed from the bare folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock/.vb-util-yt-dlp.preset"
run_cli --subdir "Krautrock" --subdir-tag "Best" "https://youtu.be/e4"
t_file "the legacy tag still reuses its bare folder" \
  "$XDG_DOWNLOAD_DIR/Krautrock/Entry.mp4"

# ---------------------------------------------------------------------------
# Playlist history: one row for the folder, not one row per entry
# ---------------------------------------------------------------------------

t_section "playlist history"

fresh_download
export FAKE_TITLE="One" FAKE_SIZE="11"
run_cli --subdir "Album" --subdir-tag "Best" \
  --playlist-history "https://www.youtube.com/playlist?list=PL1" \
  "https://youtu.be/one"
t_eq "a playlist entry exits 0" 0 "$RC"
t_file "the entry lands in the folder" "$XDG_DOWNLOAD_DIR/Album/One.mp4"
t_lines "the batch writes one history row" 1 "$(wc -l <"$HISTORY")"
t_eq "the row is named after the playlist" "Album" "$(history_field 1 2)"
t_eq "the row size is the folder size" "8" "$(history_field 1 3)"
t_eq "the row points at the folder" "$XDG_DOWNLOAD_DIR/Album" \
  "$(history_field 1 4)"
t_eq "the row keeps the playlist URL" \
  "https://www.youtube.com/playlist?list=PL1" "$(history_field 1 5)"
t_eq "the row marks the batch and preset" "playlist:Best" "$(history_field 1 6)"
t_file "the entry index records the file" "$ENTRIES"
t_lines "the entry index has one entry" 1 "$(wc -l <"$ENTRIES")"
t_no_file "the playlist folder has no preset marker" \
  "$XDG_DOWNLOAD_DIR/Album/.vb-util-yt-dlp.preset"

export FAKE_TITLE="Two" FAKE_SIZE="22"
run_cli --subdir "Album" --subdir-tag "Best" \
  --playlist-history "https://www.youtube.com/playlist?list=PL1" \
  "https://youtu.be/two"
t_eq "a second entry still exits 0" 0 "$RC"
t_lines "the second entry updates the same row" 1 "$(wc -l <"$HISTORY")"
t_eq "the folder size covers both files" "16" "$(history_field 1 3)"
t_lines "the entry index keeps both files" 2 "$(wc -l <"$ENTRIES")"

run_cli --history-delete 1
t_eq "deleting the batch row exits 0" 0 "$RC"
t_eq "deleting the batch row removes its history" 0 "$(wc -l <"$HISTORY")"
t_eq "deleting the batch row removes its entry index" 0 "$(wc -l <"$ENTRIES")"

fresh_download
export FAKE_TITLE="Entry" FAKE_SIZE="1"
run_cli --playlist-history "https://example.com/list" \
  "https://youtu.be/solo"
t_eq "--playlist-history without --subdir exits 2" 2 "$RC"
t_contains "--playlist-history names the missing folder option" "needs --subdir" "$ERR"

# ---------------------------------------------------------------------------
# Collisions
# ---------------------------------------------------------------------------

t_section "existing files"

fresh_download
export FAKE_TITLE="Collision" FAKE_SIZE="1"
printf 'old\n' >"$XDG_DOWNLOAD_DIR/Collision.mp4"
# A real yt-dlp fails in postprocessing when the target exists; the wrapper
# then resolves a free " (n)" name and retries.
export FAKE_COLLISION_NAME="$XDG_DOWNLOAD_DIR/Collision.mp4"
export FAKE_COLLISION_ERROR=1
run_cli "https://youtu.be/collision"
t_eq "a colliding download exits 0" 0 "$RC"
t_eq "the existing capture is untouched" "old" "$(cat "$XDG_DOWNLOAD_DIR/Collision.mp4")"
t_file "the new capture takes the first free name" \
  "$XDG_DOWNLOAD_DIR/Collision (1).mp4"
t_eq "the history names the new file" \
  "$XDG_DOWNLOAD_DIR/Collision (1).mp4" "$(history_field 1 4)"

rm -f "$ATTEMPT_FILE"
printf 'older\n' >"$XDG_DOWNLOAD_DIR/Collision (1).mp4"
run_cli "https://youtu.be/collision"
t_file "a taken (1) moves to (2)" "$XDG_DOWNLOAD_DIR/Collision (2).mp4"
t_eq "the history names the second free name" \
  "$XDG_DOWNLOAD_DIR/Collision (2).mp4" "$(history_field 2 4)"

fresh_download
export FAKE_TITLE="Postprocessed" FAKE_SIZE="1"
export FAKE_COLLISION_ERROR=1
export FAKE_COLLISION_NAME="$XDG_DOWNLOAD_DIR/Existing.mp4"
printf 'old\n' >"$XDG_DOWNLOAD_DIR/Existing.mp4"
run_cli "https://youtu.be/postprocessed"
t_eq "a postprocessing collision recovers" 0 "$RC"
t_file "and lands on the free name" "$XDG_DOWNLOAD_DIR/Existing (1).mp4"

# ---------------------------------------------------------------------------
# Failures and retries
# ---------------------------------------------------------------------------

t_section "retries and failure"

fresh_download
export FAKE_TITLE="Retried" FAKE_SIZE="1"
export FAKE_FAIL_TIMES=2
run_cli "https://youtu.be/retried"
t_eq "a download that fails twice then works exits 0" 0 "$RC"
t_eq "three attempts were made" 3 "$(cat "$ATTEMPT_FILE")"
t_lines "one history row is written" 1 "$(wc -l <"$HISTORY")"
t_contains "the retry is reported" "retrying (1/3)" "$OUT"
t_contains "the second retry is reported" "retrying (2/3)" "$OUT"

fresh_download
export FAKE_TITLE="Broken" FAKE_SIZE="1"
export FAKE_FAIL_TIMES=3
printf 'old part\n' >"$XDG_DOWNLOAD_DIR/Broken.mp4.part"
run_cli "https://youtu.be/broken"
t_eq "a download that fails every attempt exits 1" 1 "$RC"
t_eq "exactly three attempts were made" 3 "$(cat "$ATTEMPT_FILE")"
t_no_file "no history row is written for a failure" "$HISTORY"
t_contains "the yt-dlp error is surfaced" "ERROR: simulated failure" "$OUT"
t_contains "the failure is named" "Something went wrong!" "$OUT"
t_file "a pre-existing .part file is left alone" \
  "$XDG_DOWNLOAD_DIR/Broken.mp4.part"

fresh_download
export FAKE_TITLE="Failure" FAKE_SIZE="1"
export FAKE_FAIL_TIMES=3 FAKE_PART=0
run_cli "https://youtu.be/failure"
t_eq "a failure without a pre-existing part exits 1" 1 "$RC"
t_no_file "a .part file created by the failed attempt is cleaned up" \
  "$XDG_DOWNLOAD_DIR/Failure.mp4.part"

fresh_download
export FAKE_TITLE="No Path" FAKE_SIZE="1"
export FAKE_NO_PATH=1
run_cli "https://youtu.be/nopath"
t_eq "a download that reports no path exits 1" 1 "$RC"
t_contains "the missing path is reported" "file path was not reported" "$OUT"
t_no_file "no history row is written without a path" "$HISTORY"

fresh_download
export FAKE_TITLE="Clipboard Fail" FAKE_SIZE="1"
export WL_COPY_FAIL=1
run_cli "https://youtu.be/clipboard"
t_eq "a clipboard failure does not fail the download" 0 "$RC"
t_contains "the fallback path is reported" "Clipboard copy failed" "$OUT"
t_file "the file is still on disk" "$XDG_DOWNLOAD_DIR/Clipboard Fail.mp4"
t_lines "the download is still recorded" 1 "$(wc -l <"$HISTORY")"

# ---------------------------------------------------------------------------
# --select: an fzf pick is a format id, and a video-only pick gains audio
# ---------------------------------------------------------------------------

t_section "interactive format pick"

fresh_download
export FAKE_TITLE="Picked" FAKE_SIZE="1"
export FAKE_FZF_LINE="137     mp4   1920x1080    30    |   78.41MiB  1500k https | avc1.640028  1500k video only          1080p, mp4_dash"
run_cli --select "https://youtu.be/picked"
t_eq "a picked video-only row exits 0" 0 "$RC"
t_true "the pick adds the best audio" \
  grep -qF -- "-f 137+bestaudio/137" "$FAKE_LOG"
t_eq "and the merged selector is recorded" "137+bestaudio/137" \
  "$(history_field 1 6)"

fresh_download
export FAKE_TITLE="Progressive" FAKE_SIZE="1"
export FAKE_FZF_LINE="18      mp4   640x360      30    |    9.24MiB  1500k https | avc1.42001E  96k mp4a.40.2  96k 44k medium"
run_cli --select "https://youtu.be/progressive"
t_eq "a picked progressive row exits 0" 0 "$RC"
t_eq "a row with sound stays itself" "18" "$(history_field 1 6)"

fresh_download
export FAKE_FZF_RC_FILE="$R/fzf-cancel"
: >"$FAKE_FZF_RC_FILE"
run_cli --select "https://youtu.be/cancelled"
t_eq "cancelling the picker exits 1" 1 "$RC"
t_no_file "cancelling writes no history" "$HISTORY"
t_contains "cancelling is reported as a cancellation" "Operation canceled" "$OUT"

rm -f "$FAKE_FZF_RC_FILE"

t_summary
