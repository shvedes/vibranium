#!/usr/bin/env bash

RED=$'\e[0;31m'
YELLOW=$'\e[0;33m'
BLUE=$'\e[0;34m'
PURPLE=$'\e[0;35m'
GREEN=$'\e[0;32m'
CYAN=$'\e[0;36m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

VIBRANIUM="$HOME/.local/share/vibranium"

_show_logo() {
    printf "\n%s%s%s\n\n" "$YELLOW" "$(< "$VIBRANIUM/logo.txt")" "$RESET"
}

_is_installed() {
    pacman -Qq "$1" &> /dev/null
}

_log_info() {
    echo -e "${YELLOW}[VIBRANIUM]${RESET} ${*}"
}

_log_success() {
    echo -e "${GREEN}[VIBRANIUM]${RESET} ${*}"
}

_log_error() {
    echo -e "${RED}[VIBRANIUM]${RESET} ${*}"
}

_install_yay() {
    local tmp_dir="/tmp/yay"

    sudo pacman -Suy --noconfirm &> /dev/null

    if ! _is_installed "base-devel"; then
        sudo pacman --noconfirm -S base-devel &> /dev/null
    fi

    if [[ -d $tmp_dir ]]; then
        rm -rf $tmp_dir
    fi

    git clone -q "https://aur.archlinux.org/yay.git" $tmp_dir
    cd $tmp_dir

    if ! makepkg -sirc --noconfirm &> /dev/null; then
        cd $HOME; rm -rf $tmp_dir
        return 1
    fi

    cd $HOME; rm -rf $tmp_dir
}

_install_packages() {
    local packages=("$@")
    local total=${#packages[@]}
    local current=0
    local pkg

    _log_info "Refreshing repositories"
    yay --noconfirm -Sy &> /dev/null

    for pkg in "${packages[@]}"; do
        [[ -z $pkg || $pkg == \#* ]] && continue

        ((current++))

        printf "\r\033[K%s[VIBRANIUM]%s Installing %s [%d/%d]" \
          "$YELLOW" "$RESET" "${GRAY}${pkg}${RESET}" "$current" "$total"

        yay --noconfirm --needed -S "$pkg" &> /dev/null
    done

    printf "\n"
}

_ask_yes_no() {
    local default="${1:-Y}"
    local message="$2"
    local input prompt hint

    default="${default^^}"

    # Set hint based on default
    case "$default" in
        Y) hint="(Y/n)" ;;
        N) hint="(y/N)" ;;
        *) hint="(Y/n)"; default="Y" ;;
    esac

    while true; do
        # Show cursor
        printf '\e[?25h'

        prompt=$'\e[0;33m[VIBRANIUM]\e[0m '"${message} ${hint}: "

        printf "%s" "$prompt"
        read -r input

        # Use default if empty
        [[ -z "$input" ]] && input="$default"

        case "$input" in
            [Yy][Ee][Ss]|[Yy])
                # Hide cursor before returning
                printf '\e[?25l'
                return 0
                ;;
            [Nn][Oo]|[Nn])
                # Hide cursor before returning
                printf '\e[?25l'
                return 1
                ;;
            *)
                # Clear line and retry
                printf "\r\e[K"
                ;;
        esac
    done
}

