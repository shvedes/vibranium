#!/bin/bash
# Suite: the generated bar and demand handler types construct inertly.
#
# A-5: both types sit on Boot's eager import path. Each owns an authored hook
# that calls Boot only from function bodies, but the generated type must not
# load that hook component while Boot constructs the handler object. The
# regression is a URL component creation in a QML property initializer: it is
# a new synchronous load edge even when no hook method ever runs.
#
# Static parts (import closure, no hook reference outside a function body) are
# covered by tests/shell/suites/js/unit-generation.test.mjs. This suite proves
# the dynamic half in a live engine: before the first handler call both hook
# properties are still null and the injected Boot stub has seen zero calls;
# after the first call the real hook file has been loaded, cached, and driven
# through the generated handler API.
#
# The generated files and their hook files are copied verbatim into a real
# directory inside the probe mirror. Quickshell's QML scanner does not follow
# a symlinked directory import, while the harness mirrors `shell` as a
# symlink, so a plain `import "shell/boot/generated/bar"` cannot see them.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "generated-hook-inertness" "bar/demand generated types: no hook load until a handler is called"

require_qs
trap qp_teardown EXIT

_QP_CFG="$(qp_setup)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-hook-inertness.XXXXXX")"
trap 'rm -rf "$WORK"; qp_teardown' EXIT

# A real (non-symlinked) tree for the directory imports, holding only the two
# generated types and the two authored hooks they load by relative URL.
TREE="$_QP_CFG/generated-probe"
mkdir -p "$TREE/boot/generated/bar" "$TREE/boot/generated/demand"
cp "$SHELL_DIR/boot/generated/bar/BarHandlers.qml" "$TREE/boot/generated/bar/"
cp "$SHELL_DIR/boot/generated/demand/DemandHandlers.qml" "$TREE/boot/generated/demand/"
cp "$SHELL_DIR/boot/BarUnitHooks.qml" "$SHELL_DIR/boot/AnnotationsUnitHooks.qml" "$TREE/boot/"

cat >"$WORK/probe.qml" <<'QML'
import QtQml
import "generated-probe/boot/generated/bar" as GeneratedBar
import "generated-probe/boot/generated/demand" as GeneratedDemand

QtObject {
  id: root

  property int calls: 0
  property string trace: ""
  property var barHookRef: null
  property var demandHookRef: null

  // Stands in for Boot. The real hooks call these methods; a hook object
  // loaded too early would make a call here before any handler was invoked.
  property var bootStub: QtObject {
    function _mountBarRuntime() { root.calls++; root.trace += "mount,"; return "bar-resolved" }
    // The authored bar hook checks this bridge's presence rather than calling
    // it, so a correct readiness call leaves no trace here.
    function _barRuntimeItem() { return true }
    function _unmountBarRuntime() { root.calls++; root.trace += "unmount," }
    function _activateAnnotations() { root.calls++; root.trace += "activate," }
    function _annotationsReady() { root.calls++; root.trace += "annReady,"; return true }
    function _teardownAnnotations() { root.calls++; root.trace += "annTeardown," }
  }

  // These two constructions are the eager path under test: nothing in either
  // component's property initializer may load a hook URL or touch Boot.
  property var bar: GeneratedBar.BarHandlers { boot: root.bootStub }
  property var demand: GeneratedDemand.DemandHandlers { boot: root.bootStub }

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  Component.onCompleted: {
    kv("construct.barHookNull", root.bar.barHooks === null)
    kv("construct.demandHookNull", root.demand.annotationsHooks === null)
    kv("construct.bootCalls", root.calls)
    kv("construct.trace", root.trace)

    // First use: the hook component is loaded here and only here.
    kv("resolve.bar", root.bar.handlers.bar.resolve())
    root.barHookRef = root.bar.barHooks
    kv("resolve.barHookCreated", root.bar.barHooks !== null)
    kv("resolve.bootCalls", root.calls)
    kv("resolve.trace", root.trace)

    kv("ready.bar", root.bar.handlers.bar.ready())
    root.bar.handlers.bar.teardown()
    kv("bar.hookCached", root.bar.barHooks === root.barHookRef)
    kv("bar.trace", root.trace)

    // Demand starts equally inert, then loads its own hook on first use.
    root.demand.handlers.annotations.resolve()
    root.demandHookRef = root.demand.annotationsHooks
    kv("resolve.demandHookCreated", root.demand.annotationsHooks !== null)
    kv("ready.demand", root.demand.handlers.annotations.ready())
    root.demand.handlers.annotations.teardown()
    kv("demand.hookCached", root.demand.annotationsHooks === root.demandHookRef)
    kv("demand.trace", root.trace)
    kv("final.bootCalls", root.calls)
    console.log("##DONE##")
  }
}
QML

if ! qp_run "$WORK/probe.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "construction is inert"
t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
t_eq "bar's hook is still null after construction" "true" "$(qp_get construct.barHookNull)"
t_eq "demand's hook is still null after construction" "true" "$(qp_get construct.demandHookNull)"
t_eq "no Boot call happened during construction" "0" "$(qp_get construct.bootCalls)"
t_eq "no hook side effect happened during construction" "" "$(qp_get construct.trace)"

t_section "first use loads and caches the hook"
t_eq "bar resolve still returns through its hook" "bar-resolved" "$(qp_get resolve.bar)"
t_eq "bar's hook exists after first resolve" "true" "$(qp_get resolve.barHookCreated)"
t_eq "bar resolve made exactly one Boot call" "1" "$(qp_get resolve.bootCalls)"
t_eq "bar resolve called only the mount bridge" "mount," "$(qp_get resolve.trace)"
t_eq "bar readiness still goes through its hook" "true" "$(qp_get ready.bar)"
t_eq "bar's hook was not re-created by ready/teardown" "true" "$(qp_get bar.hookCached)"
t_eq "bar's full hook trace is unchanged" "mount,unmount," "$(qp_get bar.trace)"

t_eq "demand's hook exists after first resolve" "true" "$(qp_get resolve.demandHookCreated)"
t_eq "demand readiness still goes through its hook" "true" "$(qp_get ready.demand)"
t_eq "demand's hook was not re-created by ready/teardown" "true" "$(qp_get demand.hookCached)"
t_eq "demand's full hook trace is unchanged" \
  "mount,unmount,activate,annReady,annTeardown," "$(qp_get demand.trace)"
t_eq "both hooks together made five Boot calls" "5" "$(qp_get final.bootCalls)"

t_summary
