#!/bin/bash
# Suite: services/system/ipptool/*.test - the nine IPP request templates.
#
# They are data, not code, so nothing here starts a printer, a cupsd or an
# ipptool round-trip: every assertion is made by reading the templates, the
# service that executes them and the library that parses what comes back.
# ipptool/README.md:51 says the templates have no coverage at all and :59 says
# why that matters - "a malformed template is a runtime failure in
# Printers.qml with nothing to catch it at test time."
#
# The rules under test, quoted:
#
#   ipptool/README.md:21  "requesting-user-name must be identical across every
#                         request. Each template carries
#                         `ATTR name requesting-user-name $user`"
#   ipptool/README.md:24  "A different value in any one template would make CUPS
#                         treat the subscription as belonging to somebody else,
#                         and the queue would stop being owned by this shell."
#   ipptool/README.md:25  "`$user`, `$puri` and `$jobid` are `ipptool` variable
#                         references the caller substitutes; they are not
#                         literals."
#   ipptool/README.md:28  "Each template names the attributes it will read.
#                         `requested-attributes` is an explicit list per
#                         operation"
#   ipptool/README.md:29  "`parseReport()` in `../PrintersLib.js` is anchored on
#                         one of them (`printer-name` for `printers.test`,
#                         `job-id` for `jobs.test`). A template that stops
#                         sending its anchor, or an anchor that moves out of the
#                         list, silently produces zero rows"
#   ipptool/README.md:35  "`sub-create.test` also carries the notifier identity:
#                         `notify-recipient-uri dbus://`, the `notify-events` set
#                         (`printer-state-changed`, `job-state-changed`,
#                         `job-created`, `job-progress`), a
#                         `notify-lease-duration` of 86400, and
#                         `notify-user-data VB01-printers`."
#   ipptool/README.md:44  "No printer-level admin operations."
#
# Two things this suite found that the READMEs do not say, recorded as notes
# rather than failures because the tree is self-consistent and nothing is
# broken - see the notes in place for the detail:
#
#   - `$subid` is a fourth ipptool variable in real use (sub-cancel.test,
#     sub-renew.test). ipptool/README.md names it in its table of the
#     variables the caller substitutes, alongside `$user`, `$puri` and
#     `$jobid`.
#   - Only the three list-returning templates carry `requested-attributes`.
#     The six mutating ones cannot: Hold-Job, Release-Job, Cancel-Job and the
#     subscription operations return no attribute groups to name.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "ipptool" "the nine IPP request templates: grammar, requesting-user-name, requested-attributes, subscription identity"

require_tools awk sed grep sort tr wc find paste

IPP_DIR="$SHELL_DIR/services/system/ipptool"
IPP_README="$IPP_DIR/README.md"
PRINTERS_QML="$SHELL_DIR/services/system/Printers.qml"
PRINTERS_LIB="$SHELL_DIR/services/system/PrintersLib.js"
ISLAND_QML="$SHELL_DIR/features/bar/modules/Printers/PrintersIsland.qml"

# A file's comment header, flattened to ONE line of prose.
#
# `t_contains` is a literal substring match, so an assertion quoting a sentence
# out of a wrapped header can never pass: the string has a space where the file
# has "\n// ". That is not a hypothetical - it is how the assertion below was
# written and it failed on the sentence it was quoting, because the header said
# it on two lines. An assertion about prose must not also assert the column the
# author happened to wrap at, so the wrapping comes out here and once, rather
# than in every assertion that reads a header.
header_prose() {
  sed -n '1,30p' "$1" | sed 's|^[[:space:]]*//[[:space:]]\{0,1\}||; s|^[[:space:]]*//.*$||' |
    tr '\n' ' ' | tr -s ' '
}

# The nine templates and the operation the README's table names for each. This
# is the operation table itself: a template missing from this list, or carrying
# a different operation, fails the per-template assertion below.
TEMPLATES=(printers.test jobs.test hold.test release.test cancel-job.test
  sub-create.test sub-renew.test sub-cancel.test sub-list.test)
OPERATIONS=(CUPS-Get-Printers Get-Jobs Hold-Job Release-Job Cancel-Job
  Create-Printer-Subscription Renew-Subscription Cancel-Subscription Get-Subscriptions)
OPERATION_RE='^(CUPS-Get-Printers|Get-Jobs|Hold-Job|Release-Job|Cancel-Job|Create-Printer-Subscription|Renew-Subscription|Cancel-Subscription|Get-Subscriptions)$'

# The templates that parse rows back out, so the ones that must carry a
# requested-attributes list. The other six return no attribute groups.
LISTING_TEMPLATES=(printers.test jobs.test sub-list.test)

# The keywords an ipptool request file may contain, anchored so each is a
# whole first word. Anything else is a typo or a stray code line.
LEGAL_KEYWORD_RE='^(NAME|OPERATION|GROUP|ATTR|STATUS|DISPLAY|\{|\})([[:space:]]|$)'

# The variables the README names, and the templates that legitimately need each.
VAR_PURI_FILES=(hold.test release.test cancel-job.test
  sub-create.test sub-renew.test sub-cancel.test sub-list.test)
VAR_JOBID_FILES=(hold.test release.test cancel-job.test)
VAR_SUBID_FILES=(sub-cancel.test sub-renew.test)

# --------------------------------------------------------------------------
# template readers
# --------------------------------------------------------------------------

# body_lines <file> - the request body with the braces and any comments
# dropped and both margins trimmed, which is what the keyword assertions read.
body_lines() {
  sed -e 's/^[[:space:]]*{[[:space:]]*$//' -e 's/^[[:space:]]*}[[:space:]]*$//' \
    -e 's/^[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
    "$IPP_DIR/$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# op_of <file> - the OPERATION token, or nothing.
op_of() {
  body_lines "$1" | sed -n 's/^OPERATION[[:space:]]\{1,\}//p'
}

# attr_type <file> <name> - the value type keyword of the ATTR line for <name>.
attr_type() {
  body_lines "$1" |
    sed -n "s/^ATTR[[:space:]]\{1,\}\([a-zA-Z]*\)[[:space:]]\{1,\}$2[[:space:]]\{1,\}.*$/\1/p"
}

# attr_value <file> <name> - the value of the ATTR line for <name>.
attr_value() {
  body_lines "$1" |
    sed -n "s/^ATTR[[:space:]]\{1,\}[a-zA-Z]*[[:space:]]\{1,\}$2[[:space:]]\{1,\}\(.*\)$/\1/p"
}

# requested_attrs <file> - the requested-attributes list, one name per line.
requested_attrs() {
  body_lines "$1" |
    sed -n 's/^ATTR[[:space:]]\{1,\}keyword[[:space:]]\{1,\}requested-attributes[[:space:]]\{1,\}//p' |
    tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

# requested_attr_count <file> - how many names the list carries.
requested_attr_count() { requested_attrs "$1" | wc -l | tr -d ' '; }

# requests_attr <file> <attr> - the template's requested-attributes list names
# this attribute, matched on a whole comma-separated word.
requests_attr() {
  requested_attrs "$1" | grep -qx -- "$2"
}

# requested_by_any <attr> - which templates request it, csv-joined.
requested_by_any() {
  local attr="$1" f out=""
  for f in "${TEMPLATES[@]}"; do
    if requests_attr "$f" "$attr"; then
      [[ -n $out ]] && out="$out,"
      out="$out$f"
    fi
  done
  printf '%s' "$out"
}

# attr_names <file> - the attribute names the template sends, space-joined.
attr_names() {
  body_lines "$1" |
    sed -n 's/^ATTR[[:space:]]\{1,\}[a-zA-Z]*[[:space:]]\{1,\}\([a-z][a-z0-9-]*\)[[:space:]]\{1,\}.*$/\1/p' |
    LC_ALL=C sort | paste -sd' ' -
}

# vars_in <file> - every $-reference the template carries, csv-joined.
vars_in() {
  body_lines "$1" | grep -oE '\$[a-z][a-zA-Z0-9_-]*' | LC_ALL=C sort -u | paste -sd, -
}

# lib_reads - every response attribute PrintersLib.js reads out of a parsed
# row, in the two quoted forms it uses, deduplicated.
lib_reads() {
  {
    sed -n 's/.*\[\"\([a-z][a-z0-9-]*\)\"\].*/\1/p' "$PRINTERS_LIB"
    sed -n 's/.*\.\[\"\([a-z][a-z0-9-]*\)\"\].*/\1/p' "$PRINTERS_LIB"
  } | LC_ALL=C sort -u
}

# parse_report_anchors - the anchor argument of every parseReport call in the
# service, read straight out of Printers.qml rather than hard-coded.
parse_report_anchors() {
  sed -n 's/.*parseReport(text, "\([a-z-]*\)").*/\1/p' "$PRINTERS_QML" | LC_ALL=C sort -u
}

# callback_of <template> - the service function the template's response is
# handed to, read off the runIpp call that launches it.
callback_of() {
  # runIpp may be split across lines and its callback may be an inline lambda,
  # so gather the call text until the parens balance, then split it on the
  # top-level commas and take the fourth argument - the callback.
  awk -v want="$1" '
    index($0, "runIpp(\"" want "\"") { gathering = 1; text = "" }
    gathering {
      text = text " " $0
      opens = gsub(/\(/, "(")
      closes = gsub(/\)/, ")")
      depth += opens - closes
      if (depth <= 0) { print text; exit }
    }
  ' "$PRINTERS_QML" |
    sed -e 's/^.*runIpp(//' -e 's/)$//' |
    awk '
      {
        line = $0
        d = 0
        arg = 1
        buf[arg] = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "(" || c == "{" || c == "[") d++
          if (c == ")" || c == "}" || c == "]") d--
          if (c == "," && d == 0) { arg++; buf[arg] = ""; continue }
          buf[arg] = buf[arg] c
        }
        out = buf[4]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", out)
        # A lambda callback calls the real handler inside its own body.
        if (out ~ /=>/) {
          rest = line
          sub(/^.*=>/, "", rest)
          if (match(rest, /root\._[A-Za-z0-9_]+/)) out = substr(rest, RSTART + 5, RLENGTH - 5)
        } else {
          sub(/^root\./, "", out)
        }
        print out
      }
    '
}

# anchors_in <function> - every parseReport anchor the function filters on.
anchors_in() {
  sed -n "/^  function $1(/,/^  }$/p" "$PRINTERS_QML" |
    sed -n 's/.*parseReport(text, "\([a-z-]*\)").*/\1/p' | LC_ALL=C sort -u
}

# --------------------------------------------------------------------------

t_section "the files this suite reads"
t_file "ipptool/README.md" "$IPP_README"
t_file "Printers.qml" "$PRINTERS_QML"
t_file "PrintersLib.js" "$PRINTERS_LIB"
t_file "PrintersIsland.qml" "$ISLAND_QML"
t_true "the ipptool directory exists" test -d "$IPP_DIR"
for f in "${TEMPLATES[@]}"; do
  t_file "$f" "$IPP_DIR/$f"
done
t_eq "the README's table names nine templates" "9" \
  "$(grep -cE '^\| `[a-z-]+\.test` \|' "$IPP_README")"
t_eq "nine templates exist and nothing else is in the directory" "9 1" \
  "$(find "$IPP_DIR" -name '*.test' -type f | wc -l | tr -d ' ')$(printf ' %s' \
    "$(find "$IPP_DIR" -name 'README.md' -type f | wc -l | tr -d ' ')")"
t_eq "no template carries code: none holds a QML, JS or shebang line" "0" \
  "$(grep -lE '^(import |export |const |let |var |function |[a-z]+\.qml|//)' \
    "$IPP_DIR"/*.test 2>/dev/null | wc -l | tr -d ' ')"

t_section "grammar: every file is a well-formed ipptool request"
for f in "${TEMPLATES[@]}"; do
  t_eq "$f opens with a brace" "{" "$(head -1 "$IPP_DIR/$f" | sed 's/^[[:space:]]*//')"
  t_eq "$f closes with a brace" "}" "$(tail -1 "$IPP_DIR/$f" | sed 's/^[[:space:]]*//')"
  t_eq "$f has exactly one NAME line" "1" \
    "$(body_lines "$f" | grep -cE '^NAME[[:space:]]' || true)"
  t_eq "$f has exactly one OPERATION line" "1" \
    "$(body_lines "$f" | grep -cE '^OPERATION[[:space:]]' || true)"
  t_not_empty "$f names itself" \
    "$(body_lines "$f" | sed -n 's/^NAME[[:space:]]\{1,\}//p')"
  t_match "$f's NAME is a quoted string" '^"[^"]+"$' \
    "$(body_lines "$f" | sed -n 's/^NAME[[:space:]]\{1,\}//p')"
  t_not_empty "$f declares an operation" "$(op_of "$f")"
  t_not_empty "$f expects at least one STATUS" \
    "$(body_lines "$f" | sed -n 's/^STATUS[[:space:]]\{1,\}//p' | head -1)"
  t_match "$f expects a real IPP status token" \
    '^(successful-ok|server-error-.*|client-error-.*)$' \
    "$(body_lines "$f" | sed -n 's/^STATUS[[:space:]]\{1,\}//p' | head -1)"
  t_eq "$f uses no keyword outside the ipptool vocabulary" "" \
    "$(body_lines "$f" | grep -vE "$LEGAL_KEYWORD_RE" || true)"
  t_eq "$f's first line is the opening brace" "1" \
    "$(grep -cE '^[[:space:]]*\{[[:space:]]*$' "$IPP_DIR/$f")"
  t_eq "$f has no carriage returns" "0" \
    "$(tr -cd '\r' <"$IPP_DIR/$f" | wc -c | tr -d ' ')"
  t_eq "$f has no tab characters" "0" \
    "$(tr -cd '\t' <"$IPP_DIR/$f" | wc -c | tr -d ' ')"
  t_eq "$f ends with a newline" "1" \
    "$([[ -n $(tail -c 1 "$IPP_DIR/$f") ]] && echo 0 || echo 1)"
  t_eq "$f sends the IPP-mandated charset" "utf-8" "$(attr_value "$f" attributes-charset)"
  t_eq "$f sends the IPP-mandated natural language" "en" \
    "$(attr_value "$f" attributes-natural-language)"
  t_not_empty "$f names a printer-uri" "$(attr_value "$f" printer-uri)"
  t_eq "$f sends printer-uri as a uri" "uri" "$(attr_type "$f" printer-uri)"
  t_eq "$f has no duplicate attribute name" "" \
    "$(body_lines "$f" |
      sed -n 's/^ATTR[[:space:]]\{1,\}[a-zA-Z]*[[:space:]]\{1,\}\([a-z][a-z0-9-]*\)[[:space:]]\{1,\}.*$/\1/p' |
      LC_ALL=C sort | uniq -d || true)"
  t_eq "$f opens with operation-attributes-tag" "operation-attributes-tag" \
    "$(body_lines "$f" | sed -n 's/^GROUP[[:space:]]\{1,\}//p' | head -1)"
  t_eq "$f's groups are all legal IPP groups" "" \
    "$(body_lines "$f" | sed -n 's/^GROUP[[:space:]]\{1,\}//p' |
      grep -vE '^(operation|job|printer|subscription)-attributes-tag$' || true)"
  t_eq "$f's ATTR types are all legal IPP syntax names" "" \
    "$(body_lines "$f" | sed -n 's/^ATTR[[:space:]]\{1,\}\([a-zA-Z]*\)[[:space:]].*$/\1/p' |
      grep -vE '^(boolean|integer|enum|name|keyword|uri|charset|language|textWithoutLanguage|nameWithoutLanguage|mimeMediaType|octetString|resolution|date|collection)$' || true)"
done

t_section "the operation table the README publishes"
for i in "${!TEMPLATES[@]}"; do
  t_eq "${TEMPLATES[$i]} sends ${OPERATIONS[$i]}" "${OPERATIONS[$i]}" \
    "$(op_of "${TEMPLATES[$i]}")"
done
t_unique "no two templates share an operation" "$(printf '%s\n' "${OPERATIONS[@]}")"
# ipptool/README.md:44 "No printer-level admin operations" - the nine named
# operations are the whole vocabulary, so a pause / accept / set-default
# template could not be added without failing this.
t_eq "no template sends an operation outside the nine" "" \
  "$(for f in "${TEMPLATES[@]}"; do op_of "$f"; done | grep -vE "$OPERATION_RE" || true)"

t_section "rule 1: requesting-user-name is identical across every request"
USER_LINES=""
for f in "${TEMPLATES[@]}"; do
  t_eq "$f carries requesting-user-name exactly once" "1" \
    "$(body_lines "$f" | grep -cE '^ATTR name requesting-user-name ' || true)"
  t_eq "$f sends it as a name attribute" "name" "$(attr_type "$f" requesting-user-name)"
  t_eq "$f sends the \$user reference, not a literal" '$user' \
    "$(attr_value "$f" requesting-user-name)"
  USER_LINES+="$(body_lines "$f" | sed -n 's/^\(ATTR name requesting-user-name .*\)$/\1/p')"$'\n'
done
USER_LINES="${USER_LINES%$'\n'}"
# t_unique would be wrong here - it reports *repeated* lines as the failure,
# and the point is that all nine are the same. Count the distinct values.
t_eq "all nine send a byte-identical requesting-user-name line" "1" \
  "$(printf '%s\n' "$USER_LINES" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
t_eq "and there are nine of them" "9" "$(printf '%s\n' "$USER_LINES" | wc -l | tr -d ' ')"
t_eq "and the shared line is the documented one" \
  'ATTR name requesting-user-name $user' "$(printf '%s\n' "$USER_LINES" | head -1)"
t_match "which is a variable reference, never a literal username" \
  '\$user$' "$(printf '%s\n' "$USER_LINES" | head -1)"
# The value has to be uniform *and* substituted from one place, or the
# templates could agree while the caller still passed something per call.
t_eq "the service resolves the user name in exactly one function" "1" \
  "$(grep -cE 'function _userName\(\): string \{' "$PRINTERS_QML")"
t_contains "which resolves \$USER" 'Quickshell.env("USER")' \
  "$(sed -n '/function _userName(): string {/,/^  }$/p' "$PRINTERS_QML")"
t_contains "and falls back to vibranium" '"vibranium"' \
  "$(sed -n '/function _userName(): string {/,/^  }$/p' "$PRINTERS_QML")"
t_eq "every runIpp call site passes that same resolved name" "0" \
  "$(grep -oE 'runIpp\("[a-z-]+\.test", \{[^}]*\}' "$PRINTERS_QML" |
    grep -vF 'user: root._userName()' | grep -c . || true)"

t_section "the \$-variables are references, not literals"
t_eq "the README names \$user, \$puri and \$jobid" '$jobid $puri $user' \
  "$(grep -oE '\$(user|puri|jobid)\b' "$IPP_README" | LC_ALL=C sort -u | paste -sd' ' -)"
t_eq "and the templates use those three plus \$subid" '$jobid,$puri,$subid,$user' \
  "$(for f in "${TEMPLATES[@]}"; do vars_in "$f"; done |
    tr ',' '\n' | LC_ALL=C sort -u | paste -sd, -)"
t_note "sub-cancel.test and sub-renew.test also use \$subid for notify-subscription-id, a fourth ipptool variable; ipptool/README.md names it in its table of the variables the caller substitutes, and Printers.qml:651 and :683 do substitute it, so the templates, the caller and the README agree"
for f in "${VAR_PURI_FILES[@]}"; do
  t_eq "$f takes the printer uri from \$puri" '$puri' "$(attr_value "$f" printer-uri)"
  t_match "$f's \$puri is a reference, not a literal" '^\$[a-z][a-zA-Z0-9_-]*$' \
    "$(attr_value "$f" printer-uri)"
done
for f in "${VAR_JOBID_FILES[@]}"; do
  t_eq "$f takes the job id from \$jobid" '$jobid' "$(attr_value "$f" job-id)"
  t_match "$f's \$jobid is a reference, not a literal" '^\$[a-z][a-zA-Z0-9_-]*$' \
    "$(attr_value "$f" job-id)"
  t_eq "$f sends job-id as an integer" "integer" "$(attr_type "$f" job-id)"
done
for f in "${VAR_SUBID_FILES[@]}"; do
  t_eq "$f takes the subscription id from \$subid" '$subid' \
    "$(attr_value "$f" notify-subscription-id)"
  t_eq "$f sends notify-subscription-id as an integer" "integer" \
    "$(attr_type "$f" notify-subscription-id)"
done
t_eq "the two server-wide reads use a literal uri instead" \
  'ipp://localhost/|ipp://localhost/' \
  "$(printf '%s\n' "$(attr_value printers.test printer-uri)|$(attr_value jobs.test printer-uri)")"
t_eq "which is exactly the uri the service passes to both" "2" \
  "$(grep -cE 'root\.runIpp\("(printers|jobs)\.test", \{ user: root\._userName\(\) \}, "ipp://localhost/"' \
    "$PRINTERS_QML")"
t_contains "the job actions are handed a caller-built puri" \
  'const puri = "ipp://localhost/printers/" + printerName' \
  "$(sed -n '/function _jobAction(/,/^  }$/p' "$PRINTERS_QML")"

t_section "rule 2: the listing templates name the attributes they will read"
for f in "${LISTING_TEMPLATES[@]}"; do
  t_eq "$f carries a requested-attributes keyword line" "1" \
    "$(body_lines "$f" | grep -cE '^ATTR keyword requested-attributes ' || true)"
  t_eq "$f's list is non-empty" "1" \
    "$([[ $(requested_attr_count "$f") -gt 0 ]] && echo 1 || echo 0)"
  t_eq "$f's list has no blank entry" "" "$(requested_attrs "$f" | grep -nE '^$' || true)"
  t_eq "$f's list has no duplicate entry" "" \
    "$(requested_attrs "$f" | LC_ALL=C sort | uniq -d || true)"
  t_eq "$f's list is comma-separated with no stray whitespace" "" \
    "$(requested_attrs "$f" | grep -nE '[[:space:]]' || true)"
  t_eq "$f's list holds only IPP attribute names" "" \
    "$(requested_attrs "$f" | grep -vE '^[a-z][a-z0-9-]*$' || true)"
  t_unique "$f's list has no repeated name" "$(requested_attrs "$f")"
done
# The six mutating templates return no attribute groups, so there is nothing to
# name. The README's "explicit list per operation" is a claim about the reads,
# and these operations perform none.
for f in hold.test release.test cancel-job.test sub-create.test sub-renew.test sub-cancel.test; do
  t_eq "$f names no attributes, because it returns none" "" \
    "$(body_lines "$f" | sed -n 's/^ATTR[[:space:]]\{1,\}[a-zA-Z]*[[:space:]]\{1,\}requested-attributes[[:space:]].*$//p')"
done

t_section "rule 2: the parse anchors are inside the lists, or rows vanish"
t_eq "printers.test requests the printer-name the service filters printers on" \
  "printers.test" "$(requested_by_any printer-name)"
t_eq "and the response is parsed with exactly that anchor" "printer-name" \
  "$(anchors_in "$(callback_of printers.test)")"
t_contains "printer-name is in printers.test's own list" 'printer-name' \
  "$(requested_attrs printers.test | paste -sd' ' -)"
t_eq "jobs.test requests the job-id the service filters jobs on" \
  "jobs.test" "$(requested_by_any job-id)"
t_eq "and the response is parsed with exactly that anchor" "job-id" \
  "$(anchors_in "$(callback_of jobs.test)")"
t_contains "job-id is in jobs.test's own list" 'job-id' \
  "$(requested_attrs jobs.test | paste -sd' ' -)"
t_eq "sub-list.test requests the subscription id the service reads" \
  "sub-list.test" "$(requested_by_any notify-subscription-id)"
t_eq "and the response is parsed with that anchor" "notify-subscription-id" \
  "$(anchors_in "$(callback_of sub-list.test)")"
t_contains "and notify-user-data, which is how it recognises its own subs" \
  'notify-user-data' "$(requested_attrs sub-list.test | paste -sd' ' -)"
# The anchors are read out of the service, so a new call site with an unlisted
# anchor is a failure rather than a silently empty result.
t_eq "the service calls parseReport with three distinct anchors" "3" \
  "$(parse_report_anchors | wc -l | tr -d ' ')"
t_eq "and every anchor it filters on is requested by some template" "" \
  "$(parse_report_anchors | while read -r anchor; do
      [[ -n $anchor && -n $(requested_by_any "$anchor") ]] || printf '%s\n' "$anchor"
    done)"

t_section "rule 2: every attribute the parse side reads is requested somewhere"
UNREQUESTED=""
READ_COUNT=0
while read -r attr; do
  [[ -n $attr ]] || continue
  READ_COUNT=$((READ_COUNT + 1))
  [[ -n $(requested_by_any "$attr") ]] || UNREQUESTED="$UNREQUESTED $attr"
done < <(lib_reads)
t_note "PrintersLib.js reads $READ_COUNT response attributes out of a parsed row; the listing templates request $(requested_attrs printers.test jobs.test sub-list.test | wc -l | tr -d ' ') in total"
# markers() (PrintersLib.js:159) reads marker-names and marker-levels, which no
# template requests. The lib is defensive about it (returns [] when absent) so
# nothing crashes and no rows are lost, but the ink bar the island renders from
# it can only ever be empty. Reported, not asserted: the tree is consistent,
# the parse side simply asks for ink levels nobody sends.
t_note "two attributes PrintersLib.js reads are requested by no template: marker-names, marker-levels (read by markers() at PrintersLib.js:159-160, rendered by PrintersIsland.qml:663). markers() returns [] when they are absent, so this costs the ink bar and nothing else - a real gap, but a defensive one"
t_eq "the attributes the parser needs that no template requests" \
  "marker-levels marker-names" "${UNREQUESTED#"${UNREQUESTED%%[![:space:]]*}"}"

t_section "rule 2: sub-create.test carries the notifier identity"
t_eq "notify-recipient-uri is dbus://" "dbus://" \
  "$(attr_value sub-create.test notify-recipient-uri)"
t_eq "sent as a uri in the subscription group" "uri" \
  "$(attr_type sub-create.test notify-recipient-uri)"
t_eq "notify-events names the four events the README lists" \
  "job-created,job-progress,job-state-changed,printer-state-changed" \
  "$(attr_value sub-create.test notify-events | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)"
t_eq "and that is four events, no more" "4" \
  "$(attr_value sub-create.test notify-events | tr ',' '\n' | grep -c . || true)"
t_eq "notify-lease-duration is 86400" "86400" \
  "$(attr_value sub-create.test notify-lease-duration)"
t_eq "sent as an integer" "integer" "$(attr_type sub-create.test notify-lease-duration)"
t_eq "notify-user-data is the VB01-printers tag" "VB01-printers" \
  "$(attr_value sub-create.test notify-user-data)"
t_contains "and the service recognises its own subs by the same prefix" "VB01-" \
  "$(sed -n '/_applySubList(code, text, name) {/,/^  }$/p' "$PRINTERS_QML")"
t_eq "the notifier identity is sent after the subscription group opens" \
  "subscription-attributes-tag" \
  "$(body_lines sub-create.test | sed -n 's/^GROUP[[:space:]]\{1,\}\(.*\)/\1/p' | tail -1)"
t_eq "sub-create.test displays the subscription id it created" "1" \
  "$(body_lines sub-create.test | grep -cE '^DISPLAY notify-subscription-id$' || true)"
t_eq "sub-create.test is the only template that sends one" "1" \
  "$(for f in "${TEMPLATES[@]}"; do
      [[ "$(attr_value "$f" notify-recipient-uri)" == "dbus://" ]] && printf '%s\n' "$f"
    done | wc -l | tr -d ' ')"

t_section "the subscription lifecycle templates agree with each other"
t_contains "sub-cancel.test names the subscription to drop" "notify-subscription-id" \
  "$(body_lines sub-cancel.test | grep 'notify-subscription-id')"
t_contains "sub-renew.test names the subscription to extend" "notify-subscription-id" \
  "$(body_lines sub-renew.test | grep 'notify-subscription-id')"
t_eq "sub-renew.test asks for the same 86400 lease sub-create.test asked for" \
  "$(attr_value sub-create.test notify-lease-duration)" \
  "$(attr_value sub-renew.test notify-lease-duration)"
t_eq "sub-list.test tolerates an empty subscription list as well as success" "2" \
  "$(body_lines sub-list.test | grep -cE '^STATUS ' || true)"
t_contains "with client-error-not-found as the second" "client-error-not-found" \
  "$(body_lines sub-list.test | sed -n 's/^STATUS[[:space:]]\{1,\}//p' | tail -1)"
t_contains "and the service parses that list on exactly that status" \
  'client-error-not-found' \
  "$(sed -n '/_applySubList(code, text, name) {/,/^  }$/p' "$PRINTERS_QML")"
t_eq "the three job-action templates name the same operation attributes" \
  "$(attr_names hold.test)" "$(attr_names hold.test release.test cancel-job.test | tr ' ' '\n' | sort -u | paste -sd' ' -)"
t_eq "the service routes hold, release and cancel through one action" "3" \
  "$(grep -cE 'root\._jobAction\("' "$PRINTERS_QML")"
t_contains "which substitutes the job id from the clicked row" 'jobid: String(jobId)' \
  "$(sed -n '/function _jobAction(/,/^  }$/p' "$PRINTERS_QML")"
t_eq "and each of the three reaches it" "cancel-job.test hold.test release.test" \
  "$(grep -oE 'root\._jobAction\("[a-z-]+\.test"' "$PRINTERS_QML" |
    sed 's/root\._jobAction("//;s/"//' | LC_ALL=C sort | paste -sd' ' -)"

t_section "what the README says is deliberately absent, and is"
# pause / accept / set-default are printer-level; printer-state-reasons is a
# read, which the listing templates legitimately ask for.
t_eq "no template sets a printer-level admin attribute" "" \
  "$(for f in "${TEMPLATES[@]}"; do
      body_lines "$f" |
        sed -n 's/^ATTR[[:space:]]\{1,\}[a-zA-Z[[:space:]]*\{1,\}\(printer-paused\|printer-accepting-jobs\|printer-is-default\|printer-uri-supported\|media-default\)[[:space:]]\{1,\}.*$/\1/p'
    done | sort -u || true)"
# Quoted from the header as prose, not as source: see header_prose for why.
t_contains "and the service says so in its own header" \
  "printer-level admin ops (pause/accept/set-default) are deliberately" \
  "$(header_prose "$PRINTERS_QML")"
t_eq "the island reads no row attribute the library does not know" "" \
  "$(sed -n 's/.*\[\"\([a-z][a-z0-9-]*\)\"\].*/\1/p' "$ISLAND_QML" |
    LC_ALL=C sort -u |
    while read -r attr; do
      [[ -n $attr ]] || continue
      grep -qE "\[\"$attr\"\]|\.$attr" "$PRINTERS_LIB" || printf '%s\n' "$attr"
    done)"

t_summary
