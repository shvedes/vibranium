#!/bin/bash
# Suite: DownloaderIsland - the general Recent pane's idle state.
#
# The JS suites own the clipboard/parser rules. This probe drives the real
# island component so an empty history, a media row, a direct-file row and the
# loading/playlist/format modes are observed as the card actually computes
# them, not as a source grep believes they are computed.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "downloader-island" "general Recent mode, empty-history placeholder and mode gates"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/downloader-island.qml" 60; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

qp_assert "an idle card with no history stays in Recent mode" \
  empty.showHistory true
qp_assert "the empty history is named as empty" empty.historyEmpty true
qp_assert "the empty pane uses the downloader glyph" empty.icon download-alt
qp_assert "the empty pane says what will appear" empty.text \
  "Downloads will appear here"
qp_assert "the empty table keeps its full box" empty.listHeight 152
t_true "the empty note is centered in that box" awk \
  -v d="$(qp_get empty.centerDelta)" 'BEGIN { exit !(d <= 1) }'

qp_assert "a media row keeps Recent mode" media.showHistory true
qp_assert "a media row is not an empty history" media.historyEmpty false
qp_assert "a media row still identifies its engine" media.engine yt-dlp

qp_assert "a direct-file row keeps Recent mode" file.showHistory true
qp_assert "a direct-file row is not an empty history" file.historyEmpty false
qp_assert "a direct-file row keeps its engine field" file.engine wget

qp_assert "a fetch in flight does not show the idle pane" loading.showHistory false
qp_assert "a loaded playlist owns the section" playlist.showHistory false
qp_assert "a loaded format table owns the section" formats.showHistory false
qp_assert "a typed URL that failed does not show the idle pane" typed.showHistory false
qp_assert "the classifier reason is not shown" classify.warning \
  "Could not tell what this link is. Choose Video or File."
qp_assert "the warning carries no parenthetical reason" classify.hasParen false
qp_assert "choosing a chip clears the warning" classify.afterChip ""
qp_assert "choosing File enters file mode" classify.kind file
qp_assert "clearing returns a typed card to the idle Recent pane" \
  cleared.showHistory true

t_summary
