#!/bin/bash
# Suite: help snapshots - one Coreutils layout with a fixed 80-cell description budget.
# Uses the same fake transport as vb-shell-cli; no live shell is involved.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "vb-shell-help" "exact help snapshots, widths, aliases and JSON shapes"

CLIENT="$VIBRANIUM_DIR/bin/vb-shell"
FIXTURE="$TESTS_SHELL_DIR/suites/cli/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-help.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export PATH="$FIXTURE:$PATH"
export VIBRANIUM="$VIBRANIUM_DIR"
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/opencode/vb-shell-help-pycache"
FAKE_QS_MODE=ok
export FAKE_QS_MODE

help_text() {
  python3 -B "$CLIENT" "$@" >"$WORK/out" 2>"$WORK/err"
  return $?
}

# ---------------------------------------------------------------------------
t_section "the verb snapshot from 01A, byte for byte"

help_text help audio volume up
t_status "verb help succeeds" 0 help_text help audio volume up
EXPECTED=$(cat <<'EOF'
Usage: vb-shell audio volume up [step <N>] [OPTS]

Raise the default output volume

Arguments:
  step <N>  Increase by N percentage points (1-200)

Examples:
  vb-shell audio volume up
  vb-shell audio volume up step 10
EOF
)
t_eq "redirected verb help matches the documented snapshot" "$EXPECTED" "$(cat "$WORK/out")"
t_eq "exactly one LF at the end" "1" "$(python3 - "$WORK/out" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(1 if b.endswith(b'\n') and not b.endswith(b'\n\n') else 0)
PY
)"
t_eq "no ANSI escapes" "0" "$(grep -c $'\033' "$WORK/out")"
t_eq "no tabs" "0" "$(grep -c $'\t' "$WORK/out")"
t_eq "no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/out")"

t_section "scoped aliases are byte-identical"
help_text audio volume up help
t_eq "target help verb" "$EXPECTED" "$(cat "$WORK/out")"
help_text audio help volume up
t_eq "target help with a filter" "$EXPECTED" "$(cat "$WORK/out")"
help_text help audio volume up
t_eq "leading help" "$EXPECTED" "$(cat "$WORK/out")"

t_eq "[OPTS] appears once at the end of an option-bearing usage" "1" \
  "$(grep -c '^Usage: .* \[OPTS\]$' "$WORK/out")"

help_text help app toggle
t_not_contains "a no-option command has no [OPTS]" "[OPTS]" "$(head -1 "$WORK/out")"
help_text help audio volume toggle
t_not_contains "a toggle with no options has no [OPTS]" "[OPTS]" "$(head -1 "$WORK/out")"

t_section "no general target page shows argument placeholders"
t_eq "every target root is literal" "0" \
  "$(python3 - "$CLIENT" "$VIBRANIUM_DIR" "$TESTS_SHELL_DIR" <<'PY'
import importlib.util, json, subprocess, sys
from importlib.machinery import SourceFileLoader
client_path, root_dir, tests = sys.argv[1:4]
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', client_path))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
script = r'''
import path from 'node:path'
import { pathToFileURL } from 'node:url'
const [root, tests] = process.argv.slice(1)
const { loadLib } = await import(pathToFileURL(path.join(tests, 'lib/qmlloader.mjs')).href)
const c = loadLib(path.join(root, 'shell/common/text/IpcCatalog.js'))
const p = loadLib(path.join(root, 'shell/common/text/IpcProtocol.js'))
const out = {}
for (const t of c.Manifest.targets) {
  const usages = []
  for (const r of t.rows) {
    if (r.route === 'injected' || r.parentHidden === true || r.helpOnly === true) continue
    usages.push(typeof r.usage === 'string' ? r.usage : p.usage(r.words))
  }
  out[t.id] = usages
}
console.log(JSON.stringify(out))
'''
import json
res = subprocess.run(['node', '-e', script, root_dir, tests],
                     capture_output=True, text=True, check=True)
targets = json.loads(res.stdout)
bad = []
for tid, usages in targets.items():
    desc = {'path': [tid], 'usage': 'vb-shell ' + tid, 'summary': 'A target.',
            'commands': [{'usage': u} for u in usages], 'examples': ['vb-shell ' + tid]}
    text = client.render_descriptor(desc)
    if '<' in text or '[' in text:
        bad.append(tid)
print(len(bad))
PY
)"

t_section "fixed description budget in help tables"
help_text help settings get
t_status "help succeeds" 0 help_text help settings get
t_not_empty "help produced output" "$(cat "$WORK/out")"
t_contains "a long label keeps its own column" \
  "a-very-long-argument-name" "$(cat "$WORK/out")"
t_eq "help descriptions stay within 80 cells from their column" "0" "$(python3 - "$CLIENT" "$WORK/out" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = lines.index('Arguments:') + 1
block = []
for line in lines[start:]:
    if line == '':
        break
    block.append(line)
anchor = next(x for x in block if 'a-very-long-argument-name' in x)
col = client.cells(anchor[:anchor.index('A long description')])
print(sum(1 for line in block if line.strip() and client.cells(line[col:]) > 80))
PY
)"
t_eq "help output has no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/out")"
t_eq "help output ends with one LF" "1" "$(python3 - "$WORK/out" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(1 if b.endswith(b'\n') and not b.endswith(b'\n\n') else 0)
PY
)"

t_section "stdlib cell width with Unicode, CJK and combining marks"
help_text help proof cells
t_status "cell-width help succeeds" 0 help_text help proof cells
t_eq "descriptions share one cell column" "9" "$(python3 - "$CLIENT" "$WORK/out" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
cols = set()
for summary in ('ascii-summary', 'cjk-summary', 'combining-summary', 'emoji-summary'):
    line = next(x for x in open(sys.argv[2], encoding='utf-8') if summary in x)
    cols.add(client.cells(line[:line.index(summary)]))
print(','.join(str(c) for c in sorted(cols)))
PY
)"
t_eq "a combining mark adds no cell to its label" "4" "$(python3 - "$CLIENT" "$WORK/out" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
line = next(x for x in open(sys.argv[2], encoding='utf-8') if 'combining-summary' in x)
label = line[:line.index('combining-summary')].rstrip()
print(client.cells(label))
PY
)"
t_eq "CJK occupies four cells in the label" "4" "$(python3 - "$CLIENT" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
print(client.cells('汉字'))
PY
)"
t_eq "emoji occupies two cells" "2" "$(python3 - "$CLIENT" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
print(client.cells('🙂'))
PY
)"
t_eq "escaped controls are measured, not emitted raw" "2" "$(python3 - "$CLIENT" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
print(client.cells('\t'))
PY
)"

FAKE_QS_MODE=table python3 -B "$CLIENT" state ping >"$WORK/table" 2>"$WORK/err"
t_not_empty "unicode table produced output" "$(cat "$WORK/table")"
t_eq "table separators align by cells" "5" "$(python3 - "$CLIENT" "$WORK/table" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
cols = set()
for line in open(sys.argv[2], encoding='utf-8'):
    if ' | ' in line:
        cols.add(client.cells(line[:line.index(' | ')]))
print(','.join(str(c) for c in sorted(cols)))
PY
)"
t_eq "unicode table has no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/table")"

t_section "root help, index and JSON shapes"
help_text help
t_status "root help succeeds" 0 help_text help
t_eq "root help starts with the guide usage" "Usage: vb-shell [OPTIONS] <target> [command] [args...]" \
  "$(head -1 "$WORK/out")"
t_contains "root help names the common verbs once" "status, ping and help [path...]" "$(cat "$WORK/out")"
t_contains "root help lists a target" "systemUpdates" "$(cat "$WORK/out")"
t_eq "root help describes every child row" "0" "$(python3 - "$WORK/out" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
anchor = next(x for x in block if 'application search' in x)
col = anchor.index('application')
print(sum(1 for line in block if line.strip() and line[:col].strip()
          and not re.match(r'^\s*\S.* {2,}\S.*$', line)))
PY
)"
t_eq "root help separates targets with one blank line" "5" "$(python3 - "$WORK/out" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
while block and not block[-1].strip():
    block.pop()
print(sum(1 for line in block if not line.strip()))
PY
)"

help_text --list
t_status "index succeeds" 0 help_text --list
t_not_contains "no common help row in the index" "  help:" "$(cat "$WORK/out")"
t_not_contains "no common status row in the index" "  status:" "$(cat "$WORK/out")"
t_not_contains "no common ping row in the index" "  ping:" "$(cat "$WORK/out")"
t_eq "index describes every child row" "0" "$(python3 - "$WORK/out" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
anchor = next(x for x in block if 'application search' in x)
col = anchor.index('application')
print(sum(1 for line in block if line.strip() and line[:col].strip()
          and not re.match(r'^\s*\S.* {2,}\S.*$', line)))
PY
)"
t_eq "index has one blank line between groups" "5" "$(python3 - "$WORK/out" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
while block and not block[-1].strip():
    block.pop()
print(sum(1 for line in block if not line.strip()))
PY
)"
t_eq "index shows the nested branch with its description" "fonts reload Rescan installed system fonts" \
  "$(grep -F 'fonts reload' "$WORK/out" | sed -E 's/^[[:space:]]+//; s/  +/ /g' | head -1)"
t_eq "index has no trailing blank line" "1" "$(python3 - "$WORK/out" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(1 if b.endswith(b'\n') and not b.endswith(b'\n\n') else 0)
PY
)"

t_section "the global index keeps only literal signatures"
FAKE_QS_MODE=ok
help_text --list
t_eq "no argument placeholders in the index" "0" \
  "$(python3 - "$WORK/out" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
end = len(lines)
bad = 0
for line in lines[start:end]:
    if not line.startswith('    '):
        continue
    label = re.split(r' {2,}', line.strip(), maxsplit=1)[0]
    if '<' in label or '[' in label:
        bad += 1
print(bad)
PY
)"
t_contains "branch keywords are still shown" "fonts" "$(cat "$WORK/out")"

help_text help audio volume up
t_contains "scoped help still shows its placeholder" "volume up [step <N>]" "$(head -1 "$WORK/out")"

t_section "aligned placeholders in help command tables"
help_text help proof commands
t_eq "help command placeholders share one column" "1" "$(python3 - "$CLIENT" "$WORK/out" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = lines.index('Commands:') + 1
cols = set()
for line in lines[start:]:
    if not line.strip():
        break
    places = [p for p in (line.find('<'), line.find('[')) if p >= 0]
    if places:
        cols.add(client.cells(line[:min(places)]))
print(len(cols))
PY
)"
t_eq "help command tokens are not reflowed" \
  "hold <printer> <jobid>|release <printer> <jobid>|cancel <printer> <jobid>|log [<SCOPE>...]" \
  "$(python3 - "$WORK/out" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Commands:') + 1
want = [('hold', 'Hold a job'), ('release', 'Release a job'),
        ('cancel', 'Cancel a job'), ('log', 'Follow logs by scope')]
out = []
for line in lines[start:]:
    if not line.strip():
        break
    for key, summary in want:
        if summary in line:
            label = line[:line.index(summary)].strip()
            out.append((key, re.sub(r'\s+', ' ', label)))
out.sort(key=lambda pair: [k for k, _ in want].index(pair[0]))
print('|'.join(label for _, label in out))
PY
)"

t_section "leading placeholders are standalone rows"
t_eq "a placeholder-first label stays at the left" "0|1" \
  "$(python3 - "$CLIENT" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
labels = client.align_placeholders(["list", "<ID> status", "reload"])
print(str(labels[1].find("<ID>")) + "|" + str(1 if labels[0].startswith("list ") else 0))
PY
)"

t_section "capitalized help prose, unchanged JSON"
help_text help proof capital
t_eq "descriptor summary is verbatim" "application search, usage and plugins" \
  "$(grep -F 'usage and plugins' "$WORK/out" | head -1)"
t_contains "command summary is verbatim" "open the launcher" "$(cat "$WORK/out")"
t_contains "Notes prose is verbatim" "usage and plugins stay lowercase after the first word" "$(cat "$WORK/out")"
t_contains "argument text is not touched" "lowercase argument text" "$(cat "$WORK/out")"
t_contains "example command is not touched" "vb-shell appLauncher show" "$(cat "$WORK/out")"
help_text --json help proof capital
t_eq "JSON help keeps the raw lowercase prose" "application search, usage and plugins|lowercase argument text" \
  "$(python3 - "$WORK/out" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
print(v['summary'] + '|' + v['arguments'][0]['summary'])
PY
)"

help_text --json help audio volume up
t_eq "JSON help is one value" "1" "$(python3 - "$WORK/out" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
print(1 if v['usage'] == 'vb-shell audio volume up [step <N>] [OPTS]'
      and len(v['examples']) == 2 and len(v['arguments']) == 1 else 0)
PY
)"
help_text --json --help
t_eq "local JSON help is one object" "1" "$(python3 - "$WORK/out" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
print(1 if isinstance(v.get('options'), list) and isinstance(v.get('usage'), list) else 0)
PY
)"

t_section "conventional help and JSON flags"
help_text -h
cp "$WORK/out" "$WORK/h-short"
help_text --help
t_eq "-h and --help are byte-identical" "0" "$(cmp -s "$WORK/h-short" "$WORK/out"; echo $?)"
help_text -j --help
cp "$WORK/out" "$WORK/j-short"
help_text --json --help
t_eq "-j --help and --json --help are byte-identical" "0" "$(cmp -s "$WORK/j-short" "$WORK/out"; echo $?)"
help_text -j help audio volume up
cp "$WORK/out" "$WORK/j-help"
help_text --json help audio volume up
t_eq "-j help and --json help are byte-identical" "0" "$(cmp -s "$WORK/j-help" "$WORK/out"; echo $?)"

t_section "a help-kind data reply uses the same layout"
FAKE_QS_MODE=app-help python3 -B "$CLIENT" app call list audioMixer >"$WORK/out" 2>"$WORK/err"
FAKE_QS_MODE=app-help
t_status "app call list succeeds" 0 python3 -B "$CLIENT" app call list audioMixer
t_eq "the help-kind usage is rendered" "Usage: vb-shell app call audioMixer" "$(head -1 "$WORK/out")"
t_contains "the commands section is present" "Commands:" "$(cat "$WORK/out")"
t_eq "openTab is columnized with its argument" "1" \
  "$(grep -Ec '^  openTab +<TAB>  Open the mixer' "$WORK/out")"
t_contains "selectTab is documented" "selectTab <TAB>" "$(cat "$WORK/out")"
t_contains "the real tab ids are taught" "configuration and graph" "$(cat "$WORK/out")"
t_contains "examples are rendered" "Examples:" "$(cat "$WORK/out")"
t_contains "a concrete openTab example is rendered" \
  "vb-shell app call audioMixer openTab apps" "$(cat "$WORK/out")"
t_not_contains "no raw table header is printed" "Verb | Usage | Description" "$(cat "$WORK/out")"
t_eq "help text has no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/out")"

FAKE_QS_MODE=app-help python3 -B "$CLIENT" --json app call list audioMixer >"$WORK/out" 2>"$WORK/err"
t_eq "JSON mode keeps the descriptor unchanged" \
  "vb-shell app call audioMixer|2|app.call.audioMixer.openTab" \
  "$(python3 - "$WORK/out" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
print(v['usage'] + '|' + str(len(v['commands'])) + '|' + v['commands'][0]['id'])
PY
)"

t_section "Output prose only for raw JSON payload queries"
check_output() {
  local mode="$1" want="$2"
  FAKE_QS_MODE="$mode" python3 -B "$CLIENT" audit >"$WORK/out" 2>"$WORK/err"
  t_status "$mode exits 0" 0 python3 -B "$CLIENT" audit
  t_eq "$mode Output section count" "$want" "$(grep -c '^Output:$' "$WORK/out")"
}
check_output output-value 1
t_contains "value pages keep their summary" "Stored value" "$(cat "$WORK/out")"
check_output output-record 1
t_contains "record pages keep their summary" "Safe current snapshot" "$(cat "$WORK/out")"
check_output output-table 1
t_contains "table pages keep their summary" "Package rows" "$(cat "$WORK/out")"
check_output output-text 0
check_output output-none 0
check_output output-bool 0
check_output output-number 0
check_output output-help 0

t_summary
