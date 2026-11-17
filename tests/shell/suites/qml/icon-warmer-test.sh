#!/bin/bash
# Suite: common/ui/IconWarmer - decoded-raster prewarm for menu glyphs.
# The warmer pushes each (source, sourceSize) pair through a hidden cache:true
# Image so a consumer Icon created later is Image.Ready on its first frame.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "icon-warmer" "IconWarmer: deduped warm set and a warm first-frame cache hit"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/icon-warmer.qml" 40; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
# Four inputs, one duplicate -> three admitted requests.
t_eq "requests are deduplicated by name and tone" "3" "$(qp_get requests)"
t_eq "an admitted request is never refused at this size" "0" "$(qp_get refused)"
t_eq "the warm raster matches the menu row side" "20" "$(qp_get raster.width)"
t_eq "and is square" "20" "$(qp_get raster.height)"
t_eq "every admitted warmer finished decoding" "true" "$(qp_get warmers.ready)"
t_true "the warmed URL is the real recolor data URL" awk \
  -v n="$(qp_get url.len)" 'BEGIN { exit !(n > 100) }'
t_eq "the warmed URL is exactly Icons.url for that triple" "true" "$(qp_get url.matchesIcons)"
t_eq "a new consumer at the same source and size is ready at once" "true" \
  "$(qp_get consumer.same.initialReady)"
t_eq "a different source size still decodes asynchronously" "false" \
  "$(qp_get consumer.diff.initialReady)"

t_summary
