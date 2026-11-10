.pragma library

// The busctl invocation shapes the shell reads.
//
// A D-Bus read is one property (`get-property`) or one method (`call`), on
// the system bus by default and the session bus with `--user`. Every call
// site spelled the option order out itself, so the same service, path and
// interface triple was repeated next to a different flag arrangement. These
// builders keep the order the working commands use - `--json=short` after
// the verb, `--user` before it - and leave the reply parsing to the caller.
//
// Pure JS, no Qt imports: the builders are unit-drivable and a caller can
// hand the result straight to CommandSpec.argv.

// `busctl get-property --json=short <service> <path> <interface> <property>`.
function getPropertyArgv(service, path, iface, prop) {
  return ["busctl", "get-property", "--json=short",
    String(service), String(path), String(iface), String(prop)]
}

// `busctl call --json=short <service> <path> <interface> <method> [args...]`.
function callArgv(service, path, iface, method, args) {
  return appendArgs(["busctl", "call", "--json=short",
    String(service), String(path), String(iface), String(method)], args)
}

// `busctl --user call <service> <path> <interface> <method> [args...]`.
function userCallArgv(service, path, iface, method, args) {
  return appendArgs(["busctl", "--user", "call",
    String(service), String(path), String(iface), String(method)], args)
}

// Method arguments are data: each is appended as its own argv element, in
// the order the signature expects. A missing list is a call with no
// arguments rather than a malformed command.
function appendArgs(argv, args) {
  if (!Array.isArray(args)) return argv
  for (let i = 0; i < args.length; i++) argv.push(String(args[i]))
  return argv
}
