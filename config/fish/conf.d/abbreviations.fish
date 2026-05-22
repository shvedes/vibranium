if command -q fastfetch
    abbr neofetch fastfetch
    abbr nf fastfetch
    abbr ff fastfetch
end

if not command -q nmtui
    abbr restart-network "sudo systemctl restart iwd systemd-{network,resolve}d"
end

abbr restart-pipewire "systemctl --user restart pipewire pipewire-pulse wireplumber"

# Systemd abbrs. Think of it like this:
# <s>ystem<c>tl --<u>ser <s>tatus
abbr --position command se sudoedit
abbr --position command sc systemctl
abbr --position command scs "systemctl status"
abbr --position command scu "systemctl --user"
abbr --position command scus "systemctl --user status"

# Vim time :D
abbr \:q exit

# Most common typos
###################

# ls
abbr l ls
abbr sl ls
abbr lss ls

# cd
abbr dc cd
abbr cdd cd
abbr cd.. "cd .."
abbr .. "cd .."
abbr ... "cd ../.."
abbr .... "cd ../../.."

# git
abbr gti git
abbr gi git
abbr gt git
abbr gtiu git
abbr gut git

# sudo
abbr sudp sudo
abbr suod sudo
abbr sduo sudo

# pacman
abbr pacamn pacman
abbr apcman pacman

# misc
abbr cleart clear
abbr clera clear
abbr clea clear
abbr exti exit
abbr exti exit
abbr mkidr mkdir

abbr grpe grep
abbr gerp grep
