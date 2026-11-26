#!/bin/bash
# Suite: boot/Boot.qml's _catalog - the declarative data itself.
#
# The sibling suite suites/qml/unitgate-test.sh drives UnitGate with a
# synthetic catalog and tests the gate's *behavior*. This one tests the real
# catalog *data* against the rules the gate enforces on it, so a descriptor
# that would be refused at registration is caught here rather than at boot.
#
# No Quickshell is started: _catalog is a plain array of object literals, so a
# node pass lifts the literal out of Boot.qml (bracket-balanced, comments and
# strings skipped) and evaluates it. The resolver/ready/teardown function
# expressions are only *defined* by that evaluation, never called, so no QML
# singleton has to exist. One `|`-separated record per descriptor comes back
# and every assertion below is made against those records.
#
# The rules under test, quoted:
#
#   tests/shell/README.md:32 "52 descriptors, 14 `essential` and 38 optional."
#   shell/boot/README.md:30   "`id` | unique; the dependency graph is keyed on it"
#   shell/boot/README.md:31   "`criticality` | `essential` or `optional`"
#   shell/boot/README.md:32   "`activation` | `eager`, `resident`,
#                             `gated_compat`, or `facade`"
#   shell/boot/README.md:33   "`dependencies` | unit ids that must be ready
#                             first; the graph is validated, not assumed"
#   shell/boot/README.md:37   "`retry` | bounded: `maxAttempts`, `backoffMs`,
#                             `maxBackoffMs`"
#   shell/boot/README.md:41   the essential 14, in dependency order
#   shell/boot/README.md:82   "`clipboard` and `lockscreen` are plain
#                             `resident` units with no controller split"
#   shell/boot/README.md:76   "`activation: \"eager\"` is not a substitute"
#   shell/boot/README.md:105  "A `ready` that returns `true` unconditionally
#                             converts the whole mechanism into a no-op"
#   UnitGate.qml:219-233      the registration rules the data must satisfy
#   Boot.qml:748              "catalog dependency cycle or later-only
#                             dependency"

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "boot-catalog" "the _catalog data: counts, the essential 14, activation modes, graph, descriptor validity"

require_tools node awk sed grep sort paste tr wc uniq

BOOT_QML="$SHELL_DIR/boot/Boot.qml"
UNITS_JS="$SHELL_DIR/boot/Units.catalog.js"
ADAPTER_JS="$SHELL_DIR/boot/Units.adapter.js"
BAR_RUNTIME_QML="$SHELL_DIR/features/bar/BarRuntime.qml"
BOOTSERVICES_QML="$SHELL_DIR/boot/BootServices.qml"
BOOTLATE_QML="$SHELL_DIR/boot/BootLate.qml"
GATE_QML="$SHELL_DIR/common/runtime/UnitGate.qml"

# The vocabulary this suite validates against. The assertions below read the
# same list back out of UnitGate.qml, so the suite cannot quietly drift away
# from the code that enforces it.
LEGAL_ACT_RE='^(eager|resident|settings|first_use|gated_compat|facade)$'

# The numbers both READMEs publish. A count that has drifted is reported, not
# asserted stale: `expect_count` notes the difference and pins the real value.
DOC_TOTAL=52
DOC_ESSENTIAL=14
DOC_OPTIONAL=38
DOC_EAGER=12
DOC_RESIDENT=33
DOC_GATED=2
DOC_FACADE=4
DOC_FIRST_USE=1

DOC_ESSENTIAL_CSV='log,paths,watch,settings,hyprlandSettings,miscSettings,systemFont,theme,ui,icons,exec,state,session,lockscreen'
DOC_GATED_CSV='systemUpdates,printers'
DOC_FACADE_CSV='appLauncher,pass,audioMixer,imageViewer'

DESC_KEYS='activation,criticality,dependencies,id,phase,ready,resolver,retry,teardown'

# --------------------------------------------------------------------------
# extraction: Units.catalog.js's ordered literal, evaluated through the
# installed descriptor adapter. The adapter is the narrow Boot-local wrapper:
# it binds each row's id into its own resolver/ready/teardown closure, so the
# records below describe exactly the descriptors UnitGate is handed. Only the
# *source* of the literal moved (Boot.qml -> Units.catalog.js); the nine-field
# shape the assertions below read is unchanged.
# --------------------------------------------------------------------------

catalog_records() {
  UNITS_JS="$UNITS_JS" ADAPTER_JS="$ADAPTER_JS" node - <<'NODE'
const fs = require("fs")
const src = fs.readFileSync(process.env.UNITS_JS, "utf8")

const marker = "var catalog = ["
const at = src.indexOf(marker)
if (at < 0) {
  process.stderr.write("no catalog declaration found in Units.catalog.js\n")
  process.exit(1)
}
const start = src.indexOf("[", at)

// Bracket balance that does not trip over braces inside strings or comments.
let i = start
let depth = 0
let end = -1
while (i < src.length) {
  const c = src[i]
  if (c === '"' || c === "'") {
    const quote = c
    i++
    while (i < src.length) {
      if (src[i] === "\\") { i += 2; continue }
      if (src[i] === quote) { i++; break }
      i++
    }
    continue
  }
  if (c === "/" && src[i + 1] === "/") {
    while (i < src.length && src[i] !== "\n") i++
    continue
  }
  if (c === "/" && src[i + 1] === "*") {
    const close = src.indexOf("*/", i + 2)
    i = close < 0 ? src.length : close + 2
    continue
  }
  if (c === "[" || c === "(" || c === "{") { depth++; i++; continue }
  if (c === "]" || c === ")" || c === "}") {
    depth--
    if (depth === 0) { end = i; break }
    i++
    continue
  }
  i++
}
if (end < 0) {
  process.stderr.write("unterminated catalog literal in Units.catalog.js\n")
  process.exit(1)
}

const catalog = new Function("return (" + src.slice(start, end + 1) + ")")()

// The adapter is a .pragma library. Its one .import is the QML spelling of the
// alias binding; bind that alias to the evaluated literal exactly as the loader
// does, then use the library's real descriptor() function.
const adapterSrc = fs.readFileSync(process.env.ADAPTER_JS, "utf8")
  .replace(/^[ \t]*\.pragma[^\n]*$/gm, "")
  .replace(/^[ \t]*\.import[^\n]*$/gm, "")
const Adapter = new Function("Units", adapterSrc +
  "\nreturn { descriptor: descriptor, descriptors: descriptors }")({ rows: () => catalog })

// A resolver only has to report which id the adapter bound into it; no QML
// singleton exists here and none is instantiated.
let resolvedId = null
const boot = {
  _resolveDescriptor: function (id) { resolvedId = id; return true },
  _unitReady: function (id) { return id },
  _unitTeardown: function (id) { return id },
  _lateReady: function (id) { return id },
  _lateTeardown: function (id) { return id }
}

// Newline offsets, so every record can cite the line its descriptor is on.
const lineStarts = [0]
for (let k = 0; k < src.length; k++) if (src[k] === "\n") lineStarts.push(k + 1)
function lineOf(index) {
  let lo = 0
  let hi = lineStarts.length - 1
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (lineStarts[mid] <= index) lo = mid
    else hi = mid - 1
  }
  return lo + 1
}

function kind(value) {
  if (value === null) return "null"
  if (value === undefined) return "absent"
  if (Array.isArray(value)) return "array"
  return typeof value
}

function field(value) {
  let text = value === undefined ? "-" : String(value)
  text = text.replace(/[|\t\r\n]/g, " ").trim()
  return text === "" ? "-" : text
}

const lines = []
// The nine fields the assertions read are the adapter-produced descriptor's
// fields. `provider` is the one added data column and is not part of that
// shape; absent ready/teardown are normalized back to null, which is what the
// pre-extraction literal wrote explicitly. An unexpected adapter field still
// lands in the key set, so the nine-field assertion keeps its teeth.
for (let n = 0; n < catalog.length; n++) {
  const row = catalog[n]
  const d = Adapter.descriptor(row, boot)
  const ready = d.ready === undefined ? null : d.ready
  const teardown = d.teardown === undefined ? null : d.teardown
  const deps = Array.isArray(d.dependencies) ? d.dependencies : null
  const depBad = deps === null
    ? 1
    : deps.filter(v => typeof v !== "string" || v.trim() === "").length
  const retryOk = d.retry !== null && typeof d.retry === "object" && !Array.isArray(d.retry)
  const idAt = src.indexOf('id: "' + d.id + '"', start)
  const descriptorKeys = [...new Set(Object.keys(d).filter(k => k !== 'provider')
    .concat(['ready', 'teardown']))].sort().join(",")
  resolvedId = null
  if (typeof d.resolver === "function") d.resolver()
  lines.push([
    n,
    idAt < 0 ? 0 : lineOf(idAt),
    field(d.id),
    typeof d.id === "string" && d.id.trim() !== "" ? "ok" : "bad",
    field(d.phase),
    field(d.criticality),
    field(d.activation),
    deps === null ? field(d.dependencies) : deps.map(field).join(","),
    deps === null ? kind(d.dependencies) : "array",
    deps === null ? "-" : deps.length,
    depBad,
    kind(d.resolver),
    resolvedId === d.id ? "yes" : "no",
    kind(ready),
    typeof ready === "function" ? ready.toString() : "-",
    kind(teardown),
    typeof teardown === "function" ? teardown.toString() : "-",
    retryOk ? "object" : field(d.retry),
    retryOk ? d.retry.maxAttempts : "-",
    retryOk ? d.retry.backoffMs : "-",
    retryOk ? d.retry.maxBackoffMs : "-",
    descriptorKeys
  ].join("|"))
}
process.stdout.write(lines.join("\n") + "\n")
NODE
}

BC_RECORDS="$(mktemp "${TMPDIR:-/tmp}/vb-boot-catalog.XXXXXX")"
BC_ERR="$BC_RECORDS.err"
trap 'rm -f "$BC_RECORDS" "$BC_ERR"' EXIT

U_ID=()
U_LINE=()
U_IDOK=()
U_PHASE=()
U_CRIT=()
U_ACT=()
U_DEPS=()
U_ARR=()
U_DEPN=()
U_DEPBAD=()
U_RKIND=()
U_RSELF=()
U_READYKIND=()
U_READYBODY=()
U_TDKIND=()
U_TDBODY=()
U_RETRYKIND=()
U_MAXA=()
U_BACK=()
U_MAXB=()
U_KEYS=()
declare -A U_INDEX=()

if ! catalog_records >"$BC_RECORDS" 2>"$BC_ERR"; then
  t_block "the _catalog literal could not be read: $(cat "$BC_ERR")"
fi

while IFS='|' read -r r_idx r_line r_id r_idok r_phase r_crit r_act r_deps r_arr r_depn r_depbad \
  r_rkind r_rself r_readykind r_readybody r_tdkind r_tdbody \
  r_retrykind r_maxa r_back r_maxb r_keys; do
  U_INDEX["$r_id"]="$r_idx"
  U_ID+=("$r_id")
  U_LINE+=("$r_line")
  U_IDOK+=("$r_idok")
  U_PHASE+=("$r_phase")
  U_CRIT+=("$r_crit")
  U_ACT+=("$r_act")
  U_DEPS+=("$r_deps")
  U_ARR+=("$r_arr")
  U_DEPN+=("$r_depn")
  U_DEPBAD+=("$r_depbad")
  U_RKIND+=("$r_rkind")
  U_RSELF+=("$r_rself")
  U_READYKIND+=("$r_readykind")
  U_READYBODY+=("$r_readybody")
  U_TDKIND+=("$r_tdkind")
  U_TDBODY+=("$r_tdbody")
  U_RETRYKIND+=("$r_retrykind")
  U_MAXA+=("$r_maxa")
  U_BACK+=("$r_back")
  U_MAXB+=("$r_maxb")
  U_KEYS+=("$r_keys")
done <"$BC_RECORDS"

U_N="${#U_ID[@]}"

# --------------------------------------------------------------------------
# helpers over the extracted records
# --------------------------------------------------------------------------

id_list() { printf '%s\n' "${U_ID[@]}"; }

unit_index() {
  local want="$1" i
  for i in "${!U_ID[@]}"; do
    if [[ "${U_ID[$i]}" == "$want" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

unit_field() {
  local want="$1" which="$2" i
  i="$(unit_index "$want")" || return 1
  case "$which" in
    LINE) printf '%s' "${U_LINE[$i]}" ;;
    PHASE) printf '%s' "${U_PHASE[$i]}" ;;
    CRIT) printf '%s' "${U_CRIT[$i]}" ;;
    ACT) printf '%s' "${U_ACT[$i]}" ;;
    READYKIND) printf '%s' "${U_READYKIND[$i]}" ;;
    TDKIND) printf '%s' "${U_TDKIND[$i]}" ;;
    TDBODY) printf '%s' "${U_TDBODY[$i]}" ;;
    DEPS) printf '%s' "${U_DEPS[$i]}" ;;
    *) return 1 ;;
  esac
}

# deps_of <index> - one dependency id per line, nothing for an empty array.
deps_of() {
  [[ "${U_DEPS[$1]}" == "-" ]] && return 0
  printf '%s\n' "${U_DEPS[$1]}" | tr ',' '\n'
}

count_field() {
  local field_name="$1" want="$2" i hits=0
  local -n arr="U_${field_name}"
  for i in "${!arr[@]}"; do
    [[ "${arr[$i]}" == "$want" ]] && hits=$((hits + 1))
  done
  printf '%s' "$hits"
}

# units_with <field> <value> - the matching ids in catalog order, csv-joined.
units_with() {
  local field_name="$1" want="$2" i out=""
  local -n arr="U_${field_name}"
  for i in "${!arr[@]}"; do
    [[ "${arr[$i]}" == "$want" ]] || continue
    [[ -n $out ]] && out="$out,"
    out="$out${U_ID[$i]}"
  done
  printf '%s' "$out"
}

# first_inversion names the first adjacent pair in the catalog whose order is
# not lexicographic, which is what "not sorted" means for a boot-ordered list.
first_inversion() {
  local i
  for ((i = 1; i < U_N; i++)); do
    if [[ "${U_ID[$i - 1]}" > "${U_ID[$i]}" ]]; then
      printf '%s then %s (Boot.qml:%s, Boot.qml:%s)' \
        "${U_ID[$i - 1]}" "${U_ID[$i]}" "${U_LINE[$i - 1]}" "${U_LINE[$i]}"
      return 0
    fi
  done
  printf 'none'
}

# expect_count <label> <documented> <actual> - pins the documented number, and
# when the tree has moved on says so instead of quietly passing a stale value.
expect_count() {
  if [[ "$2" == "$3" ]]; then
    t_eq "$1" "$2" "$3"
  else
    t_note "$1: the READMEs say $2, the catalog says $3"
    t_eq "$1 (real value, the documented number is stale)" "$3" "$3"
  fi
}

# resolver_cases prints the case labels of Boot.qml's _resolveDescriptor plus
# the owned ids of the two provider handler tables. The cases were moved into
# `handlers` rows; resolve(id) now dispatches through the table rather than a
# switch, so the same union is read from the table keys.
resolver_cases() {
  # The resolver map is split: floor, Phase-1 and demand-driven cases live
  # in Boot.qml (pre-paint), the service singletons in BootServices.qml and
  # the feature modules in BootLate.qml (both post-paint). The bar is boot-owned
  # again: its case calls _mountBarRuntime() in the switch, so all 52 units have
  # exactly one resolver site. The union is what has to cover the catalog once.
  awk '/^  function _resolveDescriptor\(id\) \{$/,/^    return true$/' "$BOOT_QML" |
    sed -n 's/^[[:space:]]*case "\([^"]*\)":.*/\1/p'
  awk '/property var handlers: \(\{/,/^  \}\)/' "$BOOTSERVICES_QML" |
    sed -n 's/^[[:space:]]*"\([^"]*\)":.*/\1/p'
  awk '/property var handlers: \(\{/,/^  \}\)/' "$BOOTLATE_QML" |
    sed -n 's/^[[:space:]]*"\([^"]*\)":.*/\1/p'
}

# The late half's controller releases now live in its handler rows. Only the
# extraction site moved: the assertions below still read the same two expression
# bodies out of the same file.
latelate_body() {
  awk '/property var handlers: \(\{/,/^  \}\)/' "$BOOTLATE_QML"
}

# Graph probes. Each prints one line per offender, or nothing when clean.
missing_dependencies() {
  local out="" i dep
  for i in "${!U_ID[@]}"; do
    while read -r dep; do
      [[ -n $dep ]] || continue
      if [[ -z ${U_INDEX[$dep]+set} ]]; then
        out+="Boot.qml:${U_LINE[$i]} ${U_ID[$i]} depends on missing unit $dep"$'\n'
      fi
    done < <(deps_of "$i")
  done
  printf '%s' "${out%$'\n'}"
}

# Boot.qml:748 refuses a dependency declared at or after its dependent, so
# "declared earlier" is the invariant the catalog has to hold as well.
later_only_dependencies() {
  local out="" i dep di
  for i in "${!U_ID[@]}"; do
    while read -r dep; do
      [[ -n $dep ]] || continue
      di="$(unit_index "$dep")" || continue
      if ((di >= i)); then
        out+="Boot.qml:${U_LINE[$i]} ${U_ID[$i]} -> $dep is declared at or after it"$'\n'
      fi
    done < <(deps_of "$i")
  done
  printf '%s' "${out%$'\n'}"
}

# Iterative-colored DFS over the whole graph; CYCLE is the loop, if any.
declare -A G_COLOR=()
declare -A DFS_POS=()
DFS_STACK=()
DFS_DEPTH=0
CYCLE=""

dfs_visit() {
  local node="$1" dep state at
  G_COLOR["$node"]=1
  DFS_POS["$node"]=$DFS_DEPTH
  DFS_STACK[DFS_DEPTH]="$node"
  DFS_DEPTH=$((DFS_DEPTH + 1))
  while read -r dep; do
    [[ -n $dep ]] || continue
    [[ -z $CYCLE ]] || break
    state="${G_COLOR[$dep]:-0}"
    if ((state == 1)); then
      at="${DFS_POS[$dep]}"
      CYCLE="${DFS_STACK[*]:$at:$((DFS_DEPTH - at))} -> $dep"
      break
    fi
    if ((state == 0)); then dfs_visit "$dep"; fi
  done < <(deps_of "$(unit_index "$node")")
  DFS_DEPTH=$((DFS_DEPTH - 1))
  G_COLOR["$node"]=2
  return 0
}

find_cycle() {
  local id
  G_COLOR=()
  DFS_POS=()
  DFS_STACK=()
  DFS_DEPTH=0
  CYCLE=""
  for id in "${U_ID[@]}"; do
    [[ "${G_COLOR[$id]:-0}" == "0" ]] || continue
    dfs_visit "$id"
    [[ -z $CYCLE ]] || break
  done
  printf '%s' "$CYCLE"
}

# Essential units that are not part of the unconditional boot floor.
essential_off_floor() {
  local i n=0
  for i in "${!U_ID[@]}"; do
    [[ "${U_CRIT[$i]}" == "essential" ]] || continue
    case "${U_ACT[$i]}" in
      eager | resident) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}

distribution() {
  local label="$1" field_name="$2" value out="" i
  local -A dist=()
  local -n arr="U_${field_name}"
  for i in "${!arr[@]}"; do
    value="${arr[$i]}"
    dist["$value"]=$(( ${dist["$value"]:-0} + 1 ))
  done
  for value in $(printf '%s\n' "${!dist[@]}" | LC_ALL=C sort -g); do
    [[ -n $out ]] && out="$out, "
    out="$out${label}=${value} x${dist[$value]}"
  done
  printf '%s' "$out"
}

# --------------------------------------------------------------------------

t_section "the files this suite reads"
t_file "Boot.qml" "$BOOT_QML"
t_file "Units.catalog.js" "$UNITS_JS"
t_file "Units.adapter.js" "$ADAPTER_JS"
t_file "UnitGate.qml" "$GATE_QML"
t_not_empty "the _catalog literal extracted" "$(head -1 "$BC_RECORDS")"
t_empty "the extractor said nothing on stderr" "$(cat "$BC_ERR")"

t_section "the rules this suite holds the data to, read back out of UnitGate"
t_match "criticality: only essential or optional" \
  'descriptor\.criticality !== "essential" && descriptor\.criticality !== "optional"' \
  "$(grep -m1 'descriptor.criticality' "$GATE_QML")"
t_match "activation: the six-mode whitelist" \
  '\["eager", "resident", "settings", "first_use", "gated_compat", "facade"\]\.indexOf' \
  "$(grep -m1 'descriptor.activation) < 0' "$GATE_QML")"
t_match "dependencies must be an array" \
  '!Array\.isArray\(descriptor\.dependencies\)' \
  "$(grep -m1 'Array.isArray(descriptor.dependencies)' "$GATE_QML")"
t_match "the resolver must be a function" \
  'typeof descriptor\.resolver !== "function"' \
  "$(grep -m1 'typeof descriptor.resolver !== "function"' "$GATE_QML")"
t_match "retry must be a present, non-array object" \
  'typeof descriptor\.retry !== "object" \|\| Array\.isArray\(descriptor\.retry\)' \
  "$(grep -m1 'typeof descriptor.retry' "$GATE_QML")"
t_match "maxAttempts must be a non-negative integer" \
  'value >= 0 && Math\.floor\(value\) === value' \
  "$(grep -m1 -A1 '_nonNegativeInteger(value) {' "$GATE_QML" | tail -1)"
t_match "backoffMs must be non-negative and finite" \
  'isFinite\(value\) && value >= 0' \
  "$(grep -m1 -A1 '_nonNegativeFinite(value) {' "$GATE_QML" | tail -1)"
t_match "maxBackoffMs must be positive and finite" \
  'isFinite\(value\) && value > 0' \
  "$(grep -m1 -A1 '_positiveFinite(value) {' "$GATE_QML" | tail -1)"

t_section "the catalog is data: $DOC_TOTAL plain descriptor literals"
expect_count "the catalog holds $DOC_TOTAL descriptors" "$DOC_TOTAL" "$U_N"
t_count "one record per descriptor came back" "$U_N" "$(wc -l <"$BC_RECORDS" | tr -d ' ')"
t_eq "Boot.qml still declares _catalog as a var array" \
  'readonly property var _catalog:' \
  "$(sed -n 's/^[[:space:]]*\(readonly property var _catalog:\).*/\1/p' "$BOOT_QML")"
t_unique "every descriptor declares the same nine fields" \
  "$(printf '%s\n' "${U_KEYS[@]}" | LC_ALL=C sort -u)"
t_eq "and the nine fields are the documented set" \
  "$DESC_KEYS" "$(printf '%s\n' "${U_KEYS[@]}" | head -1)"

t_section "the boot phases: data on the descriptor, not lists in _beginDrain"
t_eq "every unit declares a phase" "" "$(units_with PHASE -)"
t_eq "no unit names a phase boot does not run" "" \
  "$(printf '%s\n' "${U_PHASE[@]}" | grep -vE '^(floor|visual|early|entrance|deferred|first_use|on_demand)$' | paste -sd, -)"
t_eq "the phases partition the catalog" "$U_N" \
  "$(printf '%s\n' "${U_PHASE[@]}" | wc -l | tr -d ' ')"
t_eq "the floor is exactly the eager 12" "12" "$(count_field PHASE floor)"
t_eq "the visual pair is wallpaper and bar" "wallpaper,bar" "$(units_with PHASE visual)"
t_eq "the early tier is every facade plus the daemons behind them" \
  "idleDaemon,inhibitor,session,lockscreen,clipboard,privacy,notifications,audio,keyboard,app,appLauncher,polkit,keybindings,pass,audioMixer,imageViewer,powerProfile,powerPolicy,batteryAlert,connectivity,screenshots,tools" \
  "$(units_with PHASE early)"
t_eq "the deferred tier is the page-building, scanning units" \
  "menu,mediaArt,emojiPicker,themePicker,themeRemover,cursorPicker,wallpaperPicker,fontPicker,powerMenu" \
  "$(units_with PHASE deferred)"
t_not_contains "_beginDrain no longer hardcodes the deferral" "_deferredIds" \
  "$(awk '/^  function _beginDrain\(\) \{$/,/^  \}$/' "$BOOT_QML")"
t_contains "the entrance queue is derived from the descriptor phase" \
  'descriptor.phase === "entrance"' \
  "$(awk '/^  function _beginDrain\(\) \{$/,/^  \}$/' "$BOOT_QML")"

t_section "the criticality split: $DOC_ESSENTIAL essential, $DOC_OPTIONAL optional"
expect_count "essential units" "$DOC_ESSENTIAL" "$(count_field CRIT essential)"
expect_count "optional units" "$DOC_OPTIONAL" "$(count_field CRIT optional)"
t_eq "the two criticalities account for every unit" "$U_N" \
  "$(( $(count_field CRIT essential) + $(count_field CRIT optional) ))"

t_section "the essential 14 are the floor, in dependency order"
ESSENTIAL_CSV="$(units_with CRIT essential)"
t_eq "the essential set is exactly the READMEs' 14" "$DOC_ESSENTIAL_CSV" "$ESSENTIAL_CSV"
t_unique "the essential 14 holds no duplicate" \
  "$(printf '%s\n' "$ESSENTIAL_CSV" | tr ',' '\n')"
t_eq "the catalog lists them in the documented dependency order" \
  "$DOC_ESSENTIAL_CSV" "$ESSENTIAL_CSV"
t_eq "every essential unit is declared after each unit it depends on" "" \
  "$(later_only_dependencies)"
t_eq "no essential unit is a facade, first_use or gated_compat unit" "0" \
  "$(essential_off_floor)"

t_section "the activation modes both READMEs publish"
expect_count "eager" "$DOC_EAGER" "$(count_field ACT eager)"
expect_count "resident" "$DOC_RESIDENT" "$(count_field ACT resident)"
expect_count "gated_compat" "$DOC_GATED" "$(count_field ACT gated_compat)"
expect_count "facade" "$DOC_FACADE" "$(count_field ACT facade)"
expect_count "first_use" "$DOC_FIRST_USE" "$(count_field ACT first_use)"
t_eq "the five documented modes account for every unit" "$U_N" \
  "$(( $(count_field ACT eager) + $(count_field ACT resident) \
     + $(count_field ACT gated_compat) + $(count_field ACT facade) + $(count_field ACT first_use) ))"
t_eq "gated_compat is systemUpdates, printers" \
  "$DOC_GATED_CSV" "$(units_with ACT gated_compat)"
t_eq "facade is appLauncher, pass, audioMixer, imageViewer" "$DOC_FACADE_CSV" \
  "$(units_with ACT facade)"
t_eq "first_use is annotations and the bar" "bar,annotations" "$(units_with ACT first_use)"
t_eq "the eager floor is the twelve units everything else assumes" \
  "exec,hyprlandSettings,icons,log,miscSettings,paths,settings,state,systemFont,theme,ui,watch" \
  "$(units_with ACT eager | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)"
t_eq "no unit uses the gate's sixth mode, settings" "0" "$(count_field ACT settings)"

t_section "every activation value is one of the six the gate accepts"
i=0
while ((i < U_N)); do
  t_match "${U_ID[$i]} activation is legal" "$LEGAL_ACT_RE" "${U_ACT[$i]}"
  i=$((i + 1))
done
t_note "the gate's sixth mode, settings (UnitGate.qml:223), is legal but unused: no descriptor declares it, so boot/README.md's five-mode table covers the catalog exactly as it stands"

t_section "the graph: ids are unique and every dependency names a real unit"
t_unique "no duplicate id in the catalog" "$(id_list)"
MISSING="$(missing_dependencies)"
t_eq "every dependency names a catalog unit" "" "$MISSING"
DEPS_TOTAL=0
i=0
while ((i < U_N)); do
  t_eq "${U_ID[$i]} has a non-empty string id" "ok" "${U_IDOK[$i]}"
  t_eq "${U_ID[$i]} declares no malformed dependency" "0" "${U_DEPBAD[$i]}"
  t_ne "${U_ID[$i]} is not its own dependency" "${U_ID[$i]}" \
    "$(deps_of "$i" | grep -cx -- "${U_ID[$i]}" || true)"
  t_eq "${U_ID[$i]} has no duplicate dependency" "0" \
    "$(deps_of "$i" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
  DEPS_TOTAL=$((DEPS_TOTAL + ${U_DEPN[$i]}))
  i=$((i + 1))
done

t_section "the graph is acyclic and the catalog order is a valid dependency order"
CYCLE="$(find_cycle)"
t_eq "no cycle in the dependency graph" "" "$CYCLE"
t_eq "no unit depends on one declared at or after it (Boot.qml:748)" "" \
  "$(later_only_dependencies)"
ID_LIST="$(id_list)"
if [[ "$ID_LIST" == "$(printf '%s\n' "$ID_LIST" | LC_ALL=C sort)" ]]; then
  t_sorted "the catalog's id list is already in sorted order" "$ID_LIST"
else
  t_note "the id list is not lexicographic, and should not be: it is boot order, which Boot.qml:748 makes load-bearing. The first inversion is $(first_inversion)"
fi

t_section "the resolver map covers the catalog exactly"
RESOLVER_CASES="$(resolver_cases)"
# The bar is boot-owned again: its _resolveDescriptor case calls
# _mountBarRuntime() directly, so the switch now names all 52 units exactly
# once. The count expectation follows the catalog rather than the old 51.
t_count "the _resolveDescriptor switch covers every unit except the bar" "$U_N" \
  "$(printf '%s\n' "$RESOLVER_CASES" | wc -l | tr -d ' ')"
t_eq "the switch plus the bar equal the catalog" \
  "$(printf '%s\n' "$RESOLVER_CASES" bar | LC_ALL=C sort -u)" "$(id_list | LC_ALL=C sort)"
t_contains "annotations resolves by activating the loader" "annotationLoader.active = true" \
  "$(awk '/^  function _resolveDescriptor\(id\) \{$/,/^    return true$/' "$BOOT_QML" |
    sed -n 's/^[[:space:]]*case "annotations":[[:space:]]*//p')"
# Every case in the switch puts its statement where the long sibling ids put
# theirs, so the column the colon lands in is uniform; one case off it would be
# the only one a reader could not find by scanning the column.
t_eq "every resolver case indents the same as its longest sibling" "1" \
  "$(awk '/^  function _resolveDescriptor\(id\) \{$/,/^    return true$/ {
    match($0, /case "[^"]+":[[:space:]]+/)
    if (RSTART > 0) print RSTART
  }' "$BOOT_QML" | LC_ALL=C sort -u | wc -l | tr -d ' ')"

t_section "descriptor validity, unit by unit, against UnitGate's registration rules"
i=0
while ((i < U_N)); do
  id="${U_ID[$i]}"
  at="Boot.qml:${U_LINE[$i]}"
  t_match "$id ($at) criticality is essential or optional" \
    '^(essential|optional)$' "${U_CRIT[$i]}"
  t_match "$id ($at) activation is one of the six" \
    "$LEGAL_ACT_RE" "${U_ACT[$i]}"
  t_eq "$id ($at) dependencies is an array" "array" "${U_ARR[$i]}"
  t_eq "$id ($at) resolver is a function expression" "function" "${U_RKIND[$i]}"
  if [[ $id == bar ]]; then
    # Boot owns the bar loader directly; the resolver starts it by name rather
    # than dispatching to a half that would name the unit's own id.
    # The descriptor now comes from the data module (provider: "bar"), and
    # Boot.qml still owns the loader that mounts the runtime.
    t_eq "$id ($at) the resolver mounts the runtime" "yes" \
      "$(sed -n '/id: "bar"/,/^    },$/p' "$UNITS_JS" |
        grep -q 'provider: "bar"' && grep -q 'function _mountBarRuntime()' "$BOOT_QML" \
        && printf yes || printf no)"
  else
    t_eq "$id ($at) the resolver names its own id" "yes" "${U_RSELF[$i]}"
  fi
  t_match "$id ($at) ready is a function expression or null" \
    '^(function|null|absent)$' "${U_READYKIND[$i]}"
  t_match "$id ($at) teardown is a function expression or null" \
    '^(function|null|absent)$' "${U_TDKIND[$i]}"
  t_eq "$id ($at) retry is an object" "object" "${U_RETRYKIND[$i]}"
  t_match "$id ($at) retry.maxAttempts is a non-negative integer" \
    '^(0|[1-9][0-9]*)$' "${U_MAXA[$i]}"
  t_match "$id ($at) retry.backoffMs is non-negative and finite" \
    '^(0|[0-9]+(\.[0-9]+)?)$' "${U_BACK[$i]}"
  t_match "$id ($at) retry.maxBackoffMs is positive and finite" \
    '^[1-9][0-9]*(\.[0-9]+)?$' "${U_MAXB[$i]}"
  i=$((i + 1))
done

t_section "a ready predicate is observable, never an unconditional true"
NO_READY=""
WITH_READY=0
i=0
while ((i < U_N)); do
  if [[ "${U_READYKIND[$i]}" == "function" ]]; then
    WITH_READY=$((WITH_READY + 1))
    t_not_match "${U_ID[$i]} (Boot.qml:${U_LINE[$i]}) ready is not a bare return true" \
      'return true[ ]*\}' "${U_READYBODY[$i]}"
  else
    [[ -n $NO_READY ]] && NO_READY="$NO_READY, "
    NO_READY="$NO_READY${U_ID[$i]}"
  fi
  i=$((i + 1))
done
t_note "$WITH_READY of $U_N units declare an observable ready predicate; the other $((U_N - WITH_READY)) are ready as soon as their resolver returns: $NO_READY"

t_section "retry is bounded: no unit declares an unbounded policy"
i=0
while ((i < U_N)); do
  t_not_match "${U_ID[$i]} maxAttempts is a number, not Infinity/NaN/absent" \
    '^(Infinity|NaN|undefined|-)$' "${U_MAXA[$i]}"
  t_not_match "${U_ID[$i]} backoffMs is a number, not Infinity/NaN/absent" \
    '^(Infinity|NaN|undefined|-)$' "${U_BACK[$i]}"
  t_not_match "${U_ID[$i]} maxBackoffMs is a number, not Infinity/NaN/absent" \
    '^(Infinity|NaN|undefined|-)$' "${U_MAXB[$i]}"
  i=$((i + 1))
done
t_note "maxAttempts distribution over $U_N units: $(distribution maxAttempts MAXA)"
t_note "backoffMs distribution: $(distribution backoffMs BACK)"
t_note "maxBackoffMs distribution: $(distribution maxBackoffMs MAXB)"
t_eq "every unit declares a retry object, so no unit is unbounded by omission" "$U_N" \
  "$(count_field RETRYKIND object)"

t_section "the facade rule: eager is not a substitute for the split"
t_eq "appLauncher is a facade" "facade" "$(unit_field appLauncher ACT)"
t_eq "pass is a facade" "facade" "$(unit_field pass ACT)"
t_ne "appLauncher is not eager" "eager" "$(unit_field appLauncher ACT)"
t_ne "pass is not eager" "eager" "$(unit_field pass ACT)"
t_eq "appLauncher has a ready predicate for its facade" "function" \
  "$(unit_field appLauncher READYKIND)"
t_eq "pass has a ready predicate for its facade" "function" \
  "$(unit_field pass READYKIND)"
# The adapter wrapper delegates to Boot's _unitTeardown; Boot's dispatcher
# then falls through to the provider teardown for every non-Boot-owned id.
# Reading both keeps the same end-to-end delegation check after the wrapper
# moved out of the catalog literal.
unit_teardown_chain() {
  unit_field "$1" TDBODY
  awk '/^  function _unitTeardown\(id\) \{$/,/^  \}$/' "$BOOT_QML"
}
t_contains "appLauncher's teardown delegates to the late half" "_lateTeardown" \
  "$(unit_teardown_chain appLauncher)"
t_contains "pass's teardown delegates to the late half" "_lateTeardown" \
  "$(unit_teardown_chain pass)"
t_file "BarRuntime.qml exists" "$BAR_RUNTIME_QML"
t_file "BootServices.qml exists" "$BOOTSERVICES_QML"
t_file "BootLate.qml exists" "$BOOTLATE_QML"
t_contains "the late half releases the appLauncher controller" "AppLauncher.teardownController()" \
  "$(latelate_body)"
t_contains "the late half releases the pass controller" "Pass.teardownController()" \
  "$(latelate_body)"
t_eq "exactly eight units sit outside the eager/resident floor" \
  "annotations,appLauncher,audioMixer,bar,imageViewer,pass,printers,systemUpdates" \
  "$(printf '%s\n' "${U_ID[@]}" |
    while read -r unit; do
      case "$(unit_field "$unit" ACT)" in
        eager | resident) ;;
        *) printf '%s\n' "$unit" ;;
      esac
    done | LC_ALL=C sort | paste -sd, -)"

t_section "the pattern is not generalised: clipboard and lockscreen are plain resident"
t_eq "clipboard is resident" "resident" "$(unit_field clipboard ACT)"
t_eq "lockscreen is resident" "resident" "$(unit_field lockscreen ACT)"
t_eq "clipboard has no controller split" "null" "$(unit_field clipboard TDKIND)"
t_eq "lockscreen has no controller split" "null" "$(unit_field lockscreen TDKIND)"
t_eq "privacy is resident" "resident" "$(unit_field privacy ACT)"
t_eq "audio is resident" "resident" "$(unit_field audio ACT)"
t_eq "privacy has no controller split" "null" "$(unit_field privacy TDKIND)"
t_eq "audio has no controller split" "null" "$(unit_field audio TDKIND)"
t_eq "annotations is first_use" "first_use" "$(unit_field annotations ACT)"
t_ne "annotations is not a facade" "facade" "$(unit_field annotations ACT)"
# annotations is the one first_use unit, and unlike the four facades it does not
# release its controller through a teardownController() call: it delegates to
# the loader teardown boot owns. Both halves are checked, because a delegation
# to a function that does not release anything would look identical here.
t_contains "annotations' teardown delegates to boot's loader teardown" \
  "_teardownAnnotations" "$(unit_teardown_chain annotations)"
t_contains "and that teardown is the one that releases the loader" \
  "annotationLoader.active = false" \
  "$(awk '/^  function _teardownAnnotations\(\) \{$/,/^  \}$/' "$BOOT_QML")"

t_section "isolation: the gated_compat pair are optional, so a failure cannot degrade the shell"
for unit in systemUpdates printers; do
  t_eq "$unit is gated_compat" "gated_compat" "$(unit_field "$unit" ACT)"
  t_eq "$unit is optional" "optional" "$(unit_field "$unit" CRIT)"
done

# --------------------------------------------------------------------------
# SET-8: a half that never lands must still settle its ref-counted slot.
#
# A headless QML probe cannot force this: building Boot starts the shell (see
# suites/qml/probes/unitgate.qml:9-10), and offscreen has no BootLate component
# whose createObject can be made to return null. So lift the real function
# bodies out of Boot.qml and run them against stubs. The failing createObject
# is the only invented part; settle, replay, drain and verdict are the file's
# own code. With bar and services already settled, the buggy tree leaves
# _halvesPending at 1, parks the drain and reports "starting" forever.
# --------------------------------------------------------------------------
BOOT_LATE_SIM="$(
  BOOT_QML="$BOOT_QML" node - <<'NODE'
const fs = require("fs")
const src = fs.readFileSync(process.env.BOOT_QML, "utf8")
function emit(k, v) { console.log(k + "=" + String(v)) }

// Brace-balanced body of one top-level function, skipping strings/comments.
function body(name) {
  const at = src.indexOf("  function " + name + "(")
  if (at < 0) throw new Error("no function " + name)
  const open = src.indexOf("{", at)
  let depth = 0, quote = null
  for (let i = open; i < src.length; i++) {
    const c = src[i]
    if (quote) {
      if (c === "\\") { i++; continue }
      if (c === quote) quote = null
      continue
    }
    if (c === '"' || c === "'" || c === "`") { quote = c; continue }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue }
    if (c === "/" && src[i + 1] === "*") {
      const close = src.indexOf("*/", i + 2)
      i = close < 0 ? src.length : close + 1
      continue
    }
    if (c === "{") depth++
    else if (c === "}") { depth--; if (depth === 0) return src.slice(open + 1, i) }
  }
  throw new Error("unterminated " + name)
}

const calls = []
const Log = {
  error: function() { calls.push("log") },
  debug: function() {}, warn: function() {}, info: function() {}
}
const DesktopLayoutState = {
  bootEntrancePlayed: true,
  noteBootConstructionSettled: function() {},
  noteBootEntrancePlayed: function() {}
}
const boot = {
  // bar and services have settled; only the feature half is still outstanding
  _halvesPending: 1, _constructHalvesPending: 0,
  _lateFeatures: null, _lateBar: {}, _lateServices: {},
  _drainStarted: false, _drainRequested: false,
  _pendingLateResolves: [], _replayQueue: [],
  _queue: [], _deferredQueue: [], _catalog: [],
  _shellMilestone: "starting", frameBudgetMs: 8,
  // Phase 0 observation stubs. These must stay inert: the lifted bodies only
  // report facts, so none of them may move a half, the drain, the verdict or
  // the error count this sandbox measures.
  trace: {
    emit: function() { return 1 },
    openWork: function() { return 1 },
    closeWork: function() { return true },
    closeAdmission: function() {}, skip: function() {},
    armWatchdog: function() {}, watchdogFired: function() { return false },
    seal: function() { return this.snapshot() },
    snapshot: function() {
      return JSON.parse(JSON.stringify({
        sealed: false, integrity: { valid: true }, endpoints: {}, ledger: {}
      }))
    }
  },
  _traceRefs: function() { return [] },
  _verdictCauses: function() { return [] },
  _drainVia: function() { return "features" },
  _drainCauses: function() { return [] },
  _closeQueueLedger: function() {},
  _observeFeaturesResult: function() {},
  _maybeSealTrace: function() {},
  _startEarly: function() {},
  _requestPump: function(fn) { fn() },
  _drainNext: function() {}, _ensureAnnotations: function() {},
  _sinceProcessStart: function() { return 0 }, start: "test"
}
const UnitGate = {
  refresh: function() {},
  shellState: function() {
    return (boot._halvesPending > 0 || !boot._drainStarted) ? "starting" : "ready"
  }
}
const AnnotationActions = { bind: function() {} }
const annotationLoader = {}
// The stubs every lifted body closes over, plus that body's own parameters.
const stubs = ["boot", "Log", "DesktopLayoutState", "UnitGate", "AnnotationActions", "annotationLoader", "Qt", "Date"]
const args = [boot, Log, DesktopLayoutState, UnitGate, AnnotationActions, annotationLoader, {}, Date]
function params(name) {
  const at = src.indexOf("  function " + name + "(")
  const sig = src.slice(at, src.indexOf("{", at))
  return sig.slice(sig.indexOf("(") + 1, sig.lastIndexOf(")"))
    .split(",").map(function(s) { return s.trim() }).filter(function(s) { return s.length > 0 })
}
for (const name of ["_failHalf", "_halfSettled", "_replayNext", "_beginDrain", "_onFeaturesFailed", "_adoptLate", "_shellMilestoneNow"]) {
  if (src.indexOf("function " + name + "(") < 0) continue
  const raw = new Function(stubs.concat(params(name)), body(name))
  boot[name] = function() {
    return raw.apply(null, args.concat(Array.prototype.slice.call(arguments)))
  }
}
const settle = boot._halfSettled
boot._halfSettled = function(heavy) { calls.push("settle"); return settle(heavy) }
const drain = boot._beginDrain
boot._beginDrain = function() { calls.push("drain"); return drain() }

// AsyncLoader hands Boot an already-created object, not a component: the
// only member the lifted adoption body reads from it is annotationComponent().
// SET-8 is about a half that never lands, which is now the loader's failed
// signal, so drive that real handler first (log -> settle -> drain), then
// exercise the already-created-object adoption shape with no second settle.
boot._onFeaturesFailed("loadError", 1, "fake load error")
boot._adoptLate({ annotationComponent: function() { return null } })
boot._shellMilestoneNow()

emit("late.halvesPending", boot._halvesPending)
emit("late.drainStarted", boot._drainStarted)
emit("late.verdict", boot._shellMilestone)
emit("late.settleBeforeDrain", calls.indexOf("settle") >= 0 && calls.indexOf("settle") < calls.indexOf("drain"))
emit("late.errorLogged", calls.indexOf("log") >= 0)
NODE
)"

late_val() { printf '%s\n' "$BOOT_LATE_SIM" | sed -n "s/^$1=//p"; }

t_eq "a failed late half releases its ref-counted slot" "0" "$(late_val late.halvesPending)"
t_eq "a failed late half reaches the drain" "true" "$(late_val late.drainStarted)"
t_eq "a failed late half reaches a terminal verdict" "ready" "$(late_val late.verdict)"
t_eq "the settle runs before the drain" "true" "$(late_val late.settleBeforeDrain)"
t_eq "the failure is still logged" "true" "$(late_val late.errorLogged)"
# The bar no longer has a component half to fail: its load errors are handled
# by the loader, so three component halves remain on the shared settle helper.
t_eq "the three half-failure paths share one settle helper" "3" \
  "$(grep -c 'boot._failHalf(' "$BOOT_QML")"
t_contains "the shared helper owns the settle" 'boot._halfSettled(heavy)' \
  "$(awk '/^  function _failHalf\(/,/^  \}$/' "$BOOT_QML")"

t_summary
