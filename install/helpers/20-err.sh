#!/bin/bash
# Written by helpers::prompt_err_action; read immediately after it returns.
# Valid values: "retry", "skip", "abort".
# Must never be read from a subshell -- callers must invoke helpers::prompt_err_action
# as a plain function call, not via $(...), so the assignment is visible here.
_LAST_ERROR_ACTION=""

helpers::abort_install() {
    _INSTALL_COMPLETE=aborted
    exit 1
}

# Prompt the user for how to handle a failed step and set _LAST_ERROR_ACTION.
# MUST be called as a plain function, never inside $(...): it calls
# term::enable_input / term::disable_input which affect the live TTY, and
# the _LAST_ERROR_ACTION assignment must reach the caller's shell.
helpers::prompt_err_action() {
    local phase="$1"
    local script="$2"
    local exit_code="$3"
    local choice

    printf '[%(%H:%M:%S)T] FAILED phase=%s script=%s exit=%d\n' -1 \
        "$phase" "$script" "$exit_code" >> "$_LOG_FILE" 2>/dev/null

    helpers::log::error "Script '${script}' failed in phase '${phase}' (exit ${exit_code})"
    helpers::log::warn  "Full output is in ${_LOG_FILE}"

    term::enable_input
    while true; do
        printf '%s[FAIL]%s [R]etry  [S]kip  [A]bort: %s' "$RED" "$RESET" "$YELLOW"
        read -r choice; printf '%s' "$RESET"

        case "${choice,,}" in
            r|retry)
                _LAST_ERROR_ACTION=retry
                break
                ;;
            s|skip)
                _LAST_ERROR_ACTION=skip
                break
                ;;
            a|abort)
                _LAST_ERROR_ACTION=abort
                break
                ;;
            *)
                printf '%s[FAIL]%s Please enter R, S, or A.\n' "$RED" "$RESET"
                ;;
        esac
    done
    term::disable_input
}

# Run a single .sh file as a named step within a phase.
# The script's stdout+stderr are tee'd to $helpers::log::FILE so the output is
# available on the terminal and persisted for post-mortem inspection.
# On non-zero exit the user is offered retry / skip / abort.
helpers::run_step() {
    local phase="$1"
    local script="$2"
    local script_name exit_code
    script_name="${script##*/}"

    printf '\n[%(%H:%M:%S)T] START phase="%s" script="%s"\n' -1 \
     "$phase" "$script_name" >> "$_LOG_FILE" 2>/dev/null

    while true; do
        # Capture output to the log while keeping it visible on the terminal.
        # PIPESTATUS[0] is the exit code of bash itself, not of tee.
        if [[ -n "${_LOG_FILE:-}" ]]; then
        # Strip all ANSI escape characters before writing to the log file.
        # Keep the log  readable.
            bash "$script" 2>&1 | tee >(
                local esc=$'\x1b'
                shopt -s extglob
                while IFS= read -r line || [[ -n "$line" ]]; do
                    line="${line//${esc}\[*([0-9;])[A-Za-z]/}"
                    line="${line//$'\r'/}"
                    printf '%s\n' "$line"
                done >> "$_LOG_FILE"
            )
            exit_code="${PIPESTATUS[0]}"
        else
            bash "$script"
            exit_code=$?
        fi

        # Restore non-interactive TTY state regardless of how the child exited.
        # A child that failed mid-prompt may have left echo enabled.
        term::disable_input

        printf '[%(%H:%M:%S)T] END   phase="%s" script="%s" exit=%d\n' -1 \
          "$phase" "$script_name" "$exit_code" >> "$_LOG_FILE" 2>/dev/null

        ((exit_code == 0)) && return 0

        helpers::prompt_err_action "$phase" "$script_name" "$exit_code"

        case "$_LAST_ERROR_ACTION" in
            retry)
                helpers::log::info "Retrying ${script_name}..."
                printf '[%(%H:%M:%S)T] RETRY %s\n' -1 "$script_name" >> "$_LOG_FILE" 2>/dev/null
                ;;
            skip)
                helpers::log::warn "Skipped: ${script_name}"
                printf '[%(%H:%M:%S)T] SKIP  %s\n' -1 "$script_name" >> "$_LOG_FILE" 2>/dev/null
                return 0
                ;;
            abort)
                printf '[%(%H:%M:%S)T] ABORT at %s\n' -1 "$script_name" >> "$_LOG_FILE" 2>/dev/null
                helpers::abort_install
                ;;
        esac
    done
}

# Run all .sh files in $2 in glob order as steps belonging to phase $1.
helpers::run_phase() {
    local phase_name="$1"
    local phase_dir="$2"
    local script

    if [[ ! -d "$phase_dir" ]]; then
        helpers::log::warn "Phase directory not found, skipping: ${phase_dir}"
        return 0
    fi

    helpers::log::phase "${phase_name}"
    printf '\n=== PHASE: %s ===\n' "$phase_name" >> "$_LOG_FILE" 2>/dev/null

    for script in "$phase_dir"/*.sh; do
        [[ -f "$script" ]] || continue
        helpers::run_step "$phase_name" "$script"
    done
}
