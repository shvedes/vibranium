#!/bin/bash
# Shared paths and the platform gate for the shell test suite.
#
# Sourced by every suite. Defines where the shell tree is, where the suite
# root is, and the two functions used to decide whether a suite can run at
# all on the current machine.

# Root of the Vibranium checkout, derived from this file's location:
# tests/shell/lib/lib.sh -> ../../..
SHELL_TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_SHELL_DIR="$(dirname "$SHELL_TEST_LIB_DIR")"
TESTS_DIR="$(dirname "$TESTS_SHELL_DIR")"
VIBRANIUM_DIR="$(dirname "$TESTS_DIR")"
SHELL_DIR="$VIBRANIUM_DIR/shell"

# The pinned platform, from shell/README.md. A different pair is a platform
# gate failure, not a silent "probably fine": the suites below assert on
# behaviour that was written against this exact Quickshell and Qt.
REQUIRED_QUICKSHELL_VERSION="0.3.2"
REQUIRED_QT_VERSION="6.12.0"

QMLLINT_BIN="${QMLLINT_BIN:-/usr/lib/qt6/bin/qmllint}"

# quickshell_version prints the version string of the qs on PATH, or nothing.
quickshell_version() {
  qs --version 2>/dev/null | awk 'NR==1 { print $2 }'
}

# qt_version prints the Qt version qmllint reports, or nothing.
qt_version() {
  "$QMLLINT_BIN" --version 2>/dev/null | awk '{ print $2 }'
}

# platform_mismatch prints a human reason when the host is not the pinned
# platform, and returns 0. Returns 1 with no output when the gate passes.
platform_mismatch() {
  local qs_ver qt_ver
  qs_ver="$(quickshell_version)"
  qt_ver="$(qt_version)"

  if [[ -z $qs_ver ]]; then
    printf 'qs is not on PATH\n'
    return 0
  fi
  if [[ $qs_ver != "$REQUIRED_QUICKSHELL_VERSION" ]]; then
    printf 'quickshell %s, suite pins %s\n' "$qs_ver" "$REQUIRED_QUICKSHELL_VERSION"
    return 0
  fi
  if [[ -z $qt_ver ]]; then
    printf 'qmllint not found at %s\n' "$QMLLINT_BIN"
    return 0
  fi
  if [[ $qt_ver != "$REQUIRED_QT_VERSION" ]]; then
    printf 'qt %s, suite pins %s\n' "$qt_ver" "$REQUIRED_QT_VERSION"
    return 0
  fi
  return 1
}

# require_platform prints the pinned versions on stdout. Suites that need a
# live Quickshell call this first and exit 77 (see harness.sh BLOCKED) when
# the gate fails, so an unrunnable suite is never reported as a pass.
require_platform() {
  local reason
  if reason="$(platform_mismatch)"; then
    printf 'BLOCKED: %s (suite pins quickshell %s / qt %s)\n' \
      "$reason" "$REQUIRED_QUICKSHELL_VERSION" "$REQUIRED_QT_VERSION"
    exit 77
  fi
}

# require_tools fails loudly when a suite needs a binary that is absent, but
# does not treat it as a behavioural failure.
require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'BLOCKED: %s is not on PATH\n' "$tool"
      exit 77
    fi
  done
}

# Every .qml under the shell tree, sorted, so two suites agree on file order.
shell_qml_files() {
  find "$SHELL_DIR" -name '*.qml' -type f | sort
}

# Every .js under the shell tree, sorted.
shell_js_files() {
  find "$SHELL_DIR" -name '*.js' -type f | sort
}

# Every qmldir under the shell tree, sorted.
shell_qmldir_files() {
  find "$SHELL_DIR" -name 'qmldir' -type f | sort
}

# rel_to_shell turns an absolute path into a shell-relative one for readable
# diagnostics. Paths outside the tree are printed absolute.
rel_to_shell() {
  local p="$1"
  if [[ $p == "$SHELL_DIR"/* ]]; then
    printf '%s' "${p#"$SHELL_DIR"/}"
  else
    printf '%s' "$p"
  fi
}
