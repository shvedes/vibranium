#!/bin/bash
# Suite: downloader-cli - bin/vb-util-download end to end.
#
# The dispatcher is the routing layer: it must send a media link to yt-dlp, a
# direct file to wget, and an ambiguous link nowhere. Every case runs the real
# script with stub vb-util-yt-dlp and stub wget on PATH, so the argv shape,
# filename resolution, collision suffix, history row and exit status are real
# while no network is involved.
#
# Isolation: HOME, the XDG roots, VIBRANIUM_STATE and the download directory
# point inside one mktemp root. PATH carries a private tools directory, so the
# host's own wget or yt-dlp can never decide a case.
#
# shellcheck disable=SC2317  # fake binaries are written as heredocs

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "downloader-cli" "routing, the wget file contract and history delegation"

CLI="$VIBRANIUM_DIR/bin/vb-util-download"
t_file "the dispatcher under test is in the tree" "$CLI"
t_true "the dispatcher is executable" test -x "$CLI"

R="$(mktemp -d "${TMPDIR:-/tmp}/vb-download-cli.XXXXXX")"
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
FAKE_YTDLP_LOG="$R/ytdlp.log"
FAKE_WGET_LOG="$R/wget.log"
FAKE_ARIA2C_LOG="$R/aria2c.log"

TOOLS="$R/tools"
mkdir -p "$TOOLS"
for _tool in awk basename bash cat date dirname grep mkdir mv node readlink rm \
  stat tr wc; do
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

cat >"$FAKE_BIN/vb-util-yt-dlp" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_YTDLP_LOG:?}"
if [[ ${FAKE_YTDLP_RC:-0} != 0 ]]; then
  exit "${FAKE_YTDLP_RC}"
fi
printf 'media handled\n'
FAKE

cat >"$FAKE_BIN/wget" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_WGET_LOG:?}"

out=""
prev=""
for arg in "$@"; do
  if [[ $prev == "-O" ]]; then
    out="$arg"
  fi
  prev="$arg"
done
if [[ -z $out ]]; then
  printf 'wget: no output path\n' >&2
  exit 2
fi

mkdir -p "$(dirname "$out")"
if [[ ${FAKE_WGET_FAIL:-0} == 1 ]]; then
  printf 'partial\n' >"$out"
  printf 'wget: simulated failure\n' >&2
  exit 8
fi
printf 'file payload\n' >"$out"
exit 0
FAKE

cat >"$FAKE_BIN/aria2c" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_ARIA2C_LOG:?}"

dir=""
out=""
for arg in "$@"; do
  case "$arg" in
    --dir=*) dir="${arg#--dir=}" ;;
    --out=*) out="${arg#--out=}" ;;
  esac
done
if [[ -z $dir || -z $out ]]; then
  printf 'aria2c: no output path\n' >&2
  exit 2
fi
mkdir -p "$dir"
if [[ ${FAKE_ARIA2C_FAIL:-0} == 1 ]]; then
  printf 'partial\n' >"$dir/$out"
  printf 'partial\n' >"$dir/$out.aria2"
  printf 'aria2c: simulated failure\n' >&2
  exit 1
fi
printf 'file payload\n' >"$dir/$out"
exit 0
FAKE

chmod +x "$FAKE_BIN/vb-util-yt-dlp" "$FAKE_BIN/wget" "$FAKE_BIN/aria2c"
export FAKE_YTDLP_LOG FAKE_WGET_LOG FAKE_ARIA2C_LOG

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_cli() {
  PATH="$TOOL_PATH" "$CLI" "$@" >"$R/out" 2>"$R/err"
  RC=$?
  OUT="$(<"$R/out")"
  ERR="$(<"$R/err")"
}

run_cli_no_wget() {
  PATH="$BASE_PATH" "$CLI" "$@" >"$R/out" 2>"$R/err"
  RC=$?
  OUT="$(<"$R/out")"
  ERR="$(<"$R/err")"
}

# The fake bin minus aria2c, with wget still available. Used to prove the
# installed-engine preference falls back instead of breaking file downloads.
run_cli_no_aria2c() {
  local dir="$R/no-aria"
  mkdir -p "$dir"
  ln -sf "$FAKE_BIN/wget" "$dir/wget"
  ln -sf "$FAKE_BIN/vb-util-yt-dlp" "$dir/vb-util-yt-dlp"
  PATH="$dir:$BASE_PATH" "$CLI" "$@" >"$R/out" 2>"$R/err"
  RC=$?
  OUT="$(<"$R/out")"
  ERR="$(<"$R/err")"
}

reset_fake() {
  : >"$FAKE_YTDLP_LOG"
  : >"$FAKE_WGET_LOG"
  : >"$FAKE_ARIA2C_LOG"
  unset FAKE_YTDLP_RC FAKE_WGET_FAIL FAKE_ARIA2C_FAIL
}

fresh() {
  rm -rf "${XDG_DOWNLOAD_DIR:?}"/*
  rm -f "$HISTORY"
  reset_fake
}

ytdlp_log() { printf '%s' "$(<"$FAKE_YTDLP_LOG")"; }
wget_log() { printf '%s' "$(<"$FAKE_WGET_LOG")"; }
aria2c_log() { printf '%s' "$(<"$FAKE_ARIA2C_LOG")"; }

hist_count() {
  if [[ -f $HISTORY ]]; then
    awk 'END { print NR }' "$HISTORY"
  else
    printf '0'
  fi
}

history_field() {
  # history_field <line-number> <field-number>
  awk -F'\t' -v n="$1" -v f="$2" 'NR == n { print $f }' "$HISTORY" 2>/dev/null
}

history_columns() {
  awk -F'\t' 'NR == 1 { print NF }' "$HISTORY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The CLI surface
# ---------------------------------------------------------------------------

t_section "option surface"

reset_fake
run_cli --help
t_eq "--help exits 0" 0 "$RC"
t_eq "--help leaves stderr empty" "" "$ERR"
t_contains "--help names --tool" "--tool" "$OUT"
t_contains "--help names --classify" "--classify" "$OUT"
t_contains "--help names wget" "wget" "$OUT"
t_contains "--help names aria2c" "aria2c" "$OUT"
t_contains "--help names the history owner" "--history-delete" "$OUT"
t_contains "--help names the thumbnail option" "--embed-thumbnail" "$OUT"
t_contains "--help names batch history" "--playlist-history" "$OUT"

run_cli
t_eq "no URL exits 2" 2 "$RC"
t_contains "no URL says what is missing" "missing URL" "$ERR"

for _opt in --tool --format --subdir --subdir-tag --playlist-history; do
  run_cli "$_opt"
  t_eq "$_opt without a value exits 2" 2 "$RC"
  t_contains "$_opt without a value says so" "needs a value" "$ERR"
done

run_cli --tool bogus "https://youtu.be/x"
t_eq "an unknown tool exits 2" 2 "$RC"
t_contains "an unknown tool names the choices" "auto, yt-dlp, wget, or aria2c" "$ERR"

run_cli --classify "https://youtu.be/x"
t_eq "--classify exits 0" 0 "$RC"
t_eq "--classify reports media" $'media\tyt-dlp\tmedia host' "$OUT"
t_empty "--classify never reaches a downloader" "$(ytdlp_log)$(wget_log)$(aria2c_log)"

run_cli --classify "https://example.com/report.pdf"
t_eq "--classify prefers aria2c when installed" \
  $'file\taria2c\tdirect file extension' "$OUT"

run_cli --classify "https://example.com/page"
t_eq "--classify reports an unknown" $'unknown\t\tneeds content-type probe' "$OUT"

run_cli --classify
t_eq "--classify without a URL exits 2" 2 "$RC"

run_cli --bogus "https://youtu.be/x"
t_eq "an unknown option exits 2" 2 "$RC"
t_contains "an unknown option is named" "unknown option --bogus" "$ERR"

run_cli "https://example.com/a.pdf" "https://example.com/b.pdf"
t_eq "two URLs exit 2" 2 "$RC"
t_contains "two URLs say only one" "only one URL" "$ERR"

# ---------------------------------------------------------------------------
# Auto routing
# ---------------------------------------------------------------------------

t_section "auto routing"

fresh
run_cli "https://www.youtube.com/watch?v=x"
t_eq "a watch link exits 0" 0 "$RC"
t_contains "a watch link reaches yt-dlp" "https://www.youtube.com/watch?v=x" "$(ytdlp_log)"
t_empty "a watch link never reaches wget" "$(wget_log)"
t_contains "the media engine's answer is on stdout" "media handled" "$OUT"

fresh
run_cli "https://youtu.be/x"
t_eq "a short link exits 0" 0 "$RC"
t_contains "a short link reaches yt-dlp" "https://youtu.be/x" "$(ytdlp_log)"
t_empty "a short link never reaches wget" "$(wget_log)"

fresh
run_cli "https://www.youtube.com/watch?v=x&list=PL1"
t_eq "a playlist video exits 0" 0 "$RC"
t_contains "a playlist video reaches yt-dlp" \
  "https://www.youtube.com/watch?v=x&list=PL1" "$(ytdlp_log)"
t_empty "a playlist video never reaches wget" "$(wget_log)"

fresh
run_cli "https://cdn.example.com/live/index.m3u8"
t_eq "a manifest exits 0" 0 "$RC"
t_contains "a manifest reaches yt-dlp" "index.m3u8" "$(ytdlp_log)"
t_empty "a manifest never reaches wget" "$(wget_log)"

fresh
run_cli "https://example.com/report.pdf"
t_eq "a PDF exits 0" 0 "$RC"
t_file "the PDF lands on disk" "$XDG_DOWNLOAD_DIR/report.pdf"
t_no_file "no part file is left" "$XDG_DOWNLOAD_DIR/report.pdf.part"
t_empty "an aria2c success leaves stderr empty" "$ERR"
t_contains "the saved path is reported" "File has been saved to" "$OUT"
t_eq "the download is one history row" 1 "$(hist_count)"
t_eq "the row has six columns" 6 "$(history_columns)"
t_match "the timestamp leads the row" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$(history_field 1 1)"
t_eq "the filename is the title" "report" "$(history_field 1 2)"
t_eq "the size is the file size" "13" "$(history_field 1 3)"
t_eq "the path is absolute" "$XDG_DOWNLOAD_DIR/report.pdf" "$(history_field 1 4)"
t_eq "the URL is kept" "https://example.com/report.pdf" "$(history_field 1 5)"
t_eq "the sixth field names the engine" "aria2c" "$(history_field 1 6)"
t_empty "an automatic file never reaches wget while aria2c exists" "$(wget_log)"
t_contains "aria2c is given a part path" \
  "--out=report.pdf.part" "$(aria2c_log)"
t_contains "aria2c is given the URL" "https://example.com/report.pdf" "$(aria2c_log)"
t_contains "aria2c splits the transfer" "--split=8" "$(aria2c_log)"
t_contains "aria2c opens several connections" \
  "--max-connection-per-server=8" "$(aria2c_log)"

fresh
run_cli "ftp://ftp.example.com/pub/file.iso"
t_eq "an FTP link exits 0" 0 "$RC"
t_file "an FTP link is an aria2c file" "$XDG_DOWNLOAD_DIR/file.iso"
t_eq "an FTP link names aria2c" "aria2c" "$(history_field 1 6)"

fresh
run_cli_no_aria2c "https://example.com/fallback.pdf"
t_eq "the fallback file exits 0" 0 "$RC"
t_file "the fallback file lands" "$XDG_DOWNLOAD_DIR/fallback.pdf"
t_eq "the fallback names wget" "wget" "$(history_field 1 6)"
t_contains "the fallback uses wget" "fallback.pdf" "$(wget_log)"

fresh
run_cli "https://example.com/page"
t_eq "an ambiguous link exits 2" 2 "$RC"
t_contains "an ambiguous link names the reason" "needs content-type probe" "$ERR"
t_contains "an ambiguous link asks for --tool" "--tool yt-dlp or --tool wget" "$ERR"
t_empty "an ambiguous link never reaches yt-dlp" "$(ytdlp_log)"
t_empty "an ambiguous link never reaches wget" "$(wget_log)"

fresh
run_cli "https://example.com/page.html"
t_eq "an HTML page exits 2" 2 "$RC"
t_empty "an HTML page never reaches wget" "$(wget_log)"

fresh
run_cli "ftps://ftp.example.com/pub/file.iso"
t_eq "an FTPS link exits 0" 0 "$RC"
t_file "an FTPS link lands on disk" "$XDG_DOWNLOAD_DIR/file.iso"
t_eq "an FTPS link uses aria2c" "aria2c" "$(history_field 1 6)"
t_contains "aria2c is given a part name" "--out=file.iso.part" "$(aria2c_log)"
t_contains "aria2c is given the destination" "--dir=$XDG_DOWNLOAD_DIR" "$(aria2c_log)"
t_contains "aria2c splits the FTPS transfer" "--split=8" "$(aria2c_log)"
t_contains "aria2c opens several FTPS connections" \
  "--max-connection-per-server=8" "$(aria2c_log)"
t_empty "an FTPS link never reaches wget" "$(wget_log)"

fresh
printf 'old\n' >"$XDG_DOWNLOAD_DIR/aria.iso"
run_cli --tool aria2c "sftp://ftp.example.com/pub/aria.iso"
t_eq "an aria2c collision exits 0" 0 "$RC"
t_file "an aria2c collision takes (1)" "$XDG_DOWNLOAD_DIR/aria (1).iso"
t_contains "aria2c writes the collision-resolved part" \
  "--out=aria (1).iso.part" "$(aria2c_log)"
t_not_contains "SFTP stays single-stream" "--split=8" "$(aria2c_log)"
t_eq "the aria2c collision is recorded" "$XDG_DOWNLOAD_DIR/aria (1).iso" \
  "$(history_field 1 4)"

fresh
run_cli "magnet:?xt=urn:btih:abc"
t_eq "a magnet link exits 2" 2 "$RC"
t_contains "a magnet link names aria2c" "aria2c" "$ERR"
t_contains "a magnet link says it is unsupported" "magnet" "$ERR"
t_empty "a magnet link never reaches yt-dlp" "$(ytdlp_log)"
t_empty "a magnet link never reaches wget" "$(wget_log)"
t_empty "a magnet link never reaches aria2c" "$(aria2c_log)"

# ---------------------------------------------------------------------------
# Names and history
# ---------------------------------------------------------------------------

t_section "file naming and history"

fresh
run_cli "https://example.com/Quarterly%20Report%202026.pdf"
t_eq "a percent-encoded name exits 0" 0 "$RC"
t_file "the spaces are decoded" "$XDG_DOWNLOAD_DIR/Quarterly Report 2026.pdf"
t_eq "the decoded name is the title" "Quarterly Report 2026" "$(history_field 1 2)"
t_eq "the decoded path is stored" "$XDG_DOWNLOAD_DIR/Quarterly Report 2026.pdf" "$(history_field 1 4)"

fresh
run_cli "https://example.com/a%2Fb.pdf"
t_eq "a decoded slash exits 0" 0 "$RC"
t_file "a decoded slash cannot make a directory" "$XDG_DOWNLOAD_DIR/a_b.pdf"
t_no_file "no nested directory is created" "$XDG_DOWNLOAD_DIR/a"

fresh
run_cli "https://example.com/Back%5Cslash.pdf"
t_eq "a backslash name exits 0" 0 "$RC"
t_file "a backslash is a filename character" "$XDG_DOWNLOAD_DIR/Back\\slash.pdf"
t_eq "the backslash row keeps six columns" 6 "$(history_columns)"
t_contains "a backslash is escaped in the history" 'Back\\slash.pdf' "$(<"$HISTORY")"

fresh
run_cli --tool wget "https://example.com/"
t_eq "a bare host with an explicit file tool exits 0" 0 "$RC"
t_file "an empty basename falls back to download" "$XDG_DOWNLOAD_DIR/download"

fresh
run_cli --tool wget "https://example.com/.."
t_eq "a dots-only basename exits 0" 0 "$RC"
t_file "a dots-only basename falls back to download" "$XDG_DOWNLOAD_DIR/download"

# ---------------------------------------------------------------------------
# Collisions and subdirectories
# ---------------------------------------------------------------------------

t_section "collisions and subdirectories"

fresh
printf 'old\n' >"$XDG_DOWNLOAD_DIR/collision.pdf"
run_cli "https://example.com/collision.pdf"
t_eq "a collision exits 0" 0 "$RC"
t_eq "the existing file is untouched" "old" "$(<"$XDG_DOWNLOAD_DIR/collision.pdf")"
t_file "the new file takes (1)" "$XDG_DOWNLOAD_DIR/collision (1).pdf"
t_eq "the history names the new file" "$XDG_DOWNLOAD_DIR/collision (1).pdf" "$(history_field 1 4)"

printf 'old1\n' >"$XDG_DOWNLOAD_DIR/collision (1).pdf"
run_cli "https://example.com/collision.pdf"
t_eq "a taken (1) exits 0" 0 "$RC"
t_file "a taken (1) moves to (2)" "$XDG_DOWNLOAD_DIR/collision (2).pdf"
t_eq "the history names (2)" "$XDG_DOWNLOAD_DIR/collision (2).pdf" "$(history_field 2 4)"

fresh
run_cli --subdir "Batch" "https://example.com/batch.pdf"
t_eq "a file subdirectory exits 0" 0 "$RC"
t_file "the file lands in the named folder" "$XDG_DOWNLOAD_DIR/Batch/batch.pdf"
t_eq "the stored path includes the folder" "$XDG_DOWNLOAD_DIR/Batch/batch.pdf" "$(history_field 1 4)"

fresh
run_cli --format 137 --subdir "Batch" --subdir-tag "Best" \
  --playlist-history "https://www.youtube.com/playlist?list=PL1" \
  --embed-thumbnail "https://youtu.be/x"
t_eq "media options exit 0" 0 "$RC"
t_contains "the format reaches yt-dlp" "--format 137" "$(ytdlp_log)"
t_contains "the subdirectory reaches yt-dlp" "--subdir Batch" "$(ytdlp_log)"
t_contains "the preset tag reaches yt-dlp" "--subdir-tag Best" "$(ytdlp_log)"
t_contains "the batch history URL reaches yt-dlp" \
  "--playlist-history https://www.youtube.com/playlist?list=PL1" "$(ytdlp_log)"
t_contains "the thumbnail flag reaches yt-dlp" \
  "--embed-thumbnail" "$(ytdlp_log)"
t_contains "the URL reaches yt-dlp" "https://youtu.be/x" "$(ytdlp_log)"
t_empty "media options never reach wget" "$(wget_log)"

fresh
run_cli --format 18 "https://example.com/report.pdf"
t_eq "--format on a file exits 2" 2 "$RC"
t_contains "--format on a file says it is yt-dlp only" "only for yt-dlp" "$ERR"
t_empty "the rejected format never reaches wget" "$(wget_log)"

fresh
run_cli --subdir-tag "Best" "https://example.com/report.pdf"
t_eq "--subdir-tag on a file exits 2" 2 "$RC"
t_contains "--subdir-tag on a file says it is yt-dlp only" "only for yt-dlp" "$ERR"
t_empty "the rejected tag never reaches wget" "$(wget_log)"

fresh
run_cli --tool wget --playlist-history "https://example.com/list" \
  "https://example.com/report.pdf"
t_eq "--playlist-history on a file exits 2" 2 "$RC"
t_contains "--playlist-history on a file says it is yt-dlp only" \
  "only for yt-dlp" "$ERR"
t_empty "the rejected batch history never reaches wget" "$(wget_log)"

fresh
run_cli --embed-thumbnail "https://example.com/report.pdf"
t_eq "--embed-thumbnail on a file exits 2" 2 "$RC"
t_contains "--embed-thumbnail on a file says it is yt-dlp only" \
  "only for yt-dlp" "$ERR"
t_empty "the rejected thumbnail flag never reaches wget" "$(wget_log)"
t_empty "the rejected thumbnail flag never reaches yt-dlp" "$(ytdlp_log)"

# ---------------------------------------------------------------------------
# Explicit tool override
# ---------------------------------------------------------------------------

t_section "explicit tool override"

fresh
run_cli --tool wget "https://youtu.be/override"
t_eq "--tool wget on media exits 0" 0 "$RC"
t_contains "the explicit file tool gets the URL" "https://youtu.be/override" "$(wget_log)"
t_empty "the explicit file tool never reaches yt-dlp" "$(ytdlp_log)"
t_file "the explicit file tool writes a file" "$XDG_DOWNLOAD_DIR/override"

fresh
run_cli --tool yt-dlp "https://example.com/file.pdf"
t_eq "--tool yt-dlp on a file exits 0" 0 "$RC"
t_contains "the explicit media tool gets the URL" "https://example.com/file.pdf" "$(ytdlp_log)"
t_empty "the explicit media tool never reaches wget" "$(wget_log)"

fresh
run_cli --tool WGET "https://example.com/case.pdf"
t_eq "the tool name is case-insensitive" 0 "$RC"
t_file "the case-insensitive override writes" "$XDG_DOWNLOAD_DIR/case.pdf"

fresh
run_cli --tool aria2c "https://example.com/aria.pdf"
t_eq "--tool aria2c exits 0" 0 "$RC"
t_file "--tool aria2c writes the file" "$XDG_DOWNLOAD_DIR/aria.pdf"
t_eq "the aria2c row names its engine" "aria2c" "$(history_field 1 6)"
t_empty "an explicit aria2c run never reaches wget" "$(wget_log)"

fresh
run_cli --tool wget "https://example.com/page"
t_eq "an explicit file tool takes an ambiguous page" 0 "$RC"
t_file "the explicit file tool names the page" "$XDG_DOWNLOAD_DIR/page"

fresh
run_cli --tool yt-dlp "https://example.com/page"
t_eq "an explicit media tool takes an ambiguous page" 0 "$RC"
t_contains "the explicit media tool gets the page" "https://example.com/page" "$(ytdlp_log)"

# ---------------------------------------------------------------------------
# History delegation and exit propagation
# ---------------------------------------------------------------------------

t_section "history delegation and exit propagation"

fresh
run_cli --history
t_eq "--history exits 0" 0 "$RC"
t_contains "--history reaches the owner" "--history" "$(ytdlp_log)"

run_cli --history-delete 3
t_eq "--history-delete exits 0" 0 "$RC"
t_contains "--history-delete passes its argument" "--history-delete 3" "$(ytdlp_log)"

run_cli --history-clear
t_eq "--history-clear exits 0" 0 "$RC"
t_contains "--history-clear reaches the owner" "--history-clear" "$(ytdlp_log)"

run_cli --missing /a /b
t_eq "--missing exits 0" 0 "$RC"
t_contains "--missing passes every path" "--missing /a /b" "$(ytdlp_log)"

run_cli --tool wget --history
t_eq "history wins over a tool choice" 0 "$RC"
t_contains "the whole argv reaches the owner" "--tool wget --history" "$(ytdlp_log)"

fresh
export FAKE_YTDLP_RC=7
run_cli "https://youtu.be/fail"
t_eq "a media failure propagates its exit status" 7 "$RC"

run_cli --tool yt-dlp "https://example.com/file.pdf"
t_eq "an explicit media failure propagates too" 7 "$RC"

# ---------------------------------------------------------------------------
# Failures
# ---------------------------------------------------------------------------

t_section "failures"

fresh
export FAKE_ARIA2C_FAIL=1
run_cli --tool aria2c "https://example.com/bad.iso"
t_eq "an aria2c failure exits 1" 1 "$RC"
t_no_file "a failed aria2c leaves no final file" "$XDG_DOWNLOAD_DIR/bad.iso"
t_no_file "a failed aria2c removes its part" "$XDG_DOWNLOAD_DIR/bad.iso.part"
t_no_file "a failed aria2c removes its control file" "$XDG_DOWNLOAD_DIR/bad.iso.part.aria2"
t_contains "aria2c's error is on stderr" "simulated failure" "$ERR"
t_eq "a failed aria2c writes no history" 0 "$(hist_count)"

fresh
export FAKE_WGET_FAIL=1
run_cli --tool wget "https://example.com/fail.pdf"
t_eq "a wget failure exits 1" 1 "$RC"
t_no_file "a failed download leaves no final file" "$XDG_DOWNLOAD_DIR/fail.pdf"
t_no_file "a failed download removes its part file" "$XDG_DOWNLOAD_DIR/fail.pdf.part"
t_contains "wget's error is on stderr" "simulated failure" "$ERR"
t_contains "the failure is a result" "Download failed" "$OUT"
t_eq "a failed download writes no history" 0 "$(hist_count)"

fresh
run_cli_no_wget --tool wget "https://example.com/no-wget.pdf"
t_eq "a missing wget exits 1" 1 "$RC"
t_contains "a missing wget says so" "wget is not installed" "$ERR"
t_no_file "a missing wget writes no file" "$XDG_DOWNLOAD_DIR/no-wget.pdf"
t_eq "a missing wget writes no history" 0 "$(hist_count)"

fresh
run_cli_no_wget "ftps://ftp.example.com/pub/file.iso"
t_eq "a missing aria2c exits 1" 1 "$RC"
t_contains "a missing aria2c says so" "aria2c is not installed" "$ERR"
t_eq "a missing aria2c writes no history" 0 "$(hist_count)"

fresh
run_cli --tool aria2c --format 18 "https://example.com/file.pdf"
t_eq "--format on aria2c exits 2" 2 "$RC"
t_contains "--format on aria2c says it is yt-dlp only" "only for yt-dlp" "$ERR"
t_empty "the rejected aria2c format never reaches aria2c" "$(aria2c_log)"

t_summary
