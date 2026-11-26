#!/bin/bash
# shellcheck disable=SC2034  # globals are consumed by functions sourced below
# Suite: vb-pkg-remove systemd unit prompts.
# Drives the real _disable_systemd_units with stubbed prompts and systemctl so
# the "all" answer is checked without touching a package manager or a service.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "vb-pkg-remove" "systemd unit prompts, especially the sticky all answer"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-pkg-remove.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Pull the function definitions from the real script. Everything from the
# SUDO_PROMPT assignment down is top-level work (argument parsing and main).
sed -e '/^source vb-lib-/d' \
    -e '/^printf -v SUDO_PROMPT/,$d' \
    "$VIBRANIUM_DIR/bin/vb-pkg-remove" > "$WORK/functions.sh"

log() { :; }
B=""; G=""; RS=""
term::enable_input() { :; }
term::disable_input() { :; }

vb::print() {
  printf '%s\n' "${*: -1}" >> "$WORK/messages"
}

# Simulated keyboard: one queued answer per prompt. Deliberately uses a
# distinct local name, since printf -v writes into the caller's scope.
FAKE_ANSWERS=()
PROMPTS=()
term::prompt_line() {
  local _var="$1" _prompt="$2" _reply
  printf '%s\n' "$_prompt" >> "$WORK/prompts"
  PROMPTS+=("$_prompt")
  _reply="${FAKE_ANSWERS[0]:-}"
  FAKE_ANSWERS=("${FAKE_ANSWERS[@]:1}")
  printf -v "$_var" '%s' "$_reply"
}

systemctl() {
  printf '%s\n' "$*" >> "$WORK/disabled"
}
sudo() {
  if [[ $1 == systemctl ]]; then
    shift
    systemctl "$@"
  fi
}

source "$WORK/functions.sh"

reset_case() {
  : > "$WORK/prompts"
  : > "$WORK/messages"
  : > "$WORK/disabled"
  FAKE_ANSWERS=("$@")
  PROMPTS=()
  usr_enb_units=()
  sys_enb_units=()
  declare -gA unit_pkg_user=()
  declare -gA unit_pkg_system=()
}

disabled_count() {
  wc -l < "$WORK/disabled" | tr -d ' '
}

prompt_count() {
  wc -l < "$WORK/prompts" | tr -d ' '
}

# ---------------------------------------------------------------------------
t_section "all covers every scope, not just the scope that prompted"

reset_case all
usr_enb_units=(flatpak-oci-authenticator.service)
sys_enb_units=(flatpak-system-helper.service)
unit_pkg_user["flatpak-oci-authenticator.service"]=flatpak
unit_pkg_system["flatpak-system-helper.service"]=flatpak

_disable_systemd_units

t_eq "a single all asks only once" "1" "$(prompt_count)"
t_eq "both units are disabled" "2" "$(disabled_count)"
t_contains "the user unit was disabled" "flatpak-oci-authenticator.service" "$(cat "$WORK/disabled")"
t_contains "the system unit was disabled" "flatpak-system-helper.service" "$(cat "$WORK/disabled")"
t_eq "the all notice is printed once" "1" "$(wc -l < "$WORK/messages" | tr -d ' ')"

# ---------------------------------------------------------------------------
t_section "all also covers later packages and multiple units"

reset_case all
usr_enb_units=(one-user.service two-user.service)
sys_enb_units=(one-system.service)
unit_pkg_user["one-user.service"]=alpha
unit_pkg_user["two-user.service"]=beta
unit_pkg_system["one-system.service"]=alpha

_disable_systemd_units

t_eq "still a single prompt" "1" "$(prompt_count)"
t_eq "all three units are disabled" "3" "$(disabled_count)"

# ---------------------------------------------------------------------------
t_section "all chosen in the second scope stops there"

reset_case y all
usr_enb_units=(first-user.service)
sys_enb_units=(first-system.service second-system.service)
unit_pkg_user["first-user.service"]=flatpak
unit_pkg_system["first-system.service"]=flatpak
unit_pkg_system["second-system.service"]=flatpak

_disable_systemd_units

t_eq "only two prompts were needed" "2" "$(prompt_count)"
t_eq "all three units are disabled" "3" "$(disabled_count)"
t_eq "the all notice is printed once" "1" "$(wc -l < "$WORK/messages" | tr -d ' ')"

# ---------------------------------------------------------------------------
t_section "yes and no keep their per-unit behavior"

reset_case y n
usr_enb_units=(first-user.service)
sys_enb_units=(first-system.service)
unit_pkg_user["first-user.service"]=flatpak
unit_pkg_system["first-system.service"]=flatpak

_disable_systemd_units

t_eq "each unit gets its own prompt" "2" "$(prompt_count)"
t_eq "only the yes unit is disabled" "1" "$(disabled_count)"
t_contains "the yes unit was disabled" "first-user.service" "$(cat "$WORK/disabled")"
t_not_contains "the no unit was left alone" "first-system.service" "$(cat "$WORK/disabled")"
t_eq "no all notice was printed" "0" "$(wc -l < "$WORK/messages" | tr -d ' ')"

t_summary
