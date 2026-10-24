#!/usr/bin/env node
// CLI over shell/common/settings/HyprlandEditor.js -- the out-of-process entry
// point for Hyprland's text config. It is what lets tools that are neither
// Quickshell nor Node-hosted programs read and write a single
// hl.config/hl.monitor value; the shell's QML stack (HyprlandSettings.qml)
// runs the same editor in-process instead.
//
// Every run writes exactly one line to stdout: the resolved config path on
// success, or "err: <message>" on failure. That line is the whole result
// contract, because a caller in Hyprland's config VM cannot observe a child
// exit status -- os.execute and io.popen both fail to wait on a child there and
// return ECHILD regardless of what the child did -- so it reads this line.
// Empty output means the command itself never ran.
//
// Usage:
//   HyprlandEditorCli.js get <path> <file> [options]
//   HyprlandEditorCli.js set <path> <value> <file> [options]
//
// <path> is colon-separated ("general:border_size"); a "name@N" component
// selects the Nth match, counting from the end when negative. <value> is typed
// as a boolean, a number, or a string.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

// HyprlandEditor.js is a QML library, so its .pragma library line is not valid
// Node syntax. Evaluating it in a vm context keeps one implementation shared by
// both hosts instead of a second copy of the parser. Quickshell.env is shimmed
// because the library reads the environment through it, and the shell engine
// exposes no host globals inside a .pragma library file.
const libPath = path.join(__dirname, "HyprlandEditor.js");
const ctx = {
  console,
  require,
  process,
  Quickshell: { env: (k) => process.env[k] || "" },
};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(libPath, "utf8").replace(/^\.pragma library.*\n/m, ""), ctx);

function usage(code) {
  const me = path.basename(process.argv[1]);
  process.stderr.write(
    `Usage:
  ${me} get <path> <file> [options]
  ${me} set <path> <value> <file> [options]

Arguments:
  <path>    colon-separated option path, e.g. general:border_size
  <value>   boolean, number or string; only valid with "set"
  <file>    config file to read or rewrite

Options:
  --scope <config|monitor>   root the path at an hl.config or hl.monitor block
                             (default: config)
  --output <name>            monitor block to select; required for monitor scope
  --occurrence <n>           select the nth match instead of the first
  -h, --help                 display this help and exit
`
  );
  process.exit(code);
}

// splitPath, parseComponent and inferType come from the library so the CLI and
// any in-process caller type and split arguments identically.
function fail(message) {
  process.stdout.write(`err: ${message}\n`);
  process.exit(1);
}

const argv = process.argv.slice(2);
if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") usage(argv.length === 0 ? 1 : 0);

const mode = argv[0];
if (mode !== "get" && mode !== "set") fail(`unknown mode '${mode}', expected 'get' or 'set'`);

const opts = { scope: "config" };
const positional = [];
for (let i = 1; i < argv.length; i++) {
  const arg = argv[i];
  if (!arg.startsWith("--")) {
    positional.push(arg);
    continue;
  }
  // Every option is a two-token flag, so a missing operand is a usage error
  // rather than a silently absent value.
  if (i + 1 >= argv.length) fail(`${arg} requires an argument`);
  const operand = argv[++i];
  if (arg === "--scope") {
    if (operand !== "config" && operand !== "monitor") fail(`invalid scope '${operand}'`);
    opts.scope = operand;
  } else if (arg === "--output") {
    opts.output = operand;
  } else if (arg === "--occurrence") {
    if (!/^-?\d+$/.test(operand)) fail(`--occurrence requires an integer, got '${operand}'`);
    opts.occurrence = parseInt(operand, 10);
  } else {
    fail(`unknown option '${arg}'`);
  }
}

// "set" carries one extra operand, the value between the path and the file.
const operands = mode === "get" ? 2 : 3;
if (positional.length !== operands) usage(1);

const rawPath = positional[0];
const rawValue = mode === "set" ? positional[1] : undefined;
const file = positional[operands - 1];

// A "name@N" component selects one of several identically named sections or
// monitor blocks; the last such component in the path wins, and an explicit
// --occurrence only applies when the path names none.
const components = ctx.splitPath(rawPath);
if (components.length === 0 || (components.length === 1 && components[0] === "")) {
  fail("empty path");
}
const optionPath = [];
for (let i = 0; i < components.length; i++) {
  const { name, occ } = ctx.parseComponent(components[i]);
  if (occ !== null) opts.occurrence = occ;
  optionPath.push(name);
}

if (opts.scope === "monitor" && opts.output === undefined) {
  fail("--output is required when --scope is monitor");
}

const resolved = ctx.expand_path(file);
let content = "";
try {
  content = fs.readFileSync(resolved, "utf8");
} catch (e) {
  // A missing file reads as empty and is created on write, matching the
  // library's own read_lines contract.
  content = "";
}

if (mode === "get") {
  const res = ctx.hyprGetContent(content, optionPath, opts);
  if (!res.ok) fail(res.error);
  process.stdout.write(`${String(res.value)}\n`);
  process.exit(0);
}

const res = ctx.hyprEditContent(content, optionPath, ctx.inferType(rawValue), opts);
if (!res.ok) fail(res.error);
// The write stays in place rather than going through a temp file and a rename:
// a config file can be a symlink into the default set, and replacing it with a
// regular file would silently break the symlink contract the theme and
// animation presets are built on.
try {
  fs.writeFileSync(resolved, res.content, "utf8");
} catch (e) {
  fail(String(e && e.message ? e.message : e));
}
process.stdout.write(`${resolved}\n`);
