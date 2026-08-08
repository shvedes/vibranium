
#######################################################
#                       Vibranium                     #
#######################################################

alias vibranium-healthcheck="vb-cmd-healthcheck"
alias omarchy-theme-install="vb-theme-install"

alias imv="imv-dir"

#######################################################
#                       General                       #
#######################################################

# Since wget doesn't have special environment variables to store
# options in, we will force it to comply with XDG Base Directory via CLI.
alias wget="wget --hsts-file=\${XDG_DATA_HOME:-$HOME/.local/share}/wget/wget-hsts"

if command -v nvim > /dev/null; then
  alias v="nvim"
elif command -v vim > /dev/null; then
  alias v="vim"
fi

#######################################################
# GNU ls & eza (https://github.com/eza-community/eza) #
#######################################################

# Store shared CLI options to save line width.
opts="--color=auto --hyperlink=auto"

if command -v eza > /dev/null; then
  opts+=" --group-directories-first"

  alias l="eza $opts"
  alias ls="eza $opts"
  alias la="eza -Ahbg@ $opts"
  alias laa="eza -ahbg@ $opts"

  alias ll="eza -lhbg@ $opts"
  alias lla="eza -Alhbg@ $opts"
  alias llaa="eza -aalhbg@ $opts"
  alias tree="eza --tree $opts"

else
  alias l="ls $opts"
  alias ls="ls $opts"
  alias la="ls --almost-all $opts"
  alias laa="ls --all $opts"

  alias ll="ls -lhp $opts"
  alias lla="ls -Alhp $opts"
  alias llaa="ls -alhp $opts"
fi

# Typos
alias sl=ls

# Cleanup. Don't let it go to your shell.
unset opts

#######################################################
# cd & zoxide (https://github.com/ajeetdsouza/zoxide) #
#######################################################

# Typos
alias dc=cd
alias cd..='cd ..'
alias cd...='cd ../..'
alias cd....='cd ../../..'

# Parent-directory shortcuts
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

if command -v zoxide > /dev/null; then
  alias zq="zoxide query"
  alias zz="zoxide query"
  alias za="zoxide add"
  alias zr="zoxide remove"
  alias zrm="zoxide remove"
fi

###############################################################
# rm & trash-cli (https://github.com/andreafrancia/trash-cli) #
###############################################################

if command -v trash > /dev/null; then
  alias rm="trash -v"
fi

#######################################################
#                   General typos                     #
#######################################################

# clear
alias clearr="clear"
alias cleart="clear"
alias clera="clear"
alias clea="clear"

# exit (or just use ^D)
alias exti="exit"
alias exti="exit"

# sudo
alias sudp="sudo"
alias suod="sudo"
alias sduo="sudo"

# mkdir
alias mkidr="mkdir"

# grep
alias grpe="grep"
alias gerp="grep"

# pacman
alias pacamn="pacman"
alias apcman="pacman"

# git
alias gti="git"
alias gi="git"
alias gt="git"
alias gtiu="git"
alias gut="git"

# docker
alias dokcer="docker"
alias dockr="docker"
alias dockre="docker"

# podman
alias podamn="podman"
alias pdoman="podman"

# kubernetes
alias kubecrl="kubectl"
alias kubelt="kubectl"

# curl
alias crul="curl"
alias clur="curl"

# nginx
alias ngix="nginx"
alias nginix="nginx"

# ffmpeg
alias ffmepg="ffmpeg"
alias fmpeg="ffmpeg"
