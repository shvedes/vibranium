#######################################################
#                       Vibranium                     #
#######################################################

alias vibranium-healthcheck "vb-cmd-healthcheck"
alias omarchy-theme-install "vb-theme-install"

alias imv "imv-dir"

#######################################################
#                       General                       #
#######################################################

# Since wget doesn't have special environment variables to store
# options in, we will force it to comply with XDG Base Directory via CLI.
set -l xdg_data $XDG_DATA_HOME
test -n "$xdg_data"; or set xdg_data "$HOME/.local/share"
alias wget "wget --hsts-file=$xdg_data/wget/wget-hsts"
set -e xdg_data

if command -v nvim > /dev/null
    alias v "nvim"
else if command -v vim > /dev/null
    alias v "vim"
end

#######################################################
# GNU ls & eza (https://github.com/eza-community/eza) #
#######################################################

# Store shared CLI options to save line width.
set -l opts "--color=auto --hyperlink=auto"

if command -v eza > /dev/null
    set opts "$opts --group-directories-first"

    alias l "eza $opts"
    alias ls "eza $opts"
    alias la "eza -Ahbg $opts"
    alias laa "eza -ahbg $opts"

    alias ll "eza -lhbg $opts"
    alias lla "eza -Alhbg $opts"
    alias llaa "eza -aalhbg $opts"
    alias tree "eza --tree $opts"

else
    alias l "ls $opts"
    alias ls "ls $opts"
    alias la "ls --almost-all $opts"
    alias laa "ls --all $opts"

    alias ll "ls -lhp $opts"
    alias lla "ls -Alhp $opts"
    alias llaa "ls -alhp $opts"
end

# Cleanup. Don't let it go to your shell.
set -e opts

#######################################################
# cd & zoxide (https://github.com/ajeetdsouza/zoxide) #
#######################################################

# Parent-directory shortcuts
alias .. "cd .."
alias ... "cd ../.."
alias .... "cd ../../.."
alias ..... "cd ../../../.."

if command -v zoxide > /dev/null
    alias zq "zoxide query"
    alias zz "zoxide query"
    alias za "zoxide add"
    alias zr "zoxide remove"
    alias zrm "zoxide remove"
end

###############################################################
# rm & trash-cli (https://github.com/andreafrancia/trash-cli) #
###############################################################

if command -v trash > /dev/null
    alias rm "trash -v"
end
